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

## Recent Session Summary (2026-06-02)

- **`run_pipeline.R` Telegram heartbeat added:** every 30-minute pipeline invocation now sends a summary to `@LBA_Betting_Intel_Bot` with games tracked, steam flags, and injury updates; steam and injury alerts still fire immediately on detection; heartbeat fires at end of each run
- **`setup_schedule.ps1` fixed:** two bugs corrected — (1) execution policy: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` then `powershell -ExecutionPolicy Bypass` workaround; (2) trigger repetition: `-Once` with `-RepetitionInterval` is the correct syntax for repeating scheduled tasks on Windows (not `-Daily` + `.Repetition.Interval` property assignment which doesn't work)
- **WNBA Pipeline scheduled task registered and confirmed:** `Enabled: True`, `Repetition: MSFT_TaskRepetitionPattern` (30-minute interval), `NextRunTime: 6/2/2026 10:30:30 AM`; runs 8:00 AM–11:30 PM daily
- **First pipeline run confirmed:** `Start-ScheduledTask -TaskName "WNBA Pipeline"` fired; Telegram confirmed: "🏀 WNBA Pipeline | Jun 02 12:18 PM ET | 📊 Games: 0 | 🔥 Steam: 0 | 🩹 Injuries: 0" — zeros expected on first run (opener snapshot fires at 9 AM ET, run was post-window; baselines established for future delta comparisons)
- Next: monitor tomorrow 9 AM ET opener snapshot for non-zero game count; steam flags start appearing tomorrow afternoon (need opener + midday snapshot to compare); injury updates will fire as ESPN detects status changes from today's baseline

## Previous Session Summary (2026-06-01)

- `seed.R` re-run with 15-minute bench threshold for on/off splits: 838 game outcomes, 1676 game log rows, 34 on/off rows across 2023/2024/2025 seasons; expansion teams and teams with <2 bench splits warned but handled via median imputation
- `train.R` fixed (type mismatch on `home_team_id` join, `collect_metrics` `.estimate` vs `mean` in tidymodels 1.5, deprecated `grid_latin_hypercube` replaced with `grid_space_filling`); both models trained successfully
- **Totals XGB:** CV RMSE 17.65, Test RMSE 17.01, R² 0.005 — no market features yet, expected baseline
- **Spreads XGB:** CV RMSE 13.51, Test RMSE 13.35, R² 0.053 — on/off delta provides weak spread signal
- Models saved: `models/totals_xgb.rds`, `models/spreads_xgb.rds`, `models/training_meta.rds`
