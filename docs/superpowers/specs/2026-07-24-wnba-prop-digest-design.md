# WNBA Daily Prop Edge Digest — Design Spec

**Date:** 2026-07-24
**Project:** wnba_project
**Status:** Approved, not yet planned/implemented

## Background

`detect_prop_edges()` (`scripts/shadow_model/player_props.R`) already evaluates every posted player-prop line against the rolling-average projection model and fires a real-time Discord alert (via `emit_wnba_bet_alert()` in `bet_alerts.R`) whenever an edge clears `MIN_EV_PCT` (3.0%). This is wired into `run_pipeline.R` at exactly two points, both gated by `PROP_ALERTS_ENABLED` (currently `TRUE`): the **MIDDAY step** (~5PM ET, `run_pipeline.R:273`, first time each day's props get evaluated) and the **near-tip/closing step** (`run_pipeline.R:333`, right before each game's own tipoff — this runs per-game as games approach tip, not at one fixed clock time for the whole slate). There is no separate 3PM-specific prop call — that was an inaccuracy in an earlier draft of this spec, corrected here after checking the actual call sites.

The user wants a single curated "here are today's best plays" summary they can scan once and act on, rather than tracking scattered individual alerts as they trickle in throughout the afternoon.

## Goal

Add a daily digest that posts the best currently-live prop edges (≥6% EV, no fixed count) as one Discord message, twice a day (after each of the existing 3PM and 5PM odds steps), into the existing `#auto-bet-broadcast` channel — without disturbing the existing real-time individual alerts, which keep firing exactly as they do today, and without being auto-ingested by `bet_router` as a duplicate bet.

## Architecture

**New function:** `send_prop_digest(con, creds, min_ev = 6.0)` in `scripts/shadow_model/player_props.R`.

Reuses `detect_prop_edges()`'s exact candidate-evaluation loop (same query against `player_prop_lines` for the latest snapshot per game, same `compute_prop_projection()` call per player/stat/opponent), but instead of relying on `emit_wnba_bet_alert()`'s own alert-firing side effect, it calls `emit_wnba_bet_alert(..., send_alerts = FALSE)` for every candidate/side and collects the **full returned list** (`model_prob`, `ev_pct`, `kelly`, and — needs a small addition, see below — the formatted `play` string and `fair_odds`) regardless of whether that edge would have fired a real-time alert. This avoids re-implementing projection math or EV/Kelly computation: `emit_wnba_bet_alert()` already computes all of it internally and currently only discards it by returning early past the threshold check.

**Small addition to `emit_wnba_bet_alert()`'s return value:** its final return statement (reached whenever real odds were found AND `ev_pct >= MIN_EV_PCT`, i.e. whenever there's a genuine bet to describe) currently returns only `message`, `model_prob`, `ev_pct`, `kelly`, `fired` — not `play` or `fair_odds`, even though both are already computed earlier in the same function call, before that return is reached. (The below-3%-threshold early return, by contrast, never needs `play`/`fair_odds` added — anything failing that lower 3% bar necessarily also fails the digest's higher 6% bar, so the digest never needs data from that path.) The fix is a one-line addition to that single final return's list literal — no reordering, no new computation, no change to any existing field or to real-time alert behavior.

**Collection step in `send_prop_digest()`:**
```
For each candidate (game, player, stat) × side (over, under):
  res <- emit_wnba_bet_alert(..., send_alerts = FALSE)
  if not null and res$ev_pct >= min_ev: append to results list
Sort results by ev_pct descending
Build message, send via direct webhook (see Message Format below)
```

**Wiring into `run_pipeline.R`:** one new call, `safe_run(send_prop_digest(con, creds), "WNBA prop digest")`, placed immediately after each of the two existing `detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED)` calls — `run_pipeline.R:273` (MIDDAY step, gated by `prop_midday_count == 0` so it fires exactly once per day) and `run_pipeline.R:333` (near-tip/closing step) — so the digest always reflects the same freshly-fetched lines the real-time pass just evaluated, no separate odds fetch needed.

**Known, accepted behavior:** unlike the MIDDAY hook, the near-tip step is not a single fixed-clock-time event — it runs on every ~30-min pipeline cycle and processes whichever games are newly entering their own pre-tip window (`props_pending <- setdiff(near_tip_games, props_already_closed)`), which can span multiple cycles across an evening as games with staggered tip times each approach their own start. The digest hooked to this step will therefore fire once per such cycle, not exactly once — each firing reflecting whatever is live at that moment (typically the field narrows as the evening progresses and more games go final). This is accepted as-is per the spec's "no dedup tracking" simplicity decision; if it proves too noisy in practice, adding a once-per-day guard (matching this file's own `already_closed`/`prop_midday_count` idempotency idiom) is a small, fast follow-up — not built preemptively without evidence it's needed.

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
