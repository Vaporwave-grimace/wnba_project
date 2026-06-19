# WNBA Sandbox Intelligence Pipeline — Current State

> For full architecture, variable definitions, and pipeline diagram see `WNBA_Architecture.md`.

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

## Current State Note (2026-06-19)

- **`wnba_settle.R` added** — populates `game_outcomes` from Odds API scores; wired into 9 AM opener step in `run_pipeline.R`. 8 games written on first backfill run; table now at 958 rows (950 training + 8 live).
- **`game_outcomes` daysFrom limit = 3** — Odds API returns 422 for `daysFrom > 3`. Default `SCORES_DAYS_BACK = 3L` is correct. Do not pass higher values in manual calls.
- **bet_router settler can now settle WNBA bets** once WNBA alerts start posting to `#auto-bet-broadcast`. Settlement joins `open_bets` → `game_outcomes` on `game_id` (Odds API hex format matches both endpoints).
- **WNBA bet-sizing/alerts not yet live** — XGBoost models trained but no bet-sizing or alert output wired yet. bet_router WNBA settler stub remains dormant until this is built.

## Previous State Note (2026-06-14)

- **Pipeline fully operational.** Telegram heartbeat confirmed firing: 6 games tracked Jun 14.
- All prior blockers resolved — see Recent Session Summary below.
- Next focus: steam detection quality (0 flags despite live action — check threshold calibration and whether line movement data is populating); shadow model predictions logging against closing lines for CLV tracking.

## Session Summary (2026-06-19, Session 4 — Cross-Pipeline Integration)

### `scripts/wnba_settle.R` (new)

Populates `game_outcomes` from Odds API `/sports/basketball_wnba/scores` endpoint so `settle_wnba_bets()` in bet_router can join on `game_id` (same hex format used in the events/lines endpoints).

- `wnba_settle_run(con, days_from = SCORES_DAYS_BACK)` — fetches completed games, writes `(game_id, game_date, home_team_id, away_team_id, home_score, away_score, actual_total, actual_spread, season)` via `INSERT OR IGNORE` on `game_id` PK
- `SCORES_DAYS_BACK = 3L` — **Odds API returns 422 for `daysFrom > 3`**; do not pass higher values
- Requires `key_state$init(creds)` before calling standalone (same as all `odds_request()` calls)
- Wired into `run_pipeline.R` 9 AM opener step, before line collection

### `game_outcomes` backfill (2026-06-19)

Manual run: `wnba_settle_run(con, days_from=3L)` → 8 new games written; table now 958 rows.

---

## Recent Session Summary (2026-06-14, Session 3)

- **CLV tracking wired up** — steam flags now write to `clv_log` as simulated bet entries; closing snapshot settles open entries and computes directional CLV
  - `record_clv_entry(steam_df, con)` in `odds_ingest.R` — logs current (post-steam) Pinnacle-first line as `model_line`; idempotent (skips if already logged for that game/market/side); stores `steam_direction` for correct sign convention
  - `compute_wnba_clv(con)` in `odds_ingest.R` — joins open `clv_log` entries to closing snapshot; CLV = `model_line − closing_line` for "down" steam, `closing_line − model_line` for "up" steam (positive = beat the close)
  - `alert_steam_flags()` in `run_pipeline.R` — calls `record_clv_entry()` after alerts sent
  - Closing snapshot step in `run_pipeline.R` — calls `compute_wnba_clv()` after closing is captured
  - `db_setup.R` — idempotent migration adds `steam_direction TEXT` to `clv_log`
- **Data flow:** steam fires → entry logged at current line → closing snapshot captured pre-tip → CLV settled; all in `clv_log`
- **Note:** CLV accumulates only when steam is detected; zero-steam days produce no entries (correct — no signal, no simulated bet)

## Previous Session Summary (2026-06-14, Session 2)

- **Heartbeat message overhauled** — replaced count-only summary with actionable data:
  - **Game slate:** shows each matchup (Away @ Home), tip time ET, favored team + spread, o/u total pulled from latest snapshot (Pinnacle-first book preference)
  - **Steam detail:** when flags exist, lists game matchup, market, direction (↑/↓), magnitude in pts, and book count
  - **Injury detail:** when injuries exist, lists player name, team, status — not just a count
  - Zero-count sections collapse to a single "No X today" line
- Change in `scripts/run_pipeline.R` — summary block at bottom (~lines 287+)

## Previous Session Summary (2026-06-14)

- **R path in `.bat` fixed** and `setup_schedule.ps1` re-run to re-register Task Scheduler with correct path
- **`now_et()` forward reference** resolved in `run_pipeline.R`
- **ESPN API structure** patched in `fetch_team_roster()` and `fetch_all_injuries()` to match current response shape
- **`run_pipeline.ps1` null ExitCode** fixed — `$proc.ExitCode` returns null on clean R exit; now treated as 0, eliminating false FAILED log entries
- **Telegram confirmed:** `🏀 WNBA Pipeline | Jun 14 04:04 PM ET | 📊 Games: 6 | 🔥 Steam: 0 | 🩹 Injuries: 0`
- Next: investigate 0 steam flags with 6 live games — check `Steam_Movements` threshold and odds API line history population

## Previous Session Summary (2026-06-06)

- Silent Telegram heartbeat flagged (no output 6/4–6/6); root cause not identified; diagnostics deferred
- No code changes made

## Session Summary (2026-06-02)

- **`run_pipeline.R` Telegram heartbeat added:** every 30-minute pipeline invocation now sends a summary to `@LBA_Betting_Intel_Bot` with games tracked, steam flags, and injury updates; steam and injury alerts still fire immediately on detection; heartbeat fires at end of each run
- **`setup_schedule.ps1` fixed:** two bugs corrected — (1) execution policy: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` then `powershell -ExecutionPolicy Bypass` workaround; (2) trigger repetition: `-Once` with `-RepetitionInterval` is the correct syntax for repeating scheduled tasks on Windows (not `-Daily` + `.Repetition.Interval` property assignment which doesn't work)
- **WNBA Pipeline scheduled task registered and confirmed:** `Enabled: True`, `Repetition: MSFT_TaskRepetitionPattern` (30-minute interval), `NextRunTime: 6/2/2026 10:30:30 AM`; runs 8:00 AM–11:30 PM daily
- **First pipeline run confirmed:** `Start-ScheduledTask -TaskName "WNBA Pipeline"` fired; Telegram confirmed: "🏀 WNBA Pipeline | Jun 02 12:18 PM ET | 📊 Games: 0 | 🔥 Steam: 0 | 🩹 Injuries: 0" — zeros expected on first run (opener snapshot fires at 9 AM ET, run was post-window; baselines established for future delta comparisons)
- Next: debug silent Telegram (no output 6/4+); verify Task Scheduler still firing; check games query for date logic

## Previous Session Summary (2026-06-01)

- `seed.R` re-run with 15-minute bench threshold for on/off splits: 838 game outcomes, 1676 game log rows, 34 on/off rows across 2023/2024/2025 seasons; expansion teams and teams with <2 bench splits warned but handled via median imputation
- `train.R` fixed (type mismatch on `home_team_id` join, `collect_metrics` `.estimate` vs `mean` in tidymodels 1.5, deprecated `grid_latin_hypercube` replaced with `grid_space_filling`); both models trained successfully
- **Totals XGB:** CV RMSE 17.65, Test RMSE 17.01, R² 0.005 — no market features yet, expected baseline
- **Spreads XGB:** CV RMSE 13.51, Test RMSE 13.35, R² 0.053 — on/off delta provides weak spread signal
- Models saved: `models/totals_xgb.rds`, `models/spreads_xgb.rds`, `models/training_meta.rds`
