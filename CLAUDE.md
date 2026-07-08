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
