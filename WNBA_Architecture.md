# WNBA Sandbox Intelligence Pipeline

**Objective:** Operate a zero-capital paper trading market to observe line movement, quantify bookmaker inefficiencies, and map rotation depth variance without financial exposure.

---

## 1. Data Ingestion & Variables

Run this collection stage continuously throughout the day across three windows: **Open**, **Midday**, and **Lock**.

### Market Mechanics

| Variable | Description |
|---|---|
| `Line_Opener` | The opening spread and total at market open |
| `Line_Closing` | The final market price before tip-off |
| `Steam_Movements` | Rapid movements across multiple sharp sportsbooks indicating heavy syndicate action |

### Roster Depth Tracker

| Variable | Description |
|---|---|
| `On_Off_NetRating` | The team's net efficiency when the 6th and 7th rotational players are off the court |
| `Injury_Discrepancies` | Script alerts comparing official injury reports against line movement delay windows |

---

## 2. Machine Learning Sandbox (Shadow Model)

### Feature Collection
Capture historical sequences of total line movements alongside pace metrics and team rest periods.

### Analysis Focus
Quantify **Closing Line Value (CLV)** capture. The sandbox logs instances where an early automated calculation successfully anticipates line movement driven by sharp action.

### Performance Metrics
The pipeline generates a **calibration curve** comparing simulated predictions against actual game totals, providing a clear view of market blindspots.

---

## Pipeline Overview

```
[Data Sources]
    │
    ├── Market Feed (Open / Midday / Lock)
    │       ├── Line_Opener
    │       ├── Line_Closing
    │       └── Steam_Movements
    │
    └── Roster Feed (Continuous)
            ├── On_Off_NetRating
            └── Injury_Discrepancies
                        │
                        ▼
            [ML Shadow Model]
                        │
                        ├── Feature: Line movement sequences
                        ├── Feature: Pace metrics
                        └── Feature: Team rest periods
                        │
                        ▼
            [Output: Calibration Curve]
                CLV Capture vs. Actual Game Totals
```

---

## Session Log

### [2026-05-29] Session 1 — Shadow model layer built and historical data seeded

- `scripts/shadow_model/seed.R`, `train.R`, `predict.R`, `calibrate.R` implemented; seed.R ran successfully (526 game outcomes, 1052 game log rows, on/off splits for all WNBA teams, 2023/2024 seasons)
- Fixed critical `on.exit(dbDisconnect(con))` bug across all three scripts — fires unexpectedly when sourced at top level; replaced with `tryCatch(..., finally = { dbDisconnect(con) })` throughout
- `tidymodels` (1.5.0), `xgboost` (3.2.1.1), and `vip` installed; all shadow model dependencies satisfied
- No structural schema changes beyond `game_outcomes` table addition — append-only design, calibration pipeline auto-generates reports to `reports/` directory

### [2026-06-02] Session 3 — Scheduled task confirmed live; first pipeline run; Telegram heartbeat added
- Telegram run-summary heartbeat added to `run_pipeline.R` — fires at end of every 30-minute invocation with games tracked, steam flags, and injury update counts; first confirmed message: "🏀 WNBA Pipeline | Jun 02 12:18 PM ET | 📊 0 | 🔥 0 | 🩹 0"
- `setup_schedule.ps1` syntax fixed: trigger repetition uses `-Once` + `-RepetitionInterval` (not `-Daily` with `.Repetition.Interval` property assignment); `DisallowStartIfOnBatteries:$false` also removed (unsupported on this Windows build)
- WNBA Pipeline Task Scheduler task registered and verified: `Enabled=True`, `Repetition=MSFT_TaskRepetitionPattern` (PT30M), `NextRunTime=2026-06-02 10:30 AM` — pipeline now running autonomously
- First live run completed via `Start-ScheduledTask`; 0 games/steam/injuries on first run (expected — opener snapshot at 9 AM already passed; baselines established for delta detection)
- No structural schema changes — operational session only

### [2026-06-01] Session 2 — Shadow model trained on full 3-season dataset; scheduled tasks registered
- `seed.R` re-run with 15-minute bench threshold for on/off splits; 838 game outcomes, 1676 game log rows, 34 on/off rows seeded across 2023/2024/2025 seasons
- Fixed `home_team_id` type mismatch (character vs integer on join), tidymodels 1.5 API changes (`collect_metrics` `.estimate` column, `grid_space_filling` replacing deprecated `grid_latin_hypercube`) in `train.R`
- Both XGB models trained: Totals (RMSE 17.01, R² 0.005), Spreads (RMSE 13.35, R² 0.053) — roster-only baseline, market features will assert as live data accumulates
- `setup_schedule.ps1` run as Administrator; 7 scheduled tasks registered for daily pipeline automation
- No structural schema changes — training set built directly from `game_outcomes` without `lines` dependency
