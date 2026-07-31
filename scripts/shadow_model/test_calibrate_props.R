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

# ── Task 1b: skewness column, isolated fixture ────────────────────────────────
section("Task 1b: compute_prop_sd_residuals skewness column")

tmp_db1b <- tempfile(fileext = ".sqlite")
init_db(tmp_db1b)
con1b <- open_wnba_db(tmp_db1b)

# "Skewed Player": 10 base games (8/12 alternating, mean=10, real variance)
# then 5 "mature" games whose actual value is deliberately
# window_mean + delta, for deltas = c(-1,-1,-1,-1,9) -- since actual is
# constructed as window_mean + delta, the residual (actual - window_mean)
# is EXACTLY delta by construction, regardless of how the window mean itself
# drifts as later games get added. This gives an exact, hand-verified
# residual sequence c(-1,-1,-1,-1,9): mean=1.0, sd=4.472136,
# skewness=1.073313 (computed independently via
# (sum((x-mean(x))^3)/length(x))/sd(x)^3 -- verified by direct simulation
# before writing this test, not guessed). Isolated in its own database (no
# other player present) so this is the ONLY contributor to the pooled
# per-stat skewness -- see the note above this code block for why that
# isolation matters.
dates_skew <- sprintf("2026-06-%02d", 1:15)
base_skew  <- c(8,12,8,12,8,12,8,12,8,12)
for (i in 1:10) {
  dbExecute(con1b, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Skewed Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("gs", i), dates_skew[i], base_skew[i]))
}
running_desc_skew <- rev(base_skew)
deltas <- c(-1, -1, -1, -1, 9)
for (i in seq_along(deltas)) {
  window_mean  <- mean(running_desc_skew[1:10])
  this_actual  <- window_mean + deltas[i]
  dbExecute(con1b, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Skewed Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("gs", 10 + i), dates_skew[10 + i], this_actual))
  running_desc_skew <- c(this_actual, running_desc_skew)
}

check("compute_prop_sd_residuals reports a skewness column with the known right-skewed value for pts", {
  residuals <- compute_prop_sd_residuals(con1b)
  pts_row <- residuals[residuals$stat == "pts", ]
  stopifnot(nrow(pts_row) == 1)
  stopifnot("skewness" %in% names(pts_row))
  stopifnot(abs(pts_row$skewness - 1.073313) < 1e-4)
})

dbDisconnect(con1b)
file.remove(tmp_db1b)

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

# ── Task 3: calibrate_prop_skew ───────────────────────────────────────────────
section("Task 3: calibrate_prop_skew")

tmp_db3 <- tempfile(fileext = ".sqlite")
init_db(tmp_db3)
con3 <- open_wnba_db(tmp_db3)

# Reuses this file's "Skewed Player" construction (Task 1) but seeded fresh
# in this isolated DB, so calibrate_prop_skew() has a real, known skewness
# (1.073313 for pts, computed the same way) to gate/cap/clamp against.
dates_skew3 <- sprintf("2026-06-%02d", 1:15)
base_skew3  <- c(8,12,8,12,8,12,8,12,8,12)
for (i in 1:10) {
  dbExecute(con3, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Skewed Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("g3s", i), dates_skew3[i], base_skew3[i]))
}
running3 <- rev(base_skew3)
for (i in seq_along(c(-1,-1,-1,-1,9))) {
  d <- c(-1,-1,-1,-1,9)[i]
  window_mean <- mean(running3[1:10])
  this_actual <- window_mean + d
  dbExecute(con3, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Skewed Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("g3s", 10+i), dates_skew3[10+i], this_actual))
  running3 <- c(this_actual, running3)
}

check("calibrate_prop_skew applies pts skew when n >= MIN_N_APPLY_PROP_SKEW", {
  applied <- calibrate_prop_skew(con3, min_n = 3L, max_delta = 2.0)
  stopifnot(isTRUE(applied))
  v <- dbGetQuery(con3, "SELECT value FROM model_config WHERE param = 'wnba_prop_skew_pts'")$value
  stopifnot(length(v) == 1, abs(v - 0.9) < 1e-6)   # 1.073313 clamped to the 0.9 ceiling
})
check("calibrate_prop_skew skips when min_n is set above the available sample", {
  applied <- calibrate_prop_skew(con3, min_n = 100000L, max_delta = 2.0)
  stopifnot(isFALSE(applied))
})
check("a large delta is capped at max_delta", {
  dbExecute(con3, "UPDATE model_config SET value = -0.5 WHERE param = 'wnba_prop_skew_pts'")
  calibrate_prop_skew(con3, min_n = 3L, max_delta = 0.1)
  v <- dbGetQuery(con3, "SELECT value FROM model_config WHERE param = 'wnba_prop_skew_pts'")$value
  stopifnot(abs(v - (-0.4)) < 1e-6)   # -0.5 + 0.1 (delta capped toward the higher target)
})
check("empty player_box_scores returns FALSE, does not error", {
  tmp_empty3 <- tempfile(fileext = ".sqlite")
  init_db(tmp_empty3)
  con_empty3 <- open_wnba_db(tmp_empty3)
  applied <- calibrate_prop_skew(con_empty3)
  stopifnot(isFALSE(applied))
  dbDisconnect(con_empty3)
  file.remove(tmp_empty3)
})

dbDisconnect(con3)
file.remove(tmp_db3)

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
