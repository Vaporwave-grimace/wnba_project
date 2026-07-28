# scripts/shadow_model/test_calibrate_props.R
# Smoke tests for the WNBA prop SD calibration loop. Run with:
#   Rscript scripts/shadow_model/test_calibrate_props.R
# Mirrors test_player_props.R's check()/pass()/fail() style -- no testthat,
# tests run against a real (temp) SQLite file instead of mocks.

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
source(here("scripts", "shadow_model", "player_props.R"))
source(here("scripts", "shadow_model", "calibrate_mispricing.R"))
source(here("scripts", "shadow_model", "calibrate_props.R"))

# ── Task 1: compute_prop_sd_residuals ────────────────────────────────────────
section("Task 1: compute_prop_sd_residuals")

tmp_db1 <- tempfile(fileext = ".sqlite")
init_db(tmp_db1)
con1 <- open_wnba_db(tmp_db1)

# 15 games for "Bias Player": actual pts is always exactly projected_mean+3
# once a real rolling window exists (game 11 onward, since the first 10
# games seed the window with no prior history -- .compute_prop_projection_asof
# returns NULL for those, same zero/insufficient-window guard as the live
# function). Games 1-10 alternate 8/12 so the rolling window has a real,
# non-zero SD (mean 10, sd ~2.11) once it's established; games 11-15 are then
# each exactly (rolling mean of the prior 10 games) + 3, giving a known,
# recoverable mean_residual of +3.0 for pts.
dates <- sprintf("2026-05-%02d", 1:15)
vals  <- c(8,12,8,12,8,12,8,12,8,12, rep(NA_real_, 5))
for (i in 1:10) {
  dbExecute(con1, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Bias Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("gb", i), dates[i], vals[i]))
}
# Games 11-15: each game's pts = mean of the 10 games immediately before it + 3.
running_desc <- rev(vals[1:10])   # most recent first
for (i in 11:15) {
  window_mean <- mean(running_desc[1:10])
  this_pts <- window_mean + 3
  dbExecute(con1, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Bias Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("gb", i), dates[i], this_pts))
  running_desc <- c(this_pts, running_desc)
}
dbExecute(con1, "
  INSERT INTO team_def_factors (team, stat, allowed_avg, league_avg, factor, season, updated_at)
  VALUES ('Rival Team', 'pts', 20, 20, 1.0, 2026, datetime('now'))
")

check(".compute_prop_projection_asof excludes games on/after as_of_date", {
  p <- .compute_prop_projection_asof("Bias Player", "pts", "Rival Team", con1,
                                     2026L, "2026-05-11")
  stopifnot(!is.null(p))
  stopifnot(p$n_games == 10)   # only games 1-10, not game 11 itself
  stopifnot(abs(p$baseline_mean - 10) < 1e-9)
})
check("compute_prop_sd_residuals recovers the known +3 mean_residual for pts", {
  residuals <- compute_prop_sd_residuals(con1)
  stopifnot(nrow(residuals) > 0)
  pts_row <- residuals[residuals$stat == "pts", ]
  stopifnot(nrow(pts_row) == 1)
  stopifnot(abs(pts_row$mean_residual - 3.0) < 1e-6)
  stopifnot(pts_row$n == 5)   # games 11-15 are the only ones with 10 prior games
})
check("empirical_sd is near-zero (residuals are a constant +3, no scatter)", {
  residuals <- compute_prop_sd_residuals(con1)
  pts_row <- residuals[residuals$stat == "pts", ]
  stopifnot(pts_row$empirical_sd < 1e-6)
})
check("mean_raw_sd reflects the real rolling-window variance (~2.11), not zero", {
  residuals <- compute_prop_sd_residuals(con1)
  pts_row <- residuals[residuals$stat == "pts", ]
  stopifnot(pts_row$mean_raw_sd > 1.5, pts_row$mean_raw_sd < 2.5)
})

dbDisconnect(con1)
file.remove(tmp_db1)

# ── Task 2: calibrate_prop_sd ─────────────────────────────────────────────────
section("Task 2: calibrate_prop_sd")

tmp_db2 <- tempfile(fileext = ".sqlite")
init_db(tmp_db2)
con2 <- open_wnba_db(tmp_db2)

# Seed enough distinct players with a real, small, non-zero SD and non-zero
# mean_residual for pts so a residuals row exists with n above MIN_N_APPLY_PROP
# (100). Uses 12 players x 11 games each = 132 usable residual rows (each
# player's games 11 has 10 prior games to build a real window from).
seed_calib_player <- function(con, player, base) {
  dates <- sprintf("2026-05-%02d", 1:11)
  vals  <- base + c(-2, 2, -2, 2, -2, 2, -2, 2, -2, 2, 3)  # game 11 = base+3, real bias
  for (i in 1:11) {
    dbExecute(con, "
      INSERT INTO player_box_scores
        (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
      VALUES (?, ?, ?, 'Some Team', 'Rival Team', 30, ?, 4, 3)
    ", list(paste0(player, "_g", i), dates[i], player, vals[i]))
  }
}
for (p in seq_len(12)) seed_calib_player(con2, paste0("Player", p), 10)
dbExecute(con2, "
  INSERT INTO team_def_factors (team, stat, allowed_avg, league_avg, factor, season, updated_at)
  VALUES ('Rival Team', 'pts', 20, 20, 1.0, 2026, datetime('now'))
")

check("calibrate_prop_sd applies pts scale when n >= MIN_N_APPLY_PROP", {
  applied <- calibrate_prop_sd(con2, min_n = 10L, max_delta = 1.0)
  stopifnot(isTRUE(applied))
  v <- dbGetQuery(con2, "SELECT value FROM model_config WHERE param = 'wnba_prop_sd_scale_pts'")$value
  stopifnot(length(v) == 1, !is.na(v))
})
check("reb/ast are skipped (constant reb=4/ast=3 -> zero-SD guard -> no residual rows)", {
  n_reb <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM model_config WHERE param = 'wnba_prop_sd_scale_reb'")$n
  stopifnot(n_reb == 0)
  n_ast <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM model_config WHERE param = 'wnba_prop_sd_scale_ast'")$n
  stopifnot(n_ast == 0)
})
check("pra is NOT skipped (pra=pts+reb+ast inherits pts variance, has real SD)", {
  n_pra <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM model_config WHERE param = 'wnba_prop_sd_scale_pra'")$n
  stopifnot(n_pra == 1)
})
check("calibrate_prop_sd skips when min_n is set above the available sample", {
  applied <- calibrate_prop_sd(con2, min_n = 100000L, max_delta = 1.0)
  stopifnot(isFALSE(applied))
})
check("a large delta is capped at max_delta", {
  # Current pts scale was just set (n=12 rows, real bias/sd from seeded data).
  # Force current far away, then re-run with a tight max_delta and confirm the
  # written value moved by at most max_delta from that forced current value.
  dbExecute(con2, "UPDATE model_config SET value = 5.0 WHERE param = 'wnba_prop_sd_scale_pts'")
  calibrate_prop_sd(con2, min_n = 10L, max_delta = 0.1)
  v <- dbGetQuery(con2, "SELECT value FROM model_config WHERE param = 'wnba_prop_sd_scale_pts'")$value
  stopifnot(abs(v - 5.0) <= 0.1 + 1e-9)
})
check("empty player_box_scores returns FALSE, does not error", {
  tmp_empty <- tempfile(fileext = ".sqlite")
  init_db(tmp_empty)
  con_empty <- open_wnba_db(tmp_empty)
  applied <- calibrate_prop_sd(con_empty)
  stopifnot(isFALSE(applied))
  dbDisconnect(con_empty)
  file.remove(tmp_empty)
})

dbDisconnect(con2)
file.remove(tmp_db2)

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
