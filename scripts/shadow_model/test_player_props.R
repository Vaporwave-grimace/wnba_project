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

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
