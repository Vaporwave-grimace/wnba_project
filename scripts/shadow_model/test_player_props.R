# scripts/shadow_model/test_player_props.R
# Smoke tests for the WNBA player props model. Run with:
#   Rscript scripts/shadow_model/test_player_props.R
# Mirrors the check()/pass()/fail() style of scripts/test_pipeline.R —
# this project doesn't use testthat, tests run against a real (temp)
# SQLite file instead of mocks.

library(here)
library(DBI)
library(RSQLite)

pass <- function(label) cat(sprintf("  [PASS] %s\n", label))
fail <- function(label, reason) cat(sprintf("  [FAIL] %s -- %s\n", label, reason))
section <- function(label) cat(sprintf("\n-- %s --\n", label))

errors <- 0L
check <- function(label, expr) {
  tryCatch({
    result <- expr
    pass(label)
    invisible(result)
  }, error = function(e) {
    fail(label, conditionMessage(e))
    errors <<- errors + 1L
    invisible(NULL)
  })
}

source(here("scripts", "db_setup.R"))

# ── Task 1: schema ────────────────────────────────────────────────────────────
section("Task 1: player props schema")

tmp_db <- tempfile(fileext = ".sqlite")
init_db(tmp_db)
con <- open_wnba_db(tmp_db)

check("player_box_scores table exists", {
  stopifnot("player_box_scores" %in% dbListTables(con))
})
check("player_box_scores has expected columns", {
  cols <- dbListFields(con, "player_box_scores")
  expected <- c("game_id", "game_date", "player_name", "team", "opponent",
               "min", "pts", "reb", "ast")
  stopifnot(all(expected %in% cols))
})
check("player_prop_lines table exists", {
  stopifnot("player_prop_lines" %in% dbListTables(con))
})
check("team_def_factors table exists", {
  stopifnot("team_def_factors" %in% dbListTables(con))
})
check("odds_api_quota_log table exists", {
  stopifnot("odds_api_quota_log" %in% dbListTables(con))
})
check("prop_min_books seeded in model_config with default 3", {
  v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'prop_min_books'")$value
  stopifnot(length(v) == 1, abs(v - 3) < 1e-9)
})
check("prop_main_line_tol seeded in model_config with default 1.5", {
  v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'prop_main_line_tol'")$value
  stopifnot(length(v) == 1, abs(v - 1.5) < 1e-9)
})
check("init_db is safe to re-run (idempotent)", {
  init_db(tmp_db)   # must not error on second call
  TRUE
})

dbDisconnect(con)
file.remove(tmp_db)

source(here("scripts", "shadow_model", "player_props.R"))

# ── Task 2: sync_player_box_scores ────────────────────────────────────────────
section("Task 2: sync_player_box_scores")

tmp_db2 <- tempfile(fileext = ".sqlite")
init_db(tmp_db2)
con2 <- open_wnba_db(tmp_db2)

check("sync_player_box_scores writes real 2025 rows", {
  n <- sync_player_box_scores(con2, season = 2025L)
  stopifnot(n > 0)
})
check("player_box_scores has plausible row count for a season", {
  n <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM player_box_scores")$n
  stopifnot(n > 1000)   # WNBA season is ~300 team-games x ~10 rostered players
})
check("re-running sync is idempotent (no duplicate rows)", {
  before <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM player_box_scores")$n
  sync_player_box_scores(con2, season = 2025L)
  after  <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM player_box_scores")$n
  stopifnot(before == after)
})
check("min column is numeric, not character", {
  row <- dbGetQuery(con2, "SELECT min FROM player_box_scores LIMIT 1")
  stopifnot(is.numeric(row$min))
})

dbDisconnect(con2)
file.remove(tmp_db2)

# ── Task 3: compute_team_def_factors ──────────────────────────────────────────
section("Task 3: compute_team_def_factors")

tmp_db3 <- tempfile(fileext = ".sqlite")
init_db(tmp_db3)
con3 <- open_wnba_db(tmp_db3)

# Seed synthetic box scores: "Strong Defense" allows very little (should
# clamp to the floor), "Weak Defense" allows a lot (should clamp to the
# ceiling), "New Team" has only 3 games (should passthrough to 1.0).
seed_rows <- function(con, opponent, n_games, pts_allowed) {
  for (g in seq_len(n_games)) {
    dbExecute(con, "
      INSERT INTO player_box_scores
        (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ", list(paste0("g", opponent, g), "2026-06-01", paste0("p", opponent, g),
            "Some Team", opponent, 30, pts_allowed, 5, 3))
  }
}
seed_rows(con3, "Strong Defense", 8, 5)    # allows very few points
seed_rows(con3, "Weak Defense",   8, 40)   # allows a lot of points
seed_rows(con3, "New Team",       3, 5)    # below MIN_GAMES_FOR_DEF_FACTOR

check("compute_team_def_factors writes rows for all 3 synthetic teams", {
  compute_team_def_factors(con3, season = 2026L)
  n <- dbGetQuery(con3, "SELECT COUNT(DISTINCT team) AS n FROM team_def_factors")$n
  stopifnot(n == 3)
})
check("Strong Defense clamps to the floor (0.85)", {
  f <- dbGetQuery(con3, "SELECT factor FROM team_def_factors WHERE team = 'Strong Defense' AND stat = 'pts'")$factor
  stopifnot(abs(f - 0.85) < 1e-9)
})
check("Weak Defense clamps to the ceiling (1.15)", {
  f <- dbGetQuery(con3, "SELECT factor FROM team_def_factors WHERE team = 'Weak Defense' AND stat = 'pts'")$factor
  stopifnot(abs(f - 1.15) < 1e-9)
})
check("New Team (< MIN_GAMES_FOR_DEF_FACTOR) passes through at 1.0", {
  f <- dbGetQuery(con3, "SELECT factor FROM team_def_factors WHERE team = 'New Team' AND stat = 'pts'")$factor
  stopifnot(abs(f - 1.0) < 1e-9)
})
check("pra stat is written too", {
  n <- dbGetQuery(con3, "SELECT COUNT(*) AS n FROM team_def_factors WHERE stat = 'pra'")$n
  stopifnot(n == 3)
})

dbDisconnect(con3)
file.remove(tmp_db3)

# ── Task 4: compute_prop_projection ───────────────────────────────────────────
section("Task 4: compute_prop_projection")

tmp_db4 <- tempfile(fileext = ".sqlite")
init_db(tmp_db4)
con4 <- open_wnba_db(tmp_db4)

seed_player_games <- function(con, player, pts_vec) {
  for (i in seq_along(pts_vec)) {
    dbExecute(con, "
      INSERT INTO player_box_scores
        (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ", list(paste0("g", i), sprintf("2026-06-%02d", i), player,
            "Some Team", "Rival Team", 30, pts_vec[i], 4, 3))
  }
}

# 12 games so the 10-game rolling window actually trims the oldest 2.
# First two values (indices 1-2) are trimmed by the rolling window, so
# they're irrelevant to the mean -- the remaining 10 (indices 3-12) sum to
# 100 (8+12+9+11+10+13+7+10+12+8), mean = 10.0 exactly, but with real
# variance so baseline_sd != 0 for pts.
seed_player_games(con4, "Steady Scorer", c(10,10, 8,12,9,11,10,13,7,10,12,8))
seed_player_games(con4, "One Gamer", c(20))
dbExecute(con4, "
  INSERT INTO team_def_factors (team, stat, allowed_avg, league_avg, factor, season, updated_at)
  VALUES ('Rival Team', 'pts', 22, 20, 1.1, 2026, datetime('now'))
")

check("projection uses last 10 games, applies def factor", {
  p <- compute_prop_projection("Steady Scorer", "pts", "Rival Team", con4, season = 2026L)
  stopifnot(!is.null(p))
  stopifnot(p$n_games == 10)
  stopifnot(abs(p$baseline_mean - 10) < 1e-9)
  stopifnot(abs(p$projected_mean - 11) < 1e-9)   # 10 * 1.1
})
check("PRA computed as summed pts+reb+ast, not summed averages", {
  p <- compute_prop_projection("Steady Scorer", "pra", "Rival Team", con4, season = 2026L)
  stopifnot(!is.null(p))
  stopifnot(abs(p$baseline_mean - (10 + 4 + 3)) < 1e-9)
})
check("zero-SD guard skips single-game players", {
  p <- compute_prop_projection("One Gamer", "pts", "Rival Team", con4, season = 2026L)
  stopifnot(is.null(p))
})
check("zero-SD guard skips constant-stat players on realistic non-NA data", {
  # reb is hardcoded to 4 for every seeded game -- sd(reb) is a real,
  # non-NA 0, not NA. This proves the restored `baseline_sd == 0` branch
  # of the guard actually fires (not just the is.na() branch above).
  p <- compute_prop_projection("Steady Scorer", "reb", "Rival Team", con4, season = 2026L)
  stopifnot(is.null(p))
})
check("unknown opponent falls back to def_factor 1.0", {
  p <- compute_prop_projection("Steady Scorer", "pts", "Nonexistent Team", con4, season = 2026L)
  stopifnot(!is.null(p))
  stopifnot(abs(p$def_factor - 1.0) < 1e-9)
})

dbDisconnect(con4)
file.remove(tmp_db4)

# ── Task 5: check_quota_headroom ──────────────────────────────────────────────
source(here("scripts", "odds_ingest.R"))
source(here("scripts", "injury_alert.R"))   # send_telegram()/send_discord() live here --
                                             # without this, the fake-credential calls
                                             # below fail on "function not found" instead
                                             # of a real (failing) HTTP call, which is a
                                             # false-positive pass for the tryCatch path.

section("Task 5: check_quota_headroom")

tmp_db5 <- tempfile(fileext = ".sqlite")
init_db(tmp_db5)
con5 <- open_wnba_db(tmp_db5)

fake_creds <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                   discord_bot_token = "x", discord_webhook_url = "x")

# key_state is a module-level singleton (local({}) closure) -- drive it
# directly via its own public update_remaining()/init() API rather than
# mocking, matching this project's live-only testing convention.
key_state$init(list(odds_api_keys = c("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                                      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
key_state$update_remaining(200)   # below the 500 floor -- should alert

check("check_quota_headroom logs a row per key", {
  # send_telegram/send_discord will attempt real network calls with fake
  # creds and fail -- that's fine, they're wrapped in tryCatch below and
  # the log-write must still succeed regardless.
  suppressMessages(check_quota_headroom(con5, fake_creds, channel_id = "0", floor = 500L))
  n <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log")$n
  stopifnot(n >= 1)
})
check("low-quota row is marked alerted", {
  n <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE alerted = 1")$n
  stopifnot(n >= 1)
})
check("second call same day does not double-alert the same key", {
  before <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE alerted = 1")$n
  suppressMessages(check_quota_headroom(con5, fake_creds, channel_id = "0", floor = 500L))
  after <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE alerted = 1")$n
  # a new row is logged each call, but only the first should be flagged alerted=1
  stopifnot(after == before)
})

dbDisconnect(con5)
file.remove(tmp_db5)

# ── UTC dedup regression test ─────────────────────────────────────────────
# Directly proves the fix for the UTC/local timezone mismatch: the dedup
# check must compare checked_at against SQLite's own UTC clock
# (DATE('now')), not an R-side DATE(Sys.Date()) local-time string. Rather
# than fake the host machine's timezone, this inserts a synthetic
# already-alerted row stamped with SQLite's own datetime('now') (guaranteed
# same UTC day as whatever check_quota_headroom will compute), then calls
# check_quota_headroom() and confirms no additional alerted=1 row appears
# for that key -- i.e. the dedup recognizes the synthetic row as "already
# alerted today" purely via the SQL-side DATE comparison, with no R-side
# date variable involved at all. Uses a fresh DB/connection so there's no
# collision with key_index values already written by the checks above.
tmp_db6 <- tempfile(fileext = ".sqlite")
init_db(tmp_db6)
con6 <- open_wnba_db(tmp_db6)

key_state$init(list(odds_api_keys = c("cccccccccccccccccccccccccccccccc")))
key_state$update_remaining(200)   # below the 500 floor

dbExecute(con6, "
  INSERT INTO odds_api_quota_log (key_index, key_tail, remaining, checked_at, alerted)
  VALUES (1, 'cccccc', 200, datetime('now'), 1)
")

check("UTC-day dedup: pre-seeded same-UTC-day alerted row suppresses a new alert", {
  before <- dbGetQuery(con6, "
    SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE key_index = 1 AND alerted = 1
  ")$n
  stopifnot(before == 1)   # sanity: only the synthetic row so far

  suppressMessages(check_quota_headroom(con6, fake_creds, channel_id = "0", floor = 500L))

  after <- dbGetQuery(con6, "
    SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE key_index = 1 AND alerted = 1
  ")$n
  # A new (unalerted) row is logged for this call, but the dedup check --
  # now computed entirely in SQL against DATE('now') -- must see the
  # synthetic row as "already alerted today" and NOT flag the new row too.
  stopifnot(after == 1)
})

dbDisconnect(con6)
file.remove(tmp_db6)

# ── Task 7: bet_side encoding ──────────────────────────────────────────────────
section("Task 7: .encode_prop_bet_side")

source(here("scripts", "bet_alerts.R"))

check("encodes stat/side/point/player into pipe-delimited string", {
  s <- .encode_prop_bet_side("pts", "over", 24.5, "Sabrina Ionescu")
  stopifnot(s == "PTS|OVER|24.5|Sabrina Ionescu")
})
check("handles player names with apostrophes", {
  s <- .encode_prop_bet_side("reb", "under", 8.5, "A'ja Wilson")
  stopifnot(s == "REB|UNDER|8.5|A'ja Wilson")
})
check("round-trips through a manual split", {
  s <- .encode_prop_bet_side("ast", "over", 5.5, "Julie Allemand")
  parts <- strsplit(s, "|", fixed = TRUE)[[1]]
  stopifnot(parts[1] == "AST", parts[2] == "OVER", parts[3] == "5.5",
           parts[4] == "Julie Allemand")
})

# ── Task 8: emit_wnba_bet_alert() returns play/fair_odds ───────────────────────
section("Task 8: emit_wnba_bet_alert() play/fair_odds in return value")

tmp_db8 <- tempfile(fileext = ".sqlite")
init_db(tmp_db8)
con8 <- open_wnba_db(tmp_db8)

# Must insert into games first due to foreign key constraint in lines table
dbExecute(con8, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game8', '2026-06-10T23:00:00Z', 'Home Team', 'Rival Team')
")
dbExecute(con8, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game8', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
dbExecute(con8, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 7.5, datetime('now'))
")

fake_creds8 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                    discord_bot_token = "x", discord_webhook_url = "x")

check("returned list includes play and fair_odds for a real fired alert", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game8", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con8, creds = fake_creds8,
    player_name = "Steady Scorer", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(!is.null(res$play))
  stopifnot(res$play == "Steady Scorer Over 7.5 PTS")
  stopifnot(!is.na(res$fair_odds))
  stopifnot(is.numeric(res$fair_odds) || is.integer(res$fair_odds))
})

dbDisconnect(con8)
file.remove(tmp_db8)

# ── Task 9: send_prop_digest ────────────────────────────────────────────────────
section("Task 9: send_prop_digest")

tmp_db9 <- tempfile(fileext = ".sqlite")
init_db(tmp_db9)
con9 <- open_wnba_db(tmp_db9)

# Reuses the exact same fixture as the existing Task 4 compute_prop_projection
# tests (12 games, last 10 average to pts=10, Rival Team's def_factor=1.1
# -> projected_mean=11, real nonzero baseline_sd). player_box_scores.team =
# "Some Team" for this player, so the candidate row's OTHER team must be
# "Rival Team" for send_prop_digest's opponent lookup to resolve correctly.
seed_player_games(con9, "Steady Scorer", c(10,10, 8,12,9,11,10,13,7,10,12,8))
dbExecute(con9, "
  INSERT INTO team_def_factors (team, stat, allowed_avg, league_avg, factor, season, updated_at)
  VALUES ('Rival Team', 'pts', 22, 20, 1.1, 2026, datetime('now'))
")

# Must insert into games first due to foreign key constraint in lines table
dbExecute(con9, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game9', '2026-06-10T23:00:00Z', 'Some Team', 'Rival Team')
")
dbExecute(con9, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game9', 'midday', 'Some Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
# Over 7.5 at +120: point is far below the projected mean (11), so model_prob
# for Over is very high -- a clearly large, positive EV regardless of the
# exact baseline_sd value.
# Under 7.5 at -500: same point, but for the losing side of a clearly
# lopsided real distribution -- a clearly large NEGATIVE EV.
dbExecute(con9, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, commence_time, pulled_at)
  VALUES
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Under', -500, 7.5, datetime('now', '+2 hours'), datetime('now'))
")

fake_creds9 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                    discord_bot_token = "x", discord_webhook_url = "x")

check("digest includes the clearly-qualifying Over pick, excludes the negative-EV Under", {
  msg_sent <- NULL
  # send_discord posts for real against fake creds and fails (network error) --
  # that's fine and matches this project's existing convention (see the
  # check_quota_headroom tests above); we only need send_prop_digest's return
  # value and internal filtering logic, not a successful HTTP response.
  n <- suppressWarnings(suppressMessages(
    send_prop_digest(con9, fake_creds9, min_ev = 5.0, season = 2026L)
  ))
  stopifnot(n == 1L)
})

check("min_ev above every real edge sends zero picks", {
  n <- suppressWarnings(suppressMessages(
    send_prop_digest(con9, fake_creds9, min_ev = 500.0, season = 2026L)
  ))
  stopifnot(n == 0L)
})

# Second, independently-seeded candidate (different game/player) that also
# clearly qualifies at >=5% EV but at a smaller edge than Steady Scorer's
# Over pick -- exercises the descending-EV sort loop past a single pick.
# Last-10 window (indices 3-12, trimming the first 2): 8,10,9,10,9,11,8,9,10,8
# -> mean 9.2, projected_mean = 9.2 * 1.1 (Rival Team def_factor) = 10.12.
# Over 8.5 at -110 is a real, sizeable edge but well below Steady Scorer's
# Over 7.5 @ +120 edge (point is much closer to the projected mean here).
seed_player_games(con9, "Backup Scorer", c(9,9, 8,10,9,10,9,11,8,9,10,8))
dbExecute(con9, "
  INSERT INTO games (game_id, home_team, away_team, commence_time) VALUES ('game9b', 'Some Team', 'Rival Team', datetime('now', '+2 hours'))
")
dbExecute(con9, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game9b', 'midday', 'Some Team', 'Rival Team', datetime('now', '+2 hours'))
")
dbExecute(con9, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, commence_time, pulled_at)
  VALUES
    ('game9b', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Backup Scorer', 'Over', -110, 8.5, datetime('now', '+2 hours'), datetime('now'))
")

check("digest scales to 2 qualifying picks across 2 games", {
  n <- suppressWarnings(suppressMessages(
    send_prop_digest(con9, fake_creds9, min_ev = 5.0, season = 2026L)
  ))
  stopifnot(n == 2L)
})

check("digest message lists the higher-EV pick before the lower-EV pick", {
  # Captures the actual message send_prop_digest() would post, via a
  # test-local stub of send_discord() -- all real computation (SQL,
  # projections, EV math) still runs unmocked, matching this project's
  # no-mocking-framework convention; only the final Discord POST is
  # intercepted so the test can inspect what would have been sent.
  captured_msg <- NULL
  original_send_discord <- send_discord
  send_discord <<- function(message_text, creds, channel_id = "1499488823598387412") {
    captured_msg <<- message_text
    invisible(TRUE)
  }
  on.exit(send_discord <<- original_send_discord, add = TRUE)

  n <- suppressWarnings(suppressMessages(
    send_prop_digest(con9, fake_creds9, min_ev = 5.0, season = 2026L)
  ))
  stopifnot(n == 2L)
  stopifnot(!is.null(captured_msg))

  pos_steady <- regexpr("Steady Scorer", captured_msg)
  pos_backup <- regexpr("Backup Scorer", captured_msg)
  stopifnot(pos_steady > 0, pos_backup > 0)
  stopifnot(pos_steady < pos_backup)   # Steady Scorer's higher EV must list first
})

dbDisconnect(con9)
file.remove(tmp_db9)

# ── Task 10: prop SD calibration scale is applied in emit_wnba_bet_alert() ────
section("Task 10: .get_prop_sd_scale() applied to prop model_prob")

tmp_db10 <- tempfile(fileext = ".sqlite")
init_db(tmp_db10)
con10 <- open_wnba_db(tmp_db10)

dbExecute(con10, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game10', '2026-06-10T23:00:00Z', 'Home Team', 'Rival Team')
")
dbExecute(con10, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game10', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
dbExecute(con10, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game10', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 13.5, datetime('now'))
")

fake_creds10 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                     discord_bot_token = "x", discord_webhook_url = "x")

check(".get_prop_sd_scale falls back to 1.0 with con = NULL", {
  s <- .get_prop_sd_scale(NULL, "pts", 1.0)
  stopifnot(abs(s - 1.0) < 1e-9)
})
check(".get_prop_sd_scale falls back to 1.0 when no model_config row exists", {
  s <- .get_prop_sd_scale(con10, "pts", 1.0)
  stopifnot(abs(s - 1.0) < 1e-9)
})
check("a stored scale of 2.0 changes model_prob vs. an unscaled baseline", {
  res_unscaled <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game10", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con10, creds = fake_creds10,
    player_name = "Steady Scorer", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))

  dbExecute(con10, "
    INSERT INTO model_config (param, value, updated_at)
    VALUES ('wnba_prop_sd_scale_pts', 2.0, datetime('now'))
  ")

  res_scaled <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game10", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con10, creds = fake_creds10,
    player_name = "Steady Scorer", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))

  stopifnot(abs(res_unscaled$model_prob - res_scaled$model_prob) > 1e-6)
})

dbDisconnect(con10)
file.remove(tmp_db10)

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
