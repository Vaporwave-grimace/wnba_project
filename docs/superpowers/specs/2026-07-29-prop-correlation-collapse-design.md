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
2. **Grouping pass:** group the dry-run results by `(game_id, player_name,
   side)`, keep the single row with max `ev_pct` per group via
   `dplyr::slice_max(ev_pct, n = 1, with_ties = FALSE)`.
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

New test in `scripts/shadow_model/test_player_props.R`. Since suppression is
only observable through the real-fire pass, the test calls
`detect_prop_edges(con, creds, send_alerts = TRUE, ...)` with `send_discord()`
stubbed by reassignment (`send_discord <<- function(message_text, creds,
channel_id = ...) { captured <<- c(captured, message_text); invisible(TRUE) }`,
restored via `on.exit()`) — the exact pattern already used in
`test_player_props.R`'s existing "digest message lists the higher-EV pick
before the lower-EV pick" test. `send_telegram()` and the `open_bets` direct
write are left live but harmless against fake credentials/a nonexistent
`router_db` path in the test's temp environment (same as every other test in
this file that exercises `send_alerts = TRUE`).

Fixture: seed two stats (`pts` and `pra`) for the same player/game/side with
real, differing `ev_pct` (achievable via different market lines posted for
each stat against the same underlying rolling-window projection — a lower
`pts` line and a correspondingly lower `pra` line both clear `MIN_EV_PCT`, but
at different margins). Assertions:

1. Exactly one Discord message is captured for that `(game_id, player_name,
   side)` — not two.
2. The captured message references the higher-EV stat, not the lower one.
3. A third pick seeded for the same player/game on the OPPOSITE side (e.g. an
   `Under` line on a different stat) still fires independently — proving the
   grouping key is genuinely `(game_id, player_name, side)`, not just
   `(game_id, player_name)`.

## Out of Scope

- `send_prop_digest()` — untouched, still shows every candidate independently.
- Distribution-shape / Gaussian-vs-fat-tailed fix — separate spec, not part of
  this design.
- Any cross-player correlation (e.g. two players on the same team whose
  projections move together) — only same-player, same-game, same-side
  redundancy is addressed here.
- Stake-scaling as an alternative to suppression — considered, rejected (see
  Scope Decisions).
