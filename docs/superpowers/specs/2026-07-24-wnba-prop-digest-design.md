# WNBA Daily Prop Edge Digest — Design Spec

**Date:** 2026-07-24
**Project:** wnba_project
**Status:** Approved, not yet planned/implemented

## Background

`detect_prop_edges()` (`scripts/shadow_model/player_props.R`) already evaluates every posted player-prop line against the rolling-average projection model and fires a real-time Discord alert (via `emit_wnba_bet_alert()` in `bet_alerts.R`) whenever an edge clears `MIN_EV_PCT` (3.0%). This is wired into `run_pipeline.R` at two points: the 3PM ET opener-odds step and the 5PM ET midday-odds step (both gated by `PROP_ALERTS_ENABLED`, currently `TRUE`).

The user wants a single curated "here are today's best plays" summary they can scan once and act on, rather than tracking scattered individual alerts as they trickle in throughout the afternoon.

## Goal

Add a daily digest that posts the best currently-live prop edges (≥6% EV, no fixed count) as one Discord message, twice a day (after each of the existing 3PM and 5PM odds steps), into the existing `#auto-bet-broadcast` channel — without disturbing the existing real-time individual alerts, which keep firing exactly as they do today, and without being auto-ingested by `bet_router` as a duplicate bet.

## Architecture

**New function:** `send_prop_digest(con, creds, min_ev = 6.0)` in `scripts/shadow_model/player_props.R`.

Reuses `detect_prop_edges()`'s exact candidate-evaluation loop (same query against `player_prop_lines` for the latest snapshot per game, same `compute_prop_projection()` call per player/stat/opponent), but instead of relying on `emit_wnba_bet_alert()`'s own alert-firing side effect, it calls `emit_wnba_bet_alert(..., send_alerts = FALSE)` for every candidate/side and collects the **full returned list** (`model_prob`, `ev_pct`, `kelly`, and — needs a small addition, see below — the formatted `play` string and `fair_odds`) regardless of whether that edge would have fired a real-time alert. This avoids re-implementing projection math or EV/Kelly computation: `emit_wnba_bet_alert()` already computes all of it internally and currently only discards it by returning early past the threshold check.

**Small addition to `emit_wnba_bet_alert()`'s return value:** currently, the below-threshold early return (`ev_pct < MIN_EV_PCT`) only returns `message`, `model_prob`, `ev_pct`, `kelly`, `fired` — it does not return `play` or `fair_odds` (those are computed after the threshold check, in the code path that only runs when an alert actually fires). Since the digest needs `play` and `fair_odds` for edges between 3% and 6% too (to build its own filtered list independently of the 3% real-time threshold), `play` and `fair_odds` must be computed and included in the return value **before** the threshold check, not after. This is a minimal reordering, not a new computation — `play` and `fair_odds` are cheap string/prob-to-odds calculations already present in the function, just currently sequenced after the early-return.

**Collection step in `send_prop_digest()`:**
```
For each candidate (game, player, stat) × side (over, under):
  res <- emit_wnba_bet_alert(..., send_alerts = FALSE)
  if not null and res$ev_pct >= min_ev: append to results list
Sort results by ev_pct descending
Build message, send via direct webhook (see Message Format below)
```

**Wiring into `run_pipeline.R`:** one new call, `safe_run(send_prop_digest(con, creds), "WNBA prop digest")`, placed immediately after each of the two existing `detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED)` calls (3PM opener step, 5PM midday step) — so the digest always reflects the same freshly-fetched lines the real-time pass just evaluated, no separate odds fetch needed.

## Message Format

**Critical constraint:** `bet_router` (a separate repo) polls `#auto-bet-broadcast` via both `watch/index.js` (Node, 30-min interval) and `discord_reader.R` (R, daily safety net) and auto-ingests any message matching the structured `PIPELINE: <SPORT>` KEY:VALUE block that `emit_broadcast()` (`broadcast_schema.R`) produces — that structured format is exactly how real-time alerts already become tracked rows in `open_bets.db`. If the digest reused `emit_broadcast()`, `bet_router` would try to parse it as N new bets, creating duplicate/garbage `open_bets` rows for picks already logged by the original real-time alert earlier that day.

**Therefore:** the digest does **not** call `emit_broadcast()` to build its message (that's what produces the structured `PIPELINE: WNBA` block bet_router looks for). It builds a plain, human-readable message string itself and sends it via the existing `send_discord(msg, creds, channel_id)` transport helper (defined in `injury_alert.R`, already used by `bet_alerts.R` at line 294 — note that call passes an `emit_broadcast()`-built structured string; `send_discord()` itself is content-agnostic, it just posts whatever string it's given, preferring the bot-token REST API so it shows as the WNBA bot, falling back to the webhook only for the default channel). The digest reuses this same transport with its own plain string instead — numbered list, no `PIPELINE:` header, nothing matching `bet_router`'s parser patterns. Example:

```
📋 **WNBA Daily Top Props** — 5:00 PM ET (4 picks ≥6% EV)
1. Marina Mabrey Over 18.5 PTS — Fair -125 | Book -105 | Edge +8.2%
2. Kelsey Plum Under 7.5 REB — Fair +140 | Book +165 | Edge +7.1%
3. ...
```

If zero candidates clear `min_ev` that run, no message is sent (not an empty/placeholder message) — consistent with existing convention (`detect_prop_edges()` logs and returns silently when there's nothing to fire).

## Data Flow / Dedup

Per the approved decision: **no dedup against already-fired real-time alerts.** Since the digest's 6% bar is strictly higher than the real-time 3% threshold, virtually every digest pick will already have fired individually earlier — this is intentional. The digest is a convenience summary ("here's today's best, all in one place"), not a filter for "what haven't you seen yet." This keeps the implementation simple: no new table, no alerted-state tracking, no join against `bets_log`/`open_bets` needed.

## Error Handling

Matches this file's existing convention throughout: every step (candidate query, projection computation, `emit_wnba_bet_alert()` call, webhook POST) is already wrapped in the same `tryCatch`/`safe_run()` patterns used by `detect_prop_edges()` and `run_pipeline.R`'s other steps. A failure at any point (webhook down, no candidates, projection failure for one player) logs via `message()` and does not crash the pipeline run. No alert-on-failure needed beyond what `run_pipeline.R`'s existing `safe_run()` wrapper already provides (it already catches and logs step failures without halting the rest of the pipeline).

## Testing / Verification Plan

No test framework exists in this repo for this kind of script (established convention, matching `detect_prop_edges()` and every other pipeline step). Verification is manual:

1. Run `send_prop_digest(con, creds, min_ev = 6.0)` directly against real, currently-posted prop lines (a live game day) and confirm the Discord message posts to `#auto-bet-broadcast` with correctly formatted, correctly sorted (EV descending) real picks.
2. Confirm the message contains no `PIPELINE:` header or any other string `bet_router`'s parser matches on.
3. After posting, manually check `bet_router`'s `open_bets.db` (or wait for the next scheduled read) to confirm the digest message did **not** create any new `open_bets` rows — only the original real-time individual alerts (already fired earlier) should be present.
4. Confirm a day/run with zero candidates ≥6% EV sends no message at all (check pipeline logs for the "nothing to send" log line, confirm no webhook call was made).
5. Confirm the existing real-time alert behavior (`detect_prop_edges(..., send_alerts = PROP_ALERTS_ENABLED)`) is completely unchanged — same alerts fire, same count, same content, as before this change.

## Out of Scope

- Email delivery — explicitly decided against; Discord reuses all existing infrastructure.
- A dedicated new Discord channel — posts into the existing `#auto-bet-broadcast` channel per the approved decision.
- Deduping digest picks against already-fired real-time alerts — explicitly decided against (repost is intentional).
- Any change to `MIN_EV_PCT` (3.0%, the real-time alert threshold) or to `detect_prop_edges()`'s existing alert-firing behavior.
- A fixed top-N count — the digest includes every edge clearing the 6% bar, however many that is on a given day (including zero).
