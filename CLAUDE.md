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
