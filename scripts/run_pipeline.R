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
source(here("scripts", "shadow_model", "mispricing.R"))
source(here("scripts", "rotowire_injuries.R"))
source(here("scripts", "action_network.R"))
source(here("scripts", "bet_alerts.R"))
source(here("scripts", "wnba_settle.R"))

# ── Config ────────────────────────────────────────────────────────────────────

TZ_LOCAL        <- "America/New_York"
SETTLE_HOUR     <- 10L   # 10:00 AM ET — settlement + on/off refresh (no odds)
OPEN_HOUR       <- 15L   # 3:00 PM ET — opener odds snapshot (WNBA books post by ~2-3 PM ET)
MIDDAY_HOUR     <- 17L   # 5:00 PM ET — midday odds snapshot (2 hrs before typical tip)
PRE_TIP_MINS    <- 70L   # minutes before tip-off to take closing snapshot
SEASON          <- as.integer(format(Sys.Date(), "%Y"))

# ── Startup ───────────────────────────────────────────────────────────────────

log_info("──────────────────────────────────────────")
log_info("WNBA pipeline started")
log_info("Pipeline invoked at", format(now("UTC"), "%Y-%m-%d %H:%M:%S"), "UTC")

# Load credentials and initialize key state
creds <- safe_run(load_credentials(), "load credentials")
if (is.null(creds)) stop("Cannot continue without credentials.")
key_state$init(creds)

# Ensure DB exists and schema is current
safe_run(init_db(), "db init")

# Open DB connection — shared across all steps this invocation
con <- open_wnba_db()
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
  utc_lo    <- paste0(today_str, "T04:00:00Z")
  utc_hi    <- paste0(format(as.Date(today_str) + 1L, "%Y-%m-%d"), "T04:00:00Z")

  games <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT game_id, commence_time
      FROM lines
      WHERE commence_time >= ? AND commence_time < ?
    ", list(utc_lo, utc_hi)) |> as_tibble(),
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

STEAM_CHANNEL_ID <- "1521690907760525342"  # #steam-alerts

alert_steam_flags <- function(steam_df, creds, con) {
  if (is.null(steam_df) || nrow(steam_df) == 0) return(invisible(NULL))

  game_meta <- tryCatch(
    dbGetQuery(con, "SELECT game_id, home_team, away_team FROM games") |>
      as_tibble(),
    error = function(e) tibble(game_id = character(), home_team = character(),
                               away_team = character())
  )

  for (i in seq_len(nrow(steam_df))) {
    row <- steam_df[i, ]

    # Dedup gate — only alert once per (game, market, outcome, direction)
    new_steam <- tryCatch(
      is_new_steam(con, row$game_id, row$market, row$outcome_name,
                   row$direction, row$magnitude, row$books_moved),
      error = function(e) TRUE  # fail open: alert if dedup check errors
    )
    if (!new_steam) next

    meta <- game_meta |> filter(game_id == row$game_id)
    msg  <- format_steam_alert(
      row,
      home_team = if (nrow(meta) > 0) meta$home_team[1] else NULL,
      away_team = if (nrow(meta) > 0) meta$away_team[1] else NULL
    )
    safe_run(send_telegram(msg, creds), paste("steam telegram alert", i))
    safe_run(send_discord(msg, creds, channel_id = STEAM_CHANNEL_ID), paste("steam discord alert", i))
    Sys.sleep(1)
  }

  safe_run(record_clv_entry(steam_df, con), "CLV entry logging")
}

# ── Step 0: Morning settlement + on/off refresh (10 AM ET, no odds) ──────────
#
# Decoupled from odds collection so settlement runs early regardless of when
# WNBA books post lines (typically 2-3 PM ET, too late for a 10 AM opener).

if (hour_et() >= SETTLE_HOUR && !has_run_today("settle", con)) {
  log_info("MORNING — settling yesterday's completed games")
  safe_run(wnba_settle_run(con), "WNBA score settlement")

  log_info("MORNING — refreshing on/off net ratings")
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

  mark_run_today("settle", con)
}

# ── Step 1: Opener odds snapshot (3 PM ET) ───────────────────────────────────
#
# WNBA books typically post same-day lines by 2-3 PM ET. Running at 3 PM
# ensures a populated baseline for the 5 PM midday steam comparison.

if (hour_et() >= OPEN_HOUR) {
  today_str    <- format(now_et(), "%Y-%m-%d")
  opener_count <- tryCatch(
    dbGetQuery(con, "
      SELECT COUNT(*) AS n FROM lines
      WHERE snapshot_type = 'opener'
        AND DATE(pulled_at) = ?
    ", list(today_str))$n,
    error = \(e) 1L
  )

  if (opener_count == 0) {
    log_info("OPEN window — fetching opener snapshot")
    opener_result <- safe_run(run_collection("opener", con), "opener snapshot")
  } else {
    log_info("OPEN window — opener already captured today, skipping")
  }
}

# ── Step 2: Midday odds snapshot (5 PM ET) ───────────────────────────────────

if (hour_et() >= MIDDAY_HOUR) {
  today_str     <- format(now_et(), "%Y-%m-%d")
  midday_count  <- tryCatch(
    dbGetQuery(con, "
      SELECT COUNT(*) AS n FROM lines
      WHERE snapshot_type = 'midday'
        AND DATE(pulled_at) = ?
    ", list(today_str))$n,
    error = \(e) 1L
  )

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
  already_closed <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT game_id FROM lines WHERE snapshot_type = 'closing'
    ")$game_id,
    error = \(e) character(0)
  )

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

# Resolve steam dedup entries for games that just closed — runs after Step 3b
# so the dedup gate blocks re-detection within the same invocation.
if (length(near_tip_games) > 0) {
  walk(near_tip_games, function(gid) resolve_steam(con, gid))
}

# ── Step 4: XGBoost CLV logging (steam-triggered, no alerts) ─────────────────
#
# When steam is detected, log XGBoost predictions to clv_log for calibration.
# Alerts are NOT fired here — they come from Step 4b (mispricing + steam gate).
# This keeps the two approaches independently trackable in clv_log via trigger col.

if (file.exists(here("models", "totals_xgb.rds"))) {
  steam_today <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT game_id, direction, magnitude, books_moved, detected_at
      FROM steam_movements
      WHERE DATE(detected_at) = ?
      ORDER BY detected_at DESC
    ", list(format(now_et(), "%Y-%m-%d"))) |>
      as_tibble() |>
      distinct(game_id, .keep_all = TRUE),
    error = \(e) tibble()
  )

  if (nrow(steam_today) > 0) {
    team_box_cache <- safe_run(
      wehoop::load_wnba_team_box(seasons = SEASON),
      "load team box for XGBoost CLV log"
    )
    walk(seq_len(nrow(steam_today)), function(i) {
      safe_run(
        run_prediction(steam_today$game_id[i], steam_today[i, ], con,
                       team_box = team_box_cache),
        paste("XGBoost CLV log for", steam_today$game_id[i])
      )
    })
    log_info("XGBoost CLV log complete —", nrow(steam_today), "steam game(s)")
  }
} else {
  log_info("XGBoost models not trained yet — skipping CLV log step")
}

# ── Step 4b: Mispricing model — Pinnacle deviation + steam gate ───────────────
#
# Fires once per day at MIDDAY_HOUR (5 PM ET). Alert fires only when BOTH:
#   1. Soft book total deviates from injury-adjusted Pinnacle by >= DEV_THRESHOLD
#   2. Steam today confirms the model's direction (down for UNDER, up for OVER)
#
# XGBoost (Step 4) only logs to clv_log for calibration — it does not alert.

if (hour_et() >= MIDDAY_HOUR && !has_run_today("mispricing_model", con)) {
  log_info("Step 4b: mispricing model — Pinnacle deviation + steam gate")

  today_games <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT game_id FROM lines
      WHERE DATE(commence_time, '-4 hours') = ?
    ", list(format(now_et(), "%Y-%m-%d"))) |> as_tibble(),
    error = \(e) tibble(game_id = character(0))
  )

  # ── Injury snapshot: ESPN + RotoWire merged ───────────────────────────────────
  espn_raw  <- safe_run(fetch_all_injuries(), "ESPN injuries")
  espn_named <- if (!is.null(espn_raw) && nrow(espn_raw) > 0) {
    teams_map <- safe_run(fetch_espn_teams(), "ESPN team names")
    if (!is.null(teams_map) && "team_id" %in% names(espn_raw))
      left_join(espn_raw, teams_map, by = "team_id")
    else espn_raw
  } else NULL

  rw_raw <- safe_run(fetch_rotowire_injuries(), "RotoWire injuries")

  injuries_with_names <- merge_injury_sources(espn_named, rw_raw)
  if (nrow(injuries_with_names) == 0) injuries_with_names <- NULL

  # ── Action Network sharp money (secondary gate) ───────────────────────────────
  an_data <- safe_run(
    fetch_wnba_sharp_report(date = as.Date(format(now_et(), "%Y-%m-%d"))),
    "Action Network sharp report"
  )

  # ── Steam movements today (primary gate, totals + spreads) ───────────────────
  steam_today_all <- tryCatch(
    dbGetQuery(con, "
      SELECT game_id, direction, market FROM steam_movements
      WHERE DATE(detected_at) = ?
    ", list(format(now_et(), "%Y-%m-%d"))) |> as_tibble(),
    error = \(e) tibble()
  )

  if (nrow(today_games) > 0) {
    walk(today_games$game_id, function(gid) {
      misprice <- safe_run(
        compute_mispricing(gid, con, injuries_with_names),
        paste("mispricing for", gid)
      )
      if (is.null(misprice)) return(invisible(NULL))

      # Get game teams for AN lookup
      meta <- tryCatch(
        dbGetQuery(con, "SELECT DISTINCT home_team, away_team FROM lines WHERE game_id = ? LIMIT 1",
                   list(gid)) |> as_tibble(),
        error = \(e) tibble()
      )
      home_t <- if (nrow(meta) > 0) meta$home_team[1] else ""
      away_t <- if (nrow(meta) > 0) meta$away_team[1] else ""

      # Each mispricing row is one market (totals or spreads) — gate per row
      for (j in seq_len(nrow(misprice))) {
        row        <- misprice[j, ]
        mkt        <- row$market
        model_side <- row$side

        # Steam gate: direction must match model side for this market
        game_steam <- steam_today_all |>
          filter(game_id == gid, grepl(sub("s$", "", mkt), market, ignore.case = TRUE))

        steam_agrees <- nrow(game_steam) > 0 && any(
          (model_side %in% c("under", "away") & game_steam$direction == "down") |
          (model_side %in% c("over",  "home")  & game_steam$direction == "up")
        )

        # Action Network gate: sharp money on same side
        an_agrees <- isTRUE(an_confirms(row, an_data, home_t, away_t))

        if (!steam_agrees && !an_agrees) {
          log_info(sprintf("Mispricing %s %s %s — no steam or AN confirmation, skipping",
                           gid, mkt, toupper(model_side)))
          next
        }

        gate_source <- if (steam_agrees && an_agrees) "steam+AN"
                       else if (steam_agrees) "steam"
                       else "AN"
        log_info(sprintf("Alert gate passed for %s %s %s [%s]",
                         gid, mkt, toupper(model_side), gate_source))

        safe_run(
          emit_wnba_bet_alert(
            game_id         = row$game_id,
            market          = row$market,
            side            = row$side,
            model_line      = row$adj_pinnacle,
            mkt_line        = row$soft_line,
            con             = con,
            creds           = creds,
            steam_confirmed = steam_agrees   # HIGH confidence if steam confirmed
          ),
          paste("mispricing alert for", gid, mkt)
        )
      }
    })

    mark_run_today("mispricing_model", con)
    log_info("Step 4b: mispricing model complete —", nrow(today_games), "game(s) evaluated")
  } else {
    log_info("Step 4b: no games found for today")
  }
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

# Closing snapshot = full-day steam recap; all other runs = last 35 min only
is_closing_run <- identical(latest_snap_type, "closing")
steam_time_sql <- ifelse(is_closing_run, "", "AND s.first_detected >= datetime('now', '-35 minutes')")
count_time_sql <- ifelse(is_closing_run, "", "AND first_detected >= datetime('now', '-35 minutes')")

steam_count <- tryCatch(
  dbGetQuery(con, paste0("
    SELECT COUNT(*) AS n FROM steam_log
    WHERE DATE(first_detected) = ? AND alert_sent = 1 ", count_time_sql),
    list(today_str))$n,
  error = function(e) 0L
)

steam_msg <- if (steam_count > 0) {
  steam_rows <- tryCatch(
    dbGetQuery(con, paste0("
      SELECT s.market, s.outcome_name, s.direction,
             ROUND(s.magnitude, 1) AS magnitude, s.books_moved,
             l.home_team, l.away_team
      FROM steam_log s
      LEFT JOIN games l ON l.game_id = s.game_id
      WHERE DATE(s.first_detected) = ?
        AND s.alert_sent = 1 ", steam_time_sql, "
      ORDER BY s.first_detected DESC
    "), list(today_str)) |> as_tibble(),
    error = function(e) tibble()
  )
  if (nrow(steam_rows) > 0) {
    # Group by matchup+market; flag when both ↑ and ↓ detected (book disagreement)
    lines_out <- steam_rows |>
      dplyr::group_by(home_team, away_team, market) |>
      dplyr::summarise(
        directions = paste(sort(unique(direction)), collapse = "+"),
        mag_up     = max(magnitude[direction == "up"],   na.rm = TRUE),
        mag_dn     = max(magnitude[direction == "down"], na.rm = TRUE),
        books      = max(books_moved),
        .groups = "drop"
      ) |>
      dplyr::mutate(
        matchup     = ifelse(!is.na(home_team),
                             paste0(away_team, " @ ", home_team), "Unknown"),
        conflict    = grepl("up", directions) & grepl("down", directions),
        line_str    = dplyr::case_when(
          conflict ~ sprintf("⚡ CONFLICT ↑%.1fpts / ↓%.1fpts | %d books split",
                             mag_up, mag_dn, books),
          grepl("up",   directions) ~ sprintf("↑%.1fpts | %d books", mag_up, books),
          grepl("down", directions) ~ sprintf("↓%.1fpts | %d books", mag_dn, books),
          TRUE ~ "?"
        )
      ) |>
      dplyr::arrange(dplyr::desc(conflict), matchup)

    bullets <- vapply(seq_len(nrow(lines_out)), function(i) {
      r <- lines_out[i, ]
      paste0("  • ", r$matchup, " | ", r$market, " ", r$line_str)
    }, character(1))

    n_conflict <- sum(lines_out$conflict)
    header_tag <- if (n_conflict > 0)
      sprintf("Steam (%d, %d⚡ conflict)", nrow(lines_out), n_conflict)
    else
      sprintf("Steam (%d)", nrow(lines_out))

    paste0("\U0001f525 *", header_tag, "*\n", paste(bullets, collapse = "\n"))
  } else "\U0001f525 No new steam"
} else if (is_closing_run) "\U0001f525 No steam today" else "\U0001f525 No new steam"

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

# Send summary only:
#   (a) within game hours  — 3 PM ET through 2 AM ET (hour >= OPEN_HOUR OR hour < 2)
#   (b) not a repeated closing recap — closing state fires every 30 min for hours;
#       only send the full-day recap once and mark it done
within_game_hours    <- hour_et() >= OPEN_HOUR || hour_et() < 2L
closing_already_sent <- is_closing_run && has_run_today("closing_summary", con)

if (!within_game_hours) {
  log_info("Summary suppressed — outside game hours (before 3 PM or after 2 AM ET)")
} else if (closing_already_sent) {
  log_info("Summary suppressed — closing recap already sent today")
} else {
  safe_run(send_telegram(summary_msg, creds), "telegram run summary")
  safe_run(send_discord(summary_msg, creds, channel_id = STEAM_CHANNEL_ID), "discord run summary")
  if (is_closing_run) mark_run_today("closing_summary", con)
}

log_info("Pipeline run complete")
log_info("──────────────────────────────────────────")
