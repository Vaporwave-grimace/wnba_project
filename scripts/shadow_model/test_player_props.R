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
     'Steady Scorer', 'Over', 120, 7.5, datetime('now')),
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Over', -105, 7.5, datetime('now')),
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Over', -110, 7.5, datetime('now'))
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
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Over', -105, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Over', -110, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Under', -500, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Under', -450, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Under', -480, 7.5, datetime('now', '+2 hours'), datetime('now'))
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
     'Backup Scorer', 'Over', -110, 8.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9b', 'midday', 'player_points', 'Some Team', 'Rival Team', 'draftkings',
     'Backup Scorer', 'Over', -105, 8.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9b', 'midday', 'player_points', 'Some Team', 'Rival Team', 'fanduel',
     'Backup Scorer', 'Over', -108, 8.5, datetime('now', '+2 hours'), datetime('now'))
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
     'Steady Scorer', 'Over', 120, 13.5, datetime('now')),
    ('game10', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Over', -105, 13.5, datetime('now')),
    ('game10', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Over', -110, 13.5, datetime('now'))
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

# ── Task 11: devig / consensus-line / book-depth helpers ─────────────────────
section("Task 11: .devig_prop_prob() / .get_prop_config() / .best_prop_odds()")

check(".devig_prop_prob(-115, -115) returns exactly 0.5 (symmetric vig removed)", {
  p <- .devig_prop_prob(-115, -115)
  stopifnot(abs(p - 0.5) < 1e-9)
})
check(".devig_prop_prob falls back to raw implied prob when odds_other is NA", {
  p <- .devig_prop_prob(-115, NA_real_)
  stopifnot(abs(p - .american_to_prob(-115)) < 1e-9)
})
check(".get_prop_config falls back to module constants with con = NULL", {
  cfg <- .get_prop_config(NULL)
  stopifnot(cfg$min_books == PROP_MIN_BOOKS, abs(cfg$main_line_tol - PROP_MAIN_LINE_TOL) < 1e-9)
})

tmp_db11 <- tempfile(fileext = ".sqlite")
init_db(tmp_db11)
con11 <- open_wnba_db(tmp_db11)

check(".get_prop_config reads seeded model_config values", {
  cfg <- .get_prop_config(con11)
  stopifnot(cfg$min_books == 3L, abs(cfg$main_line_tol - 1.5) < 1e-9)
})

# 3 books at the consensus point (14.5) + 1 alt-line book (8.5) for the same
# player/market/side -- the alt-line book must be filtered out by the
# consensus-point check, not just outvoted by preference ranking.
dbExecute(con11, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'pinnacle',
     'Test Player', 'Under', -110, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'draftkings',
     'Test Player', 'Under', -105, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'fanduel',
     'Test Player', 'Under', -108, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'betmgm',
     'Test Player', 'Under', 250, 8.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'pinnacle',
     'Test Player', 'Over', -108, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'draftkings',
     'Test Player', 'Over', -102, 14.5, datetime('now'))
")

check("consensus-point filter excludes the alt-line book from book_count", {
  bo <- .best_prop_odds('game11', 'player_rebounds', 'Test Player', 'Under', con11)
  stopifnot(bo$book_count == 3L)
  stopifnot(abs(bo$point - 14.5) < 1e-9)
})
check("odds_other reflects the opposite side's best-ranked price at the consensus point", {
  # 'Over' rows: pinnacle -108, draftkings -102, both at 14.5. pinnacle ranks
  # first in BOOK_PREF, so odds_other must be pinnacle's -108, not draftkings'
  # -102 -- proves real selection, not just presence.
  bo <- .best_prop_odds('game11', 'player_rebounds', 'Test Player', 'Under', con11)
  stopifnot(!is.na(bo$odds_other))
  stopifnot(bo$odds_other == -108L)
})
# Only 2 books for this player/side -- below the default min_books (3). Also
# no opposite-side ('Under') rows at all for this player/market.
dbExecute(con11, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game11b', 'midday', 'player_assists', 'Home Team', 'Away Team', 'pinnacle',
     'Thin Player', 'Over', -110, 5.5, datetime('now')),
    ('game11b', 'midday', 'player_assists', 'Home Team', 'Away Team', 'draftkings',
     'Thin Player', 'Over', -105, 5.5, datetime('now'))
")
check("book_count below min_books returns NA book/odds/point (caller must gate)", {
  bo <- .best_prop_odds('game11b', 'player_assists', 'Thin Player', 'Over', con11)
  stopifnot(bo$book_count == 2L)
  stopifnot(is.na(bo$odds), is.na(bo$point))
})
check("odds_other is NA when no opposite-side rows exist at all", {
  bo <- .best_prop_odds('game11b', 'player_assists', 'Thin Player', 'Over', con11)
  stopifnot(is.na(bo$odds_other))
})

dbDisconnect(con11)
file.remove(tmp_db11)

# ── Task 12: book-depth gate fires through the full emitter ──────────────────
section("Task 12: emit_wnba_bet_alert() prop book-depth gate")

tmp_db12 <- tempfile(fileext = ".sqlite")
init_db(tmp_db12)
con12 <- open_wnba_db(tmp_db12)

dbExecute(con12, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game12', '2026-06-10T23:00:00Z', 'Home Team', 'Rival Team')
")
dbExecute(con12, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game12', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
# Only 1 book -- below the default min_books (3).
dbExecute(con12, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game12', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Thin Coverage Player', 'Over', 120, 7.5, datetime('now'))
")

fake_creds12 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                     discord_bot_token = "x", discord_webhook_url = "x")

check("book-depth gate returns NA model_prob / NULL play / fired=FALSE for a thin market", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game12", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con12, creds = fake_creds12,
    player_name = "Thin Coverage Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(is.na(res$model_prob))
  stopifnot(is.null(res$play))
  stopifnot(isFALSE(res$fired))
})

dbDisconnect(con12)
file.remove(tmp_db12)

# ── Task 3 fix: model_config override of prop_min_books ──────────────────────
section("Task 3 fix: model_config override of prop_min_books actually changes gate behavior")

tmp_db13 <- tempfile(fileext = ".sqlite")
init_db(tmp_db13)
con13 <- open_wnba_db(tmp_db13)

dbExecute(con13, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game13', '2026-06-10T23:00:00Z', 'Home Team', 'Rival Team')
")
dbExecute(con13, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game13', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
# Only 2 books -- below the seeded default prop_min_books (3).
dbExecute(con13, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game13', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Config Override Player', 'Over', -110, 7.5, datetime('now')),
    ('game13', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Config Override Player', 'Over', -105, 7.5, datetime('now'))
")

fake_creds13 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                     discord_bot_token = "x", discord_webhook_url = "x")

check("2-book fixture is gated under the default prop_min_books=3", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game13", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con13, creds = fake_creds13,
    player_name = "Config Override Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(is.na(res$model_prob))
  stopifnot(is.null(res$play))
})

check("lowering prop_min_books to 2 via model_config lets the same fixture through the gate", {
  dbExecute(con13, "UPDATE model_config SET value = 2 WHERE param = 'prop_min_books'")
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game13", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con13, creds = fake_creds13,
    player_name = "Config Override Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(!is.na(res$model_prob))
  stopifnot(!is.null(res$play))
})

dbDisconnect(con13)
file.remove(tmp_db13)

# ── Task 3 fix: devig changes ev_pct for a real fired prop alert ─────────────
section("Task 3 fix: devig changes ev_pct for a real fired prop alert")

tmp_db14 <- tempfile(fileext = ".sqlite")
init_db(tmp_db14)
con14 <- open_wnba_db(tmp_db14)

dbExecute(con14, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game14', '2026-06-10T23:00:00Z', 'Home Team', 'Rival Team')
")
dbExecute(con14, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game14', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
# 3 books each side, symmetric -110/-110 pinnacle prices (real vig) so raw
# implied prob (~0.5238) and devigged implied prob (exactly 0.5) are clearly
# different, provable numbers -- not just "some difference".
dbExecute(con14, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game14', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Devig Test Player', 'Over', -110, 10, datetime('now')),
    ('game14', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Devig Test Player', 'Over', -108, 10, datetime('now')),
    ('game14', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Devig Test Player', 'Over', -105, 10, datetime('now')),
    ('game14', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Devig Test Player', 'Under', -110, 10, datetime('now')),
    ('game14', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Devig Test Player', 'Under', -108, 10, datetime('now')),
    ('game14', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Devig Test Player', 'Under', -105, 10, datetime('now'))
")

fake_creds14 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                     discord_bot_token = "x", discord_webhook_url = "x")

check("devig produces a different ev_pct than the raw (vigged) calculation would", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game14", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con14, creds = fake_creds14,
    player_name = "Devig Test Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(!is.na(res$ev_pct))

  # pinnacle wins book preference on both sides -> odds=-110, odds_other=-110
  raw_implied    <- .american_to_prob(-110)
  devig_implied  <- .devig_prop_prob(-110, -110)
  stopifnot(abs(devig_implied - 0.5) < 1e-9)      # symmetric -110/-110 devigs to exactly 0.5
  stopifnot(abs(raw_implied - devig_implied) > 0.01)  # genuinely different inputs

  raw_ev_pct   <- (res$model_prob - raw_implied)   / raw_implied   * 100
  devig_ev_pct <- (res$model_prob - devig_implied) / devig_implied * 100

  stopifnot(abs(res$ev_pct - devig_ev_pct) < 1e-6)  # actual result matches the DEVIGGED formula
  stopifnot(abs(res$ev_pct - raw_ev_pct) > 1)       # and is NOT the raw (vigged) formula's value
})

dbDisconnect(con14)
file.remove(tmp_db14)

# ── Task 13: .collapse_correlated_prop_edges() pure grouping logic ───────────
section("Task 13: .collapse_correlated_prop_edges() pure grouping logic")

check("keeps only the max-ev_pct row per (game_id, player_name, side) group; independent groups untouched", {
  synthetic <- data.frame(
    game_id     = c("game1", "game1", "game1", "game2"),
    player_name = c("PlayerA", "PlayerA", "PlayerA", "PlayerB"),
    stat        = c("pts", "pra", "pra", "pts"),
    side        = c("over", "over", "under", "over"),
    ev_pct      = c(50, 15, 60, 10),
    model_line  = c(11, 17, 17, 20),
    sd          = c(2.28, 2.28, 2.28, 3.0),
    stringsAsFactors = FALSE
  )
  winners <- .collapse_correlated_prop_edges(synthetic)

  stopifnot(nrow(winners) == 3L)

  over_a <- winners[winners$game_id == "game1" & winners$side == "over", ]
  stopifnot(nrow(over_a) == 1L, over_a$stat == "pts", abs(over_a$ev_pct - 50) < 1e-9)

  under_a <- winners[winners$game_id == "game1" & winners$side == "under", ]
  stopifnot(nrow(under_a) == 1L, under_a$stat == "pra", abs(under_a$ev_pct - 60) < 1e-9)

  over_b <- winners[winners$game_id == "game2", ]
  stopifnot(nrow(over_b) == 1L, over_b$stat == "pts", abs(over_b$ev_pct - 10) < 1e-9)
})

# ── Task 14: detect_prop_edges() wires the collapse helper end-to-end ────────
section("Task 14: detect_prop_edges() real-fires only the collapsed winners")

tmp_db14b <- tempfile(fileext = ".sqlite")
init_db(tmp_db14b)
con14b <- open_wnba_db(tmp_db14b)

# Real player_box_scores fixture so compute_prop_projection() succeeds for
# both pts and pra (reb/ast are hardcoded constants by seed_player_games(),
# so pra inherits pts's real variance -- same fixture shape as Tasks 4/8/9/10/
# 13b above). The exact market lines/prices don't matter here since
# emit_wnba_bet_alert() itself is stubbed below -- only candidate discovery
# (which markets exist for this game/player) matters.
seed_player_games(con14b, "Wired Test Player", c(10,10, 8,12,9,11,10,13,7,10,12,8))

dbExecute(con14b, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, commence_time, pulled_at)
  VALUES
    ('game16', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Wired Test Player', 'Over', -110, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game16', 'midday', 'player_points_rebounds_assists', 'Some Team', 'Rival Team', 'pinnacle',
     'Wired Test Player', 'Over', -110, 16.5, datetime('now', '+2 hours'), datetime('now'))
")

fake_creds14b <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                      discord_bot_token = "x", discord_webhook_url = "x")

check("only the higher-EV correlated candidate (pts, not pra) real-fires; the independent Under candidate fires too", {
  # Stub emit_wnba_bet_alert() itself (not just send_discord()) so the real
  # function body -- and its hardcoded production open_bets.db write -- is
  # NEVER reached, even with send_alerts = TRUE below. Canned ev_pct per
  # (stat, side) deterministically makes pts win the Over group; pra/under
  # has no competing candidate so it always "wins" its own group trivially.
  original_emit <- emit_wnba_bet_alert
  emit_wnba_bet_alert <<- function(game_id, market, side, model_line, mkt_line,
                                    con, creds, steam_confirmed = FALSE,
                                    player_name = NULL, stat = NULL, sd = NULL,
                                    send_alerts = TRUE) {
    ev <- if (stat == "pts" && side == "over") 50
          else if (stat == "pra" && side == "over") 15
          else if (stat == "pra" && side == "under") 60
          else NA_real_
    if (is.na(ev)) {
      return(invisible(list(message = NULL, model_prob = NA_real_, ev_pct = NA_real_,
                            kelly = 0, fired = FALSE, play = NULL, fair_odds = NA_real_)))
    }
    play_str <- sprintf("%s %s %s", player_name, if (side == "over") "Over" else "Under", toupper(stat))
    invisible(list(message = if (send_alerts) "posted" else NULL,
                  model_prob = 0.6, ev_pct = ev, kelly = 0.01,
                  fired = send_alerts, play = play_str, fair_odds = -150))
  }
  # Restoration MUST use tryCatch(..., finally = ...), not on.exit(): this
  # on.exit() is registered while forcing a promise argument inside check()'s
  # tryCatch({ result <- expr; ... }), and that does not create the kind of
  # call frame on.exit() binds to here -- confirmed empirically the stub
  # remains permanently installed afterward in BOTH the pass and fail case.
  # tryCatch(..., finally = ...) restores correctly in both cases instead.
  tryCatch({
    n <- suppressWarnings(suppressMessages(
      detect_prop_edges(con14b, fake_creds14b, send_alerts = TRUE, season = 2026L)
    ))

    # Only 2 real-fires expected: pts-over (winner of the Over group) and
    # pra-under (no competing candidate) -- NOT 3, which would mean pra-over
    # also fired and no collapse happened.
    stopifnot(n == 2L)
  }, finally = {
    emit_wnba_bet_alert <<- original_emit
  })
})

dbDisconnect(con14b)
file.remove(tmp_db14b)

# ── Task 15: skew-normal model_prob with pnorm() fallback ────────────────────
section("Task 15: .get_prop_skew() / sn::psn() wiring with pnorm() fallback")

check(".get_prop_skew falls back to 0.0 with con = NULL", {
  s <- .get_prop_skew(NULL, "pts", 0.0)
  stopifnot(abs(s - 0.0) < 1e-9)
})

tmp_db15 <- tempfile(fileext = ".sqlite")
init_db(tmp_db15)
con15 <- open_wnba_db(tmp_db15)

check(".get_prop_skew falls back to 0.0 when no model_config row exists", {
  s <- .get_prop_skew(con15, "pts", 0.0)
  stopifnot(abs(s - 0.0) < 1e-9)
})

dbExecute(con15, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game17', datetime('now', '+2 hours'), 'Home Team', 'Rival Team')
")
dbExecute(con15, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game17', 'midday', 'Home Team', 'Rival Team', datetime('now', '+2 hours'))
")
# 3 books, matching the book-depth gate default (min_books=3).
dbExecute(con15, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game17', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Skew Test Player', 'Over', -110, 10.5, datetime('now')),
    ('game17', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Skew Test Player', 'Over', -105, 10.5, datetime('now')),
    ('game17', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Skew Test Player', 'Over', -108, 10.5, datetime('now'))
")

fake_creds15 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                     discord_bot_token = "x", discord_webhook_url = "x")

check("zero skew (uncalibrated default) makes model_prob numerically identical to plain pnorm()", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game17", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con15, creds = fake_creds15,
    player_name = "Skew Test Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  expected <- pnorm(10.5, mean = 11, sd = 1.9, lower.tail = FALSE)
  stopifnot(abs(res$model_prob - min(expected, MODEL_PROB_CEILING)) < 1e-9)
})

check("a real calibrated skew measurably changes model_prob vs the zero-skew baseline", {
  dbExecute(con15, "
    INSERT INTO model_config (param, value, updated_at)
    VALUES ('wnba_prop_skew_pts', 0.7, datetime('now'))
  ")
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game17", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con15, creds = fake_creds15,
    player_name = "Skew Test Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  dp <- sn::cp2dp(c(11, 1.9, 0.7), family = "SN")
  expected_skewed <- 1 - sn::psn(10.5, dp = dp)
  stopifnot(abs(res$model_prob - min(expected_skewed, MODEL_PROB_CEILING)) < 1e-9)

  baseline <- pnorm(10.5, mean = 11, sd = 1.9, lower.tail = FALSE)
  stopifnot(abs(res$model_prob - min(baseline, MODEL_PROB_CEILING)) > 1e-4)
})

check("an invalid calibrated skew (out of range) falls back to plain pnorm(), not a crash", {
  dbExecute(con15, "UPDATE model_config SET value = 5.0 WHERE param = 'wnba_prop_skew_pts'")
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game17", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con15, creds = fake_creds15,
    player_name = "Skew Test Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(!is.na(res$model_prob))
  expected <- pnorm(10.5, mean = 11, sd = 1.9, lower.tail = FALSE)
  stopifnot(abs(res$model_prob - min(expected, MODEL_PROB_CEILING)) < 1e-9)
})

dbDisconnect(con15)
file.remove(tmp_db15)

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
