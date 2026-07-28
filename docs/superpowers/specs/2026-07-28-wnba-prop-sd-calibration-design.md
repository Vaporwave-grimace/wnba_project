# WNBA Player-Prop SD Calibration Loop — Design Spec

**Date:** 2026-07-28
**Project:** wnba_project
**Status:** Approved, not yet planned/implemented

## Background

`compute_prop_projection()` (`scripts/shadow_model/player_props.R`) estimates a player's
per-stat mean and SD from their last `ROLLING_WINDOW_GAMES` (10) games, multiplies the mean
by an opponent `def_factor`, and hands `projected_mean`/`baseline_sd` to
`emit_wnba_bet_alert()` (`bet_alerts.R`), which runs `pnorm()` against the market line to get
`model_prob` and, from that, `ev_pct`. Unlike totals/spreads — whose assumed SD
(`wnba_total_sd`/`wnba_spread_sd`) is already empirically calibrated against real settled
outcomes via `calibrate_wnba_sd()` (`shadow_model/calibrate_mispricing.R`, run daily) — props
have never had an equivalent backtest-and-calibrate step. `baseline_sd` is just the raw
rolling-window sample SD, never checked against how often the model's implied probability
actually resolves correctly.

A live diagnostic replay against one real day's slate found this shows up as a real
miscalibration, not noise: 362 prop sides cleared ≥6% EV, 169 even cleared ≥20% EV, with a
median `model_prob` of 63.9% — mostly nowhere near the 80% `MODEL_PROB_CEILING`, so the
clamp isn't masking it. Real market odds for the flagged props were confirmed genuine (not
corrupted data). Two secondary hypotheses were checked and ruled out: `def_factor` coverage
(all 17 real teams have genuine, non-default calibrated factors 0.90–1.13; only 2 All-Star
exhibition placeholder teams correctly fall back to 1.0 via the existing
`MIN_GAMES_FOR_DEF_FACTOR` rule) and rolling-vs-full-season SD divergence (no consistent
pattern in spot checks). The remaining, most direct explanation: `baseline_sd` itself is
systematically too small relative to how much a player's actual stat really varies against a
point projection, inflating every `pnorm()`-derived `model_prob` and thus every `ev_pct`
downstream.

## Goal

Add a `calibrate_wnba_sd()`-style empirical calibration loop for player props: measure the
real residual between historical projections and actual outcomes, derive a per-stat
correction, gate/cap/auto-apply it the same way the existing totals/spreads calibrator does,
and wire it into the same daily calibration pipeline step.

## Approach

**Scale-factor correction** (chosen over two alternatives — direct SD replacement, and a full
Platt-scaling/isotonic probability recalibration curve). Unlike totals/spreads, props already
have a live per-player rolling SD that carries real signal (a streaky player legitimately has
a wider spread than a metronome). A flat per-stat SD replacement would destroy that
heterogeneity. A full probability recalibration curve is the more statistically rigorous
option but has no precedent in this codebase and adds a harder-to-debug new pattern. The
scale factor keeps each player's live relative SD intact while correcting the systemic bias
in its magnitude.

## Architecture

**New file:** `scripts/shadow_model/calibrate_props.R`, sibling to `calibrate_mispricing.R`.
Kept separate because it operates on entirely different tables (`player_box_scores`, not
`clv_log`/`game_outcomes`), and keeps `calibrate_mispricing.R` scoped to totals/spreads.

**Wiring into `run_pipeline.R`:** a new block immediately after the existing
`mispricing_calibration` block (`run_pipeline.R:186-193`), gated by its own
`has_run_today("prop_sd_calibration", con)` marker (independent from `mispricing_calibration`
so a failure in one doesn't skip the other) and run through the same `safe_run()` wrapper:

```r
if (!has_run_today("prop_sd_calibration", con)) {
  log_info("MORNING — running prop SD calibration")
  safe_run(calibrate_prop_sd_run(con), "prop SD calibration")
  mark_run_today("prop_sd_calibration", con)
}
```

## Data Flow

**`compute_prop_sd_residuals(con)`** (`calibrate_props.R`):

1. Pull every `(player_name, stat, game_date, opponent, season)` row across all of
   `player_box_scores` history (all 4 stats: pts/reb/ast/pra).
2. For each row, replay `compute_prop_projection()` using only that player's games strictly
   before `game_date` — the rolling window itself is causal, no lookahead.
3. `def_factor` lookup uses whatever's currently stored in `team_def_factors` for that
   historical season. This is a full-season snapshot, not point-in-time, so it leaks a small
   amount of future information into earlier games in the same season. **Accepted
   approximation** — same style MLB's backtest already uses for park factors ("2026-seeded
   values applied retroactively — acceptable approximation" per that project's CLAUDE.md).
   Building a point-in-time `team_def_factors` history is second-order next to the SD
   miscalibration itself (roughly 1.5–2x per the diagnostic), and is not part of this design.
4. `residual = actual_stat - projected_mean`. Group by `stat`, compute `sd(residual)` and
   `mean(residual)` (bias check, same as `compute_wnba_sd_residuals()`).
5. Also carry `mean(raw_window_sd)` per stat group — the SD `compute_prop_projection()` would
   have used live for that group — so `calibrate_prop_sd()` can derive
   `scale = empirical_sd / mean_raw_sd`.
6. Rows a player doesn't have enough games for (fewer than 2, or a constant/zero-SD stat) are
   skipped via the same guard `compute_prop_projection()` already uses — not zero-filled.

**`calibrate_prop_sd(con, min_n = MIN_N_APPLY_PROP, max_delta = MAX_SD_SCALE_DELTA)`**
(`calibrate_props.R`), mirroring `calibrate_wnba_sd()`'s shape:

```r
MIN_N_APPLY_PROP    <- 100L   # higher than totals/spreads' MIN_N_APPLY (30L) --
                              # player-game rows are far more plentiful, so a
                              # tighter confidence bar is affordable before
                              # touching a live probability multiplier.
MAX_SD_SCALE_DELTA  <- 0.25   # cap on how far the scale can move in one run.
                              # Separate constant from MAX_SD_DELTA (that one is
                              # in raw stat-points; this one is a dimensionless
                              # ratio centered on 1.0).

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
```

Each of the 4 stats is gated independently — one stat can apply while another skips for
insufficient sample size, same as totals/spreads gating per-market.

**`calibrate_prop_sd_run(con)`** — thin orchestrator wrapper, mirrors
`calibrate_mispricing_run()`'s shape: calls `compute_prop_sd_residuals()` then
`calibrate_prop_sd()`.

## Wiring Into the Live Path

`compute_prop_projection()` in `player_props.R` is **not modified** — it keeps returning the
raw rolling-window `baseline_sd`, exactly as today. This keeps
`compute_prop_sd_residuals()`'s backtest replay circularity-free: it calls
`compute_prop_projection()` directly and never touches the calibrated scale, so a calibration
run can never feed back into its own input data.

The scale is applied at the same layer totals/spreads already apply theirs:
`emit_wnba_bet_alert()`'s `market == "prop"` branch (`bet_alerts.R:218-229`). New helper,
exact mirror of `.get_wnba_sd()`:

```r
.get_prop_sd_scale <- function(con, stat, default = 1.0) {
  if (is.null(con)) return(default)
  tryCatch({
    v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?",
                    list(sprintf("wnba_prop_sd_scale_%s", stat)))$value[1]
    if (is.null(v) || is.na(v)) default else v
  }, error = \(e) default)
}
```

`bet_alerts.R:225-228` changes from:

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

Both `detect_prop_edges()` (real-time alerts) and `send_prop_digest()` (the daily digest, per
the prior `2026-07-24-wnba-prop-digest-design.md` spec) call `emit_wnba_bet_alert()` for
every candidate, so both benefit from the correction automatically — no separate wiring needed
for the digest.

## Error Handling

- `compute_prop_sd_residuals()`: `tryCatch` around the DB pull, returns an empty tibble on
  error — mirrors `compute_wnba_sd_residuals()`.
- `calibrate_prop_sd()`: empty residuals → log message, return `FALSE`, no crash. Each stat
  gated independently on `min_n`, as shown above.
- `.get_prop_sd_scale()`: `tryCatch`, falls back to `default = 1.0` on any DB error, missing
  row, or `NULL` con — mirrors `.get_wnba_sd()` exactly.
- `calibrate_prop_sd_run()` is invoked through `run_pipeline.R`'s existing `safe_run()`
  wrapper — no additional try/catch needed at that layer, matching
  `calibrate_mispricing_run()`'s call site.

## Testing / Verification Plan

New `scripts/shadow_model/test_calibrate_props.R`, mirroring `test_player_props.R`'s existing
style (no testthat, real temp SQLite, `check()/pass()/fail()`):

1. Seed synthetic `player_box_scores` with a known constant bias between rolling projection
   and actual (e.g. actual always projected_mean + 3), verify `compute_prop_sd_residuals()`
   recovers that non-zero `mean_residual` and a plausible `sd` for the affected stat.
2. Verify `calibrate_prop_sd()` skips a stat whose sample size is below `MIN_N_APPLY_PROP`,
   applies one above it, and caps a delta that exceeds `MAX_SD_SCALE_DELTA`.
3. Verify `.get_prop_sd_scale()` falls back to `1.0` both with `con = NULL` and with no
   matching `model_config` row.
4. Verify `emit_wnba_bet_alert()`'s prop branch actually uses the scaled SD in its `pnorm()`
   call: set a stored scale far from 1.0 (e.g. 2.0), confirm the resulting `model_prob`
   differs from the same call against an unscaled baseline (`scale = 1.0`).

## Out of Scope

- Point-in-time `team_def_factors` history for the backtest replay — accepted approximation,
  see Data Flow step 3.
- Any change to `def_factor` itself, `MIN_GAMES_FOR_DEF_FACTOR`, or `DEF_FACTOR_CLAMP` —
  ruled out as a contributing cause during diagnosis; all real teams have genuine, plausible
  calibrated factors.
- A full Platt-scaling/isotonic probability recalibration curve — considered, not chosen; see
  Approach.
- Any change to `MIN_EV_PCT`, `MODEL_PROB_CEILING`, or `ROLLING_WINDOW_GAMES`.
- Backtesting or calibrating anything for totals/spreads — already covered by
  `calibrate_wnba_sd()`, untouched by this design.
