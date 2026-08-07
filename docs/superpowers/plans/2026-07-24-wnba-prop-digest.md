# WNBA Daily Prop Edge Digest Implementation Plan

> **For agentic workers:** Implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a curated daily Discord digest of the best currently-live WNBA prop edges (≥6% EV), posted twice a day into the existing `#auto-bet-broadcast` channel, without disturbing the existing real-time individual alerts or being auto-ingested by `bet_router` as a duplicate bet.

**Architecture:** A new `send_prop_digest(con, creds, min_ev = 6.0)` function in `scripts/shadow_model/player_props.R` reuses `detect_prop_edges()`'s exact candidate-evaluation loop, calling `emit_wnba_bet_alert(..., send_alerts = FALSE)` for every candidate/side and collecting every returned edge (not just ones that fire) into a filtered, EV-sorted list. It builds a plain (non-`emit_broadcast()`) message string and posts it via the existing `send_discord()` transport. Wired into `run_pipeline.R` right after each of the two existing `detect_prop_edges()` calls.

**Tech Stack:** R, `DBI`/`RSQLite` (existing WNBA pipeline DB), `httr2` (via the existing `send_discord()` helper — no new dependency).

## Global Constraints

- Digest bar: `min_ev = 6.0` (percent), no fixed pick count — every edge clearing 6% EV is included, however many that is (including zero, in which case no message is sent).
- Digest must **not** call `emit_broadcast()` — it must never produce the structured `PIPELINE: WNBA` block, since `bet_router` auto-ingests any message matching that format from `#auto-bet-broadcast` and would create duplicate `open_bets` rows for picks already logged by the original real-time alert.
- No dedup against already-fired real-time alerts — reposting is intentional (approved design decision).
- Existing real-time alert behavior (`detect_prop_edges(..., send_alerts = PROP_ALERTS_ENABLED)`, `MIN_EV_PCT = 3.0`) must be completely unchanged by this work.
- Posts into the existing `#auto-bet-broadcast` channel (`.BROADCAST_CHANNEL` constant, `"1499488823598387412"`) — no new channel.
- Follow this project's real (non-mocked) testing convention: tests run against a real temp SQLite file seeded with realistic rows via `dbExecute()`, using the `check()`/`pass()`/`fail()` harness already established in `scripts/shadow_model/test_player_props.R`. Do not introduce `testthat` or a mocking framework.

---

### Task 1: Add `play`/`fair_odds` to `emit_wnba_bet_alert()`'s return value

**Files:**
- Modify: `g:/My Drive/Scripting Projects/wnba_project/scripts/bet_alerts.R:340-341`
- Test: `g:/My Drive/Scripting Projects/wnba_project/scripts/shadow_model/test_player_props.R` (new section, appended after the existing "Task 7: .encode_prop_bet_side" section)

**Interfaces:**
- Consumes: nothing new — `play` and `fair_odds` are local variables already computed earlier in `emit_wnba_bet_alert()` (lines 180/191/205 for `play`, depending on market; line 226 for `fair_odds`), both already in scope at the function's final return statement.
- Produces: `emit_wnba_bet_alert(...)`'s returned list now includes `play` (character, the formatted bet description e.g. `"Steady Scorer Over 7.5 PTS"`) and `fair_odds` (integer, American odds) alongside the existing `message`, `model_prob`, `ev_pct`, `kelly`, `fired` fields — for **every** call that reaches this final return (i.e. real odds were found and `ev_pct >= MIN_EV_PCT`). Task 2's `send_prop_digest()` reads `res$play` and `res$fair_odds` from this return value.

- [ ] **Step 1: Read the current final return statement**

Open `g:/My Drive/Scripting Projects/wnba_project/scripts/bet_alerts.R` and find (currently lines 340-341):

```r
  invisible(list(message = msg, model_prob = model_prob, ev_pct = ev_pct,
                 kelly = kelly, fired = send_alerts))
```

- [ ] **Step 2: Add the two fields**

Replace it with:

```r
  invisible(list(message = msg, model_prob = model_prob, ev_pct = ev_pct,
                 kelly = kelly, fired = send_alerts, play = play, fair_odds = fair_odds))
```

Do not touch any other return statement in this function (the two early returns — missing game meta, missing odds — never reach `ev_pct >= MIN_EV_PCT`, and anything caught by the below-3%-threshold early return can never clear the digest's 6% bar either, so neither needs these fields).

- [ ] **Step 3: Write the test**

Append this section to the end of `g:/My Drive/Scripting Projects/wnba_project/scripts/shadow_model/test_player_props.R`, right after the existing `"Task 7: .encode_prop_bet_side"` section and before the final `cat(sprintf("\n%s -- %d error(s)\n", ...))` summary line:

```r
# ── Task 8: emit_wnba_bet_alert() returns play/fair_odds ───────────────────────
section("Task 8: emit_wnba_bet_alert() play/fair_odds in return value")

tmp_db8 <- tempfile(fileext = ".sqlite")
init_db(tmp_db8)
con8 <- open_wnba_db(tmp_db8)

dbExecute(con8, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game8', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
dbExecute(con8, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 7.5, datetime('now'))
")

fake_creds8 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                    discord_bot_token = "x", discord_webhook_url = "x")

check("returned list includes play and fair_odds for a real fired alert", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game8", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con8, creds = fake_creds8,
    player_name = "Steady Scorer", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(!is.null(res$play))
  stopifnot(res$play == "Steady Scorer Over 7.5 PTS")
  stopifnot(!is.na(res$fair_odds))
  stopifnot(is.numeric(res$fair_odds) || is.integer(res$fair_odds))
})

dbDisconnect(con8)
file.remove(tmp_db8)
```

- [ ] **Step 4: Run the test to verify it fails first**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `[FAIL] returned list includes play and fair_odds for a real fired alert -- ...` (either a "could not find function" if `emit_wnba_bet_alert` hasn't been sourced correctly, or `res$play` being `NULL` since the field doesn't exist yet before Step 2's edit is applied). If you're doing Step 3 after Step 2, temporarily re-check by reverting Step 2's edit locally to confirm the test does fail without it, then reapply Step 2.

- [ ] **Step 5: Verify the test passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `[PASS] returned list includes play and fair_odds for a real fired alert`, and the final summary line shows no new failures (`ALL PASS -- 0 error(s)` assuming no other unrelated failures already existed in the suite).

- [ ] **Step 6: Commit**

```bash
cd "g:/My Drive/Scripting Projects/wnba_project"
git add scripts/bet_alerts.R scripts/shadow_model/test_player_props.R
git commit -m "feat: emit_wnba_bet_alert() returns play/fair_odds for downstream digest use"
```

---

### Task 2: Add `send_prop_digest()` to `player_props.R`

**Files:**
- Modify: `g:/My Drive/Scripting Projects/wnba_project/scripts/shadow_model/player_props.R` (append new function after `detect_prop_edges()`, currently ending at line 380)
- Test: `g:/My Drive/Scripting Projects/wnba_project/scripts/shadow_model/test_player_props.R` (new section, appended after Task 1's Task 8 section)

**Interfaces:**
- Consumes: `emit_wnba_bet_alert(game_id, market, side, model_line, mkt_line, con, creds, player_name, stat, sd, send_alerts)` from `bet_alerts.R` (now returning `play`/`fair_odds` per Task 1); `compute_prop_projection(player_name, stat, opponent, con, season)` (existing, unchanged, returns `list(projected_mean, baseline_mean, baseline_sd, n_games, def_factor)` or `NULL`); `STAT_MARKET_MAP` (existing named vector, already defined earlier in `player_props.R`); `send_discord(message_text, creds, channel_id)` from `injury_alert.R` (globally available by the time this runs, since `run_pipeline.R` sources `injury_alert.R` before `bet_alerts.R`, which in turn sources `player_props.R`); `.BROADCAST_CHANNEL` constant from `bet_alerts.R` (same lazy-lookup-at-call-time reasoning — safe even though `player_props.R` is sourced partway through `bet_alerts.R`, since the reference only resolves when `send_prop_digest()` is actually called, not when it's defined).
- Produces: `send_prop_digest(con, creds, min_ev = 6.0, season = as.integer(format(Sys.Date(), "%Y")))` — returns (invisibly) the integer count of picks included in the digest (`0L` if none). Task 3 calls this with just `(con, creds)`.

- [ ] **Step 1: Write the failing test**

Append this section to the end of `g:/My Drive/Scripting Projects/wnba_project/scripts/shadow_model/test_player_props.R`, after Task 1's "Task 8" section and before the final summary `cat(...)` line:

```r
# ── Task 9: send_prop_digest ────────────────────────────────────────────────────
section("Task 9: send_prop_digest")

tmp_db9 <- tempfile(fileext = ".sqlite")
init_db(tmp_db9)
con9 <- open_wnba_db(tmp_db9)

# Reuses the exact same fixture as the existing Task 4 compute_prop_projection
# tests (12 games, last 10 average to pts=10, Rival Team's def_factor=1.1
# -> projected_mean=11, real nonzero baseline_sd). player_box_scores.team =
# "Some Team" for this player, so the candidate row's OTHER team must be
# "Rival Team" for send_prop_digest's opponent lookup to resolve correctly.
seed_player_games(con9, "Steady Scorer", c(10,10, 8,12,9,11,10,13,7,10,12,8))
dbExecute(con9, "
  INSERT INTO team_def_factors (team, stat, allowed_avg, league_avg, factor, season, updated_at)
  VALUES ('Rival Team', 'pts', 22, 20, 1.1, 2026, datetime('now'))
")

dbExecute(con9, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game9', 'midday', 'Some Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
# Over 7.5 at +120: point is far below the projected mean (11), so model_prob
# for Over is very high -- a clearly large, positive EV regardless of the
# exact baseline_sd value.
# Under 7.5 at -500: same point, but for the losing side of a clearly
# lopsided real distribution -- a clearly large NEGATIVE EV.
dbExecute(con9, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 7.5, datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Under', -500, 7.5, datetime('now'))
")

fake_creds9 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                    discord_bot_token = "x", discord_webhook_url = "x")

check("digest includes the clearly-qualifying Over pick, excludes the negative-EV Under", {
  msg_sent <- NULL
  # send_discord posts for real against fake creds and fails (network error) --
  # that's fine and matches this project's existing convention (see the
  # check_quota_headroom tests above); we only need send_prop_digest's return
  # value and internal filtering logic, not a successful HTTP response.
  n <- suppressWarnings(suppressMessages(
    send_prop_digest(con9, fake_creds9, min_ev = 5.0, season = 2026L)
  ))
  stopifnot(n == 1L)
})

check("min_ev above every real edge sends zero picks", {
  n <- suppressWarnings(suppressMessages(
    send_prop_digest(con9, fake_creds9, min_ev = 500.0, season = 2026L)
  ))
  stopifnot(n == 0L)
})

dbDisconnect(con9)
file.remove(tmp_db9)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `[FAIL] digest includes the clearly-qualifying Over pick, excludes the negative-EV Under -- could not find function "send_prop_digest"` (function doesn't exist yet).

- [ ] **Step 3: Implement `send_prop_digest()`**

Append this function to `g:/My Drive/Scripting Projects/wnba_project/scripts/shadow_model/player_props.R`, after the end of `detect_prop_edges()` (currently line 380):

```r
# ── Daily curated digest ───────────────────────────────────────────────────────
#
# Posts one plain-text summary of today's best currently-live prop edges
# (>= min_ev) to Discord. Reuses the exact same candidate query and
# projection/EV computation as detect_prop_edges() -- the only differences
# are send_alerts = FALSE (no individual alert fires, no open_bets write, no
# BET_HISTORY write -- all gated behind emit_wnba_bet_alert()'s own
# `if (send_alerts)` block) and collecting every evaluated edge instead of
# just counting fired ones.
#
# Does NOT call emit_broadcast() -- that produces the structured "PIPELINE:
# WNBA" block bet_router auto-ingests from #auto-bet-broadcast. Reusing it
# here would create duplicate open_bets rows for picks already logged by the
# original real-time alert. This posts a plain string via send_discord()
# instead, which bet_router's parser does not match.
send_prop_digest <- function(con, creds, min_ev = 6.0,
                             season = as.integer(format(Sys.Date(), "%Y"))) {
  candidates <- dbGetQuery(con, "
    SELECT DISTINCT ppl.game_id, ppl.player_name, ppl.market,
           ppl.home_team, ppl.away_team
    FROM player_prop_lines ppl
    WHERE ppl.snapshot_type = (
      SELECT snapshot_type FROM player_prop_lines ppl2
      WHERE ppl2.game_id = ppl.game_id
      ORDER BY pulled_at DESC LIMIT 1
    )
  ")

  if (nrow(candidates) == 0) {
    message("[player_props] Digest: no prop line candidates to evaluate.")
    return(invisible(0L))
  }

  picks <- list()
  for (i in seq_len(nrow(candidates))) {
    row  <- candidates[i, ]
    stat <- names(STAT_MARKET_MAP)[STAT_MARKET_MAP == row$market]
    if (length(stat) == 0) next

    player_team <- dbGetQuery(con, "
      SELECT team FROM player_box_scores WHERE player_name = ?
      ORDER BY game_date DESC LIMIT 1
    ", list(row$player_name))$team[1]

    opponent <- if (!is.na(player_team) && identical(player_team, row$home_team)) {
      row$away_team
    } else if (!is.na(player_team) && identical(player_team, row$away_team)) {
      row$home_team
    } else {
      ""
    }

    proj <- compute_prop_projection(row$player_name, stat, opponent, con, season)
    if (is.null(proj)) next

    for (side in c("over", "under")) {
      res <- tryCatch(
        emit_wnba_bet_alert(
          game_id     = row$game_id,
          market      = "prop",
          side        = side,
          model_line  = proj$projected_mean,
          mkt_line    = NA_real_,
          con         = con,
          creds       = creds,
          player_name = row$player_name,
          stat        = stat,
          sd          = proj$baseline_sd,
          send_alerts = FALSE
        ),
        error = function(e) {
          message("[player_props] Digest eval error for ", row$player_name, " ", stat, " ", side,
                  ": ", e$message)
          NULL
        }
      )
      if (!is.null(res) && !is.null(res$ev_pct) && !is.na(res$ev_pct) && res$ev_pct >= min_ev) {
        picks[[length(picks) + 1L]] <- list(play = res$play, fair_odds = res$fair_odds, ev_pct = res$ev_pct)
      }
    }
  }

  if (length(picks) == 0) {
    message(sprintf("[player_props] Digest: no edges >= %.1f%% EV today.", min_ev))
    return(invisible(0L))
  }

  ev_order <- order(vapply(picks, function(p) p$ev_pct, numeric(1)), decreasing = TRUE)
  picks    <- picks[ev_order]

  lines_out <- vapply(seq_along(picks), function(i) {
    p <- picks[[i]]
    sprintf("%d. %s — Fair %+d | Edge %+.1f%%", i, p$play, as.integer(p$fair_odds), p$ev_pct)
  }, character(1))

  header <- sprintf("📋 **WNBA Daily Top Props** — %s (%d pick%s ≥%.0f%% EV)",
                    format(Sys.time(), "%I:%M %p ET"), length(picks),
                    if (length(picks) == 1) "" else "s", min_ev)

  msg <- paste(c(header, lines_out), collapse = "\n")

  tryCatch(
    send_discord(msg, creds, channel_id = .BROADCAST_CHANNEL),
    error = function(e) message("[player_props] Digest Discord send failed: ", e$message)
  )

  message(sprintf("[player_props] Digest sent -- %d pick(s) >= %.1f%% EV", length(picks), min_ev))
  invisible(length(picks))
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `[PASS] digest includes the clearly-qualifying Over pick, excludes the negative-EV Under` and `[PASS] min_ev above every real edge sends zero picks`, plus all previously-passing checks (including Task 8 from Task 1) still passing. Final line: `ALL PASS -- 0 error(s)`.

- [ ] **Step 5: Commit**

```bash
cd "g:/My Drive/Scripting Projects/wnba_project"
git add scripts/shadow_model/player_props.R scripts/shadow_model/test_player_props.R
git commit -m "feat: add send_prop_digest() curated top-edge Discord summary"
```

---

### Task 3: Wire `send_prop_digest()` into `run_pipeline.R`

**Files:**
- Modify: `g:/My Drive/Scripting Projects/wnba_project/scripts/run_pipeline.R:273-274` and `:333-334`

**Interfaces:**
- Consumes: `send_prop_digest(con, creds)` from Task 2 (uses its default `min_ev = 6.0`).
- Produces: nothing new consumed by later tasks — this is the final task in this plan.

- [ ] **Step 1: Read the current MIDDAY step call site**

In `g:/My Drive/Scripting Projects/wnba_project/scripts/run_pipeline.R`, find (currently lines 273-274):

```r
      safe_run(detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED),
               "player prop edge detection")
```

- [ ] **Step 2: Add the digest call right after it**

Replace with:

```r
      safe_run(detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED),
               "player prop edge detection")
      safe_run(send_prop_digest(con, creds),
               "WNBA prop digest (midday)")
```

- [ ] **Step 3: Read the current near-tip/closing step call site**

Find (currently lines 333-334):

```r
    safe_run(detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED),
             "player prop edge detection (near-tip)")
```

- [ ] **Step 4: Add the digest call right after it**

Replace with:

```r
    safe_run(detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED),
             "player prop edge detection (near-tip)")
    safe_run(send_prop_digest(con, creds),
             "WNBA prop digest (near-tip)")
```

(Per the design spec's accepted behavior: this near-tip hook can fire more than once per evening as different games approach their own staggered tip-off within the pre-tip window — this is intentional, not a bug, and no additional guard is added in this task. If it proves too noisy in practice, adding a once-per-day guard is a small follow-up, not built here without evidence it's needed.)

- [ ] **Step 5: Manual verification against real live data**

This project has no automated test of the full pipeline orchestrator itself (`run_pipeline.R`) — individual functions are unit-tested (Tasks 1-2 above), but the top-level dispatch is verified manually, matching this project's existing convention (see `scripts/test_pipeline.R`'s scope: config/credentials checks only, not a live pipeline run).

On a real WNBA game day, with real `player_prop_lines` already populated for the day (i.e. after the pipeline's normal midday odds fetch has run):

```r
setwd("g:/My Drive/Scripting Projects/wnba_project")
source("scripts/run_pipeline.R")
```

Expected in the console output: the existing `[player_props] detect_prop_edges complete -- N alert(s) fired` line, immediately followed by either `[player_props] Digest sent -- M pick(s) >= 6.0% EV` (if any real edge cleared 6%) or `[player_props] Digest: no edges >= 6.0% EV today.` (if none did) — both are valid, expected outcomes, not failures.

If a digest was sent, confirm in Discord's `#auto-bet-broadcast` channel: the message appears as a plain numbered list (not a structured `PIPELINE: WNBA` embed-style block), correctly sorted by EV descending.

- [ ] **Step 6: Confirm no double-ingestion into bet_router**

After a real digest send (Step 5), either wait for `bet_router`'s next scheduled read pass or run it manually:

```r
setwd("g:/My Drive/Scripting Projects/bet_router")
Rscript run_router.R --mode read
```

Confirm in `open_bets.db` that no new row was created that traces back to the digest message specifically (the picks in the digest should already exist as `open_bets` rows from their original real-time alert, with the same `fired_at` timestamp as before the digest ran — not a new, later `fired_at` matching the digest's post time).

- [ ] **Step 7: Commit**

```bash
cd "g:/My Drive/Scripting Projects/wnba_project"
git add scripts/run_pipeline.R
git commit -m "feat: wire send_prop_digest() into midday and near-tip pipeline steps"
```

---

## Self-Review

**Spec coverage:** New function reusing existing candidate/projection logic ✅ Task 2. `play`/`fair_odds` addition ✅ Task 1. Non-`emit_broadcast()` plain message, reuses `send_discord()` ✅ Task 2 Step 3. Wired into both real call sites (corrected from the spec's original inaccurate "3PM/5PM" framing to the actual `run_pipeline.R:273`/`:333` sites) ✅ Task 3. No dedup against real-time alerts ✅ Task 2's design (no alerted-state table, no join added). `min_ev = 6.0`, no fixed count ✅ Task 2's function signature and filtering logic. Manual verification of no bet_router double-ingestion ✅ Task 3 Step 6.

**Placeholder scan:** no TBD/TODO; every step has complete runnable code or an exact command with a stated expected output.

**Type consistency:** `send_prop_digest(con, creds, min_ev = 6.0, season = ...)` signature is identical between its definition (Task 2 Step 3) and its two call sites (Task 3 Steps 2 and 4, both using the default `min_ev`). `res$play`/`res$fair_odds` (Task 2's consumption) match exactly the field names added in Task 1 Step 2's return list edit.
