# WNBA Player Props Model — Design

**Date:** 2026-07-12
**Status:** Approved, not yet implemented

## Goal

Extend the existing WNBA shadow model (currently totals/spreads only) to
cover player props: points, rebounds, assists, and points+rebounds+assists
(PRA). Output is live EV alerts through the existing bet pipeline, not a
research/backtest-only exercise.

## Confirmed data sources

- **Player box scores:** `wehoop::load_wnba_player_box()`, already used by
  `scripts/wnba_stats_api.R::fetch_game_log()` for the on/off net rating
  feature. Provides per-player per-game min/pts/reb/ast.
- **Player prop odds:** The Odds API, per-event endpoint
  (`/v4/sports/basketball_wnba/events/{id}/odds`), markets
  `player_points`, `player_rebounds`, `player_assists`,
  `player_points_rebounds_assists`. Confirmed live 2026-07-12 against
  today's slate — FanDuel, DraftKings, BetOnlineAG, BetRivers all posting
  props for multiple players per game.

## Architecture

```
wehoop player box scores ─┐
                           ├─→ player_box_scores (DB cache, incremental)
Odds API per-event props ─┘         │
        │                           ├─→ team_def_factors (opp allowed vs league avg)
        ▼                           │
player_prop_lines (DB)              ▼
        │                  compute_prop_projection(player, stat)
        └──────────┬───────────────┘
                    ▼
           detect_prop_edges()
                    │
                    ▼
      emit_wnba_bet_alert() [extended with market="prop"]
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
  #auto-bet-broadcast     open_bets (existing table)
                                │
                          settle via actual box score (wnba_settle.R)
```

No training/regression pipeline — projections are rolling average + SD,
matching the simplicity of the existing model's `pnorm()`-based approach
rather than mirroring `shadow_model/train.R`'s tidymodels path.

## DB schema (new tables, `wnba_pipeline.sqlite`)

### `player_box_scores`
Incremental cache of wehoop's season box scores — avoids refetching the
whole season every pipeline run; only pulls games newer than
`MAX(game_date)` already stored.

```sql
CREATE TABLE player_box_scores (
  game_id     TEXT,
  game_date   DATE,
  player_name TEXT,
  team        TEXT,
  opponent    TEXT,
  min         REAL,
  pts         INTEGER,
  reb         INTEGER,
  ast         INTEGER,
  PRIMARY KEY (game_id, player_name)
)
```

### `player_prop_lines`
Mirrors the shape of the existing `lines` table but keyed per-player
(the existing table's PK has no `player_name` column and is scoped to
team-level markets — a separate table is cleaner than overloading it).

```sql
CREATE TABLE player_prop_lines (
  game_id       TEXT,
  snapshot_type TEXT,
  sport_key     TEXT,
  commence_time TEXT,
  home_team     TEXT,
  away_team     TEXT,
  bookmaker     TEXT,
  market        TEXT,   -- player_points | player_rebounds | player_assists | player_points_rebounds_assists
  player_name   TEXT,
  outcome_name  TEXT,   -- Over | Under
  price         REAL,
  point         REAL,
  pulled_at     TEXT,
  PRIMARY KEY (game_id, snapshot_type, bookmaker, market, player_name, outcome_name)
)
```

### `team_def_factors`
Opponent-allowed rate per stat vs league average, refreshed daily from
`player_box_scores`.

```sql
CREATE TABLE team_def_factors (
  team        TEXT,
  stat        TEXT,   -- pts | reb | ast | pra
  allowed_avg REAL,
  league_avg  REAL,
  factor      REAL,
  season      INTEGER,
  updated_at  TEXT,
  PRIMARY KEY (team, stat, season)
)
```

No schema change to `open_bets` — reuse as-is.

## Projection formula

For player *p*, stat *s* ∈ {pts, reb, ast, pra}, facing opponent *o*:

```
baseline_mean, baseline_sd = mean/sd(player's last 10 games' stat s)
  fallback: season-to-date if fewer than 10 games played
  PRA computed as (pts+reb+ast) per game before averaging, not as a sum of separate averages

def_factor = team_def_factors[o, s].factor, clamped [0.85, 1.15]
  factor = allowed_avg / league_avg

projected_mean = baseline_mean * def_factor

model_prob = pnorm(book_line, mean = projected_mean, sd = baseline_sd,
                    lower.tail = (side == "under"))
```

Reuses the existing `pnorm()`-vs-line pattern from `bet_alerts.R` — no new
math primitive, just a new mean/SD source. Unlike `.WNBA_TOTAL_SD`
(hardcoded, admittedly uncalibrated), SD here is computed per-player from
real game-log variance.

**Guard:** players with `baseline_sd == 0` (e.g. exactly one game logged)
are skipped before `pnorm()` — a zero-SD input produces a degenerate
deterministic probability, the same failure class as the
`injury_adj_cap` incidents documented in `CLAUDE.md`.

## Alert integration

Extend `emit_wnba_bet_alert()` in `scripts/bet_alerts.R` with a third
`market = "prop"` branch (player/stat-aware `play` string, e.g.
`"Sabrina Ionescu Over 24.5 PTS"`), rather than building a parallel
emitter — keeps one code path, one `open_bets` writer, one dedup key.

Reused as-is, no new constants:
- `MODEL_PROB_CEILING <- 0.80`
- `KELLY_STAKE_CEILING <- 0.10`
- `MIN_EV_PCT` threshold
- `#auto-bet-broadcast` channel via `emit_broadcast()`

## Pipeline wiring & cadence

New file: `scripts/shadow_model/player_props.R`
- `sync_player_box_scores(con)` — incremental wehoop fetch
- `compute_team_def_factors(con)` — daily refresh
- `compute_prop_projection(player, stat, opponent, con)`
- `fetch_player_prop_odds(con)` — per-event Odds API call (one request per
  game, per MLB's existing 1st-inning-market precedent — bulk endpoint
  doesn't support player props)
- `detect_prop_edges(con)`

Cadence: fetch player prop lines at midday and near-tip only (reusing
existing `MIDDAY_HOUR`/near-tip pipeline steps), not on every steam-check
cycle — per-event calls cost more Odds API credits than the existing bulk
game-lines call, and props move most on late injury/rotation news rather
than needing continuous polling.

## Settlement

Extend `scripts/wnba_settle.R`: actual stat line comes from
`player_box_scores` (synced post-game) instead of `game_outcomes`. Grade
Over/Under directly against the real box score row for `(game_id,
player_name, stat)`.

## Explicitly deferred (out of scope for v1)

- Regression/ML projection model (`shadow_model/train.R`-style) — v1 is
  rolling average + SD only.
- Teammate injury/usage-bump adjustment — `injury_reports` exists and
  could feed this later, not in v1.
- Rest / back-to-back adjustment.
- Separate Discord channel or EV threshold for props — reuses the
  existing totals/spreads config.
- Explicit minutes/games-played eligibility filter — scope is implicitly
  "whoever has a posted line," since books already filter to rotation
  players.

## Verification plan

- After `sync_player_box_scores()`: confirm row count matches a spot-check
  against `wehoop::load_wnba_player_box()` directly for a known player.
- After `compute_team_def_factors()`: sanity-check factors cluster near
  1.0 with a few outliers (best/worst defenses), not degenerate.
- After `fetch_player_prop_odds()`: confirm rows land in
  `player_prop_lines` for today's slate, matching the live API check done
  during design (FanDuel/DraftKings/BetOnlineAG/BetRivers).
- Dry run `detect_prop_edges()` with alerts disabled, inspect a sample of
  computed `model_prob`/`ev_pct` values for sanity before enabling live
  alerts.
- Full live dry run (`send_alerts = FALSE`) before first live-money run.
