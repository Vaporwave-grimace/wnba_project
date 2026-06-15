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

## Current State Note (2026-06-14)

- **Pipeline fully operational.** Telegram heartbeat confirmed firing: 6 games tracked Jun 14.
- All prior blockers resolved — see Recent Session Summary below.
- Next focus: steam detection quality (0 flags despite live action — check threshold calibration and whether line movement data is populating); shadow model predictions logging against closing lines for CLV tracking.

## Recent Session Summary (2026-06-14, Session 2)

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
