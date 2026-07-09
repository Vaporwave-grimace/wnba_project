# WNBA Sandbox Intelligence Pipeline — Current State

> For full architecture, variable definitions, and pipeline diagram see `WNBA_Architecture.md`.

This file is living-state only: stack, data sources, build status, and the
most recent 1-2 sessions' open items. For older session narratives (root
causes, bug fixes, historical context), see [`SESSION_ARCHIVE.md`](SESSION_ARCHIVE.md).

## Stack

- **Language:** R
- **Storage:** SQLite
- **Key packages (planned):** `httr2`, `rvest`, `DBI`, `RSQLite`, `lubridate`, `dplyr` / `data.table`, `tidymodels`

## Data Sources (Confirmed)

- **The Odds API** — market feed for `Line_Opener`, `Line_Closing`, `Steam_Movements` (10 rotating keys)
- **RapidAPI** — WNBA roster/stats feed for `On_Off_NetRating` and injury data (API-NBA)
- **Credentials:** `scripts/credentials.json`

## Alert Channels (Confirmed)

- **Telegram** — primary alert destination for steam flags and injury discrepancies
- **Discord** — secondary webhook alert channel

## Build Status

- [x] Data sources identified and connected
- [x] Ingestion scripts written
- [x] Steam detection logic implemented
- [x] Injury alert script implemented
- [x] On/Off net rating pipeline built
- [x] Shadow model trained and logging
- [x] Scheduled tasks registered (setup_schedule.ps1)

## Current State Note (2026-07-09, part 3 — Discord flood + Step 3b date-scope bug)

Triggered by the ESPN injury fix (part 2, below) activating a previously-dormant code path for the first time: real injuries started flowing, and `check_discrepancies()` cross-matched them against a badly-bloated `steam_movements` table, flooding `#auto-bet-broadcast` with hundreds of duplicate "INJURY DISCREPANCY" messages per player.

- **True root cause: `run_pipeline.R`'s Step 3b ("continuous steam check") had no date filter.** It correctly identifies today's two active snapshot *types* (e.g. "midday"/"closing"), but then queried `lines` for those types with zero date scoping — pulling every game that ever had those snapshot labels, all the way back to the 2023 OddsPortal backfill. Every 30-minute cycle re-ran `detect_steam()` against the entire season's completed games and stamped a fresh `detected_at` (today) on old, meaningless price differences. Confirmed live: games from 2026-06-21 through 07-04 had `steam_movements` rows timestamped today. Fixed by scoping both snapshot queries to today's `pulled_at` date (same filter `recent_snaps` above it already used). Applied the same defense-in-depth date-scoping to the sibling function `run_collection()` in `odds_ingest.R` (lower risk there — one side of its comparison is always a fresh live fetch — but no reason to leave the same latent pattern in place).
- **Damage, quantified:** `steam_movements` had accumulated 18,938 rows across only 72 real games (~263 duplicate "detections" per game); `injury_discrepancies` had 15,243 rows. Purged both tables down to rows tied to games commencing within ±1 day of now (238 and 1,720 rows respectively) — a one-time cleanup, not a recurring maintenance step, since the code fix stops new bloat from accumulating.
- **`check_discrepancies()` already had per-player game filtering** (joining on the injured player's `team` against `games.home_team`/`away_team`) by the time this was investigated — unclear whether this was applied by me earlier in the session or an external tool, but it's correct and appropriate; it just wasn't sufficient on its own because the underlying `steam_movements` data it was querying was itself corrupted by the Step 3b bug.
- **`alert_discrepancies()` had zero consolidation or dedup** — one Telegram + one Discord message per qualifying row, with no grouping. Rewrote to group by `(player_name, game_id)` and send one consolidated alert per real discrepancy event (reduced a 353-row test case to a handful of messages). Also routed both `alert_discrepancies()` and the (currently-disabled) `alert_all_injuries` FYI path to `#steam-alerts` (`DISCREPANCY_CHANNEL_ID`, same channel as steam alerts) instead of `#auto-bet-broadcast` — this is diagnostic/confirmatory signal, not a bet pick.
- **Discord cleanup:** bulk-delete requires `MANAGE_MESSAGES`, which the bot doesn't have in that channel (`403 Missing Permissions`, code `50013`) — worked around by deleting the bot's own messages one at a time (`DELETE /channels/{id}/messages/{id}` doesn't require that permission for a bot's own messages). ~3,545+ spam messages identified and removed from `#auto-bet-broadcast`; this channel is shared across multiple sport pipelines (PGA_Pro, NRFI Bot also post there), so the cleanup script filtered strictly on `author=WNBA_Shadow AND content contains "INJURY DISCREPANCY"` to avoid touching other pipelines' legitimate messages.
- **Not yet done:** consider giving the WNBA_Shadow bot `MANAGE_MESSAGES` in `#auto-bet-broadcast` so any future cleanup can use bulk-delete (100 messages/call) instead of one-at-a-time (which took ~20-30 min for this incident).
- **The flood continued for ~30+ min after the code fix was committed** — a stuck, orphaned `Rscript.exe` process (PID confirmed via `Get-CimInstance Win32_Process`) had been running continuously since 3:35 PM local, well before the fix was saved, and kept grinding through its in-memory (pre-fix) backlog sequentially across multiple different players (Rickea Jackson → Aneesah Morrow → Caitlin Clark), each producing its own multi-hundred-row false-positive flood at ~1 msg/sec. Killed via `Stop-Process -Force` (plain `taskkill` failed with access denied). Confirmed via Task Scheduler (`Get-ScheduledTaskInfo`) that newer cycles had already fired and "completed" (`LastTaskResult=0`) every 30 min while this one instance sat orphaned for 2+ hours — Task Scheduler's own tracking had lost it. **Task Scheduler settings for "WNBA Pipeline" are already correctly configured** (`MultipleInstances=IgnoreNew`, `ExecutionTimeLimit=PT20M`) — the leading theory is that instance predates when those settings were last applied, since Windows Task Scheduler doesn't retroactively enforce limit changes on an already-running instance. `run_pipeline.bat` itself runs Rscript directly/blocking (no detached spawning), so this wasn't a batch-file-detachment issue. Confirmed stopped: no new messages for 3+ minutes after the kill. Worth keeping an eye on whether this recurs now that the underlying code bug (which is what caused a normal few-second cycle to balloon into an hours-long send loop) is fixed.

## Current State Note (2026-07-09, part 2 — silent-failure sweep)

A health-check sweep (prompted by how bad the Pinnacle bug turned out to be) found the **same failure pattern — silently returns nothing, never crashes — in three more integrations**. All confirmed live and fixed same session:

- **ESPN injury status was always "Active"** (`injury_alert.R`) — ESPN's roster API shape changed; the real per-player status now lives at `a$injuries[[1]]$status`, not `a$status` (which is a roster-membership flag, always `{name:"Active"}` for any rostered player). `injury_reports` had **0 rows, ever**. Fixed — confirmed live: 43 real injured players found immediately, including a full end-to-end test through `compute_injury_adjustment()` producing a real non-zero adjustment where it always returned zero before.
- **RotoWire's injury page is JS-rendered — disabled, not fixed.** Investigated properly (fetched the real page via Firecrawl, inspected the raw HTML): it's a Webix virtualized data grid with a frozen player-name pane and a separately-indexed scrollable pane, nested link markup inside every cell, and virtualized rendering that may not even include every player in a single static snapshot. `rvest::html_table()` finding zero `<table>` elements was the whole bug. A robust fix needs a real headless browser driving scroll events — not attempted, given ESPN (now fixed) already provides comprehensive real data alone. `fetch_rotowire_injuries()` now returns empty immediately with a clear message instead of attempting a scrape that cannot succeed.
- **Action Network's endpoint was 404 — fixed the endpoint, but the actual sharp-money signal remains unavailable.** The hardcoded `games?league=wnba&date=...&book=2` endpoint doesn't exist (confirmed 404 live). Found the real one (`scoreboard/wnba`) — it returns real games/odds, but every betting-split field (`*_public`/`*_money`) is null across every game and book_id tested. Root cause found in Action Network's own page data: their `__NEXT_DATA__` blob includes `"proUpsell": "Save Big on PRO!"` — split data is a paid PRO-tier feature, not available from any free/public endpoint. Rewired the endpoint + parsing to match the real response shape (so it stops 404ing and will start working immediately if Action Network PRO is ever purchased), but the secondary confirmation gate cannot actually contribute today. `an_confirms()` correctly returns `FALSE` — same behavior as before, now for an honest reason instead of a dead URL.
- **Also found and fixed: a live, unfixed recurrence of a bug already "fixed" once in the same file.** `an_confirms()`'s side-matching had `filter(grepl(side, side, ...))` — a local variable `side` shadowed by dplyr's same-named data column inside `filter()`'s data mask, so both references resolved to the column and the check degenerated into "does each row match itself" (trivially true). Identical bug class to the team-matching fix already applied once (commit `1aa3db0`) — missed here. This was masked by the dead endpoint (never executed on real data); if someone had fixed the endpoint without this, Action Network would've started returning **wrong** confirmations instead of merely empty ones. Fixed together.
- **Column-name mismatch surfaced while fixing ESPN:** `injury_reports`' DB schema uses a `team` column, but `mispricing.R`'s `compute_injury_adjustment()` requires a `team_name` column on its input. `fetch_all_injuries()` now outputs `team_name` (matching the model's requirement) and `save_new_injuries()` renames to `team` right at the DB-write boundary, rather than picking one name and breaking the other consumer. `run_pipeline.R`'s Step 4b also simplified — it previously did its own redundant `team_id`→`team_name` join that's now handled inside `fetch_all_injuries()` itself.
- **Cleanup pass, same session:** removed the dead `"bookmaker"` placeholder from 3 more spots (`odds_ingest.R` ×2 SQL priority lists, `run_pipeline.R` and `bet_alerts.R`'s `BOOK_PREF`) and dead `"caesars"` from `mispricing.R`'s `SOFT_BOOKS` (confirmed never present under any region combo). Removed `run_prediction_pregame()` from `predict.R` — orphaned dead code whose own header comment falsely claimed it was still called from `run_pipeline.R` (deleted in the mispricing refactor, commit `b5eb4fd`; confirmed via grep + zero `trigger='pregame'` rows in `clv_log`, ever).
- **Test coverage gap — addressed:** `test_pipeline.R` previously wouldn't have caught any of the bugs above. Now: Odds API check uses `regions="us,eu"` and asserts Pinnacle actually appears in at least one game (the real regression guard — HTTP 200 alone missed this the first time); ESPN check now calls the real `fetch_all_injuries()` and asserts parsed statuses aren't uniformly "Active"; added an Action Network section (asserts the endpoint responds, notes 0 split-data rows is the expected PRO-tier state, not a failure); added a RotoWire section (asserts the disabled stub fails safe, i.e. returns empty without erroring).

## Current State Note (2026-07-09)

- **CRITICAL FIX — mispricing model never fired, ever, until today.** `mispricing.R` hardcodes `SHARP_BOOK <- "pinnacle"` for every totals/spreads comparison, but `fetch_wnba_odds()` fetched with `regions = "us"` only. Pinnacle is classified under the `eu` region by The Odds API and was **never** returned under `us` — confirmed live and against the DB: zero Pinnacle rows ever existed in `lines`, and `clv_log` had zero `trigger='mispricing'` rows since Step 4b was deployed (commit `b5eb4fd`, 2026-07-07). `compute_mispricing()` silently returned `NULL` on every single invocation. Fixed: `fetch_wnba_odds()` default is now `regions = "us,eu"` (`scripts/odds_ingest.R`). Cost impact: roughly doubles Odds API quota per call (confirmed 3→6 units for the 3-market fetch) — draws from the same 10-key pool shared with the MLB pipeline. No historical Pinnacle data exists to backfill; the mispricing model starts accumulating real data from today forward.
- **Steam thresholds now calibrated, not hardcoded** — `STEAM_MIN_MOVE`/`STEAM_MIN_BOOKS` in `odds_ingest.R` were pure module constants, never read anywhere dynamically. Added `.get_steam_thresholds(con)` (mirrors `mispricing.R`'s `.get_dev_threshold()`) so `detect_steam()` now reads `model_config` params `steam_min_move`/`steam_min_books` with fallback to the module constants. Seeded in `db_setup.R`.
- **`calibrate_mispricing.R` extended with steam calibration (totals V1)** — new `backtest_steam()` / `sweep_steam_thresholds()` / `auto_apply_steam_thresholds()`, wired into `calibrate_mispricing_run()` alongside the existing `dev_threshold` sweep (same guardrail philosophy: `MIN_N_APPLY=30`, `MIN_WR_IMPROVEMENT=0.02`, capped per-run delta). Unlike `dev_threshold` (which needs Pinnacle data that doesn't exist yet historically), steam backtesting only needs `SHARP_BOOKS` (pinnacle, betonlineag, lowvig) — **betonlineag/lowvig history already existed**, so this had real data to calibrate against immediately. First real run (2026-07-09, N=30-39 signals): auto-applied `steam_min_move` 0.5 → 0.75 (WR 46.2%→50.0%, +3.8pp, within guardrails). **Caveat: even the improved config is still net-negative as a standalone signal (-4.5% ROI at -110 juice)** — this measures "bet steam alone," not "steam as a mispricing confirmation gate," which is a different (currently unanswerable) question until real Pinnacle-vs-soft-book data accumulates. Scoped totals-only for V1, matching the mispricing model's own totals-first precedent — spreads needs correct per-team `outcome_name` win-check logic before extending.
- **Found, not fixed — flagging for a separate decision:** `detect_steam()`'s `STEAM_WINDOW_MINS` check only logs a warning, it has never actually filtered anything. Real snapshot gaps: opener→midday is a fixed ~120 min (15:00→17:00 ET), midday→closing varies 50-230+ min with tip time. The current value (60) is incompatible with the ~120 min opener→midday gap — enforcing it as-is would silently zero out that entire comparison. Left as a known no-op pending a decision on what the window concept should actually mean here (fixed larger value? per-comparison values? drop it?).
- **Also fixed:** `SHARP_BOOKS` included `"bookmaker"`, which isn't a real Odds API bookmaker key (confirmed against a live `us+eu` response) — dead entry removed, no behavior change since it never matched anything.

## Current State Note (2026-07-03)

- **`bet_alerts.R` is live and wired** — `emit_wnba_bet_alert()` has full Kelly sizing (half-Kelly) + `emit_broadcast()` + BET_HISTORY CSV. Sourced in `run_pipeline.R` at startup; called from Step 4 after `run_prediction()` on every steam flag. The bet chain is complete and ready to fire.
- **Steam dedup deployed** — `steam_log` table gates all alerts; `is_new_steam()` + `resolve_steam()` prevent duplicate fire. Root-cause fix for 900+ duplicate alerts in first 48h. `resolve_steam()` called after Step 3b (continuous check), not before — was causing second wave of duplicates.
- **Discord bot wired** — `send_discord()` in `injury_alert.R` prefers `discord_bot_token` over webhook; falls back on failure. Bot token confirmed in `credentials.json`.
- **Steam alerts → #steam-alerts (2026-07-03)** — individual steam flag alerts and run summary Discord posts now route to `#steam-alerts` (channel ID `1521690907760525342`) instead of `#auto-bet-broadcast`. Constant `STEAM_CHANNEL_ID` defined in `run_pipeline.R`; both `alert_steam_flags()` individual sends and the end-of-run summary pass `channel_id = STEAM_CHANNEL_ID`.
- **OddsPortal backfill complete** — 662/978 historical games (76.5%) now have real closing totals in `lines` table (`snapshot_type='closing', bookmaker='oddsportal'`). `data/op_done.rds` tracks progress; safe to re-run (skips already-done games).
- **Models retrained (2026-06-23)** — `closing_line` added as predictor. R² improved: totals 6.7%→8.0%, spreads 5.6%→13.3%. Top totals features: `home_on_off_delta` (0.25), `away_on_off_delta` (0.20), `home_pace` (0.15), `away_pace` (0.14), `closing_line` (0.14). Weekly retrain (Sun 6 AM) will continue to improve coverage as 2026 live lines accumulate.
- **Steam timing corrected** — `OPEN_HOUR = 15L`, `MIDDAY_HOUR = 17L`, `SETTLE_HOUR = 10L`. WNBA books don't post until ~3 PM ET; old 10 AM window captured 0 rows.
- **`game_outcomes` daysFrom limit = 3** — Odds API returns 422 for `daysFrom > 3`. Default `SCORES_DAYS_BACK = 3L` is correct.
- **bet_router settler wired** — `settle_wnba_bets()` joins `open_bets → game_outcomes` on `game_id`. Will activate on first real WNBA alert.
- **UTC date shift fixed (2026-06-28)** — `games_near_tip()` in `run_pipeline.R` now uses a UTC range query (`commence_time >= today 04:00Z AND < tomorrow 04:00Z`) instead of `DATE(commence_time, '-4 hours') = today`. The offset approach was EDT-correct but off by one hour in EST (Nov–Mar). The 04:00Z boundary equals midnight EDT and 11 PM EST — past any real WNBA tip time — so the range is timezone-safe year-round.
- **State-driven scheduling (2026-06-28)** — `pipeline_runs` table added to `db_setup.R` with `has_run_today()` / `mark_run_today()` helpers. Step 0 (settlement) was previously guarded by `near_hour(10)` — silently skipped if machine slept through 10 AM. Now `hour_et() >= SETTLE_HOUR && !has_run_today("settle", con)` fires on the next invocation after 10 AM. Steps 1/2 (opener/midday): `near_hour()` replaced with `hour_et() >= N`; inner DB count check retained as dedup.
- **Error containment (2026-06-28)** — bare `dbGetQuery` calls for `opener_count`, `midday_count`, `already_closed`, `steam_today` wrapped in `tryCatch` with safe sentinel defaults. A locked DB skips the step rather than crashing the run.
- **DB moved to local path (2026-06-28)** — `wnba_pipeline.sqlite` moved from Google Drive to `C:/Users/Mike/sports_data/`. All 10 scripts that defined `DB_PATH` updated. `open_wnba_db()` helper added to `db_setup.R`; `run_pipeline.R` and `wnba_settle.R` use it.
- **PRAGMA foreign_keys (2026-06-28)** — `open_wnba_db()` now sets `PRAGMA foreign_keys = ON` on every connection. Was not set anywhere before.

## Session Summary (2026-07-09, Session 10 — Silent-Failure Sweep: Injuries + Action Network)

Prompted by how serious the Pinnacle bug turned out to be (Session 9, below) — hunted for the same failure class (silently returns nothing, never crashes) elsewhere in the pipeline. Found three more, all confirmed live and fixed same session.

### `scripts/injury_alert.R` — ESPN injury status field was always "Active"

- `a$status` is a roster-membership flag ESPN always sets to `{name:"Active"}` for any rostered player — the real per-player status lives at `a$injuries[[1]]$status`. `fetch_team_roster()`'s `p_status` logic now checks the injuries array first, falling back through the historical `a$status` shapes only when no injuries entry exists
- `fetch_all_injuries()` now joins `team_name` internally (was previously left to the caller in `run_pipeline.R`) — required because `mispricing.R`'s `compute_injury_adjustment()` checks for a column literally named `team_name`
- `save_new_injuries()` renames `team_name` → `team` right before `dbAppendTable()`, since the `injury_reports` DB schema (`db_setup.R`) uses `team` — two different consumers wanting two different names for the same data, reconciled at the DB-write boundary rather than picking one name globally
- Verified end-to-end: 43 real injured players found (vs 0 before), `compute_injury_adjustment()` produces a real non-zero adjustment for a real game

### `scripts/rotowire_injuries.R` — disabled, not fixed

- RotoWire's injury page is a Webix virtualized data grid (confirmed via a Firecrawl JS-rendered fetch of the real page) — `html_table()` finding zero `<table>` elements was the whole bug, and a real fix needs a headless browser driving scroll events (virtualized rows may not all render in one static snapshot)
- `fetch_rotowire_injuries()` now returns empty immediately with a clear disabled-message instead of attempting a scrape that structurally cannot succeed
- Removed ~90 lines of now-unreachable scraping logic

### `scripts/action_network.R` — dead endpoint fixed, PRO-tier paywall found and documented

- `AN_API_BASE` endpoint changed from the 404ing `games?league=wnba&date=...&book=2` to the real `scoreboard/wnba` endpoint
- Rewrote the parsing logic to match the real response shape (`games[].teams`/`games[].odds[]` with `*_public`/`*_money` fields per book)
- Root-caused why splits are still empty: Action Network's own page data (`__NEXT_DATA__`) shows a `"proUpsell": "Save Big on PRO!"` banner — betting-split data is a paid tier feature, confirmed unavailable from any free endpoint tested
- Fixed a live recurrence of an already-once-fixed bug: `an_confirms()`'s side-matching (`filter(grepl(side, side, ...))`) had the same local-variable-shadowed-by-column bug as the team-matching fix in commit `1aa3db0` — renamed to `target_side` to match that fix's pattern (`lw_home`/`lw_away` instead of `home`/`away`)

### `scripts/run_pipeline.R`

- Simplified Step 4b's injury snapshot block — removed the now-redundant `fetch_espn_teams()` + `team_id` join, since `fetch_all_injuries()` handles it internally now

---

## Session Summary (2026-07-09, Session 9 — Pinnacle Region Bug + Steam Calibration)

### `scripts/odds_ingest.R` — Pinnacle region bug (root cause of mispricing model never firing)

- `fetch_wnba_odds()` default changed `regions = "us"` → `regions = "us,eu"` — Pinnacle only exists under `eu` at The Odds API, confirmed live
- `SHARP_BOOKS`: removed `"bookmaker"` (not a real bookmaker key, dead entry)
- Added `.get_steam_thresholds(con)` — reads `model_config` `steam_min_move`/`steam_min_books` with fallback to module constants
- `detect_steam()` now uses calibrated `min_move`/`min_books` instead of the hardcoded `STEAM_MIN_MOVE`/`STEAM_MIN_BOOKS` constants directly
- `STEAM_WINDOW_MINS` enforcement gap documented inline (still a no-op — see Current State Note above)

### `scripts/shadow_model/calibrate_mispricing.R` — steam threshold calibration (totals V1)

- New `backtest_steam()` — replays historical opener→midday / midday→closing movements from raw `lines` (not `steam_movements`) at a given (move, books) threshold, checks win rate against `game_outcomes.actual_total`
- New `sweep_steam_thresholds()` / `auto_apply_steam_thresholds()` — same grid-sweep + guardrailed auto-apply pattern as `dev_threshold`
- Wired into `calibrate_mispricing_run()`; Telegram summary extended to report both dev_threshold and steam calibration results
- Fixed a many-to-many join bug in my own first draft of `backtest_steam()` (totals carry both "Over"/"Under" rows sharing one point value — needed `outcome_name = 'Over'` filter, mirroring `detect_steam()`'s own join keys)

### `scripts/db_setup.R`

- Seeded `model_config` with `steam_min_move` (0.5) and `steam_min_books` (2) defaults

---

## Session Summary (2026-07-03, Session 8 — Steam Channel Routing)

### `scripts/run_pipeline.R` — Steam alerts routed to #steam-alerts

Steam Discord alerts were posting to `#auto-bet-broadcast` (the bet ingestion channel), cluttering it with non-actionable noise. Fixed by adding a `STEAM_CHANNEL_ID` constant and passing it to both `send_discord()` calls.

**Changes:**
- Added `STEAM_CHANNEL_ID <- "1521690907760525342"` constant (`#steam-alerts`)
- `alert_steam_flags()` individual alert loop: `send_discord(msg, creds, channel_id = STEAM_CHANNEL_ID)`
- End-of-run summary: `send_discord(summary_msg, creds, channel_id = STEAM_CHANNEL_ID)`
- `#auto-bet-broadcast` now receives only structured bet alerts (`emit_broadcast()` blocks)

---

## Session Summary (2026-06-28, Session 7 — Infrastructure Hardening)

### `scripts/db_setup.R`

- Added `pipeline_runs` table: `PRIMARY KEY (step, run_date)` — one row per completed step per day
- Added `has_run_today(step, con)` — returns TRUE if step completed today (DB query, `tryCatch`-guarded)
- Added `mark_run_today(step, con)` — inserts completion row; idempotent via `INSERT OR IGNORE`
- `open_wnba_db()` helper now sets `PRAGMA foreign_keys = ON` immediately after `dbConnect`
- `DB_PATH` updated to `C:/Users/Mike/sports_data/wnba_pipeline.sqlite` (all 10 scripts)

### `scripts/run_pipeline.R`

- **Step 0**: `near_hour(SETTLE_HOUR)` → `hour_et() >= SETTLE_HOUR && !has_run_today("settle", con)` + `mark_run_today` at end
- **Steps 1/2**: `near_hour()` replaced with `hour_et() >= N`; inner `dbGetQuery` for count wrapped in `tryCatch(error = \(e) 1L)`
- **Step 3**: `already_closed <- dbGetQuery(...)` wrapped in `tryCatch(error = \(e) character(0))`
- **Step 4**: `steam_today <- dbGetQuery(...)` wrapped in `tryCatch(error = \(e) tibble())`
- UTC range fix: `commence_time >= ? AND < ?` replacing `DATE(commence_time, '-4 hours') = ?`
