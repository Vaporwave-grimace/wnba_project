# WNBA Prop Skew-Normal Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `pnorm()` with a skew-normal CDF (`sn::psn()`) for prop
`model_prob`, with skew empirically calibrated per stat and a pnorm-identical
fallback when uncalibrated or on any failure.

**Architecture:** `calibrate_props.R`'s existing causal-replay residuals gain
a `skewness` column; a new `calibrate_prop_skew()` (mirroring
`calibrate_prop_sd()`'s gate/cap/clamp shape) writes
`wnba_prop_skew_{pts,reb,ast,pra}` to `model_config`. `bet_alerts.R`'s prop
branch reads it via `.get_prop_skew()` and converts
`(model_line, calibrated_sd, skew)` to skew-normal direct parameters via
`sn::cp2dp()`, then uses `sn::psn()` in place of `pnorm()` — wrapped in
`tryCatch` falling back to plain `pnorm()` on any failure.

**Tech Stack:** R, the `sn` package (NEW dependency — `install.packages("sn")`
needed on the machine that runs the pipeline), dplyr/DBI/RSQLite (already
present).

## Global Constraints

- `compute_prop_projection()` is **not modified** — same no-circularity
  guarantee as the prior SD-calibration design.
- Skew is calibrated **globally per stat**, pooled across all players — not
  per-player.
- `MIN_N_APPLY_PROP_SKEW <- 500L` (stricter than the SD calibration's
  `100L` — skewness estimators need more data to trust).
- `MAX_SKEW_DELTA <- 0.15` per calibration run.
- Calibrated skew clamped to `[-0.9, 0.9]` (skew-normal's theoretical max
  magnitude is ~0.9952 — stay well inside it).
- `model_config` params: `wnba_prop_skew_pts`, `wnba_prop_skew_reb`,
  `wnba_prop_skew_ast`, `wnba_prop_skew_pra`. Default `0.0` (symmetric —
  plain Gaussian) when uncalibrated.
- **`library(sn)` must NOT be added at the top of `bet_alerts.R`.** If `sn`
  is missing or broken in some environment, a top-level `library(sn)` would
  hard-fail sourcing the ENTIRE file — defeating the whole point of the
  graceful fallback. Use only namespace-qualified `sn::cp2dp()`/`sn::psn()`
  calls inside a `tryCatch`, so a missing/broken package fails only at call
  time, caught by the fallback, not at source time.
- `sn` is only needed at alert time (the `cp2dp`/`psn` conversion) — NOT in
  `calibrate_props.R`, which only needs a plain arithmetic skewness formula.
  Keep the new dependency's footprint to exactly where it's used.
- `MIN_EV_PCT`, `MODEL_PROB_CEILING`, the book-depth gate, and the devig
  logic from prior branches are unchanged.
- No test framework beyond this repo's `check()`/`pass()`/`fail()`
  convention — real temp SQLite files, no mocking of DB logic.

---

### Task 1: Add empirical skewness to `compute_prop_sd_residuals()`

**Files:**
- Modify: `scripts/shadow_model/calibrate_props.R:64-113` (the
  `compute_prop_sd_residuals()` function and its `summarise()` call)
- Test: `scripts/shadow_model/test_calibrate_props.R` (append)

**Interfaces:**
- Produces: `compute_prop_sd_residuals()`'s output tibble gains a
  `skewness` column (in addition to the existing `stat, n, empirical_sd,
  mean_residual, mean_raw_sd`). Task 2 consumes `row$skewness[1]`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/shadow_model/test_calibrate_props.R`, as its OWN new "Task
1b" section, placed right after the existing "Task 1" section's
`dbDisconnect(con1); file.remove(tmp_db1)` lines (do NOT add this to `con1`
itself — `compute_prop_sd_residuals()` pools residuals across every player in
the database for a given stat, and `con1` already has "Bias Player" seeded
with its own constant-+3 pts residuals from the existing Task 1 test; pooling
"Skewed Player" into the same database would combine both players' residuals
into one skewness figure, not the isolated value this test expects. A fresh,
separate database avoids that entirely — verified independently: the
isolated skewness is `1.073313`, but pooled with Bias Player's 5×(+3) it
would come out to `0.7589466` instead — a real, confirmed difference, not a
hypothetical):

```r
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: FAIL — `"skewness" %in% names(pts_row)` is `FALSE` (the column
doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

In `scripts/shadow_model/calibrate_props.R`, modify `compute_prop_sd_residuals()`'s
final `summarise()` call (currently lines 104-112):

```r
  bind_rows(out) |>
    group_by(stat) |>
    summarise(
      n             = n(),
      empirical_sd  = sd(residual, na.rm = TRUE),
      mean_residual = mean(residual, na.rm = TRUE),
      mean_raw_sd   = mean(raw_sd, na.rm = TRUE),
      skewness      = .sample_skewness(residual),
      .groups       = "drop"
    )
```

And add this helper right before `compute_prop_sd_residuals()` (before the
`#' Per-stat empirical residual SD...` comment, currently line 66):

```r
# Simple "g1"-style sample skewness (third standardized moment): population
# third-moment numerator over sample SD cubed. Matches the standard, widely
# used definition (e.g. moments::skewness()'s default). Returns NA for
# fewer than 3 finite values or when SD is 0/NA (a constant residual has
# undefined skewness, not zero).
.sample_skewness <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 3) return(NA_real_)
  m <- mean(x)
  s <- sd(x)
  if (is.na(s) || s == 0) return(NA_real_)
  (sum((x - m)^3) / n) / s^3
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/calibrate_props.R scripts/shadow_model/test_calibrate_props.R
git commit -m "feat: add empirical skewness column to compute_prop_sd_residuals()"
```

---

### Task 2: Add `calibrate_prop_skew()`/`calibrate_prop_skew_run()`

**Files:**
- Modify: `scripts/shadow_model/calibrate_props.R` (append)
- Test: `scripts/shadow_model/test_calibrate_props.R` (append)

**Interfaces:**
- Consumes: `compute_prop_sd_residuals()`'s `skewness` column (Task 1),
  `.set_config_param()` (from `calibrate_mispricing.R`, already sourced).
- Produces: `calibrate_prop_skew(con, min_n = MIN_N_APPLY_PROP_SKEW, max_delta
  = MAX_SKEW_DELTA)` returning `TRUE`/`FALSE` invisibly.
  `calibrate_prop_skew_run(con)` — orchestrator, consumed by Task 4.

- [ ] **Step 1: Write the failing test**

Append to `scripts/shadow_model/test_calibrate_props.R` as a new "Task 3"
section, right before the file's final summary block (move that block to
the end again, as usual):

```r
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: FAIL — `could not find function "calibrate_prop_skew"`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/shadow_model/calibrate_props.R`:

```r

MIN_N_APPLY_PROP_SKEW <- 500L
MAX_SKEW_DELTA        <- 0.15
SKEW_CLAMP            <- c(-0.9, 0.9)

#' Guardrailed upsert of wnba_prop_skew_{pts,reb,ast,pra} to model_config.
calibrate_prop_skew <- function(con, min_n = MIN_N_APPLY_PROP_SKEW, max_delta = MAX_SKEW_DELTA) {
  residuals <- compute_prop_sd_residuals(con)
  if (nrow(residuals) == 0) {
    message("[calibrate] prop_skew: no player_box_scores rows yet")
    return(invisible(FALSE))
  }

  applied <- FALSE
  for (stat in c("pts", "reb", "ast", "pra")) {
    row <- filter(residuals, stat == !!stat)
    if (nrow(row) == 0 || is.na(row$skewness[1])) next

    param   <- sprintf("wnba_prop_skew_%s", stat)
    default <- 0.0

    if (row$n[1] < min_n) {
      message(sprintf("[calibrate] prop_skew/%s: n=%d < min_n=%d -- skipping",
                      stat, row$n[1], min_n))
      next
    }

    current <- tryCatch({
      v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?", list(param))$value[1]
      if (is.null(v) || is.na(v)) default else v
    }, error = \(e) default)

    new_skew <- row$skewness[1]
    delta    <- new_skew - current
    if (abs(delta) > max_delta) {
      new_skew <- current + sign(delta) * max_delta
      message(sprintf("[calibrate] prop_skew/%s: capping delta to %.2f -> %.3f",
                      stat, max_delta, new_skew))
    }
    new_skew <- max(SKEW_CLAMP[1], min(SKEW_CLAMP[2], new_skew))

    .set_config_param(
      con, param, new_skew,
      n_games = row$n[1],
      notes = sprintf("empirical residual skewness, clamped to [%.1f, %.1f]",
                      SKEW_CLAMP[1], SKEW_CLAMP[2])
    )
    applied <- TRUE
  }
  invisible(applied)
}

#' Morning orchestrator -- called from run_pipeline.R.
calibrate_prop_skew_run <- function(con) {
  calibrate_prop_skew(con)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/calibrate_props.R scripts/shadow_model/test_calibrate_props.R
git commit -m "feat: gate/cap/clamp prop skew calibration to model_config"
```

---

### Task 3: Wire `sn::psn()` into `emit_wnba_bet_alert()` with a `pnorm()` fallback

**Files:**
- Modify: `scripts/bet_alerts.R` (add `.get_prop_skew()`, rewrite the prop
  branch's `model_prob` computation)
- Test: `scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Consumes: `model_config` param `wnba_prop_skew_<stat>` (Task 2).
- Produces: `.get_prop_skew(con, stat, default = 0.0)`. No other task depends
  on this directly — this is the terminal consumer of the calibration chain.

**Before you start:** install the `sn` package if it isn't already present:
`Rscript -e 'if (!requireNamespace("sn", quietly=TRUE)) install.packages("sn")'`.
Your tests will not pass without it.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/shadow_model/test_player_props.R` as a new "Task 15"
section, right before the file's final summary block (move it to the end
again, as usual):

```r
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
     'Skew Test Player', 'Over', -110, 7.5, datetime('now')),
    ('game17', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Skew Test Player', 'Over', -105, 7.5, datetime('now')),
    ('game17', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Skew Test Player', 'Over', -108, 7.5, datetime('now'))
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
  expected <- pnorm(7.5, mean = 11, sd = 1.9, lower.tail = FALSE)
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
  expected_skewed <- 1 - sn::psn(7.5, dp = dp)
  stopifnot(abs(res$model_prob - min(expected_skewed, MODEL_PROB_CEILING)) < 1e-9)

  baseline <- pnorm(7.5, mean = 11, sd = 1.9, lower.tail = FALSE)
  stopifnot(abs(res$model_prob - min(baseline, MODEL_PROB_CEILING)) > 1e-4)
})

check("an invalid calibrated skew (out of range) falls back to plain pnorm(), not a crash", {
  # NOTE before running this: the plan's author could not verify sn::cp2dp()'s
  # exact out-of-range error behavior empirically (sn isn't installed on the
  # machine that wrote this plan). Before trusting this test, run:
  #   Rscript -e 'library(sn); tryCatch(cp2dp(c(11,1.9,5.0), family="SN"), error=function(e) cat("ERRORS:", conditionMessage(e), "\n"))'
  # If 5.0 does NOT produce an R error (e.g. it silently clamps or returns
  # something other than throwing), pick a value that DOES verifiably error
  # under cp2dp() -- the skew-normal's valid range is roughly (-0.9952,
  # 0.9952), so anything further out should fail, but confirm it rather than
  # assume it.
  dbExecute(con15, "UPDATE model_config SET value = 5.0 WHERE param = 'wnba_prop_skew_pts'")
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game17", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con15, creds = fake_creds15,
    player_name = "Skew Test Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(!is.na(res$model_prob))
  expected <- pnorm(7.5, mean = 11, sd = 1.9, lower.tail = FALSE)
  stopifnot(abs(res$model_prob - min(expected, MODEL_PROB_CEILING)) < 1e-9)
})

dbDisconnect(con15)
file.remove(tmp_db15)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `could not find function ".get_prop_skew"`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/bet_alerts.R`, add `.get_prop_skew()` right after
`.get_prop_sd_scale()` (currently ends at line 53, before the
`.get_prop_config()` block):

```r

# Reads a calibrated prop skew (shape) parameter from model_config (written
# by calibrate_prop_skew() in calibrate_props.R); falls back to 0.0 (no
# skew -- plain Gaussian, since sn::psn() with skew=0 is numerically
# identical to pnorm()) when con is NULL, unreachable, or no calibrated
# value exists yet. Mirrors .get_prop_sd_scale() above.
.get_prop_skew <- function(con, stat, default = 0.0) {
  if (is.null(con)) return(default)
  tryCatch({
    v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?",
                    list(sprintf("wnba_prop_skew_%s", stat)))$value[1]
    if (is.null(v) || is.na(v)) default else v
  }, error = \(e) default)
}
```

Then in `scripts/bet_alerts.R`, replace the prop branch's `model_prob`
computation (currently lines 344-348):

```r
    calibrated_sd <- sd * .get_prop_sd_scale(con, stat, 1.0)
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = TRUE)
```

with:

```r
    calibrated_sd <- sd * .get_prop_sd_scale(con, stat, 1.0)
    skew <- .get_prop_skew(con, stat, 0.0)
    # sn:: is namespace-qualified deliberately -- NOT library(sn) at the top
    # of this file. If sn is missing or broken, this tryCatch degrades to
    # plain pnorm() at call time; a top-level library(sn) would instead
    # hard-fail sourcing this entire file, which defeats the fallback.
    model_prob <- tryCatch({
      dp <- sn::cp2dp(c(model_line, calibrated_sd, skew), family = "SN")
      if (side == "over") 1 - sn::psn(point, dp = dp) else sn::psn(point, dp = dp)
    }, error = function(e) {
      if (side == "over") pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = FALSE)
      else pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = TRUE)
    })
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

Also run the calibration suite to confirm it's still unaffected:

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/bet_alerts.R scripts/shadow_model/test_player_props.R
git commit -m "feat: use sn::psn() skew-normal CDF for prop model_prob, with pnorm() fallback"
```

---

### Task 4: Wire `calibrate_prop_skew_run()` into the daily pipeline

**Files:**
- Modify: `scripts/run_pipeline.R:195-201` (the existing
  `prop_sd_calibration` block)

**Interfaces:**
- Consumes: `calibrate_prop_skew_run(con)` (Task 2).
- Produces: nothing consumed by other tasks — last task in this plan.

- [ ] **Step 1: Add the call**

In `scripts/run_pipeline.R`, the existing block (currently):

```r
  # Player-prop SD calibration -- empirical scale factor sweep + auto-apply
  if (!has_run_today("prop_sd_calibration", con)) {
    log_info("MORNING — running prop SD calibration")
    safe_run(calibrate_prop_sd_run(con), "prop SD calibration")
    mark_run_today("prop_sd_calibration", con)
  }
```

becomes:

```r
  # Player-prop SD calibration -- empirical scale factor sweep + auto-apply
  if (!has_run_today("prop_sd_calibration", con)) {
    log_info("MORNING — running prop SD calibration")
    safe_run(calibrate_prop_sd_run(con), "prop SD calibration")
    safe_run(calibrate_prop_skew_run(con), "prop skew calibration")
    mark_run_today("prop_sd_calibration", con)
  }
```

(Same `prop_sd_calibration` run-today marker covers both — they're part of
the same daily distributional-calibration step, no new marker needed.)

- [ ] **Step 2: Verify the file parses cleanly**

Run: `Rscript -e "source(here::here('scripts', 'shadow_model', 'calibrate_props.R')); cat('calibrate_prop_skew_run exists:', exists('calibrate_prop_skew_run'), '\n')"`
from the `wnba_project` directory.
Expected: prints `TRUE`.

- [ ] **Step 3: Run the full test suites to confirm nothing broke**

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 4: Commit**

```bash
git add scripts/run_pipeline.R
git commit -m "feat: wire prop skew calibration into the daily pipeline"
```

---

## Manual Verification (post-implementation, live data)

Not automated — run once against the real `wnba_pipeline.sqlite` after all 4
tasks are merged:

```r
setwd("g:/My Drive/Scripting Projects/wnba_project")
source("scripts/db_setup.R")
source("scripts/shadow_model/player_props.R")
source("scripts/shadow_model/calibrate_mispricing.R")
source("scripts/shadow_model/calibrate_props.R")

con <- open_wnba_db()
residuals <- compute_prop_sd_residuals(con)
print(residuals)   # sanity-check skewness per stat -- should roughly match
                    # this session's diagnostic (pts~0.5, reb~0.5, ast~0.8, pra~0.35)

calibrate_prop_skew(con)
print(dbGetQuery(con, "SELECT * FROM model_config WHERE param LIKE 'wnba_prop_skew_%'"))
dbDisconnect(con)
```

Confirm `sn` is actually installed on the machine that runs the scheduled
pipeline (`Rscript -e "requireNamespace('sn', quietly=TRUE)"` should print
`TRUE`) before relying on this live — the fallback keeps alerts firing either
way, but the whole point of this work is for skew to actually apply.
