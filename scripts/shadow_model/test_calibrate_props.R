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

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
