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
wehoop player box scores ──→ player_box_scores (DB cache)
                                    │
                                    ├─→ team_def_factors (opp allowed vs league avg)
                                    │
Odds API per-event props ──→ player_prop_lines (DB)
                                    │
        ┌───────────────────────────┴──────────────┐
        ▼                                           ▼
compute_prop_projection(player, stat)      book line for (player, stat)
        └───────────────────┬──────────────────────┘
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
Cache of wehoop's season box scores. `load_wnba_player_box()` always
returns the full season regardless of date args — there's no incremental
*fetch* to exploit, so this is not a `MAX(game_date)` watermark (that
approach silently stops backfilling past any gap in wehoop's own data —
the watermark advances past the hole and never revisits it). Instead:
every run, pull the full season from wehoop, `INSERT OR IGNORE` against
the `(game_id, player_name)` PK. Idempotent, no gap risk, no extra cost
over the watermark approach since wehoop's call cost is the same either
way.

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

No schema change to `open_bets` — reuse as-is. **`bet_side` must encode
player identity.** `open_bets`' natural-key unique index is
`(game_date, away_team, home_team, bet_side, pipeline)` — no player
column, and it's a shared cross-sport table (`bet_router`), so migrating
its index has higher blast radius than fixing this on the WNBA side. Two
players' props in the same game with the same stat/side would otherwise
collide on that index and silently drop one. Fix: `bet_side` = e.g.
`"PTS|OVER|Sabrina Ionescu"` (`sprintf("%s|%s|%s", toupper(stat),
toupper(side), player_name)`) — `|` as delimiter, not `_`, since it can't
appear in a player name at all (unlike `_`, which is merely unlikely).
Parsed back out at settlement time with a plain
`strsplit(bet_side, "|", fixed=TRUE)[[1]]` → `stat/side/player_name` by
position, no reassembly logic needed. This disambiguates without touching
the shared table's schema.

## Projection formula

For player *p*, stat *s* ∈ {pts, reb, ast, pra}, facing opponent *o*:

```
baseline_mean, baseline_sd = mean/sd(player's last 10 games' stat s)
  fallback: season-to-date if fewer than 10 games played
  PRA computed as (pts+reb+ast) per game before averaging, not as a sum of separate averages

def_factor = team_def_factors[o, s].factor, clamped [0.85, 1.15]
  factor = allowed_avg / league_avg
  MIN_GAMES_FOR_DEF_FACTOR = 5 — below this many games played by the
    opponent this season, factor = 1.0 passthrough (clamp alone doesn't
    stop a 3-game sample from sitting structurally at the clamp boundary,
    especially for expansion teams / early season)

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
- `sync_player_box_scores(con)` — full-season wehoop pull, `INSERT OR
  IGNORE` on `(game_id, player_name)`
- `compute_team_def_factors(con)` — daily refresh; allowed stats grouped
  by each row's `opponent` column, not `team` (a team's defense factor is
  what opposing players scored against them, not what their own players
  scored — easy to invert by accident). The `GROUP BY opponent` line in
  the actual implementation must carry an inline comment stating this
  explicitly (e.g. `# defense factor: stat opponents scored AGAINST this
  team`) — `opponent` reads ambiguously enough that a future edit could
  "fix" it to `team` without realizing that inverts the whole factor.
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

**Quota risk — hard gate, not a build-time check.** This pool of 10 Odds
API keys is shared with `mlb_NRFI_YRFI` (confirmed in that project's
`CLAUDE.md`), which just had an 11-day silent dead-key outage this same
month from insufficient headroom monitoring — discovering the pool is
exhausted is worse than any gap in prop coverage. Per-event prop calls (4
markets × N games × 2 cadences/day) add real, recurring load on top of
what MLB already draws.

**Do not enable live prop fetching until:**
- Every prop-fetching call logs `x-requests-remaining` (the header Odds
  API already returns) per key, per run — not a one-time manual check.
- An alert fires (same Telegram/Discord channel as the existing MLB
  dead-key alert) when any key's remaining count drops below a defined
  floor (e.g. 500) — mirroring the dead-key detection pattern
  `mlb_NRFI_YRFI/scripts/engine.R` already has for 401/403s, extended to
  cover "still alive but running low," which that existing check doesn't
  catch.

This is a prerequisite for turning alerts on, not a nice-to-have —
build and dry-run everything else first, but the live-fire gate stays
closed until this logging/alerting exists.

## Settlement

Extend `scripts/wnba_settle.R`: actual stat line comes from
`player_box_scores` (synced post-game) instead of `game_outcomes`. Grade
Over/Under directly against the real box score row for `(game_id,
player_name, stat)`. `player_box_scores` has no `pra` column — PRA bets
grade against `pts + reb + ast` computed from the same row at settlement
time, same as the projection formula does at prediction time.

**Timing dependency:** wehoop typically lags 15–30 min behind final
whistle before a game's box score is queryable. Late West Coast tips can
end after the pipeline's last run of the day, so that night's settlement
pass may find no box score yet — not an error, just not-ready-yet. Prop
settlement must be safely retriable: same-night run finds nothing → skip
silently → next morning's existing settlement step (already runs daily,
same as the totals/spreads settle) picks up any props still `status='OPEN'`
with a game_date in the past and grades them then. No new scheduled task
needed, just don't treat "no box score found yet" as a terminal failure.

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
