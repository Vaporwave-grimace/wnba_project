# scripts/run_pipeline.R
# WNBA Pipeline — main runner
#
# Designed to be called by Windows Task Scheduler every 30 minutes
# throughout the game day. On each invocation it checks the current
# ET time and dispatches only the work that is due.
#
# Daily schedule (all times Eastern):
#   09:00        — Open snapshot + on/off net rating refresh
#   09:00–18:00  — Injury poll (every invocation)
#   13:00        — Midday snapshot + steam check vs. opener
#   Pre-tip      — Closing snapshot + steam check vs. midday
#                  (script detects games tipping within 70 min)
#
# To run manually:
#   Rscript scripts/run_pipeline.R
#
# To schedule (see run_pipeline.bat):
#   Task Scheduler → every 30 min → Rscript.exe run_pipeline.R

library(here)
library(lubridate)
library(DBI)
library(RSQLite)

# Source all pipeline components
source(here("scripts", "logger.R"))
source(here("scripts", "db_setup.R"))
source(here("scripts", "odds_ingest.R"))
source(here("scripts", "wnba_stats_api.R"))
source(here("scripts", "injury_alert.R"))
source(here("scripts", "shadow_model", "features.R"))
source(here("scripts", "shadow_model", "predict.R"))

# ── Config ────────────────────────────────────────────────────────────────────

TZ_LOCAL        <- "America/New_York"
OPEN_HOUR       <- 9L    # 9:00 AM ET — open snapshot
MIDDAY_HOUR     <- 13L   # 1:00 PM ET — midday snapshot
PRE_TIP_MINS    <- 70L   # minutes before tip-off to take closing snapshot
SEASON          <- "2025"

# ── Startup ───────────────────────────────────────────────────────────────────

log_info("──────────────────────────────────────────")
log_info("Pipeline invoked at", format(now("UTC"), "%Y-%m-%d %H:%M:%S"), "UTC")

# Load credentials and initialize key state
creds <- safe_run(load_credentials(), "load credentials")
if (is.null(creds)) stop("Cannot continue without credentials.")
key_state$init(creds)

# Ensure DB exists and schema is current
safe_run(init_db(), "db init")

# Open DB connection — shared across all steps this invocation
con <- dbConnect(RSQLite::SQLite(), DB_PATH)
on.exit(dbDisconnect(con), add = TRUE)

# ── Time Helpers ──────────────────────────────────────────────────────────────

now_et    <- function() with_tz(now("UTC"), TZ_LOCAL)
hour_et   <- function() hour(now_et())
minute_et <- function() minute(now_et())

# Returns TRUE if we are within `window_mins` of the target hour (±)
near_hour <- function(target_hour, window_mins = 25L) {
  et   <- now_et()
  diff <- abs(as.numeric(difftime(et, floor_date(et, "hour") +
                                    hours(target_hour - hour(et)),
                                  units = "mins")))
  diff <= window_mins
}

# Fetch games today and return those tipping within PRE_TIP_MINS minutes
games_near_tip <- function() {
  today_str <- format(now_et(), "%Y-%m-%d")

  games <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT game_id, commence_time
      FROM lines
      WHERE DATE(commence_time) = ?
    ", list(today_str)) |> as_tibble(),
    error = function(e) tibble()
  )

  if (nrow(games) == 0) return(character(0))

  games |>
    mutate(tip = ymd_hms(commence_time, tz = "UTC")) |>
    filter(
      as.numeric(difftime(tip, now("UTC"), units = "mins")) |>
        between(0, PRE_TIP_MINS)
    ) |>
    pull(game_id)
}

# ── Step 1: Open snapshot (once, ~9 AM ET) ────────────────────────────────────

if (near_hour(OPEN_HOUR)) {
  # Guard: skip if we already have an opener for today
  today_str    <- format(now_et(), "%Y-%m-%d")
  opener_count <- dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM lines
    WHERE snapshot_type = 'opener'
      AND DATE(pulled_at) = ?
  ", list(today_str))$n

  if (opener_count == 0) {
    log_info("OPEN window — fetching opener snapshot")
    safe_run(run_collection("opener", con), "opener snapshot")

    log_info("OPEN window — refreshing on/off net ratings")
    teams <- safe_run(
      dbGetQuery(con, "SELECT DISTINCT team_id FROM game_log") |>
        pull(team_id),
      "fetch team list"
    )

    if (!is.null(teams) && length(teams) > 0) {
      walk(teams, function(tid) {
        result <- safe_run(compute_on_off_net_rating(tid, SEASON),
                           paste("on/off for team", tid))
        if (!is.null(result)) safe_run(write_on_off_to_db(result, con),
                                       paste("write on/off for team", tid))
      })
    }
  } else {
    log_info("OPEN window — opener already captured today, skipping")
  }
}

# ── Step 2: Midday snapshot (~1 PM ET) ───────────────────────────────────────

if (near_hour(MIDDAY_HOUR)) {
  today_str     <- format(now_et(), "%Y-%m-%d")
  midday_count  <- dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM lines
    WHERE snapshot_type = 'midday'
      AND DATE(pulled_at) = ?
  ", list(today_str))$n

  if (midday_count == 0) {
    log_info("MIDDAY window — fetching midday snapshot")
    safe_run(run_collection("midday", con, compare_to = "opener"), "midday snapshot")
  } else {
    log_info("MIDDAY window — midday already captured today, skipping")
  }
}

# ── Step 3: Closing snapshot (pre-tip, per game) ──────────────────────────────

near_tip_games <- games_near_tip()

if (length(near_tip_games) > 0) {
  log_info("PRE-TIP window — ", length(near_tip_games), " game(s) approaching tip-off")

  # Only capture closing if not already done for these games
  already_closed <- dbGetQuery(con, "
    SELECT DISTINCT game_id FROM lines WHERE snapshot_type = 'closing'
  ")$game_id

  pending <- setdiff(near_tip_games, already_closed)

  if (length(pending) > 0) {
    log_info("Fetching closing snapshot for ", length(pending), " game(s)")
    safe_run(run_collection("closing", con, compare_to = "midday"), "closing snapshot")
  } else {
    log_info("Closing already captured for all near-tip games, skipping")
  }
}

# ── Step 4: Shadow model — predict on steam flags ─────────────────────────────

# If steam was detected this run, fire predictions for each flagged game.
# Models must exist (run seed.R then train.R first).
if (file.exists(here("models", "totals_xgb.rds"))) {
  steam_today <- dbGetQuery(con, "
    SELECT DISTINCT game_id, direction, magnitude, books_moved, detected_at
    FROM steam_movements
    WHERE DATE(detected_at) = ?
    ORDER BY detected_at DESC
  ", list(format(now_et(), "%Y-%m-%d"))) |> as_tibble()

  if (nrow(steam_today) > 0) {
    team_box_cache <- safe_run(
      wehoop::load_wnba_team_box(seasons = as.integer(format(now_et(), "%Y"))),
      "load team box for shadow model"
    )

    walk(seq_len(nrow(steam_today)), function(i) {
      safe_run(
        run_prediction(steam_today$game_id[i], steam_today[i, ], con,
                       team_box = team_box_cache),
        paste("shadow model prediction for", steam_today$game_id[i])
      )
    })
  }
} else {
  log_info("Shadow model not trained yet — skipping prediction step")
}

# ── Step 5: Injury poll (every invocation during game day) ───────────────────

h <- hour_et()

if (h >= 8L && h <= 23L) {
  log_info("INJURY poll")
  safe_run(run_injury_check(con, creds, alert_all_injuries = FALSE), "injury check")
} else {
  log_info("Outside injury poll window (8 AM–11 PM ET), skipping")
}

# ── Done — send Telegram run summary ─────────────────────────────────────────

run_end   <- now("UTC")
games_today <- tryCatch(
  dbGetQuery(con, "
    SELECT COUNT(DISTINCT game_id) AS n FROM lines
    WHERE DATE(pulled_at) = ?
  ", list(format(now_et(), "%Y-%m-%d")))$n,
  error = function(e) 0L
)

steam_count <- tryCatch(
  dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM steam_movements
    WHERE DATE(detected_at) = ?
  ", list(format(now_et(), "%Y-%m-%d")))$n,
  error = function(e) 0L
)

injury_count <- tryCatch(
  dbGetQuery(con, "
    SELECT COUNT(*) AS n FROM injury_reports
    WHERE DATE(ingested_at) = ?
  ", list(format(now_et(), "%Y-%m-%d")))$n,
  error = function(e) 0L
)

summary_msg <- paste0(
  "\U0001f3c0 *WNBA Pipeline* | ", format(now_et(), "%b %d %I:%M %p ET"), "\n",
  "\U0001f4ca Games tracked today: ", games_today, "\n",
  "\U0001f525 Steam flags today: ", steam_count, "\n",
  "\U0001fa79 Injury updates today: ", injury_count
)

safe_run(send_telegram(summary_msg, creds), "telegram run summary")

log_info("Pipeline run complete")
log_info("──────────────────────────────────────────")
