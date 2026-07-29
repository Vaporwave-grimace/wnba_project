# WNBA Player-Prop SD Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the WNBA player-prop model an empirical SD calibration loop, mirroring the
existing totals/spreads `calibrate_wnba_sd()` pattern, so `emit_wnba_bet_alert()`'s
`model_prob` for props stops running on an uncalibrated raw rolling-window SD.

**Architecture:** New file `scripts/shadow_model/calibrate_props.R` computes a per-stat
empirical scale factor (`empirical_sd / raw_window_sd`) from a causal retroactive replay
against `player_box_scores`, gates/caps/auto-applies it to `model_config` as
`wnba_prop_sd_scale_{pts,reb,ast,pra}`, and wires into `run_pipeline.R`'s daily calibration
step. `bet_alerts.R`'s `emit_wnba_bet_alert()` reads the calibrated scale at call time and
multiplies it into the SD it already receives, before running `pnorm()`.

**Tech Stack:** R, DBI/RSQLite, dplyr. No new dependencies.

## Global Constraints

- `MIN_N_APPLY_PROP <- 100L` (per-stat sample-size gate before a calibration applies).
- `MAX_SD_SCALE_DELTA <- 0.25` (max change in scale per calibration run).
- `model_config` params: `wnba_prop_sd_scale_pts`, `wnba_prop_sd_scale_reb`,
  `wnba_prop_sd_scale_ast`, `wnba_prop_sd_scale_pra`. Default `1.0` when uncalibrated.
- `compute_prop_projection()` in `scripts/shadow_model/player_props.R` is **not modified** —
  it must keep returning the raw, unscaled `baseline_sd` exactly as today.
- `run_pipeline.R`'s new calibration block uses its own `has_run_today("prop_sd_calibration", con)`
  marker, independent from the existing `mispricing_calibration` marker.
- No test framework beyond this repo's existing `check()`/`pass()`/`fail()` convention (see
  `scripts/shadow_model/test_player_props.R`) — no testthat, real temp SQLite files.

---

### Task 1: Causal retroactive residual computation

**Files:**
- Create: `scripts/shadow_model/calibrate_props.R`
- Test: `scripts/shadow_model/test_calibrate_props.R`

**Interfaces:**
- Consumes: `ROLLING_WINDOW_GAMES` (10L), `.lookup_def_factor(opponent, stat, con, season)` —
  both from `scripts/shadow_model/player_props.R`.
- Produces: `.compute_prop_projection_asof(player_name, stat, opponent, con, season, as_of_date)`
  returning `NULL` or `list(n_games, baseline_mean, baseline_sd, def_factor, projected_mean)`.
  `compute_prop_sd_residuals(con)` returning a tibble with columns
  `stat, n, empirical_sd, mean_residual, mean_raw_sd` (one row per stat with any data, zero
  rows if no `player_box_scores` data exists).

**Why a separate `_asof` helper instead of reusing `compute_prop_projection()` directly:**
`compute_prop_projection()` always queries a player's full history with no date cutoff — for
a live call that's fine (all data is "past"), but replaying it against a historical game would
let that game see its own future games in the same rolling window. This helper duplicates
`compute_prop_projection()`'s exact mean/SD/def-factor math but adds `WHERE game_date < ?`,
so the live function stays untouched (per Global Constraints) while the replay stays causal.

- [ ] **Step 1: Write the failing test**

Create `scripts/shadow_model/test_calibrate_props.R`:

```r
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
running <- vals[1:10]
for (i in 11:15) {
  window_mean <- mean(tail(running, 10))
  this_pts <- window_mean + 3
  dbExecute(con1, "
    INSERT INTO player_box_scores
      (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
    VALUES (?, ?, 'Bias Player', 'Some Team', 'Rival Team', 30, ?, 4, 3)
  ", list(paste0("gb", i), dates[i], this_pts))
  running <- c(running, this_pts)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: FAIL — `could not find function "compute_prop_sd_residuals"` (the
`source(here("scripts", "shadow_model", "calibrate_props.R"))` line itself will error since
the file doesn't exist yet; every check() call after that also fails since none of the
functions exist).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/shadow_model/calibrate_props.R`:

```r
# scripts/shadow_model/calibrate_props.R
# Morning auto-calibration for the WNBA player-prop SD. Mirrors
# calibrate_mispricing.R's calibrate_wnba_sd() pattern, adapted for props:
# unlike totals/spreads (a single static SD), props already have a live
# per-player rolling SD that carries real signal, so this calibrates a
# *scale factor* on top of it rather than replacing it outright.
#
# Workflow:
#   1. compute_prop_sd_residuals() — causal retroactive replay against
#      player_box_scores, per-stat empirical residual SD + mean bias check
#   2. calibrate_prop_sd()         — guardrailed upsert of the scale to model_config
#   3. calibrate_prop_sd_run()     — morning orchestrator (called from run_pipeline.R)

library(dplyr)
library(DBI)
library(RSQLite)
library(here)

source(here("scripts", "shadow_model", "player_props.R"))
source(here("scripts", "shadow_model", "calibrate_mispricing.R"))   # .set_config_param()

MIN_N_APPLY_PROP    <- 100L
MAX_SD_SCALE_DELTA  <- 0.25

# ── Causal replay ─────────────────────────────────────────────────────────────

# Mirrors compute_prop_projection()'s exact mean/SD/def-factor math, but
# restricted to games strictly before as_of_date -- player_props.R's own
# compute_prop_projection() has no cutoff param and always queries full
# history, which would leak future games into a historical replay. Kept
# as a private, calibration-only helper so the live function stays untouched.
.compute_prop_projection_asof <- function(player_name, stat, opponent, con, season, as_of_date) {
  stat <- tolower(stat)
  games <- dbGetQuery(con, "
    SELECT game_date, pts, reb, ast
    FROM player_box_scores
    WHERE player_name = ? AND game_date < ?
    ORDER BY game_date DESC
  ", list(player_name, as_of_date))

  if (nrow(games) == 0) return(NULL)

  stat_vals <- if (stat == "pra") games$pts + games$reb + games$ast else games[[stat]]
  n_avail     <- min(ROLLING_WINDOW_GAMES, length(stat_vals))
  window_vals <- stat_vals[seq_len(n_avail)]

  baseline_mean <- mean(window_vals, na.rm = TRUE)
  baseline_sd   <- sd(window_vals, na.rm = TRUE)
  if (is.na(baseline_sd) || baseline_sd == 0) return(NULL)

  def_factor <- .lookup_def_factor(opponent, stat, con, season)

  list(n_games = n_avail, baseline_mean = baseline_mean, baseline_sd = baseline_sd,
       def_factor = def_factor, projected_mean = baseline_mean * def_factor)
}

# ── Residuals ─────────────────────────────────────────────────────────────────

#' Per-stat empirical residual SD + bias check, from a causal retroactive
#' replay of every player_box_scores row across all history.
compute_prop_sd_residuals <- function(con) {
  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT game_date, player_name, opponent,
             CAST(strftime('%Y', game_date) AS INTEGER) AS season,
             pts, reb, ast
      FROM player_box_scores
      ORDER BY player_name, game_date
    ") |> as_tibble(),
    error = \(e) tibble()
  )
  if (nrow(rows) == 0) return(tibble())

  out <- list()
  for (stat in c("pts", "reb", "ast", "pra")) {
    for (i in seq_len(nrow(rows))) {
      row <- rows[i, ]
      actual <- if (stat == "pra") row$pts + row$reb + row$ast else row[[stat]]
      if (is.na(actual)) next

      proj <- tryCatch(
        .compute_prop_projection_asof(row$player_name, stat, row$opponent, con,
                                       row$season, row$game_date),
        error = \(e) NULL
      )
      if (is.null(proj)) next

      out[[length(out) + 1]] <- tibble(
        stat     = stat,
        residual = actual - proj$projected_mean,
        raw_sd   = proj$baseline_sd
      )
    }
  }
  if (length(out) == 0) return(tibble())

  bind_rows(out) |>
    group_by(stat) |>
    summarise(
      n             = n(),
      empirical_sd  = sd(residual, na.rm = TRUE),
      mean_residual = mean(residual, na.rm = TRUE),
      mean_raw_sd   = mean(raw_sd, na.rm = TRUE),
      .groups       = "drop"
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/calibrate_props.R scripts/shadow_model/test_calibrate_props.R
git commit -m "feat: add causal retroactive residual computation for prop SD calibration"
```

---

### Task 2: Gate/cap/auto-apply the scale factor

**Files:**
- Modify: `scripts/shadow_model/calibrate_props.R` (append)
- Test: `scripts/shadow_model/test_calibrate_props.R` (append)

**Interfaces:**
- Consumes: `compute_prop_sd_residuals(con)` (Task 1), `.set_config_param(con, param, value, n_games, wr_before, wr_after, notes)` (from `calibrate_mispricing.R`), `MIN_N_APPLY_PROP`, `MAX_SD_SCALE_DELTA` (Task 1).
- Produces: `calibrate_prop_sd(con, min_n = MIN_N_APPLY_PROP, max_delta = MAX_SD_SCALE_DELTA)`
  returning `TRUE`/`FALSE` (invisibly) — whether at least one stat's scale was written.
  `calibrate_prop_sd_run(con)` — thin orchestrator, no return value relied on by later tasks.

- [ ] **Step 1: Write the failing test**

Append to `scripts/shadow_model/test_calibrate_props.R` (before the final `cat(sprintf(...))`
summary block — move that block to the end of the file each time a new section is appended):

```r
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
check("reb/ast/pra are skipped (constant reb=4/ast=3 -> zero-SD guard -> no residual rows)", {
  n_reb <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM model_config WHERE param = 'wnba_prop_sd_scale_reb'")$n
  stopifnot(n_reb == 0)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: FAIL — `could not find function "calibrate_prop_sd"` on every Task 2 check.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/shadow_model/calibrate_props.R`:

```r

# ── Calibration ───────────────────────────────────────────────────────────────

#' Guardrailed upsert of wnba_prop_sd_scale_{pts,reb,ast,pra} to model_config.
calibrate_prop_sd <- function(con, min_n = MIN_N_APPLY_PROP, max_delta = MAX_SD_SCALE_DELTA) {
  residuals <- compute_prop_sd_residuals(con)
  if (nrow(residuals) == 0) {
    message("[calibrate] prop_sd: no player_box_scores rows yet")
    return(invisible(FALSE))
  }

  applied <- FALSE
  for (stat in c("pts", "reb", "ast", "pra")) {
    row <- filter(residuals, stat == !!stat)
    if (nrow(row) == 0) next

    param   <- sprintf("wnba_prop_sd_scale_%s", stat)
    default <- 1.0

    if (row$n[1] < min_n) {
      message(sprintf("[calibrate] prop_sd/%s: n=%d < min_n=%d -- skipping",
                      stat, row$n[1], min_n))
      next
    }

    current <- tryCatch({
      v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?", list(param))$value[1]
      if (is.null(v) || is.na(v)) default else v
    }, error = \(e) default)

    new_scale <- row$empirical_sd[1] / row$mean_raw_sd[1]
    delta     <- new_scale - current
    if (abs(delta) > max_delta) {
      new_scale <- current + sign(delta) * max_delta
      message(sprintf("[calibrate] prop_sd/%s: capping delta to %.2f -> %.3f",
                      stat, max_delta, new_scale))
    }

    .set_config_param(
      con, param, new_scale,
      n_games = row$n[1],
      notes = sprintf("empirical scale = empirical_sd/raw_window_sd, mean_residual=%.2f (bias check)",
                      row$mean_residual[1])
    )
    applied <- TRUE
  }
  invisible(applied)
}

#' Morning orchestrator -- called from run_pipeline.R.
calibrate_prop_sd_run <- function(con) {
  calibrate_prop_sd(con)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/calibrate_props.R scripts/shadow_model/test_calibrate_props.R
git commit -m "feat: gate/cap/auto-apply prop SD scale factor to model_config"
```

---

### Task 3: Wire the calibrated scale into `emit_wnba_bet_alert()`

**Files:**
- Modify: `scripts/bet_alerts.R:218-229` (the `market == "prop"` branch)
- Test: `scripts/shadow_model/test_player_props.R` (append — this is where the existing
  `emit_wnba_bet_alert()` prop-branch tests already live, in Task 8)

**Interfaces:**
- Consumes: nothing new from Tasks 1-2 directly (this task only needs `model_config` to
  already contain a `wnba_prop_sd_scale_<stat>` row, or be empty — it reads it live).
- Produces: `.get_prop_sd_scale(con, stat, default = 1.0)` in `bet_alerts.R`, used by
  `emit_wnba_bet_alert()`'s prop branch. No other task depends on this function directly.

- [ ] **Step 1: Write the failing test**

Append to `scripts/shadow_model/test_player_props.R`, immediately before the final
`cat(sprintf(...))` summary block (move that block to the end again):

```r
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `could not find function ".get_prop_sd_scale"` on the first two Task 10
checks; the third check fails too since `res_unscaled` and `res_scaled` would be identical
without the scale being applied (both computed from the same raw `sd`).

- [ ] **Step 3: Write minimal implementation**

In `scripts/bet_alerts.R`, add the helper right after `.get_wnba_sd()` (after line 40):

```r

# Reads a calibrated prop SD scale factor from model_config (written by
# calibrate_prop_sd() in calibrate_props.R); falls back to 1.0 (no
# correction) when con is NULL, unreachable, or no calibrated value exists
# yet. Mirrors .get_wnba_sd() above.
.get_prop_sd_scale <- function(con, stat, default = 1.0) {
  if (is.null(con)) return(default)
  tryCatch({
    v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?",
                    list(sprintf("wnba_prop_sd_scale_%s", stat)))$value[1]
    if (is.null(v) || is.na(v)) default else v
  }, error = \(e) default)
}
```

Then in `scripts/bet_alerts.R:225-228`, change:

```r
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = sd, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = sd, lower.tail = TRUE)
```

to:

```r
    calibrated_sd <- sd * .get_prop_sd_scale(con, stat, 1.0)
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = TRUE)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/bet_alerts.R scripts/shadow_model/test_player_props.R
git commit -m "feat: apply calibrated SD scale to prop model_prob in emit_wnba_bet_alert()"
```

---

### Task 4: Wire the daily calibration run into `run_pipeline.R`

**Files:**
- Modify: `scripts/run_pipeline.R:35` (source list) and `scripts/run_pipeline.R:186-193`
  (calibration block)

**Interfaces:**
- Consumes: `calibrate_prop_sd_run(con)` (Task 2), `has_run_today()` / `mark_run_today()` /
  `safe_run()` / `log_info()` (already defined elsewhere in `run_pipeline.R`'s sourced files,
  used identically by the existing `mispricing_calibration` block).
- Produces: nothing consumed by other tasks — this is the last task in the plan.

- [ ] **Step 1: Add the source line**

In `scripts/run_pipeline.R`, immediately after line 35
(`source(here("scripts", "shadow_model", "calibrate_mispricing.R"))`), add:

```r
source(here("scripts", "shadow_model", "calibrate_props.R"))
```

- [ ] **Step 2: Add the calibration block**

In `scripts/run_pipeline.R`, immediately after the existing block that ends at line 193
(`  }` closing the `mispricing_calibration` `if`), add:

```r

  # Player-prop SD calibration -- empirical scale factor sweep + auto-apply
  if (!has_run_today("prop_sd_calibration", con)) {
    log_info("MORNING — running prop SD calibration")
    safe_run(calibrate_prop_sd_run(con), "prop SD calibration")
    mark_run_today("prop_sd_calibration", con)
  }
```

- [ ] **Step 3: Verify the file parses and sources cleanly**

Run: `Rscript -e "source(here::here('scripts', 'run_pipeline.R'))"` from the `wnba_project`
directory.
Expected: no errors (the script only defines functions at top level; it should source
without executing the pipeline). If `run_pipeline.R` has side effects on source in this
codebase, instead run: `Rscript -e "here::here(); source(here::here('scripts', 'shadow_model', 'calibrate_props.R')); cat('calibrate_prop_sd_run exists:', exists('calibrate_prop_sd_run'), '\n')"`
and confirm it prints `TRUE`.

- [ ] **Step 4: Run the full existing test suites to confirm nothing else broke**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

Run: `Rscript scripts/test_pipeline.R`
Expected: `ALL PASS -- 0 error(s)` (confirms the new source line and calibration block didn't
break pipeline-level wiring tests, if this file covers that — if `test_pipeline.R` doesn't
touch `run_pipeline.R`'s calibration steps, this run is a basic sanity check that the file
still sources cleanly project-wide).

- [ ] **Step 5: Commit**

```bash
git add scripts/run_pipeline.R
git commit -m "feat: wire prop SD calibration into the daily pipeline"
```

---

## Manual Verification (post-implementation, live data)

Not automated — run once against the real `wnba_pipeline.sqlite` after all 4 tasks are
merged, to confirm the calibration behaves sensibly on real history before relying on it live:

```r
setwd("g:/My Drive/Scripting Projects/wnba_project")
source("scripts/db_setup.R")
source("scripts/shadow_model/player_props.R")
source("scripts/shadow_model/calibrate_mispricing.R")
source("scripts/shadow_model/calibrate_props.R")

con <- open_wnba_db()
residuals <- compute_prop_sd_residuals(con)
print(residuals)   # sanity-check n, empirical_sd, mean_residual, mean_raw_sd per stat

calibrate_prop_sd(con)
print(dbGetQuery(con, "SELECT * FROM model_config WHERE param LIKE 'wnba_prop_sd_scale_%'"))
dbDisconnect(con)
```

Confirm: `mean_residual` is close to 0 for each stat (a large bias would mean the mean
projection itself, not just the SD, is off — out of scope for this design, but worth
noticing). Confirm the written scale factors are a plausible order of magnitude (not, say,
0.01 or 50) before the next morning's `run_pipeline.R` run picks them up live.
