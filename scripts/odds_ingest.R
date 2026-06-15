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

DB_PATH      <- here::here("data", "wnba_pipeline.sqlite")
CREDS_PATH   <- here::here("scripts", "credentials.json")
ODDS_BASE    <- "https://api.the-odds-api.com/v4"
SPORT        <- "basketball_wnba"

# Sharp books used for steam detection — these move first on syndicate action.
# FanDuel/DraftKings excluded: recreational books that move LAST, not first.
# In thin WNBA markets even 1 sharp book moving is meaningful signal.
SHARP_BOOKS  <- c("pinnacle", "betonlineag", "bookmaker", "lowvig")

# Steam thresholds — calibrated for WNBA's thin market.
# NFL/NBA defaults (1.0 pts, 3 books) are too tight here; meaningful WNBA steam
# is often 0.5 pts across 2 books. Adjust up once we have flag history.
STEAM_MIN_MOVE    <- 0.5    # minimum line movement in points to qualify
STEAM_MIN_BOOKS   <- 2      # minimum number of books that must move together
STEAM_WINDOW_MINS <- 60     # movement must occur within this many minutes

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
fetch_wnba_odds <- function(snapshot_type = "midday",
                            regions       = "us",
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

# ── Steam Detection ───────────────────────────────────────────────────────────

# Compares two snapshots (earlier vs. later) and flags steam movements.
#
# Steam criteria (configurable at top of file):
#   - Line moves >= STEAM_MIN_MOVE points
#   - Across >= STEAM_MIN_BOOKS sharp books
#   - Within STEAM_WINDOW_MINS minutes
#
# Returns a data frame of flagged movements (empty if none).
detect_steam <- function(snap_early, snap_late, con = NULL) {
  if (nrow(snap_early) == 0 || nrow(snap_late) == 0) return(tibble())

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
    filter(abs(move) >= STEAM_MIN_MOVE)

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
    filter(books_moved >= STEAM_MIN_BOOKS) |>
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
