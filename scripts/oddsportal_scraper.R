# scripts/oddsportal_scraper.R
# Backfill historical WNBA closing totals from OddsPortal via Firecrawl.
#
# Workflow:
#   1. Scrape results pages for each season → game URLs + metadata
#   2. For each game: JS-click "Over/Under" tab → parse consensus closing total
#   3. Match to wehoop game_id via game_date + team name (game_outcomes + game_log)
#   4. Write to `lines` as snapshot_type='closing', bookmaker='oddsportal'
#
# After running: re-run train.R — closing_line predictor gets real values for
# ~660 historical games instead of NA, which significantly improves XGBoost signal.
#
# Runtime: ~660 games x 25s = 4-5 hours. Resumable: done list at data/op_done.rds.
# Safe to interrupt and restart — already-scraped games are skipped automatically.
#
# Usage:
#   source("scripts/oddsportal_scraper.R")
#   oddsportal_backfill_run()                   # 2023-2025 (default)
#   oddsportal_backfill_run(seasons = 2025L)    # one season
#   oddsportal_backfill_run(overwrite = TRUE)   # re-scrape everything

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(dplyr)
  library(purrr)
  library(DBI)
  library(RSQLite)
  library(here)
})

DB_PATH       <- here("data", "wnba_pipeline.sqlite")
OP_BASE       <- "https://www.oddsportal.com/basketball/usa"
FC_URL        <- "https://api.firecrawl.dev/v1/scrape"
FC_WAIT_INIT  <- 7000L   # ms before JS click (React hydration)
FC_WAIT_AFTER <- 6000L   # ms after JS click (tab content load)
FC_TIMEOUT    <- 130L    # seconds per Firecrawl request
SCRAPE_DELAY  <- 4L      # seconds between game page requests
PAGE_DELAY    <- 2L      # seconds between results pages
DONE_FILE     <- here("data", "op_done.rds")

# ── Firecrawl helper ──────────────────────────────────────────────────────────

.fc_scrape <- function(url, key, actions = NULL, wait_ms = 4000L) {
  body <- list(url = url, formats = list("markdown"), waitFor = wait_ms)
  if (!is.null(actions)) body$actions <- actions

  resp <- tryCatch(
    request(FC_URL) |>
      req_headers(Authorization  = paste("Bearer", key),
                  `Content-Type` = "application/json") |>
      req_body_json(body) |>
      req_timeout(FC_TIMEOUT) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(),
    error = function(e) { message("  [fc] ", e$message); NULL }
  )
  if (is.null(resp)) return(NULL)
  if (resp_status(resp) != 200L) {
    message("  [fc] HTTP ", resp_status(resp))
    return(NULL)
  }
  data <- tryCatch(resp_body_json(resp), error = function(e) NULL)
  if (!isTRUE(data$success)) {
    message("  [fc] Scrape failed: ", data$error %||% "unknown")
    return(NULL)
  }
  data$data$markdown
}

# JS click actions for the Over/Under tab.
# OddsPortal is React-hydrated — CSS selectors fail; text-match JS click works.
.ou_actions <- function() {
  js <- paste0(
    "Array.from(document.querySelectorAll('a,button,li')).forEach(",
    "function(el){ if(el.textContent.trim()==='Over/Under'){el.click();} });"
  )
  list(
    list(type = "wait",              milliseconds = FC_WAIT_INIT),
    list(type = "executeJavascript", script = js),
    list(type = "wait",              milliseconds = FC_WAIT_AFTER)
  )
}

# ── Results page parser ────────────────────────────────────────────────────────

# Parse one results page markdown → tibble of game metadata.
# Columns: op_game_id, game_url, team1_slug, team2_slug, game_date, season
.parse_results_page <- function(md, season) {
  if (is.null(md) || !nzchar(md)) return(tibble())
  lv <- strsplit(md, "\n")[[1]]

  # OddsPortal h2h links encode both team IDs and the game hash
  # Pattern: /h2h/team1-XXXXXXXX/team2-XXXXXXXX/#GAMEID
  h2h_pat <- paste0(
    "oddsportal\\.com/basketball/h2h/",
    "([^/]+)/",        # team1 slug + 8-char ID
    "([^/]+)/",        # team2 slug + 8-char ID
    "#([A-Za-z0-9]+)"  # game ID
  )
  h2h_idx <- grep(h2h_pat, lv)
  if (length(h2h_idx) == 0) return(tibble())

  # Date header lines appear as bare "DD Mon YYYY" text
  date_idx <- grep("^\\d{2} [A-Za-z]+ \\d{4}$", lv)

  year_str <- if (season == as.integer(format(Sys.Date(), "%Y"))) {
    "wnba"
  } else {
    paste0("wnba-", season)
  }

  rows <- map_dfr(h2h_idx, function(i) {
    m <- regmatches(lv[i], regexec(h2h_pat, lv[i]))[[1]]
    if (length(m) < 4L) return(NULL)

    # Strip trailing 8-char alphanumeric team ID suffix
    team1_slug <- sub("-[A-Za-z0-9]{8}$", "", m[2L])
    team2_slug <- sub("-[A-Za-z0-9]{8}$", "", m[3L])
    op_game_id <- m[4L]

    game_url <- paste0(OP_BASE, "/", year_str, "/",
                       team1_slug, "-", team2_slug, "-", op_game_id, "/")

    prior    <- date_idx[date_idx < i]
    raw_date <- if (length(prior) > 0L) trimws(lv[max(prior)]) else NA_character_
    game_date <- tryCatch(
      format(as.Date(raw_date, "%d %b %Y"), "%Y-%m-%d"),
      error = function(e) NA_character_
    )

    tibble(op_game_id, game_url, team1_slug, team2_slug,
           game_date, season = as.integer(season))
  })

  rows |> filter(!is.na(game_date)) |> distinct(op_game_id, .keep_all = TRUE)
}

# Scrape all results pages for one season — handles pagination automatically.
.season_game_list <- function(season, key) {
  year_str <- if (season == as.integer(format(Sys.Date(), "%Y"))) {
    "wnba"
  } else {
    paste0("wnba-", season)
  }
  base_url <- paste0(OP_BASE, "/", year_str, "/results/")

  all_rows <- list()
  for (page in seq_len(20L)) {
    url <- if (page == 1L) base_url else paste0(base_url, "?page=", page)
    message(sprintf("  [results] %d page %d — %s", season, page, url))

    md   <- .fc_scrape(url, key, wait_ms = 10000L)
    rows <- .parse_results_page(md, season)

    if (nrow(rows) == 0L) {
      message("  [results] Empty page — pagination done")
      break
    }
    message(sprintf("  [results]   %d games found", nrow(rows)))
    all_rows[[page]] <- rows
    Sys.sleep(PAGE_DELAY)
  }

  bind_rows(all_rows)
}

# ── OU markdown parser ─────────────────────────────────────────────────────────

# Extract consensus closing total from the OU tab markdown.
# OddsPortal OU table format (per line):
#   O/U +164.5      <- line label
#   2               <- number of books at this line
#   -110            <- over odds (American)
#   -110            <- under odds (American)
#   95.5%           <- payout
# Consensus = line with most books; tie-break by closest to -110/-110 juice.
.parse_closing_total <- function(md) {
  if (is.null(md) || !nzchar(md)) return(NA_real_)
  lv <- trimws(strsplit(md, "\n")[[1]])
  lv <- lv[nzchar(lv)]

  # Try "O/U +NNN" first (table row label); fall back to "Over/Under +NNN" (header)
  ou_idx <- grep("^O/U \\+[0-9]", lv)
  if (length(ou_idx) == 0L) ou_idx <- grep("^Over/Under \\+[0-9]", lv)
  if (length(ou_idx) == 0L) return(NA_real_)

  candidates <- map_dfr(ou_idx, function(i) {
    total_val <- suppressWarnings(
      as.numeric(sub("^(O/U |Over/Under )\\+", "", lv[i]))
    )
    if (is.na(total_val)) return(NULL)

    nxt       <- lv[(i + 1L):min(length(lv), i + 5L)]
    n_books   <- suppressWarnings(as.integer(nxt[1L]))
    over_odds <- suppressWarnings(as.integer(nxt[2L]))
    under_odds <- suppressWarnings(as.integer(nxt[3L]))

    tibble(total = total_val,
           n_books    = coalesce(n_books, 0L),
           over_odds  = coalesce(over_odds, -110L),
           under_odds = coalesce(under_odds, -110L))
  }) |> filter(!is.na(total))

  if (nrow(candidates) == 0L) return(NA_real_)

  candidates |>
    mutate(juice_dev = abs(over_odds + 110L) + abs(under_odds + 110L)) |>
    arrange(desc(n_books), juice_dev) |>
    pull(total) |>
    first()
}

# ── Wehoop game_id matcher ────────────────────────────────────────────────────

# Build full lookup: one row per game with home/away display names.
.build_game_lookup <- function(con) {
  dbGetQuery(con, "
    SELECT go.game_id,
           go.game_date,
           h.team_name AS home_name,
           a.team_name AS away_name
    FROM game_outcomes go
    JOIN game_log h
      ON h.game_id = go.game_id
     AND CAST(h.team_id AS TEXT) = CAST(go.home_team_id AS TEXT)
    JOIN game_log a
      ON a.game_id = go.game_id
     AND CAST(a.team_id AS TEXT) = CAST(go.away_team_id AS TEXT)
    GROUP BY go.game_id
  ") |> as_tibble()
}

# Fuzzy-match one OddsPortal row to a wehoop game_id.
# Converts slug to name (hyphen → space, lowercase) and checks containment
# against both home/away in either team ordering.
.match_game_id <- function(op_row, lookup) {
  day <- lookup |> filter(game_date == op_row$game_date)
  if (nrow(day) == 0L) return(NA_character_)

  s1 <- tolower(gsub("-", " ", op_row$team1_slug))
  s2 <- tolower(gsub("-", " ", op_row$team2_slug))

  scores <- day |>
    mutate(
      h = tolower(home_name),
      a = tolower(away_name),
      # Score 2 = both teams matched; 1 = one team matched; 0 = no match
      sc = pmax(
        as.integer(grepl(s1, a, fixed = TRUE) | grepl(a, s1, fixed = TRUE)) +
        as.integer(grepl(s2, h, fixed = TRUE) | grepl(h, s2, fixed = TRUE)),
        as.integer(grepl(s1, h, fixed = TRUE) | grepl(h, s1, fixed = TRUE)) +
        as.integer(grepl(s2, a, fixed = TRUE) | grepl(a, s2, fixed = TRUE))
      )
    ) |>
    arrange(desc(sc))

  if (scores$sc[1L] >= 1L) scores$game_id[1L] else NA_character_
}

# ── DB writer ─────────────────────────────────────────────────────────────────

# Write closing total to `lines` as two rows (Over / Under) with -110 each side.
# INSERT OR REPLACE — safe to re-run.
.write_total <- function(game_id, game_date, total, home_name, away_name, con) {
  pulled_at     <- paste0(game_date, "T23:59:00Z")
  commence_time <- paste0(game_date, "T00:00:00Z")

  for (side in c("Over", "Under")) {
    dbExecute(con, "
      INSERT OR REPLACE INTO lines
        (game_id, snapshot_type, sport_key, commence_time,
         home_team, away_team, bookmaker, market,
         outcome_name, price, point, pulled_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ", list(
      game_id, "closing", "basketball_wnba", commence_time,
      home_name, away_name, "oddsportal", "totals",
      side, -110L, total, pulled_at
    ))
  }
}

# ── Orchestrator ──────────────────────────────────────────────────────────────

oddsportal_backfill_run <- function(seasons = c(2023L, 2024L, 2025L),
                                    overwrite = FALSE) {
  creds <- tryCatch(
    read_json(here("scripts", "credentials.json")),
    error = function(e) stop("Cannot load credentials: ", e$message)
  )
  key <- creds$firecrawl_api_key %||% NULL
  if (is.null(key) || !nzchar(key))
    stop("firecrawl_api_key missing from credentials.json")

  con <- dbConnect(SQLite(), DB_PATH)
  on.exit(dbDisconnect(con), add = TRUE)

  message("[oddsportal] Building game lookup from game_outcomes + game_log...")
  lookup <- .build_game_lookup(con)
  message(sprintf("[oddsportal] Lookup: %d games across all seasons", nrow(lookup)))

  done_ids <- if (file.exists(DONE_FILE) && !overwrite) {
    readRDS(DONE_FILE)
  } else {
    character(0L)
  }

  total_written  <- 0L
  total_no_match <- 0L
  total_no_line  <- 0L

  for (season in seasons) {
    message(sprintf("\n[oddsportal] ── Season %d ──────────────────────────────", season))

    game_list <- .season_game_list(season, key)
    if (nrow(game_list) == 0L) {
      message("[oddsportal] No games found — skipping season")
      next
    }
    message(sprintf("[oddsportal] %d games total", nrow(game_list)))

    pending <- game_list |> filter(!op_game_id %in% done_ids)
    n_done  <- nrow(game_list) - nrow(pending)
    message(sprintf("[oddsportal] %d pending, %d already done", nrow(pending), n_done))

    if (nrow(pending) == 0L) next

    for (i in seq_len(nrow(pending))) {
      row <- pending[i, ]
      pct <- round(i / nrow(pending) * 100L)

      # Match to wehoop game_id
      wid <- .match_game_id(row, lookup)

      if (is.na(wid)) {
        message(sprintf("[%d%%] %s | %s / %s → NO MATCH",
                        pct, row$game_date, row$team1_slug, row$team2_slug))
        done_ids <- c(done_ids, row$op_game_id)
        saveRDS(done_ids, DONE_FILE)
        total_no_match <- total_no_match + 1L
        next
      }

      # Skip if already in DB (and not overwriting)
      if (!overwrite) {
        n_existing <- dbGetQuery(con,
          "SELECT COUNT(*) AS n FROM lines
           WHERE game_id = ? AND snapshot_type = 'closing' AND bookmaker = 'oddsportal'",
          list(wid))$n
        if (n_existing > 0L) {
          message(sprintf("[%d%%] %s | %s / %s → already in DB",
                          pct, row$game_date, row$team1_slug, row$team2_slug))
          done_ids <- c(done_ids, row$op_game_id)
          saveRDS(done_ids, DONE_FILE)
          next
        }
      }

      meta <- lookup |> filter(game_id == wid) |> slice(1L)
      message(sprintf("[%d%%] %s | %s vs %s → %s",
                      pct, row$game_date,
                      meta$away_name, meta$home_name, wid))

      # Scrape OU tab
      md    <- .fc_scrape(row$game_url, key, actions = .ou_actions())
      total <- .parse_closing_total(md)

      if (!is.na(total)) {
        message(sprintf("  total = %.1f ✓", total))
        tryCatch(
          .write_total(wid, row$game_date, total, meta$home_name, meta$away_name, con),
          error = function(e) message("  [write] ", e$message)
        )
        total_written <- total_written + 1L
      } else {
        message("  total = NA (no OU table found)")
        total_no_line <- total_no_line + 1L
      }

      done_ids <- c(done_ids, row$op_game_id)
      saveRDS(done_ids, DONE_FILE)
      Sys.sleep(SCRAPE_DELAY)
    }
  }

  message(sprintf(
    "\n[oddsportal] Done — %d totals written | %d no wehoop match | %d no OU table",
    total_written, total_no_match, total_no_line
  ))
  message("[oddsportal] Next: source('scripts/shadow_model/train.R') to retrain")
  invisible(total_written)
}

if (!interactive()) {
  oddsportal_backfill_run()
}
