# scripts/odds_ingest.R
# The Odds API ingestion layer
#
# Handles:
#   - API key rotation across 10 keys (tracks remaining quota per key)
#   - Odds snapshots at Open / Midday / Lock windows
#   - Writing line snapshots to SQLite
#   - Steam detection: flags rapid cross-book line movement

library(httr2)
library(dplyr)
library(purrr)
library(jsonlite)
library(DBI)
library(RSQLite)
library(lubridate)

DB_PATH      <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"
CREDS_PATH   <- here::here("scripts", "credentials.json")
ODDS_BASE    <- "https://api.the-odds-api.com/v4"
SPORT        <- "basketball_wnba"

# Sharp books used for steam detection — these move first on syndicate action.
# FanDuel/DraftKings excluded: recreational books that move LAST, not first.
# In thin WNBA markets even 1 sharp book moving is meaningful signal.
# Note: "bookmaker" was removed 2026-07-09 — not a real Odds API bookmaker key
# (confirmed against a live us+eu response), so it never matched anything.
SHARP_BOOKS  <- c("pinnacle", "betonlineag", "lowvig")

# Steam thresholds — calibrated for WNBA's thin market.
# NFL/NBA defaults (1.0 pts, 3 books) are too tight here; meaningful WNBA steam
# is often 0.5 pts across 2 books.
#
# STEAM_MIN_MOVE/STEAM_MIN_BOOKS below are fallback defaults only — the live
# values are read from model_config ('steam_min_move'/'steam_min_books') via
# .get_steam_thresholds(), auto-calibrated by calibrate_mispricing.R once
# enough settled games accumulate. These constants matter only when con=NULL.
STEAM_MIN_MOVE    <- 0.5    # minimum line movement in points to qualify
STEAM_MIN_BOOKS   <- 2      # minimum number of books that must move together
STEAM_WINDOW_MINS <- 60     # movement must occur within this many minutes (NOT enforced — see detect_steam())

# ── Credentials & Key Rotation ────────────────────────────────────────────────

load_credentials <- function(path = CREDS_PATH) {
  fromJSON(path)
}

# Key state — tracks remaining quota per key in memory during a session.
# Rotates automatically when a key drops below the threshold.
key_state <- local({
  keys      <- NULL
  index     <- 1L
  remaining <- NULL

  list(
    init = function(creds) {
      keys      <<- creds$odds_api_keys
      remaining <<- rep(NA_integer_, length(keys))
      message("Loaded ", length(keys), " Odds API keys.")
    },

    current = function() keys[[index]],

    # Call after each request with the x-requests-remaining header value
    update_remaining = function(r) {
      remaining[[index]] <<- as.integer(r)
    },

    # Rotate to the next key with quota. Call when remaining < threshold.
    rotate = function(threshold = 5L) {
      for (i in seq_along(keys)) {
        candidate <- ((index - 1L + i) %% length(keys)) + 1L
        if (is.na(remaining[[candidate]]) || remaining[[candidate]] > threshold) {
          index <<- candidate
          message("Rotated to key index ", index, " (remaining: ",
                  ifelse(is.na(remaining[[index]]), "unknown", remaining[[index]]), ")")
          return(invisible(NULL))
        }
      }
      stop("All Odds API keys exhausted. Try again later.")
    },

    status = function() {
      data.frame(
        index     = seq_along(keys),
        key_tail  = substr(keys, nchar(keys) - 5, nchar(keys)),
        remaining = remaining
      )
    }
  )
})

# ── Base Request ──────────────────────────────────────────────────────────────

odds_request <- function(path, params = list()) {
  params$apiKey <- key_state$current()

  resp <- request(ODDS_BASE) |>
    req_url_path_append(path) |>
    req_url_query(!!!params) |>
    req_retry(max_tries = 3, backoff = \(i) 2 ^ i) |>
    req_perform()

  # Track remaining quota from response headers
  remaining <- resp_header(resp, "x-requests-remaining")
  if (!is.null(remaining)) key_state$update_remaining(remaining)

  # Rotate proactively if running low
  r <- as.integer(remaining %||% Inf)
  if (!is.na(r) && r < 5L) {
    message("Key running low (", r, " remaining). Rotating.")
    key_state$rotate()
  }

  resp
}

# ── Fetch Odds ────────────────────────────────────────────────────────────────

# Pull current WNBA odds for spreads, totals, and h2h.
# `snapshot_type`: one of "opener", "midday", "closing"
#
# regions = "us,eu" — NOT just "us". Pinnacle (SHARP_BOOK in mispricing.R,
# and the first entry of SHARP_BOOKS below) is classified under the "eu"
# region by The Odds API and is NEVER returned under "us" alone. Confirmed
# live 2026-07-09: zero Pinnacle rows existed in `lines` since the mispricing
# model was deployed (commit b5eb4fd) because every fetch used regions="us".
# compute_mispricing() silently returned NULL every time as a result — the
# whole Pinnacle-deviation gate has never fired once. Combining regions
# roughly doubles Odds API quota cost per call (confirmed: 3 units for
# markets=spreads,totals,h2h under "us" alone vs 6 under "us,eu").
fetch_wnba_odds <- function(snapshot_type = "midday",
                            regions       = "us,eu",
                            markets       = "spreads,totals,h2h",
                            odds_format   = "american") {
  message("Fetching WNBA odds snapshot: ", snapshot_type)

  resp <- odds_request(
    path   = paste0("sports/", SPORT, "/odds"),
    params = list(
      regions    = regions,
      markets    = markets,
      oddsFormat = odds_format
    )
  )

  raw <- resp_body_json(resp, simplifyVector = FALSE)

  if (length(raw) == 0) {
    message("No WNBA games found.")
    return(tibble())
  }

  pulled_at <- format(now("UTC"), "%Y-%m-%d %H:%M:%S")

  # Flatten nested JSON: one row per game × bookmaker × market × outcome
  map_dfr(raw, function(game) {
    map_dfr(game$bookmakers, function(book) {
      map_dfr(book$markets, function(market) {
        map_dfr(market$outcomes, function(outcome) {
          tibble(
            game_id       = game$id,
            snapshot_type = snapshot_type,
            sport_key     = game$sport_key,
            commence_time = game$commence_time,
            home_team     = game$home_team,
            away_team     = game$away_team,
            bookmaker     = book$key,
            market        = market$key,
            outcome_name  = outcome$name,
            price         = outcome$price %||% NA_real_,
            point         = outcome$point %||% NA_real_,
            pulled_at     = pulled_at
          )
        })
      })
    })
  })
}

# ── Persist Snapshot ──────────────────────────────────────────────────────────

# Writes a snapshot to the `lines` table. Uses INSERT OR REPLACE to avoid
# duplicates on the (game_id, snapshot_type, bookmaker, market, outcome_name) PK.
save_snapshot <- function(odds_df, con) {
  if (nrow(odds_df) == 0) return(invisible(NULL))

  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS lines (
      game_id        TEXT,
      snapshot_type  TEXT,
      sport_key      TEXT,
      commence_time  TEXT,
      home_team      TEXT,
      away_team      TEXT,
      bookmaker      TEXT,
      market         TEXT,
      outcome_name   TEXT,
      price          REAL,
      point          REAL,
      pulled_at      TEXT,
      PRIMARY KEY (game_id, snapshot_type, bookmaker, market, outcome_name)
    )
  ")

  # Upsert game registry first (one row per game_id)
  games_df <- odds_df |>
    dplyr::distinct(game_id, commence_time, home_team, away_team)
  for (i in seq_len(nrow(games_df))) {
    g <- games_df[i, ]
    dbExecute(con, "
      INSERT OR IGNORE INTO games (game_id, commence_time, home_team, away_team)
      VALUES (?,?,?,?)
    ", list(g$game_id, g$commence_time, g$home_team, g$away_team))
  }

  # Write row by row via INSERT OR REPLACE to respect the PK constraint
  for (i in seq_len(nrow(odds_df))) {
    row <- odds_df[i, ]
    dbExecute(con, "
      INSERT OR REPLACE INTO lines
        (game_id, snapshot_type, sport_key, commence_time, home_team, away_team,
         bookmaker, market, outcome_name, price, point, pulled_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ", unname(as.list(row)))
  }

  message("Saved ", nrow(odds_df), " rows to lines table [", odds_df$snapshot_type[1], "].")
}

# Load calibrated steam thresholds from model_config; fall back to the module
# defaults above when no con is available or model_config is empty/pre-migration.
# Mirrors mispricing.R's .get_dev_threshold() pattern.
.get_steam_thresholds <- function(con) {
  if (is.null(con)) return(list(min_move = STEAM_MIN_MOVE, min_books = STEAM_MIN_BOOKS))
  tryCatch({
    cfg <- dbGetQuery(con, "SELECT param, value FROM model_config WHERE param IN ('steam_min_move','steam_min_books')")
    list(
      min_move  = cfg$value[cfg$param == "steam_min_move"][1]  %||% STEAM_MIN_MOVE,
      min_books = cfg$value[cfg$param == "steam_min_books"][1] %||% STEAM_MIN_BOOKS
    )
  }, error = \(e) list(min_move = STEAM_MIN_MOVE, min_books = STEAM_MIN_BOOKS))
}

# ── Steam Detection ───────────────────────────────────────────────────────────

# Compares two snapshots (earlier vs. later) and flags steam movements.
#
# Steam criteria:
#   - Line moves >= min_move points        (calibrated via model_config 'steam_min_move';
#   - Across >= min_books sharp books         falls back to STEAM_MIN_MOVE/STEAM_MIN_BOOKS
#                                              module constants when con is NULL)
#   - Within STEAM_WINDOW_MINS minutes     (NOT currently enforced — see note below)
#
# NOTE (2026-07-09): the window check below only logs a warning, it never
# filters. Left as-is pending a decision on what STEAM_WINDOW_MINS should
# actually mean — the real snapshot cadence is opener->midday fixed at ~120
# min, but midday->closing varies widely (50-230+ min) with game tip time, so
# a single fixed window doesn't obviously fit both. Do not assume enforcing
# this at the current value (60) is safe without checking real gap data first
# — it would silently zero out the opener->midday comparison, which is always
# ~120 min apart.
#
# Returns a data frame of flagged movements (empty if none).
detect_steam <- function(snap_early, snap_late, con = NULL) {
  if (nrow(snap_early) == 0 || nrow(snap_late) == 0) return(tibble())

  thr       <- .get_steam_thresholds(con)
  min_move  <- thr$min_move
  min_books <- thr$min_books

  # Check time window
  t_early <- ymd_hms(snap_early$pulled_at[1], tz = "UTC")
  t_late  <- ymd_hms(snap_late$pulled_at[1],  tz = "UTC")
  mins_apart <- as.numeric(difftime(t_late, t_early, units = "mins"))

  if (mins_apart > STEAM_WINDOW_MINS) {
    message("Snapshots are ", round(mins_apart), " mins apart — outside steam window.")
  }

  # Focus on spreads and totals from sharp books only
  early_sharp <- snap_early |>
    filter(bookmaker %in% SHARP_BOOKS, market %in% c("spreads", "totals"))

  late_sharp <- snap_late |>
    filter(bookmaker %in% SHARP_BOOKS, market %in% c("spreads", "totals"))

  # Join on stable keys, compute movement per book
  moves <- early_sharp |>
    inner_join(
      late_sharp |> select(game_id, bookmaker, market, outcome_name, point_late = point),
      by = c("game_id", "bookmaker", "market", "outcome_name")
    ) |>
    mutate(move = point_late - point) |>
    filter(abs(move) >= min_move)

  if (nrow(moves) == 0) return(tibble())

  # Group by game × market × direction: count how many books moved the same way
  steam_flags <- moves |>
    mutate(direction = if_else(move > 0, "up", "down")) |>
    group_by(game_id, market, outcome_name, direction) |>
    summarise(
      books_moved = n(),
      magnitude   = mean(abs(move)),
      .groups     = "drop"
    ) |>
    filter(books_moved >= min_books) |>
    mutate(detected_at = format(now("UTC"), "%Y-%m-%d %H:%M:%S"))

  if (nrow(steam_flags) == 0) return(tibble())

  message("STEAM DETECTED: ", nrow(steam_flags), " movement(s) flagged.")
  print(steam_flags)

  # Persist to DB if connection provided
  if (!is.null(con)) {
    dbAppendTable(con, "steam_movements", steam_flags)
  }

  steam_flags
}

# ── CLV Tracking ─────────────────────────────────────────────────────────────

# Called from alert_steam_flags() whenever steam fires.
# Logs the current (post-steam) line to clv_log as the bet entry point.
# Skips silently if an entry already exists for that game/market/side.
record_clv_entry <- function(steam_df, con) {
  if (is.null(steam_df) || nrow(steam_df) == 0) return(invisible(NULL))

  for (i in seq_len(nrow(steam_df))) {
    row <- steam_df[i, ]

    existing <- tryCatch(
      dbGetQuery(con, "
        SELECT COUNT(*) AS n FROM clv_log
        WHERE game_id = ? AND market = ? AND side = ?
      ", list(row$game_id, row$market, row$outcome_name))$n,
      error = function(e) 1L
    )
    if (existing > 0) next

    current_pt <- tryCatch(
      dbGetQuery(con, "
        SELECT point FROM lines
        WHERE game_id = ? AND market = ? AND outcome_name = ?
          AND bookmaker IN (
            'pinnacle','betonlineag','bookmaker','lowvig','draftkings','fanduel'
          )
        ORDER BY CASE bookmaker
          WHEN 'pinnacle'   THEN 1 WHEN 'betonlineag' THEN 2
          WHEN 'bookmaker'  THEN 3 WHEN 'lowvig'      THEN 4
          WHEN 'draftkings' THEN 5 WHEN 'fanduel'     THEN 6 ELSE 7 END,
          pulled_at DESC
        LIMIT 1
      ", list(row$game_id, row$market, row$outcome_name))$point,
      error = function(e) NA_real_
    )

    if (length(current_pt) == 0 || is.na(current_pt)) {
      message("[CLV] No line found for ", row$game_id,
              " | ", row$market, " | ", row$outcome_name, " — skipping")
      next
    }

    dbExecute(con, "
      INSERT INTO clv_log (game_id, market, side, model_line, steam_direction)
      VALUES (?, ?, ?, ?, ?)
    ", list(row$game_id, row$market, row$outcome_name, current_pt, row$direction))

    message("[CLV] Entry logged: ", row$game_id,
            " | ", row$market, " | ", row$outcome_name,
            " @ ", current_pt, " (steam ", row$direction, ")")
  }

  invisible(NULL)
}

# Settle open CLV entries once a closing snapshot exists.
# CLV is signed by steam direction: positive means market kept moving post-entry.
#   steam "down": model_line - closing_line  (you got a higher/better number)
#   steam "up":   closing_line - model_line  (you got a lower/better number)
compute_wnba_clv <- function(con) {
  open <- tryCatch(
    dbGetQuery(con, "
      SELECT id, game_id, market, side, model_line, steam_direction
      FROM clv_log WHERE closing_line IS NULL
    ") |> as_tibble(),
    error = function(e) tibble()
  )

  if (nrow(open) == 0) {
    message("[CLV] No open entries to settle.")
    return(invisible(NULL))
  }

  message("[CLV] Settling ", nrow(open), " open entries...")
  n_settled <- 0L

  for (i in seq_len(nrow(open))) {
    row <- open[i, ]

    closing_pt <- tryCatch(
      dbGetQuery(con, "
        SELECT point FROM lines
        WHERE game_id = ? AND market = ? AND outcome_name = ?
          AND snapshot_type = 'closing'
          AND bookmaker IN (
            'pinnacle','betonlineag','bookmaker','lowvig','draftkings','fanduel'
          )
        ORDER BY CASE bookmaker
          WHEN 'pinnacle'   THEN 1 WHEN 'betonlineag' THEN 2
          WHEN 'bookmaker'  THEN 3 WHEN 'lowvig'      THEN 4
          WHEN 'draftkings' THEN 5 WHEN 'fanduel'     THEN 6 ELSE 7 END
        LIMIT 1
      ", list(row$game_id, row$market, row$side))$point,
      error = function(e) NA_real_
    )

    if (length(closing_pt) == 0 || is.na(closing_pt)) next

    clv <- if (identical(row$steam_direction, "down")) {
      row$model_line - closing_pt
    } else {
      closing_pt - row$model_line
    }

    dbExecute(con, "
      UPDATE clv_log SET closing_line = ?, clv = ? WHERE id = ?
    ", list(closing_pt, clv, row$id))

    n_settled <- n_settled + 1L
    message("[CLV] Settled: ", row$game_id,
            " | ", row$market, " | ", row$side,
            " — entry ", row$model_line, " vs close ", closing_pt,
            " → CLV ", ifelse(clv >= 0, "+", ""), round(clv, 2))
  }

  message("[CLV] Done — ", n_settled, " of ", nrow(open), " entries settled.")
  invisible(n_settled)
}

# ── Steam Dedup Helpers ───────────────────────────────────────────────────────

# Returns TRUE and inserts a steam_log entry if this is a new move.
# Returns FALSE and updates last_seen if the move was already alerted.
# Called before firing any alert so each (game, market, outcome, direction)
# only triggers one Telegram/Discord message per game lifetime.
is_new_steam <- function(con, game_id, market, outcome_name, direction,
                         magnitude, books_moved) {
  existing <- tryCatch(
    dbGetQuery(con, "
      SELECT id FROM steam_log
      WHERE  game_id      = ?
      AND    market       = ?
      AND    outcome_name = ?
      AND    direction    = ?
      AND    resolved     = 0
    ", list(game_id, market, outcome_name, direction)),
    error = function(e) data.frame()
  )

  if (nrow(existing) == 0) {
    tryCatch(
      dbExecute(con, "
        INSERT OR IGNORE INTO steam_log
          (game_id, market, outcome_name, direction, magnitude, books_moved,
           first_detected, last_seen, alert_sent)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'), datetime('now'), 1)
      ", list(game_id, market, outcome_name, direction, magnitude, books_moved)),
      error = function(e) NULL
    )
    return(TRUE)
  }

  # Already seen — update last_seen and keep the largest magnitude seen
  tryCatch(
    dbExecute(con, "
      UPDATE steam_log
      SET    last_seen = datetime('now'),
             magnitude = CASE WHEN ? > magnitude THEN ? ELSE magnitude END
      WHERE  game_id      = ?
      AND    market       = ?
      AND    outcome_name = ?
      AND    direction    = ?
      AND    resolved     = 0
    ", list(magnitude, magnitude, game_id, market, outcome_name, direction)),
    error = function(e) NULL
  )
  FALSE
}

# Mark all open steam_log entries for a game as resolved.
# Call when a game's closing snapshot fires so stale entries don't carry over.
resolve_steam <- function(con, game_id) {
  tryCatch(
    dbExecute(con, "
      UPDATE steam_log SET resolved = 1 WHERE game_id = ?
    ", list(game_id)),
    error = function(e) NULL
  )
  invisible(NULL)
}

# ── Orchestration ─────────────────────────────────────────────────────────────

# Run a full collection pass for a given snapshot window.
# Fetches odds, saves to DB, and optionally compares against a prior snapshot.
#
# Usage:
#   creds <- load_credentials()
#   key_state$init(creds)
#   con <- dbConnect(RSQLite::SQLite(), DB_PATH)
#
#   run_collection("opener", con)
#   # ... time passes ...
#   run_collection("midday", con, compare_to = "opener")
#   run_collection("closing", con, compare_to = "midday")

run_collection <- function(snapshot_type, con, compare_to = NULL) {
  odds  <- fetch_wnba_odds(snapshot_type = snapshot_type)
  save_snapshot(odds, con)
  steam <- tibble()

  if (!is.null(compare_to) && nrow(odds) > 0) {
    prior <- dbGetQuery(con, "
      SELECT * FROM lines WHERE snapshot_type = ?
    ", list(compare_to)) |> as_tibble()

    if (nrow(prior) > 0) {
      steam <- detect_steam(prior, odds, con = con)
    } else {
      message("No prior snapshot found for '", compare_to, "' — skipping steam check.")
    }
  }

  # Return both odds and any steam flags so callers can send alerts
  invisible(list(odds = odds, steam = steam))
}
