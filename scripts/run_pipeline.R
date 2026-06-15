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
SEASON          <- as.integer(format(Sys.Date(), "%Y"))

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

# ── Alert Helper ─────────────────────────────────────────────────────────────

alert_steam_flags <- function(steam_df, creds, con) {
  if (is.null(steam_df) || nrow(steam_df) == 0) return(invisible(NULL))

  game_meta <- tryCatch(
    dbGetQuery(con, "SELECT DISTINCT game_id, home_team, away_team FROM lines") |>
      as_tibble(),
    error = function(e) tibble(game_id = character(), home_team = character(),
                               away_team = character())
  )

  for (i in seq_len(nrow(steam_df))) {
    row  <- steam_df[i, ]
    meta <- game_meta |> filter(game_id == row$game_id)
    msg  <- format_steam_alert(
      row,
      home_team = if (nrow(meta) > 0) meta$home_team[1] else NULL,
      away_team = if (nrow(meta) > 0) meta$away_team[1] else NULL
    )
    safe_run(send_telegram(msg, creds), paste("steam telegram alert", i))
    safe_run(send_discord(msg,  creds), paste("steam discord alert",  i))
    Sys.sleep(1)
  }

  safe_run(record_clv_entry(steam_df, con), "CLV entry logging")
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
    opener_result <- safe_run(run_collection("opener", con), "opener snapshot")

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
    midday_result <- safe_run(run_collection("midday", con, compare_to = "opener"), "midday snapshot")
    alert_steam_flags(midday_result$steam, creds, con)
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
    closing_result <- safe_run(run_collection("closing", con, compare_to = "midday"), "closing snapshot")
    alert_steam_flags(closing_result$steam, creds, con)
    safe_run(compute_wnba_clv(con), "CLV settlement")
  } else {
    log_info("Closing already captured for all near-tip games, skipping")
  }
}

# ── Step 3b: Continuous steam check (every invocation) ───────────────────────
#
# The named-snapshot checks (opener→midday, midday→closing) only fire at 3 windows.
# This step runs every 30 min and compares the two most-recent distinct snapshots
# in the DB, regardless of their names. Catches intraday moves that fall between
# the fixed windows.

continuous_steam <- tryCatch({
  # Pull the two most-recent snapshot timestamps for today
  recent_snaps <- dbGetQuery(con, "
    SELECT DISTINCT snapshot_type, pulled_at
    FROM lines
    WHERE DATE(pulled_at) = ?
    ORDER BY pulled_at DESC
    LIMIT 2
  ", list(format(now_et(), "%Y-%m-%d"))) |> as_tibble()

  if (nrow(recent_snaps) == 2) {
    type_late  <- recent_snaps$snapshot_type[1]
    type_early <- recent_snaps$snapshot_type[2]

    if (type_late != type_early) {
      snap_late  <- dbGetQuery(con, "SELECT * FROM lines WHERE snapshot_type = ?",
                               list(type_late))  |> as_tibble()
      snap_early <- dbGetQuery(con, "SELECT * FROM lines WHERE snapshot_type = ?",
                               list(type_early)) |> as_tibble()

      log_info("Continuous steam check: comparing '", type_early, "' → '", type_late, "'")
      cont_steam <- detect_steam(snap_early, snap_late, con = con)
      alert_steam_flags(cont_steam, creds, con)
    } else {
      log_info("Continuous steam check: only one snapshot type today, skipping")
      tibble()
    }
  } else {
    log_info("Continuous steam check: fewer than 2 snapshots today, skipping")
    tibble()
  }
}, error = function(e) {
  log_info("Continuous steam check error:", conditionMessage(e))
  tibble()
})

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
today_str <- format(now_et(), "%Y-%m-%d")

BOOK_PREF <- c("pinnacle", "betonlineag", "bookmaker", "lowvig", "draftkings", "fanduel")

# ── 1. Today's slate with current lines ───────────────────────────────────────

latest_snap_type <- tryCatch(
  dbGetQuery(con, "
    SELECT snapshot_type FROM lines
    WHERE DATE(pulled_at) = ?
    ORDER BY pulled_at DESC LIMIT 1
  ", list(today_str))$snapshot_type[1],
  error = function(e) NULL
)

game_lines_msg <- ""

if (!is.null(latest_snap_type) && length(latest_snap_type) > 0) {
  snap <- tryCatch(
    dbGetQuery(con, "SELECT * FROM lines WHERE snapshot_type = ? AND DATE(pulled_at) = ?",
               list(latest_snap_type, today_str)) |> as_tibble(),
    error = function(e) tibble()
  )

  if (nrow(snap) > 0) {
    spreads <- snap |>
      filter(market == "spreads", outcome_name == home_team) |>
      mutate(book_rank = match(bookmaker, BOOK_PREF, nomatch = 99L)) |>
      group_by(game_id) |>
      slice_min(book_rank, n = 1, with_ties = FALSE) |>
      ungroup() |>
      select(game_id, home_spread = point)

    totals <- snap |>
      filter(market == "totals", outcome_name == "Over") |>
      mutate(book_rank = match(bookmaker, BOOK_PREF, nomatch = 99L)) |>
      group_by(game_id) |>
      slice_min(book_rank, n = 1, with_ties = FALSE) |>
      ungroup() |>
      select(game_id, total = point)

    games <- snap |>
      distinct(game_id, home_team, away_team, commence_time) |>
      left_join(spreads, by = "game_id") |>
      left_join(totals,  by = "game_id") |>
      mutate(
        tip_et = format(with_tz(ymd_hms(commence_time, tz = "UTC"), "America/New_York"),
                        "%I:%M %p"),
        fav_str = dplyr::case_when(
          !is.na(home_spread) & home_spread < 0 ~ paste0(home_team, " ",  home_spread),
          !is.na(home_spread) & home_spread > 0 ~ paste0(away_team, " -", home_spread),
          !is.na(home_spread)                   ~ "PK",
          TRUE                                  ~ "N/A"
        ),
        line_str = ifelse(
          !is.na(total),
          paste0(fav_str, " | o/u ", total),
          fav_str
        )
      ) |>
      arrange(commence_time)

    game_lines_msg <- paste0(
      "\U0001f4c5 *", toupper(latest_snap_type), " — ", nrow(games), " game(s)*\n",
      paste0("  • ", games$away_team, " @ ", games$home_team,
             " (", games$tip_et, ") | ", games$line_str,
             collapse = "\n")
    )
  }
}

# ── 2. Steam details ──────────────────────────────────────────────────────────

steam_count <- tryCatch(
  dbGetQuery(con, "SELECT COUNT(*) AS n FROM steam_movements WHERE DATE(detected_at) = ?",
             list(today_str))$n,
  error = function(e) 0L
)

steam_msg <- if (steam_count > 0) {
  steam_rows <- tryCatch(
    dbGetQuery(con, "
      SELECT s.market, s.outcome_name, s.direction,
             ROUND(s.magnitude, 1) AS magnitude, s.books_moved,
             l.home_team, l.away_team
      FROM steam_movements s
      LEFT JOIN (SELECT DISTINCT game_id, home_team, away_team FROM lines) l
        ON l.game_id = s.game_id
      WHERE DATE(s.detected_at) = ?
      ORDER BY s.detected_at DESC
    ", list(today_str)) |> as_tibble(),
    error = function(e) tibble()
  )
  if (nrow(steam_rows) > 0) {
    lines_out <- vapply(seq_len(nrow(steam_rows)), function(i) {
      r       <- steam_rows[i, ]
      matchup <- if (!is.na(r$home_team)) paste0(r$away_team, " @ ", r$home_team) else "Unknown"
      arrow   <- if (identical(r$direction, "up")) "↑" else "↓"
      paste0("  • ", matchup, " | ", r$market, " ", arrow,
             r$magnitude, "pts | ", r$books_moved, " books")
    }, character(1))
    paste0("\U0001f525 *Steam (", steam_count, ")*\n", paste(lines_out, collapse = "\n"))
  } else "\U0001f525 No steam today"
} else "\U0001f525 No steam today"

# ── 3. Injury details ─────────────────────────────────────────────────────────

injury_count <- tryCatch(
  dbGetQuery(con, "SELECT COUNT(*) AS n FROM injury_reports WHERE DATE(ingested_at) = ?",
             list(today_str))$n,
  error = function(e) 0L
)

injury_msg <- if (injury_count > 0) {
  inj_rows <- tryCatch(
    dbGetQuery(con, "
      SELECT player_name, team, status
      FROM injury_reports
      WHERE DATE(ingested_at) = ?
      ORDER BY ingested_at DESC
    ", list(today_str)) |> as_tibble(),
    error = function(e) tibble()
  )
  if (nrow(inj_rows) > 0) {
    paste0(
      "\U0001fa79 *Injuries (", injury_count, ")*\n",
      paste0("  • ", inj_rows$player_name, " (", inj_rows$team, ") — ", inj_rows$status,
             collapse = "\n")
    )
  } else "\U0001fa79 No injuries today"
} else "\U0001fa79 No injuries today"

# ── Assemble and send ─────────────────────────────────────────────────────────

header <- paste0("\U0001f3c0 *WNBA Pipeline* | ", format(now_et(), "%b %d %I:%M %p ET"))

summary_msg <- paste(
  Filter(nzchar, c(header, game_lines_msg, steam_msg, injury_msg)),
  collapse = "\n\n"
)

safe_run(send_telegram(summary_msg, creds), "telegram run summary")
safe_run(send_discord(summary_msg,  creds), "discord run summary")

log_info("Pipeline run complete")
log_info("──────────────────────────────────────────")
