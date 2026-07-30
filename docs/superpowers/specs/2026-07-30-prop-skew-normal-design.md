# WNBA Prop Skew-Normal Distribution Design Spec

**Date:** 2026-07-30
**Project:** wnba_project
**Status:** Approved, not yet planned/implemented

## Background

`compute_prop_projection()` (`scripts/shadow_model/player_props.R`) computes
mean/sd from a player's rolling 10-game window. `emit_wnba_bet_alert()`
(`scripts/bet_alerts.R`) runs `pnorm()` against that mean/sd to get
`model_prob` for props — a pure Gaussian assumption. Two prior sessions
already addressed adjacent EV-inflation bugs (`calibrate_props.R`'s empirical
SD-scale calibration; a devig/consensus-line/book-depth patch), but neither
touched the distribution *family* — it's still Gaussian, just a better-fit
Gaussian.

Verified against real data before designing around it (per this project's own
working agreement to check assumptions, not assume them): pooled, per-player
mean-centered residuals across the full `player_box_scores` history (n=4208)
show real, positive skew and excess kurtosis on **all four** stats — not just
PRA, which was the original hypothesis. Actual values:

| stat | skew | excess kurtosis |
|---|---|---|
| pts | 0.51 | 1.28 |
| reb | 0.54 | 1.32 |
| ast | 0.79 | 2.48 |
| pra | 0.35 | 0.73 |

Correction to the original framing: PRA is the **mildest** case (summing
three stats smooths it toward Gaussian, central-limit-theorem-style); AST is
the worst offender. Gaussian is measurably wrong for all four, just not in
the order originally assumed.

## Goal

Replace `pnorm()` with a skew-normal CDF (`sn::psn()`) for prop `model_prob`
computation, with the skew shape parameter empirically calibrated per stat
(mirroring the existing SD-scale calibration pattern), while exactly
preserving the existing mean/sd contract everything else already depends on.

## Scope Decisions (from clarifying questions)

- **Distribution family:** skew-normal, not Negative Binomial/Poisson or a
  non-parametric empirical CDF. Rationale: still a continuous, location-scale
  family — smallest change to the existing `pnorm()`-based EV/Kelly pipeline
  (one CDF call, no conversion to a discrete distribution). Negative
  Binomial/Poisson would be more "correct" for count data but need more
  history than the 10-game rolling window provides and would touch Kelly
  sizing math too. Empirical CDF needs a much longer lookback than the
  rolling window and doesn't extrapolate for players with few games.
- **New dependency:** the `sn` package (Azzalini's — the standard R
  implementation, written by the person who introduced the skew-normal
  distribution) is added. A correct skew-normal CDF requires Owen's T
  function; not worth hand-rolling. Needs `install.packages("sn")` once on
  the machine that runs the pipeline.
- **Skew granularity:** one global `alpha` (shape) per stat, pooled across all
  players — NOT per-player. Mirrors `calibrate_props.R`'s existing
  `wnba_prop_sd_scale_<stat>` pattern exactly. A 10-game rolling window is far
  too thin to fit a stable per-player skew; pooling across all players for a
  stat gives a real, statistically defensible sample (thousands of rows, per
  the diagnostic above).

## Architecture

`compute_prop_projection()` is **not modified** — still returns raw
`baseline_mean`/`baseline_sd` exactly as today, keeping the calibration
replay's no-circularity guarantee intact (same reasoning as the prior SD
calibration design).

**Calibration side** (`scripts/shadow_model/calibrate_props.R`):
`compute_prop_sd_residuals()` gains a `skewness` column alongside its existing
`empirical_sd`/`mean_residual`/`mean_raw_sd` — computed from the same
already-built causal retroactive replay, no new replay logic needed. A new
`calibrate_prop_skew(con, min_n = MIN_N_APPLY_PROP_SKEW, max_delta =
MAX_SKEW_DELTA)` mirrors `calibrate_prop_sd()`'s gate/cap/auto-apply shape,
writing `wnba_prop_skew_{pts,reb,ast,pra}` to `model_config` (default `0.0` —
symmetric, i.e. plain Gaussian — when uncalibrated). Gated at
`MIN_N_APPLY_PROP_SKEW <- 500L` (stricter than the SD calibration's `100L`:
skewness estimators have higher variance than SD estimators, need more data
to trust). Delta-capped at `MAX_SKEW_DELTA <- 0.15` per run. Calibrated skew
clamped to `[-0.9, 0.9]` (skew-normal's theoretical max magnitude is
~0.9952 — staying well inside that avoids numerical instability in
`cp2dp()` near the boundary). `calibrate_prop_skew_run(con)` orchestrator,
wired into the same daily `prop_sd_calibration` pipeline step
(`run_pipeline.R`) right alongside `calibrate_prop_sd_run()` — no new pipeline
step needed.

**Alert-time side** (`scripts/bet_alerts.R`): new `.get_prop_skew(con, stat,
default = 0.0)`, exact mirror of `.get_prop_sd_scale()`'s fallback shape. In
the prop branch, after computing `calibrated_sd` (unchanged from the prior
branch):

```r
skew <- .get_prop_skew(con, stat, 0.0)
model_prob <- tryCatch({
  dp <- sn::cp2dp(c(model_line, calibrated_sd, skew), family = "SN")
  if (side == "over") 1 - sn::psn(point, dp = dp) else sn::psn(point, dp = dp)
}, error = function(e) {
  if (side == "over") pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = FALSE)
  else pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = TRUE)
})
```

`sn::cp2dp()` converts the *centered* parameters we already trust (mean =
`model_line`, sd = `calibrated_sd`) plus the calibrated skewness into the
skew-normal's *direct* parameters (location/scale/shape) — this preserves the
existing mean/sd contract exactly; skew only reshapes the tail probabilities.
**Key correctness/safety property:** when `skew = 0` (no calibration yet, or
a stat with genuinely no skew), `cp2dp()` degenerates to a plain normal and
`sn::psn()` is numerically identical to `pnorm()` — zero behavior change
until skew is actually calibrated and applied. This must be verified by test,
not just asserted (see Testing).

## Error Handling

- `.get_prop_skew()`: `tryCatch`, falls back to `default = 0.0` on any DB
  error, missing row, or `NULL` con — mirrors `.get_prop_sd_scale()` exactly.
- The `cp2dp()`/`psn()` call itself is wrapped in `tryCatch`, falling back to
  plain `pnorm()` on ANY failure (invalid parameters, `sn` package missing or
  broken in some environment, numerical edge case). The new dependency never
  becomes a single point of failure for alerts firing at all — a broken skew
  calculation degrades to exactly today's behavior, not a crash.
- `calibrate_prop_skew()`: empty residuals or missing `skewness` column →
  message + `FALSE`, no crash. Each stat gated independently on `min_n`, same
  as `calibrate_prop_sd()`.

## Testing

New tests in `scripts/shadow_model/test_calibrate_props.R` (calibration side,
items 1-2 below) and `scripts/shadow_model/test_player_props.R` (alert side,
items 3-6 below — the same file that already covers `.get_prop_sd_scale()`'s
fallback behavior in its "Task 10" section):

1. `compute_prop_sd_residuals()` recovers a known nonzero skewness from a
   synthetic residual distribution with deliberate asymmetry.
2. `calibrate_prop_skew()` gates on `MIN_N_APPLY_PROP_SKEW`, caps delta at
   `MAX_SKEW_DELTA`, clamps to `[-0.9, 0.9]` — same test shape as
   `calibrate_prop_sd()`'s existing gate/cap tests.
3. `.get_prop_skew()` falls back to `0.0` with `con = NULL` and with no
   matching `model_config` row.
4. **Zero-skew equivalence:** with `skew = 0`, the `sn::cp2dp()`/`sn::psn()`
   path produces a `model_prob` numerically identical (within floating-point
   tolerance) to the plain `pnorm()` calculation for the same
   point/mean/sd — proves the "zero-downtime fallback" claim empirically.
5. **Nonzero-skew effect:** with a real calibrated skew stored in
   `model_config`, `model_prob` measurably differs from the plain Gaussian
   value for the same inputs — proves skew is actually applied, not just
   present in the config.
6. **Failure fallback:** simulating a `cp2dp()`/`psn()` error (e.g. an
   out-of-range skew value bypassing the clamp somehow, or stubbing `sn::psn`
   to throw) still produces a valid `model_prob` via the `pnorm()` fallback,
   not a crash.

## Out of Scope

- Negative Binomial/Poisson or empirical-CDF alternatives — considered,
  rejected (see Scope Decisions).
- Per-player skew estimation — considered, rejected (see Scope Decisions).
- Any change to `compute_prop_projection()`, `MIN_EV_PCT`,
  `MODEL_PROB_CEILING`, the book-depth gate, or the devig logic from the
  prior branch.
- Any change to the SD-scale calibration (`calibrate_prop_sd()`,
  `wnba_prop_sd_scale_<stat>`) — skew calibration is additive alongside it,
  not a replacement.
