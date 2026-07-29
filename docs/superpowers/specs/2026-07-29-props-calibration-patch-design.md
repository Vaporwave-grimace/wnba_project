# WNBA Props Devig/Consensus-Line/Book-Depth Patch — Design Spec

**Date:** 2026-07-29
**Project:** wnba_project
**Status:** Approved (user-authored design, verified against live code, approved to plan directly)

## Background

`send_prop_digest()`/`detect_prop_edges()` were producing implausibly large EV edges
(+59%, +56%) on real slates. Root-caused to three compounding issues in
`scripts/bet_alerts.R`'s prop path:

1. **No devig.** EV was computed against the book's raw (vigged) implied probability
   instead of the fair probability. A -115/-115 line has 53.5% raw implied prob per
   side but a 50% fair prob — every edge was overstated by the vig spread.
2. **No consensus-line filter.** `.best_prop_odds()` returned whichever book ranked
   highest in `BOOK_PREF`, including alt lines (e.g. a stray "Under 8.5" when every
   other book posts "Under 14.5"). `pnorm()` against a wildly off-consensus point
   produces a near-1.0 probability — a ghost edge, not a real mispricing.
3. **No book-depth requirement.** A prop posted by only one soft book is almost
   always an illiquid alt line, not a genuine mispricing signal.

Design authored externally (user-provided `props_calibration_patch.md`), then
verified against the live `bet_alerts.R`/`db_setup.R` on `master` before planning:
line-number anchors in the prop branch (231-243), `KELLY_STAKE_CEILING` (line 70),
and `.prob_to_american()` (lines 82-86) all matched exactly. Two adjustments made
during verification:

- **`db_setup.R`'s real seeding convention** is a `defaults` list of
  `list(param, value, notes)` tuples run through one loop (`db_setup.R:267-280`),
  not the standalone `dbExecute()` calls the original doc sketched. The plan below
  follows the real convention.
- **A breaking-change ripple was found and must be fixed as part of this patch,
  not discovered later:** every existing test that seeds `player_prop_lines`
  (`test_player_props.R` Tasks 8, 9, 9b, 10) uses exactly one bookmaker per side.
  With `PROP_MIN_BOOKS <- 3L`, all of them would fail the new book-depth gate —
  in Task 10's case (the prop SD scale test from the previous branch), both sides
  of a `model_prob` comparison would become `NA`, and `stopifnot(abs(NA - NA) >
  1e-6)` errors outright rather than failing cleanly. Fixtures must be updated to
  3+ books per side wherever a test expects a real fired/evaluated result.

## Goal

Fix all three issues in `bet_alerts.R`, seed the two new tunables
(`prop_min_books`, `prop_main_line_tol`) into `model_config` via `db_setup.R`, and
keep every existing test passing (for the same reasons they passed before) by
updating fixtures to realistic multi-book depth rather than relaxing the gate in
tests.

## Task Split (drives the plan below)

Dependency analysis: replacing `.best_prop_odds()` alone (before the emitter is
wired to gate on it) already changes its return shape enough to break the
existing single-book fixtures — the new function returns `book/odds/point` as NA
once `book_count < min_books`, and the emitter's existing `is.na(bo$odds)` early
return then silently produces "no odds found" instead of a real alert. So the
fixture fix must land in the same task as the `.best_prop_odds()` replacement,
not deferred to the task that wires the explicit gate message into the emitter.

1. **`db_setup.R`** — seed `prop_min_books`/`prop_main_line_tol` defaults.
2. **`bet_alerts.R` helpers** — constants, `.get_prop_config()`,
   `.devig_prop_prob()`, replace `.best_prop_odds()`; fix the 4 existing fixtures
   that would otherwise break; add dedicated helper-level tests for consensus
   filtering, book depth, and devig math.
3. **`bet_alerts.R` emitter wiring** — add the explicit book-depth early-return
   gate to `emit_wnba_bet_alert()`'s prop branch, switch its EV calculation to
   devig; add one new end-to-end test proving the gate fires through the full
   emitter.

## Out of Scope

- Totals/spreads EV calculation — explicitly left on raw implied prob (Pinnacle
  consensus has ~1% hold, close enough; devig is a props-only fix per the
  original doc's own reasoning).
- Any change to `MODEL_PROB_CEILING`, `MIN_EV_PCT`, or the prop SD calibration
  loop from the previous branch (`calibrate_props.R`, `.get_prop_sd_scale()`) —
  those stay exactly as merged.
- Any change to `player_prop_lines`' schema — the new logic reads existing
  columns only.
