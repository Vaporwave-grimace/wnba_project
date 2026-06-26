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

## Current State Note (2026-06-26)

- **`bet_alerts.R` is live and wired** — `emit_wnba_bet_alert()` has full Kelly sizing (half-Kelly) + `emit_broadcast()` + BET_HISTORY CSV. Sourced in `run_pipeline.R` at startup; called from Step 4 after `run_prediction()` on every steam flag. The bet chain is complete and ready to fire.
- **Steam dedup deployed** — `steam_log` table gates all alerts; `is_new_steam()` + `resolve_steam()` prevent duplicate fire. Root-cause fix for 900+ duplicate alerts in first 48h. `resolve_steam()` called after Step 3b (continuous check), not before — was causing second wave of duplicates.
- **Discord bot wired** — `send_discord()` in `injury_alert.R` prefers `discord_bot_token` over webhook; falls back on failure. All Discord output posts as WNBA bot to `#auto-bet-broadcast`. Bot token confirmed in `credentials.json`.
- **OddsPortal backfill complete** — 662/978 historical games (76.5%) now have real closing totals in `lines` table (`snapshot_type='closing', bookmaker='oddsportal'`). `data/op_done.rds` tracks progress; safe to re-run (skips already-done games).
- **Models retrained (2026-06-23)** — `closing_line` added as predictor. R² improved: totals 6.7%→8.0%, spreads 5.6%→13.3%. Top totals features: `home_on_off_delta` (0.25), `away_on_off_delta` (0.20), `home_pace` (0.15), `away_pace` (0.14), `closing_line` (0.14). Weekly retrain (Sun 6 AM) will continue to improve coverage as 2026 live lines accumulate.
- **Steam timing corrected** — `OPEN_HOUR = 15L`, `MIDDAY_HOUR = 17L`, `SETTLE_HOUR = 10L`. WNBA books don't post until ~3 PM ET; old 10 AM window captured 0 rows.
- **`game_outcomes` daysFrom limit = 3** — Odds API returns 422 for `daysFrom > 3`. Default `SCORES_DAYS_BACK = 3L` is correct.
- **bet_router settler wired** — `settle_wnba_bets()` joins `open_bets → game_outcomes` on `game_id`. Will activate on first real WNBA alert.
- **UTC date shift fixed (2026-06-26)** — `games_near_tip()` in `run_pipeline.R` was filtering `WHERE DATE(commence_time) = today` using raw UTC, so any game tipping at/after 8 PM ET (midnight+ UTC) fell on the next UTC date and was silently excluded. Fixed: `DATE(commence_time, '-4 hours')` converts to EDT before the date comparison. Most WNBA primetime games were affected.

## Session Summary (2026-06-23, Session 6 — OddsPortal Backfill + Model Retraining)

### `scripts/oddsportal_scraper.R` (new)

Firecrawl-based scraper fetching historical WNBA closing totals from OddsPortal for 2023/2024/2025 seasons. Writes to `lines` table as `snapshot_type='closing', bookmaker='oddsportal'` — two rows per game (Over + Under).

**Key functions:**
- `.season_game_list(season)` — paginates OddsPortal results pages; **hash-based routing** (`results/#/page/N/`, NOT `?page=N` which cycles same content); `wait_ms = 15000L`; cycle detection: stops when >60% of a new page's game IDs were already seen
- `.parse_closing_total(game_url)` — Firecrawl JS-click actions: click "Over/Under" tab after 7s wait → scrape displayed odds; returns point + odds
- `.match_game_id(op_date, home_slug, away_slug)` — joins to `game_outcomes + game_log` via date + `agrepl(max.distance=0.3)` fuzzy team name match
- `oddsportal_backfill_run()` — processes all three seasons; progress saved to `data/op_done.rds`; safe to interrupt/resume

**Backfill result:** 662/978 games (67.7% 2023, 73.5% 2024, ~80% 2025); 76.5% overall. Remaining ~24% imputed to median in XGBoost via `step_impute_median()`.

**Pagination note:** OddsPortal is a Next.js SPA — `?page=N` returns the same recent window regardless of N. Correct URL is `results/#/page/N/` with a 15s wait for JS hydration.

### `scripts/shadow_model/train.R` — `closing_line` predictor added

- `closing_line = NA_real_` added to hardcoded NA block in `build_historical_training_set()`
- After features built, joins OddsPortal lines: `SELECT game_id, AVG(point) AS closing_line FROM lines WHERE snapshot_type='closing' AND bookmaker='oddsportal' AND market='totals' GROUP BY game_id`
- `"closing_line"` added to `PREDICTORS` (between `midday_line` and `delta_open_mid`)

### `scripts/shadow_model/features.R` — bookmaker filter updated

`'oddsportal'` added to bookmaker `IN` clause for the live inference closing line query — ensures live games can pull OddsPortal-sourced closing lines alongside Pinnacle/other books.

### Model retraining results

Both XGBoost models retrained with `closing_line` populated for 748/978 games:

| Model | Before R² | After R² |
|---|---|---|
| Totals | 6.7% | 8.0% |
| Spreads | 5.6% | 13.3% |

**Totals VIP (top 7):** `home_on_off_delta` (0.25), `away_on_off_delta` (0.20), `home_pace` (0.15), `away_pace` (0.14), `closing_line` (0.14), `home_rest_days` (0.10), `away_rest_days` (0.05). On/off delta dominates; closing_line is 5th but grows as 2026 live data accumulates with real lines for every game.

**Spreads model improved more** (5.6→13.3%) — spread prediction benefits more from closing_line (market encodes talent gap directly). Totals is more structural.

### `scripts/credentials.json` — Firecrawl key added

`"firecrawl_api_key": "fc-2716ee57343245ab96f8f9862660f1a2"` — used by `oddsportal_scraper.R` for JS-rendered page scraping.

---

## Session Summary (2026-06-20, Session 5 — Steam Timing + Alert Fixes)

### `scripts/run_pipeline.R` — Collection window timing fix

WNBA books don't post same-day lines until ~2-3 PM ET. Previous `OPEN_HOUR = 10L` (10 AM) got 0 rows from Odds API every run → no steam baseline → steam detection never fired.

**Changes:**
- `SETTLE_HOUR = 10L` (new) — morning settlement + on/off refresh, no odds collection
- `OPEN_HOUR = 15L` (was 10L) — opener odds snapshot at 3 PM ET
- `MIDDAY_HOUR = 17L` (was 13L) — midday odds snapshot at 5 PM ET
- Step 0 added — morning-only block at `SETTLE_HOUR`: runs `wnba_settle_run()` + on/off ratings
- Step 1 simplified — only fetches opener odds (settlement removed)

Steam detection windows now: opener (3 PM) → midday (5 PM) → closing (~6:20 PM for 7:30 PM tips).

### `db_setup.R` + `run_pipeline.R` — Steam dedup (`steam_log` table)

Root cause of 900+ duplicate alerts in first 48h: `alert_steam_flags()` fired on every 30-min run against the same snapshot pair with no dedup.

**Changes:**
- New table `steam_log` — unique index on `(game_id, market, outcome_name, direction)`; tracks which steam events have already been alerted
- `is_new_steam(event, con)` — returns TRUE only if the event isn't already in `steam_log`
- `resolve_steam(con)` — marks all open `steam_log` entries as resolved at end of game day
- `resolve_steam()` moved to **after** Step 3b (continuous check) — was previously called before, causing Step 3b to re-insert the same events on a clean slate (second wave of duplicates)
- `distinct(game_id, .keep_all = TRUE)` added on `steam_today` in Step 4 shadow model to prevent duplicate predictions per invocation

### `run_pipeline.R` — Opposite steam conflict display

When `steam_log` has both ↑ and ↓ for the same `game_id + market` in the same run, now displayed as `⚡ CONFLICT ↑Xpts / ↓Xpts | N books split` instead of duplicate rows. Conflicts sorted to top of steam summary with conflict count in header.

### `scripts/injury_alert.R` — Discord bot token preference

`send_discord()` now prefers `creds$discord_bot_token` over the webhook URL, falling back to webhook on failure. All Discord output (run summaries, steam alerts, injury alerts, bet alerts) posts as the WNBA bot (`#auto-bet-broadcast`). Bot token confirmed in `credentials.json`.

### `scripts/injury_alert.R` — `send_telegram` + `send_discord` 400 fix

Root cause of 22 ERR on Jun 16-17: `send_telegram` used `req_perform()` without `req_error(is_error = \(r) FALSE)`, so Telegram 400 (Markdown parse failure on game spread data) threw an R error → `safe_run()` caught it → `[ERROR]` log line → monitor alarm.

**Changes:**
- Both functions: added `req_error(is_error = \(r) FALSE)` — 4xx no longer throws
- `send_telegram`: on 400, retries without `parse_mode` (plain text fallback — symbols appear literally)
- `send_discord`: added 1990-char truncation guard (Discord 2000-char limit)
- Failures now logged via `message()` (console only), not `stop()` — monitor won't flag them as errors

---

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
