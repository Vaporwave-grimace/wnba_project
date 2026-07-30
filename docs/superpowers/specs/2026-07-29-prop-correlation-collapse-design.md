# WNBA Prop Multi-Market Correlation Collapse — Design Spec

**Date:** 2026-07-29
**Project:** wnba_project
**Status:** Approved, not yet planned/implemented

## Background

`detect_prop_edges()` (`scripts/shadow_model/player_props.R:330-`) evaluates every
`(game_id, player_name, market)` candidate independently, one `emit_wnba_bet_alert()`
call per stat (`pts`/`reb`/`ast`/`pra`) per side (`over`/`under`). Since
`pra = pts + reb + ast` exactly, a single real bias in a player's projection (the
model over- or under-rating one player's overall involvement) surfaces as up to
4 separate "edges" for the same underlying signal — inflating the apparent number
of independent betting opportunities and, since each fires its own real-money
Kelly stake via the direct `open_bets` write in `emit_wnba_bet_alert()`, over-sizing
aggregate exposure to one player's projection error.

This is the first of two related gaps identified from an external review of the
prop model (the second — Gaussian vs. fat-tailed distribution shape in
`compute_prop_projection()`/`pnorm()` — is a separate, larger design, tracked
independently and not part of this spec).

## Goal

Collapse correlated same-player, same-game, same-side picks (across `pts`/`reb`/
`ast`/`pra`) down to a single fired alert — the highest-EV one — in
`detect_prop_edges()` only. `send_prop_digest()` is explicitly untouched: it's a
read-only summary, not a source of real stakes, and showing the full set of
correlated lines there is useful context rather than a risk.

## Scope Decisions (from clarifying questions)

- **Surface:** `detect_prop_edges()` only — the function that actually fires
  alerts and writes real stakes to `open_bets`. `send_prop_digest()` is out of
  scope.
- **Grouping key:** `(game_id, player_name, side)` — NOT `(game_id, player_name)`
  alone. An `Over PTS` and an `Under AST` pick for the same player/game are
  treated as independent, non-competing signals (a real basketball insight —
  "scores more but passes less" — not noise), and both may survive. Only picks
  sharing the same side compete against each other.
- **Winner selection:** highest `ev_pct` within each group (matches this
  project's existing convention — `send_prop_digest()` already sorts by
  `ev_pct` descending).
- **Mechanism:** suppression (drop the non-winning picks entirely), not
  stake-scaling. Considered and rejected: dividing each correlated pick's Kelly
  stake by group size instead of dropping any — rejected because it doesn't
  reduce alert-count noise and the goal (per the originating review) was
  explicitly to collapse to a single derivative, not to keep all of them at a
  discount.

## Architecture

`detect_prop_edges()`'s external signature and contract are unchanged
(`detect_prop_edges(con, creds, send_alerts = TRUE, season = ...)`, returns an
invisible count of fired alerts). Only its internals restructure, from
"evaluate-and-fire-inline-per-candidate" to three passes:

1. **Dry-run pass:** for every `(game_id, player_name, stat, side)` candidate,
   call `emit_wnba_bet_alert(..., send_alerts = FALSE)` — reusing the exact
   side-effect-free contract `send_prop_digest()` already depends on (documented
   at `bet_alerts.R`'s `send_alerts` gate: "everything above this gate stays
   side-effect-free"). Collect `game_id`, `player_name`, `stat`, `side`,
   `ev_pct`, and the `model_line`/`sd` used (from `compute_prop_projection()`,
   cached to avoid recomputing in pass 3), for every candidate that produced a
   real `play` (i.e. cleared `MIN_EV_PCT` and had real odds).
2. **Grouping pass:** extracted as its own pure, side-effect-free helper,
   `.collapse_correlated_prop_edges(evaluated_df)` — groups the dry-run
   results by `(game_id, player_name, side)` and keeps the single row with max
   `ev_pct` per group via `dplyr::slice_max(ev_pct, n = 1, with_ties =
   FALSE)`. Kept as a standalone function (not inlined) specifically so it's
   directly unit-testable against a synthetic data frame with no DB, no
   network, and no risk of touching `emit_wnba_bet_alert()`'s hardcoded
   production `open_bets.db` path (see Testing).
3. **Real-fire pass:** for each group winner, call `emit_wnba_bet_alert()` again
   with `send_alerts` set to the function's own top-level parameter (preserving
   `detect_prop_edges(con, creds, send_alerts = FALSE, ...)`'s existing ability
   to dry-run the whole function for testing) — this is the only call that can
   produce real side effects (Discord/Telegram, `open_bets` write, BET_HISTORY).

**Why two evaluations per winning candidate is acceptable:** this isn't a new
cost pattern — `detect_prop_edges()` and `send_prop_digest()` already
redundantly evaluate the same candidates today, just split across two separate
functions/call sites instead of within one. `sd`/`model_line` are cached from
the dry-run pass and reused for the real-fire call, so
`compute_prop_projection()` itself is not re-run a third time.

## Error Handling

Same `tryCatch` per candidate/side already in place today — a dry-run failure
for one candidate simply excludes that row from grouping (`next`), it doesn't
abort the whole pass. No new failure modes introduced.

## Testing

**Important correction made during planning:** no existing test in
`test_player_props.R` ever calls `detect_prop_edges()`/`emit_wnba_bet_alert()`
with `send_alerts = TRUE` — every prop test uses `send_alerts = FALSE`
specifically to stay side-effect-free. `emit_wnba_bet_alert()`'s `open_bets`
write uses a hardcoded path (`C:/Users/Mike/sports_data/open_bets.db`) that
genuinely exists on the development machine — a naive integration test calling
`detect_prop_edges(..., send_alerts = TRUE)` against a real temp DB would
still reach that hardcoded path and write real fake rows into the live
production betting database. This is why the collapse logic is extracted into
`.collapse_correlated_prop_edges()` (see Architecture) rather than left
inline — it lets the actual new behavior be tested two ways, neither of which
risks that write:

1. **Pure unit test** (no DB, no stubs, no network): construct a synthetic
   data frame directly — e.g. `(game1, PlayerA, pts, over, ev=50)`, `(game1,
   PlayerA, pra, over, ev=15)`, `(game1, PlayerA, pra, under, ev=60)`, `(game2,
   PlayerB, pts, over, ev=10)` — and assert
   `.collapse_correlated_prop_edges()` returns exactly 3 rows: the `over`
   group's `pts` winner (50 > 15), the standalone `under` row (`pra`, 60,
   uncontested), and `game2`'s single row untouched. This directly,
   deterministically verifies the actual new logic.
2. **Integration wiring test** (DB-backed, but `emit_wnba_bet_alert()` itself
   stubbed by reassignment — the same pattern already used for `send_discord()`
   elsewhere in this file, just applied to a different function): seed real
   `player_prop_lines` candidate rows (so the real candidate query and real
   `compute_prop_projection()` still run) but replace `emit_wnba_bet_alert()`
   with a stub returning canned `ev_pct`/`play`/`fired` values keyed by
   `(stat, side)`, with `fired` set to whatever `send_alerts` value the stub
   itself received (mirroring the real function's `fired = send_alerts`
   contract). Since the stub never calls the real function body, the
   hardcoded `open_bets.db` path is never reached even when the outer
   `detect_prop_edges(..., send_alerts = TRUE)` is exercised. Assert exactly 2
   of the 3 candidates real-fire (`n == 2`), matching the winners the pure
   function would select.

## Out of Scope

- `send_prop_digest()` — untouched, still shows every candidate independently.
- Distribution-shape / Gaussian-vs-fat-tailed fix — separate spec, not part of
  this design.
- Any cross-player correlation (e.g. two players on the same team whose
  projections move together) — only same-player, same-game, same-side
  redundancy is addressed here.
- Stake-scaling as an alternative to suppression — considered, rejected (see
  Scope Decisions).
