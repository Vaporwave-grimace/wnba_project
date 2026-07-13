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

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
