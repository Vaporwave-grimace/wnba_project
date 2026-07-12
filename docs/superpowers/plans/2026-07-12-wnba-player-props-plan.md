# WNBA Player Props Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the WNBA shadow model to project and alert on player props
(points, rebounds, assists, PRA), reusing the existing totals/spreads alert
pipeline (`open_bets`, `emit_wnba_bet_alert`, Kelly/EV ceilings) rather than
building a parallel system.

**Architecture:** Rolling 10-game average per player, adjusted by an
opponent-defense factor computed from cached wehoop box scores, compared via
`pnorm()` against live Odds API player-prop lines — same math pattern the
existing totals/spreads model already uses, no new ML/regression pipeline.
Settlement happens in `bet_router` (a separate repo), not `wnba_project`,
because that's where WNBA bet grading already lives.

**Tech Stack:** R, SQLite (`DBI`/`RSQLite`), `wehoop` (ESPN-backed box
scores), `httr2` (Odds API), `dplyr`/`purrr`/`tibble`.

## Global Constraints

- Spec source: `docs/superpowers/specs/2026-07-12-wnba-player-props-design.md`
  (3 review rounds, all fixes folded in — read it for full rationale on
  the `|`-delimited `bet_side` encoding, `MIN_GAMES_FOR_DEF_FACTOR=5`
  passthrough, `INSERT OR IGNORE`-not-watermark sync strategy, and the
  hard gate on live alert-firing until quota logging/alerting exists.)
- No schema change to `open_bets` (shared cross-sport table in
  `bet_router`) — disambiguation happens entirely via `bet_side` encoding.
- Reuse existing constants as-is: `MODEL_PROB_CEILING <- 0.80`,
  `KELLY_STAKE_CEILING <- 0.10`, `MIN_EV_PCT <- 3.0` (all in
  `wnba_project/scripts/bet_alerts.R`). No new EV threshold, no new
  Discord channel.
- `wehoop::load_wnba_player_box()` columns confirmed live (2026-07-12):
  `game_id`, `game_date`, `athlete_display_name`, `team_display_name`,
  `opponent_team_display_name`, `minutes` (character, needs
  `as.numeric()`), `points`, `rebounds`, `assists`. `team_display_name`
  matches the Odds API's `home_team`/`away_team` string format exactly
  (e.g. `"Las Vegas Aces"`) — use it, not `team_abbreviation`, so no
  team-name crosswalk table is needed anywhere in this build.
- Odds API player prop markets confirmed live (2026-07-12) under
  `regions="us"` alone — `player_points`, `player_rebounds`,
  `player_assists`, `player_points_rebounds_assists` all returned real
  FanDuel/DraftKings/BetOnlineAG/BetRivers prices for today's slate. No
  `eu` region needed for props (unlike totals/spreads, which need `eu`
  for Pinnacle).
- **Correction to the spec during planning:** the spec said "Extend
  `scripts/wnba_settle.R`" for settlement. That file only ever writes
  `game_outcomes` (final scores) — it has never graded bets. Real
  WNBA bet grading (writing `WON`/`LOST`/`profit_loss` to `open_bets`)
  lives in `bet_router/scripts/settler.R`'s `settle_wnba_bets()`, a
  different repo. Prop settlement must live there too, as a sibling
  function (Task 11), not in `wnba_project`.
- **Correction to the spec during planning:** `wehoop`/ESPN game IDs
  (numeric, e.g. `"401820329"`) and Odds API game IDs (hash, e.g.
  `"a11188d43bce66a788fd84b4a10dc19b"`) are two unrelated ID spaces with
  no crosswalk. Prop settlement joins `player_box_scores` to `open_bets`
  on `(player_name, game_date)`, not `game_id` — see Task 11 for why
  this is safe (a player plays at most one real-world game per day).

---

### Task 1: Schema — 4 new tables in `wnba_project`

**Files:**
- Modify: `wnba_project/scripts/db_setup.R:249` (insert new tables right
  after the existing `model_config` seed block, before the
  `gate_passed` migration block at line 282)
- Test: `wnba_project/scripts/shadow_model/test_player_props.R` (new file,
  grows across later tasks too)

**Interfaces:**
- Produces: tables `player_box_scores`, `player_prop_lines`,
  `team_def_factors`, `odds_api_quota_log`, all created inside the
  existing `init_db()` function so they're covered by the existing
  "safe to re-run" `CREATE TABLE IF NOT EXISTS` convention.

- [ ] **Step 1: Write the failing test**

Create `wnba_project/scripts/shadow_model/test_player_props.R`:

```r
# scripts/shadow_model/test_player_props.R
# Smoke tests for the WNBA player props model. Run with:
#   Rscript scripts/shadow_model/test_player_props.R
# Mirrors the check()/pass()/fail() style of scripts/test_pipeline.R —
# this project doesn't use testthat, tests run against a real (temp)
# SQLite file instead of mocks.

library(here)
library(DBI)
library(RSQLite)

pass <- function(label) cat(sprintf("  [PASS] %s\n", label))
fail <- function(label, reason) cat(sprintf("  [FAIL] %s -- %s\n", label, reason))
section <- function(label) cat(sprintf("\n-- %s --\n", label))

errors <- 0L
check <- function(label, expr) {
  tryCatch({
    result <- expr
    pass(label)
    invisible(result)
  }, error = function(e) {
    fail(label, conditionMessage(e))
    errors <<- errors + 1L
    invisible(NULL)
  })
}

source(here("scripts", "db_setup.R"))

# ── Task 1: schema ────────────────────────────────────────────────────────────
section("Task 1: player props schema")

tmp_db <- tempfile(fileext = ".sqlite")
init_db(tmp_db)
con <- open_wnba_db(tmp_db)

check("player_box_scores table exists", {
  stopifnot("player_box_scores" %in% dbListTables(con))
})
check("player_box_scores has expected columns", {
  cols <- dbListFields(con, "player_box_scores")
  expected <- c("game_id", "game_date", "player_name", "team", "opponent",
               "min", "pts", "reb", "ast")
  stopifnot(all(expected %in% cols))
})
check("player_prop_lines table exists", {
  stopifnot("player_prop_lines" %in% dbListTables(con))
})
check("team_def_factors table exists", {
  stopifnot("team_def_factors" %in% dbListTables(con))
})
check("odds_api_quota_log table exists", {
  stopifnot("odds_api_quota_log" %in% dbListTables(con))
})
check("init_db is safe to re-run (idempotent)", {
  init_db(tmp_db)   # must not error on second call
  TRUE
})

dbDisconnect(con)
file.remove(tmp_db)

cat(sprintf("\n%s -- %d error(s)\n",
           if (errors == 0) "ALL PASS" else "FAILURES", errors))
if (errors > 0) quit(status = 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL on all 5 new-table checks (tables don't exist yet).

- [ ] **Step 3: Add the 4 tables to `db_setup.R`**

In `wnba_project/scripts/db_setup.R`, insert immediately after the
`for (d in defaults) { ... }` loop (currently ending at line 280,
right before `# Idempotent migration: gate_passed column on clv_log`):

```r
  # ── Player props tables (added 2026-07-12) ────────────────────────────────

  # Cache of wehoop's season box scores. load_wnba_player_box() always
  # returns the full season regardless of date args -- there's no
  # incremental fetch to exploit, so sync_player_box_scores() re-pulls the
  # full season every run and relies on INSERT OR IGNORE against this PK
  # for idempotency, rather than a MAX(game_date) watermark (which would
  # silently stop backfilling past any gap in wehoop's own data).
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS player_box_scores (
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
  ")

  # Player prop odds snapshots -- mirrors `lines` but keyed per-player.
  # market: player_points | player_rebounds | player_assists |
  #         player_points_rebounds_assists
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS player_prop_lines (
      game_id       TEXT,
      snapshot_type TEXT,
      sport_key     TEXT,
      commence_time TEXT,
      home_team     TEXT,
      away_team     TEXT,
      bookmaker     TEXT,
      market        TEXT,
      player_name   TEXT,
      outcome_name  TEXT,
      price         REAL,
      point         REAL,
      pulled_at     TEXT,
      PRIMARY KEY (game_id, snapshot_type, bookmaker, market, player_name, outcome_name)
    )
  ")

  # Opponent-allowed rate per stat vs league average, refreshed daily by
  # compute_team_def_factors(). stat: pts | reb | ast | pra
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS team_def_factors (
      team        TEXT,
      stat        TEXT,
      allowed_avg REAL,
      league_avg  REAL,
      factor      REAL,
      season      INTEGER,
      updated_at  TEXT,
      PRIMARY KEY (team, stat, season)
    )
  ")

  # Odds API quota headroom log -- one row per key per check_quota_headroom()
  # call. Backs the hard gate on prop-fetching: alerted=1 marks that a low-
  # quota Telegram/Discord alert was already sent for that key today, so we
  # don't spam on every pipeline invocation.
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS odds_api_quota_log (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      checked_at  TEXT DEFAULT (datetime('now')),
      key_index   INTEGER,
      key_tail    TEXT,
      remaining   INTEGER,
      alerted     INTEGER DEFAULT 0
    )
  ")

```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/db_setup.R scripts/shadow_model/test_player_props.R
git commit -m "Add player props schema: player_box_scores, player_prop_lines, team_def_factors, odds_api_quota_log"
```

---

### Task 2: `sync_player_box_scores()`

**Files:**
- Create: `wnba_project/scripts/shadow_model/player_props.R`
- Test: `wnba_project/scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Consumes: `wehoop::load_wnba_player_box(seasons)`, `open_wnba_db()`
  from `db_setup.R`
- Produces: `sync_player_box_scores(con, season = as.integer(format(Sys.Date(), "%Y")))`
  → `invisible(n_written)` (integer count of newly inserted rows)

- [ ] **Step 1: Write the failing test**

Append to `test_player_props.R`:

```r
source(here("scripts", "shadow_model", "player_props.R"))

# ── Task 2: sync_player_box_scores ────────────────────────────────────────────
section("Task 2: sync_player_box_scores")

tmp_db2 <- tempfile(fileext = ".sqlite")
init_db(tmp_db2)
con2 <- open_wnba_db(tmp_db2)

check("sync_player_box_scores writes real 2025 rows", {
  n <- sync_player_box_scores(con2, season = 2025L)
  stopifnot(n > 0)
})
check("player_box_scores has plausible row count for a season", {
  n <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM player_box_scores")$n
  stopifnot(n > 1000)   # WNBA season is ~300 team-games x ~10 rostered players
})
check("re-running sync is idempotent (no duplicate rows)", {
  before <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM player_box_scores")$n
  sync_player_box_scores(con2, season = 2025L)
  after  <- dbGetQuery(con2, "SELECT COUNT(*) AS n FROM player_box_scores")$n
  stopifnot(before == after)
})
check("min column is numeric, not character", {
  row <- dbGetQuery(con2, "SELECT min FROM player_box_scores LIMIT 1")
  stopifnot(is.numeric(row$min))
})

dbDisconnect(con2)
file.remove(tmp_db2)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `player_props.R` doesn't exist yet (source error).

- [ ] **Step 3: Implement `sync_player_box_scores()`**

Create `wnba_project/scripts/shadow_model/player_props.R`:

```r
# scripts/shadow_model/player_props.R
# WNBA player props: rolling-average projections + opponent-defense
# adjustment, compared against live Odds API player-prop lines.
#
# Design doc: docs/superpowers/specs/2026-07-12-wnba-player-props-design.md
#
# Key functions:
#   sync_player_box_scores()  -- wehoop box score cache
#   compute_team_def_factors() -- opponent-allowed-stat factor
#   compute_prop_projection() -- rolling avg x def factor -> projected mean/sd
#   fetch_player_prop_odds()  -- Odds API per-event player prop pull
#   detect_prop_edges()       -- orchestrator, fires alerts via bet_alerts.R

library(wehoop)
library(dplyr)
library(DBI)
library(RSQLite)

ROLLING_WINDOW_GAMES     <- 10L
MIN_GAMES_FOR_DEF_FACTOR <- 5L
DEF_FACTOR_CLAMP         <- c(0.85, 1.15)

STAT_MARKET_MAP <- c(
  pts = "player_points",
  reb = "player_rebounds",
  ast = "player_assists",
  pra = "player_points_rebounds_assists"
)

# ── Box score sync ────────────────────────────────────────────────────────────

# Pulls the full season from wehoop every call (there's no incremental
# fetch available -- load_wnba_player_box() always returns the whole
# season) and INSERT OR IGNOREs against (game_id, player_name). Idempotent,
# no watermark, no gap risk.
sync_player_box_scores <- function(con, season = as.integer(format(Sys.Date(), "%Y"))) {
  message("[player_props] Syncing player box scores for season ", season)

  pb <- tryCatch(
    wehoop::load_wnba_player_box(seasons = season),
    error = function(e) {
      message("[player_props] wehoop fetch failed: ", e$message)
      NULL
    }
  )
  if (is.null(pb) || nrow(pb) == 0) return(invisible(0L))

  rows <- pb |>
    dplyr::transmute(
      game_id     = as.character(game_id),
      game_date   = as.character(game_date),
      player_name = athlete_display_name,
      team        = team_display_name,
      opponent    = opponent_team_display_name,
      min         = suppressWarnings(as.numeric(minutes)),
      pts         = as.integer(points),
      reb         = as.integer(rebounds),
      ast         = as.integer(assists)
    ) |>
    dplyr::filter(!is.na(player_name), !is.na(game_id))

  n_written <- 0L
  for (i in seq_len(nrow(rows))) {
    r <- rows[i, ]
    n_written <- n_written + dbExecute(con, "
      INSERT OR IGNORE INTO player_box_scores
        (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ", list(r$game_id, r$game_date, r$player_name, r$team, r$opponent,
            r$min, r$pts, r$reb, r$ast))
  }

  message(sprintf("[player_props] player_box_scores: %d new row(s) inserted (of %d fetched)",
                  n_written, nrow(rows)))
  invisible(n_written)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS` for the Task 2 section. This makes a real wehoop
call (network) — takes ~15-30s.

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/player_props.R scripts/shadow_model/test_player_props.R
git commit -m "Add sync_player_box_scores() -- wehoop box score cache"
```

---

### Task 3: `compute_team_def_factors()`

**Files:**
- Modify: `wnba_project/scripts/shadow_model/player_props.R`
- Test: `wnba_project/scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Consumes: `player_box_scores` table (written by Task 2)
- Produces: `compute_team_def_factors(con, season = as.integer(format(Sys.Date(), "%Y")))`
  → `invisible(n_written)`; writes `team_def_factors` rows.

- [ ] **Step 1: Write the failing test**

Append to `test_player_props.R`:

```r
# ── Task 3: compute_team_def_factors ──────────────────────────────────────────
section("Task 3: compute_team_def_factors")

tmp_db3 <- tempfile(fileext = ".sqlite")
init_db(tmp_db3)
con3 <- open_wnba_db(tmp_db3)

# Seed synthetic box scores: "Strong Defense" allows very little (should
# clamp to the floor), "Weak Defense" allows a lot (should clamp to the
# ceiling), "New Team" has only 3 games (should passthrough to 1.0).
seed_rows <- function(con, opponent, n_games, pts_allowed) {
  for (g in seq_len(n_games)) {
    dbExecute(con, "
      INSERT INTO player_box_scores
        (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ", list(paste0("g", opponent, g), "2026-06-01", paste0("p", opponent, g),
            "Some Team", opponent, 30, pts_allowed, 5, 3))
  }
}
seed_rows(con3, "Strong Defense", 8, 5)    # allows very few points
seed_rows(con3, "Weak Defense",   8, 40)   # allows a lot of points
seed_rows(con3, "New Team",       3, 5)    # below MIN_GAMES_FOR_DEF_FACTOR

check("compute_team_def_factors writes rows for all 3 synthetic teams", {
  compute_team_def_factors(con3, season = 2026L)
  n <- dbGetQuery(con3, "SELECT COUNT(DISTINCT team) AS n FROM team_def_factors")$n
  stopifnot(n == 3)
})
check("Strong Defense clamps to the floor (0.85)", {
  f <- dbGetQuery(con3, "SELECT factor FROM team_def_factors WHERE team = 'Strong Defense' AND stat = 'pts'")$factor
  stopifnot(abs(f - 0.85) < 1e-9)
})
check("Weak Defense clamps to the ceiling (1.15)", {
  f <- dbGetQuery(con3, "SELECT factor FROM team_def_factors WHERE team = 'Weak Defense' AND stat = 'pts'")$factor
  stopifnot(abs(f - 1.15) < 1e-9)
})
check("New Team (< MIN_GAMES_FOR_DEF_FACTOR) passes through at 1.0", {
  f <- dbGetQuery(con3, "SELECT factor FROM team_def_factors WHERE team = 'New Team' AND stat = 'pts'")$factor
  stopifnot(abs(f - 1.0) < 1e-9)
})
check("pra stat is written too", {
  n <- dbGetQuery(con3, "SELECT COUNT(*) AS n FROM team_def_factors WHERE stat = 'pra'")$n
  stopifnot(n == 3)
})

dbDisconnect(con3)
file.remove(tmp_db3)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `compute_team_def_factors` not defined.

- [ ] **Step 3: Implement `compute_team_def_factors()`**

Append to `wnba_project/scripts/shadow_model/player_props.R`:

```r
# ── Opponent defense factors ──────────────────────────────────────────────────

# Refreshes team_def_factors from player_box_scores. Grouped by each row's
# `opponent` column, NOT `team` -- a team's defense factor is what
# opposing players scored AGAINST them, not what their own players scored.
# ('opponent' reads ambiguous enough that a future edit could "fix" this
# to `team` without realizing that inverts the whole factor -- see the
# GROUP BY comment below.)
compute_team_def_factors <- function(con, season = as.integer(format(Sys.Date(), "%Y"))) {
  box <- dbGetQuery(con, "
    SELECT game_id, opponent, pts, reb, ast
    FROM player_box_scores
    WHERE game_date >= ? AND game_date <= ?
  ", list(paste0(season, "-01-01"), paste0(season, "-12-31")))

  if (nrow(box) == 0) {
    message("[player_props] No player_box_scores rows for season ", season)
    return(invisible(0L))
  }

  box$pra <- box$pts + box$reb + box$ast

  games_per_opp <- box |>
    dplyr::distinct(opponent, game_id) |>
    dplyr::count(opponent, name = "n_games")

  # defense factor: stat opponents scored AGAINST this team.
  agg <- box |>
    dplyr::group_by(opponent) |>          # GROUP BY opponent, not team -- see header comment
    dplyr::summarise(
      pts_allowed = mean(pts, na.rm = TRUE),
      reb_allowed = mean(reb, na.rm = TRUE),
      ast_allowed = mean(ast, na.rm = TRUE),
      pra_allowed = mean(pra, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::left_join(games_per_opp, by = "opponent")

  league_avg <- list(
    pts = mean(box$pts, na.rm = TRUE),
    reb = mean(box$reb, na.rm = TRUE),
    ast = mean(box$ast, na.rm = TRUE),
    pra = mean(box$pra, na.rm = TRUE)
  )

  n_written <- 0L
  for (i in seq_len(nrow(agg))) {
    row <- agg[i, ]
    for (stat in c("pts", "reb", "ast", "pra")) {
      allowed_avg <- row[[paste0(stat, "_allowed")]]
      la          <- league_avg[[stat]]

      factor <- if (row$n_games < MIN_GAMES_FOR_DEF_FACTOR ||
                    is.na(allowed_avg) || is.na(la) || la == 0) {
        1.0   # passthrough -- too few games to trust the sample
      } else {
        max(DEF_FACTOR_CLAMP[1], min(DEF_FACTOR_CLAMP[2], allowed_avg / la))
      }

      dbExecute(con, "
        INSERT OR REPLACE INTO team_def_factors
          (team, stat, allowed_avg, league_avg, factor, season, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
      ", list(row$opponent, stat, allowed_avg, la, factor, season))
      n_written <- n_written + 1L
    }
  }

  message(sprintf("[player_props] team_def_factors refreshed -- %d row(s) for season %d",
                  n_written, season))
  invisible(n_written)
}

.lookup_def_factor <- function(opponent, stat, con, season) {
  row <- dbGetQuery(con, "
    SELECT factor FROM team_def_factors WHERE team = ? AND stat = ? AND season = ?
  ", list(opponent, stat, season))
  if (nrow(row) == 0 || is.na(row$factor[1])) 1.0 else row$factor[1]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS` for Task 3 section.

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/player_props.R scripts/shadow_model/test_player_props.R
git commit -m "Add compute_team_def_factors() -- opponent-allowed-stat factor with min-games guard"
```

---

### Task 4: `compute_prop_projection()`

**Files:**
- Modify: `wnba_project/scripts/shadow_model/player_props.R`
- Test: `wnba_project/scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Consumes: `player_box_scores`, `.lookup_def_factor()` (Task 3)
- Produces: `compute_prop_projection(player_name, stat, opponent, con, season)`
  → `NULL` (zero-SD guard) or
  `list(player_name, stat, opponent, n_games, baseline_mean, baseline_sd, def_factor, projected_mean)`

- [ ] **Step 1: Write the failing test**

Append to `test_player_props.R`:

```r
# ── Task 4: compute_prop_projection ───────────────────────────────────────────
section("Task 4: compute_prop_projection")

tmp_db4 <- tempfile(fileext = ".sqlite")
init_db(tmp_db4)
con4 <- open_wnba_db(tmp_db4)

seed_player_games <- function(con, player, pts_vec) {
  for (i in seq_along(pts_vec)) {
    dbExecute(con, "
      INSERT INTO player_box_scores
        (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ", list(paste0("g", i), sprintf("2026-06-%02d", i), player,
            "Some Team", "Rival Team", 30, pts_vec[i], 4, 3))
  }
}

# 12 games so the 10-game rolling window actually trims the oldest 2.
seed_player_games(con4, "Steady Scorer", c(10,10,10,10,10,10,10,10,10,10,10,10))
seed_player_games(con4, "One Gamer", c(20))
dbExecute(con4, "
  INSERT INTO team_def_factors (team, stat, allowed_avg, league_avg, factor, season, updated_at)
  VALUES ('Rival Team', 'pts', 22, 20, 1.1, 2026, datetime('now'))
")

check("projection uses last 10 games, applies def factor", {
  p <- compute_prop_projection("Steady Scorer", "pts", "Rival Team", con4, season = 2026L)
  stopifnot(!is.null(p))
  stopifnot(p$n_games == 10)
  stopifnot(abs(p$baseline_mean - 10) < 1e-9)
  stopifnot(abs(p$projected_mean - 11) < 1e-9)   # 10 * 1.1
})
check("PRA computed as summed pts+reb+ast, not summed averages", {
  p <- compute_prop_projection("Steady Scorer", "pra", "Rival Team", con4, season = 2026L)
  stopifnot(!is.null(p))
  stopifnot(abs(p$baseline_mean - (10 + 4 + 3)) < 1e-9)
})
check("zero-SD guard skips single-game players", {
  p <- compute_prop_projection("One Gamer", "pts", "Rival Team", con4, season = 2026L)
  stopifnot(is.null(p))
})
check("unknown opponent falls back to def_factor 1.0", {
  p <- compute_prop_projection("Steady Scorer", "pts", "Nonexistent Team", con4, season = 2026L)
  stopifnot(!is.null(p))
  stopifnot(abs(p$def_factor - 1.0) < 1e-9)
})

dbDisconnect(con4)
file.remove(tmp_db4)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `compute_prop_projection` not defined.

- [ ] **Step 3: Implement `compute_prop_projection()`**

Append to `wnba_project/scripts/shadow_model/player_props.R`:

```r
# ── Projection ─────────────────────────────────────────────────────────────────

# stat in {"pts","reb","ast","pra"}. Returns NULL if the player has fewer
# than 2 games logged (baseline_sd would be 0/NA -- see the zero-SD guard
# below; a degenerate SD feeding pnorm() is the same failure class as the
# injury_adj_cap incidents documented in CLAUDE.md).
compute_prop_projection <- function(player_name, stat, opponent, con,
                                    season = as.integer(format(Sys.Date(), "%Y"))) {
  stat <- tolower(stat)
  if (!stat %in% names(STAT_MARKET_MAP)) {
    stop("compute_prop_projection: stat must be one of pts/reb/ast/pra, got: ", stat)
  }

  games <- dbGetQuery(con, "
    SELECT game_date, pts, reb, ast
    FROM player_box_scores
    WHERE player_name = ?
    ORDER BY game_date DESC
  ", list(player_name))

  if (nrow(games) == 0) {
    message("[player_props] No game log for player: ", player_name)
    return(NULL)
  }

  stat_vals <- if (stat == "pra") games$pts + games$reb + games$ast else games[[stat]]

  n_avail     <- min(ROLLING_WINDOW_GAMES, length(stat_vals))
  window_vals <- stat_vals[seq_len(n_avail)]   # already DESC-ordered = most recent first

  baseline_mean <- mean(window_vals, na.rm = TRUE)
  baseline_sd   <- sd(window_vals, na.rm = TRUE)

  if (is.na(baseline_sd) || baseline_sd == 0) {
    message(sprintf("[player_props] Zero/NA SD for %s (%s) -- skipping (n=%d)",
                    player_name, stat, n_avail))
    return(NULL)
  }

  def_factor <- .lookup_def_factor(opponent, stat, con, season)

  list(
    player_name    = player_name,
    stat           = stat,
    opponent       = opponent,
    n_games        = n_avail,
    baseline_mean  = baseline_mean,
    baseline_sd    = baseline_sd,
    def_factor     = def_factor,
    projected_mean = baseline_mean * def_factor
  )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS` for Task 4 section.

- [ ] **Step 5: Commit**

```bash
git add scripts/shadow_model/player_props.R scripts/shadow_model/test_player_props.R
git commit -m "Add compute_prop_projection() -- rolling avg x def factor with zero-SD guard"
```

---

### Task 5: Odds API quota headroom logging + alert (hard gate)

**Files:**
- Modify: `wnba_project/scripts/odds_ingest.R` (append near the end, after
  `run_collection()`)
- Test: `wnba_project/scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Consumes: `key_state$status()` (already exists in `odds_ingest.R`,
  tracks `x-requests-remaining` per key in memory), `send_telegram()` /
  `send_discord()` (from `injury_alert.R`, available at call time once
  `run_pipeline.R` has sourced everything)
- Produces: `check_quota_headroom(con, creds, channel_id, floor = ODDS_API_QUOTA_FLOOR)`
  → `invisible(status)` (the `key_state$status()` data frame); writes
  `odds_api_quota_log` rows and fires a low-quota alert once per key per day.

This is the plan's hard gate per the spec: `fetch_player_prop_odds()`
(Task 6) is not wired into `run_pipeline.R` until this exists and has been
verified to log + alert correctly.

- [ ] **Step 1: Write the failing test**

Append to `test_player_props.R`:

```r
source(here("scripts", "odds_ingest.R"))

# ── Task 5: check_quota_headroom ──────────────────────────────────────────────
section("Task 5: check_quota_headroom")

tmp_db5 <- tempfile(fileext = ".sqlite")
init_db(tmp_db5)
con5 <- open_wnba_db(tmp_db5)

fake_creds <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                   discord_bot_token = "x", discord_webhook_url = "x")

# key_state is a module-level singleton (local({}) closure) -- drive it
# directly via its own public update_remaining()/init() API rather than
# mocking, matching this project's live-only testing convention.
key_state$init(list(odds_api_keys = c("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                                      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
key_state$update_remaining(200)   # below the 500 floor -- should alert

check("check_quota_headroom logs a row per key", {
  # send_telegram/send_discord will attempt real network calls with fake
  # creds and fail -- that's fine, they're wrapped in tryCatch below and
  # the log-write must still succeed regardless.
  suppressMessages(check_quota_headroom(con5, fake_creds, channel_id = "0", floor = 500L))
  n <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log")$n
  stopifnot(n >= 1)
})
check("low-quota row is marked alerted", {
  n <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE alerted = 1")$n
  stopifnot(n >= 1)
})
check("second call same day does not double-alert the same key", {
  before <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE alerted = 1")$n
  suppressMessages(check_quota_headroom(con5, fake_creds, channel_id = "0", floor = 500L))
  after <- dbGetQuery(con5, "SELECT COUNT(*) AS n FROM odds_api_quota_log WHERE alerted = 1")$n
  # a new row is logged each call, but only the first should be flagged alerted=1
  stopifnot(after == before)
})

dbDisconnect(con5)
file.remove(tmp_db5)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `check_quota_headroom` not defined.

- [ ] **Step 3: Implement `check_quota_headroom()`**

Append to `wnba_project/scripts/odds_ingest.R`:

```r
# ── Quota headroom logging + alert ────────────────────────────────────────────
#
# This pool of 10 Odds API keys is shared with mlb_NRFI_YRFI (confirmed in
# that project's CLAUDE.md), which had an 11-day silent dead-key outage in
# July 2026 from insufficient headroom monitoring -- discovering the pool
# is exhausted is worse than any gap in prop coverage. Every prop-fetching
# call logs remaining quota per key; an alert fires once per key per day
# when any key drops below `floor`.

ODDS_API_QUOTA_FLOOR <- 500L

check_quota_headroom <- function(con, creds, channel_id, floor = ODDS_API_QUOTA_FLOOR) {
  status <- key_state$status()
  today  <- format(Sys.Date(), "%Y-%m-%d")

  for (i in seq_len(nrow(status))) {
    row <- status[i, ]
    if (is.na(row$remaining)) next

    dbExecute(con, "
      INSERT INTO odds_api_quota_log (key_index, key_tail, remaining)
      VALUES (?, ?, ?)
    ", list(row$index, row$key_tail, row$remaining))

    if (row$remaining < floor) {
      already_alerted <- dbGetQuery(con, "
        SELECT COUNT(*) AS n FROM odds_api_quota_log
        WHERE key_index = ? AND DATE(checked_at) = ? AND alerted = 1
      ", list(row$index, today))$n > 0

      if (!already_alerted) {
        msg <- sprintf(
          "⚠️ WNBA Odds API key #%d low (...%s) -- %d requests remaining (floor: %d). Shared pool with mlb_NRFI_YRFI.",
          row$index, row$key_tail, row$remaining, floor
        )
        tryCatch(send_telegram(msg, creds), error = function(e) NULL)
        tryCatch(send_discord(msg, creds, channel_id = channel_id), error = function(e) NULL)
        dbExecute(con, "
          UPDATE odds_api_quota_log SET alerted = 1
          WHERE id = (SELECT MAX(id) FROM odds_api_quota_log WHERE key_index = ?)
        ", list(row$index))
        message(sprintf("[quota] LOW QUOTA ALERT sent for key #%d (%d remaining)",
                        row$index, row$remaining))
      }
    }
  }

  invisible(status)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS` for Task 5 section.

- [ ] **Step 5: Commit**

```bash
git add scripts/odds_ingest.R scripts/shadow_model/test_player_props.R
git commit -m "Add check_quota_headroom() -- Odds API low-quota logging + once-per-day alert"
```

---

### Task 6: `fetch_player_prop_odds()`

**Files:**
- Modify: `wnba_project/scripts/shadow_model/player_props.R`

**Interfaces:**
- Consumes: `odds_request()`, `key_state` (`odds_ingest.R`), `SPORT`
  constant (`odds_ingest.R`)
- Produces: `fetch_player_prop_odds(con, game_ids, snapshot_type = "midday")`
  → `invisible(odds_df)` (the tibble written, possibly 0 rows); writes
  `player_prop_lines` rows.

This task makes real Odds API calls and costs real credits — test is a
live smoke test against today's actual slate, run once, not part of the
repeatable `test_player_props.R` suite (matching how `test_pipeline.R`
already treats the Odds API check as a one-off live call).

- [ ] **Step 1: Implement `fetch_player_prop_odds()`**

Append to `wnba_project/scripts/shadow_model/player_props.R`:

```r
# ── Player prop odds fetch ────────────────────────────────────────────────────

PROP_MARKETS <- "player_points,player_rebounds,player_assists,player_points_rebounds_assists"

# One Odds API request per game (bulk endpoint doesn't support player
# props, same constraint MLB's 1st-inning markets hit). `game_ids` is
# supplied by the caller (run_pipeline.R already knows today's slate /
# near-tip games) rather than re-derived here, to avoid duplicating that
# lookup logic.
fetch_player_prop_odds <- function(con, game_ids, snapshot_type = "midday") {
  if (length(game_ids) == 0) {
    message("[player_props] No game_ids supplied -- nothing to fetch.")
    return(invisible(tibble::tibble()))
  }

  pulled_at <- format(lubridate::now("UTC"), "%Y-%m-%d %H:%M:%S")
  all_rows  <- list()

  for (gid in game_ids) {
    resp <- tryCatch(
      odds_request(
        path   = paste0("sports/", SPORT, "/events/", gid, "/odds"),
        params = list(regions = "us", markets = PROP_MARKETS, oddsFormat = "american")
      ),
      error = function(e) {
        message("[player_props] Odds API error for ", gid, ": ", e$message)
        NULL
      }
    )
    if (is.null(resp)) next

    game <- tryCatch(httr2::resp_body_json(resp, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(game) || length(game$bookmakers) == 0) next

    rows <- purrr::map_dfr(game$bookmakers, function(book) {
      purrr::map_dfr(book$markets, function(mkt) {
        purrr::map_dfr(mkt$outcomes, function(o) {
          tibble::tibble(
            game_id       = game$id,
            snapshot_type = snapshot_type,
            sport_key     = game$sport_key %||% SPORT,
            commence_time = game$commence_time,
            home_team     = game$home_team,
            away_team     = game$away_team,
            bookmaker     = book$key,
            market        = mkt$key,
            player_name   = o$description %||% NA_character_,
            outcome_name  = o$name,
            price         = o$price %||% NA_real_,
            point         = o$point %||% NA_real_,
            pulled_at     = pulled_at
          )
        })
      })
    })
    all_rows[[gid]] <- rows
  }

  odds_df <- dplyr::bind_rows(all_rows)
  if (nrow(odds_df) == 0) {
    message("[player_props] No player prop rows returned for any game.")
    return(invisible(odds_df))
  }

  for (i in seq_len(nrow(odds_df))) {
    row <- odds_df[i, ]
    dbExecute(con, "
      INSERT OR REPLACE INTO player_prop_lines
        (game_id, snapshot_type, sport_key, commence_time, home_team, away_team,
         bookmaker, market, player_name, outcome_name, price, point, pulled_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    ", unname(as.list(row)))
  }

  message(sprintf("[player_props] Saved %d prop line row(s) across %d game(s) [%s].",
                  nrow(odds_df), length(unique(odds_df$game_id)), snapshot_type))
  invisible(odds_df)
}
```

- [ ] **Step 2: Live smoke test**

Run manually (consumes real Odds API credits):

```r
setwd("G:/My Drive/Scripting Projects/wnba_project/scripts")
source("db_setup.R"); source("odds_ingest.R"); source(here::here("scripts","shadow_model","player_props.R"))
creds <- load_credentials(); key_state$init(creds)
con <- open_wnba_db()
today_ids <- dbGetQuery(con, "SELECT DISTINCT game_id FROM games")$game_id
odds <- fetch_player_prop_odds(con, today_ids, snapshot_type = "midday")
nrow(odds)   # expect > 0 if any games have posted prop lines yet today
dbGetQuery(con, "SELECT COUNT(*) AS n FROM player_prop_lines")
dbDisconnect(con)
```

Expected: rows land in `player_prop_lines`; `nrow(odds) > 0` for at least
one game once books have posted (per the 2026-07-12 live check, this can
be 0 early in the day before lines post — not a failure).

- [ ] **Step 3: Commit**

```bash
git add scripts/shadow_model/player_props.R
git commit -m "Add fetch_player_prop_odds() -- per-event Odds API player prop pull"
```

---

### Task 7: `bet_side` encode/decode helpers

**Files:**
- Modify: `wnba_project/scripts/bet_alerts.R` (add near the top, after
  the existing `.prob_to_american()` helper)
- Test: `wnba_project/scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Produces: `.encode_prop_bet_side(stat, side, point, player_name)` →
  character string, e.g. `"PTS|OVER|24.5|Sabrina Ionescu"`.

The matching decoder (`.decode_prop_bet_side()`) is a separate,
independently-maintained implementation in `bet_router/scripts/settler.R`
(Task 11) — the two repos don't share code, matching how
`broadcast_schema.R` is already kept in sync as a copied file across
projects, not imported.

- [ ] **Step 1: Write the failing test**

Append to `test_player_props.R`:

```r
source(here("scripts", "bet_alerts.R"))

# ── Task 7: bet_side encoding ──────────────────────────────────────────────────
section("Task 7: .encode_prop_bet_side")

check("encodes stat/side/point/player into pipe-delimited string", {
  s <- .encode_prop_bet_side("pts", "over", 24.5, "Sabrina Ionescu")
  stopifnot(s == "PTS|OVER|24.5|Sabrina Ionescu")
})
check("handles player names with apostrophes", {
  s <- .encode_prop_bet_side("reb", "under", 8.5, "A'ja Wilson")
  stopifnot(s == "REB|UNDER|8.5|A'ja Wilson")
})
check("round-trips through a manual split", {
  s <- .encode_prop_bet_side("ast", "over", 5.5, "Julie Allemand")
  parts <- strsplit(s, "|", fixed = TRUE)[[1]]
  stopifnot(parts[1] == "AST", parts[2] == "OVER", parts[3] == "5.5",
           parts[4] == "Julie Allemand")
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `.encode_prop_bet_side` not defined. (Note:
`bet_alerts.R` requires `here::here()` to resolve from the project root —
run from `wnba_project/` or via the full test file, which already does
`library(here)` at the top.)

- [ ] **Step 3: Implement `.encode_prop_bet_side()`**

In `wnba_project/scripts/bet_alerts.R`, add immediately after the
existing `.prob_to_american()` function (currently ending at line 56):

```r
# Encodes a prop bet's identity into bet_side for open_bets' natural-key
# unique index (game_date, away_team, home_team, bet_side, pipeline).
# That index has no player column and open_bets is a shared cross-sport
# table (bet_router) -- migrating its index has higher blast radius than
# fixing this here. | is the delimiter, not _, because player names can
# contain spaces/apostrophes/hyphens but never a pipe character.
# Format: "STAT|SIDE|POINT|PLAYER_NAME", e.g. "PTS|OVER|24.5|Sabrina Ionescu"
# Point is included (not just stat/side/player) so a line move between
# fetches produces a distinct bet_side, same behavior totals/spreads
# already get for free by embedding the point directly in their play text.
# Keep in sync with .decode_prop_bet_side() in bet_router/scripts/settler.R.
.encode_prop_bet_side <- function(stat, side, point, player_name) {
  sprintf("%s|%s|%.1f|%s", toupper(stat), toupper(side), point, player_name)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS` for Task 7 section.

- [ ] **Step 5: Commit**

```bash
git add scripts/bet_alerts.R scripts/shadow_model/test_player_props.R
git commit -m "Add .encode_prop_bet_side() -- pipe-delimited player identity for open_bets dedup"
```

---

### Task 8: Extend `emit_wnba_bet_alert()` with `market = "prop"`

**Files:**
- Modify: `wnba_project/scripts/bet_alerts.R`

**Interfaces:**
- Consumes: `STAT_MARKET_MAP` (Task 2, `player_props.R` — source it from
  `bet_alerts.R` directly, matching the existing
  `source(here::here("scripts", "broadcast_schema.R"))` pattern at the
  top of the file), `.encode_prop_bet_side()` (Task 7)
- Produces: `emit_wnba_bet_alert(..., player_name = NULL, stat = NULL,
  sd = NULL, send_alerts = TRUE)` — new optional params, 100%
  backward-compatible with existing totals/spreads callers (all default
  to values that reproduce current behavior exactly). Now always returns
  `invisible(list(message, model_prob, ev_pct, kelly, fired))` instead of
  `invisible(msg)` — safe because no existing caller in `run_pipeline.R`
  captures or inspects the return value (checked: all calls go through
  `safe_run(emit_wnba_bet_alert(...), ...)` with no assignment).

- [ ] **Step 1: Source `player_props.R` from `bet_alerts.R`**

At the top of `wnba_project/scripts/bet_alerts.R`, change:

```r
source(here::here("scripts", "broadcast_schema.R"))
```

to:

```r
source(here::here("scripts", "broadcast_schema.R"))
source(here::here("scripts", "shadow_model", "player_props.R"))
```

- [ ] **Step 2: Add the `.best_prop_odds()` helper**

Immediately after the existing `.best_book_odds()` function (ends at
line 94), add:

```r
# Same book-preference logic as .best_book_odds(), against
# player_prop_lines instead of lines (different table, different schema
# -- player_name is part of the key).
.best_prop_odds <- function(game_id, market, player_name, outcome_name, con) {
  BOOK_PREF <- c("pinnacle", "betonlineag", "lowvig", "draftkings", "fanduel")
  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT bookmaker, price, point
      FROM player_prop_lines
      WHERE game_id      = ?
        AND market       = ?
        AND player_name  = ?
        AND outcome_name = ?
        AND snapshot_type = (
          SELECT snapshot_type FROM player_prop_lines
          WHERE game_id = ? AND player_name = ? AND market = ?
          ORDER BY pulled_at DESC LIMIT 1
        )
    ", list(game_id, market, player_name, outcome_name, game_id, player_name, market)),
    error = function(e) data.frame()
  )
  if (nrow(rows) == 0)
    return(list(book = NA_character_, odds = NA_integer_, point = NA_real_))
  rows$rank <- match(tolower(rows$bookmaker), BOOK_PREF, nomatch = 99L)
  rows <- rows[order(rows$rank), ]
  list(book  = rows$bookmaker[1],
       odds  = as.integer(round(rows$price[1])),
       point = rows$point[1])
}
```

- [ ] **Step 3: Extend the function signature and add the prop branch**

Change the signature (currently at line 115):

```r
emit_wnba_bet_alert <- function(game_id, market, side, model_line, mkt_line,
                                con, creds, steam_confirmed = FALSE) {
```

to:

```r
emit_wnba_bet_alert <- function(game_id, market, side, model_line, mkt_line,
                                con, creds, steam_confirmed = FALSE,
                                player_name = NULL, stat = NULL, sd = NULL,
                                send_alerts = TRUE) {
```

Immediately after the existing `spreads` branch's closing `}` (currently
line 153, right before `model_prob <- min(model_prob, MODEL_PROB_CEILING)`),
add a third branch — change:

```r
    model_prob <- if (side == "home")
      pnorm(-point, mean = model_line, sd = sd, lower.tail = FALSE)
    else
      pnorm(point,  mean = model_line, sd = sd, lower.tail = TRUE)
  }

  model_prob <- min(model_prob, MODEL_PROB_CEILING)
```

to:

```r
    model_prob <- if (side == "home")
      pnorm(-point, mean = model_line, sd = .WNBA_SPREAD_SD, lower.tail = FALSE)
    else
      pnorm(point,  mean = model_line, sd = .WNBA_SPREAD_SD, lower.tail = TRUE)

  } else if (market == "prop") {
    stat_market  <- STAT_MARKET_MAP[[stat]]
    outcome_name <- if (side == "over") "Over" else "Under"
    bo    <- .best_prop_odds(game_id, stat_market, player_name, outcome_name, con)
    point <- bo$point
    play  <- sprintf("%s %s %.1f %s", player_name,
                     if (side == "over") "Over" else "Under", point, toupper(stat))
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = sd, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = sd, lower.tail = TRUE)
  }

  model_prob <- min(model_prob, MODEL_PROB_CEILING)
```

(Note: the totals/spreads branches previously read a local `sd` variable
they assigned themselves — `sd <- .WNBA_TOTAL_SD` / `sd <- .WNBA_SPREAD_SD`
— which would have shadowed the new `sd` parameter in a confusing way.
The totals branch's `sd <- .WNBA_TOTAL_SD` line is unchanged; the spreads
branch above now references `.WNBA_SPREAD_SD` directly instead of via a
local `sd <-` reassignment, so the new `sd` parameter is never shadowed
and always means "caller-supplied SD, used only by the prop branch.")

Also update the totals branch a few lines earlier — change:

```r
    sd    <- .WNBA_TOTAL_SD
    model_prob <- if (side == "over")
```

to:

```r
    model_prob <- if (side == "over")
```

and its two `sd = sd` references to `sd = .WNBA_TOTAL_SD`:

```r
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = .WNBA_TOTAL_SD, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = .WNBA_TOTAL_SD, lower.tail = TRUE)
```

- [ ] **Step 4: Gate the odds/EV bail and the send/write section on `send_alerts`**

Replace the entire odds-check + EV-filter block (currently lines
157-174, immediately after `model_prob <- min(model_prob, MODEL_PROB_CEILING)`)
— this single replacement covers both the existing `is.na(bo$odds)`
check and the existing EV-calc/threshold check, there is no separate
edit elsewhere for either of them. Change:

```r
  if (is.na(bo$odds)) {
    message(sprintf("[bet_alerts/WNBA] No odds found for %s %s %s",
                    game_id, market, side))
    return(invisible(NULL))
  }

  # ── EV filter ────────────────────────────────────────────────────────────────

  implied_prob  <- .american_to_prob(bo$odds)
  ev_pct        <- (model_prob - implied_prob) / implied_prob * 100
  fair_odds     <- .prob_to_american(model_prob)
  kelly         <- min(.kelly_fraction(model_prob, bo$odds), KELLY_STAKE_CEILING)

  if (is.na(ev_pct) || ev_pct < MIN_EV_PCT) {
    message(sprintf("[bet_alerts/WNBA] %s %s %s — EV=%.1f%% below threshold (%.1f%%)",
                    game_id, market, side, ev_pct %||% 0, MIN_EV_PCT))
    return(invisible(NULL))
  }
```

to:

```r
  if (is.na(bo$odds)) {
    message(sprintf("[bet_alerts/WNBA] No odds found for %s %s %s",
                    game_id, market, side))
    return(invisible(list(message = NULL, model_prob = model_prob, ev_pct = NA_real_,
                          kelly = 0, fired = FALSE)))
  }

  # ── EV filter ────────────────────────────────────────────────────────────────

  implied_prob  <- .american_to_prob(bo$odds)
  ev_pct        <- (model_prob - implied_prob) / implied_prob * 100
  fair_odds     <- .prob_to_american(model_prob)
  kelly         <- min(.kelly_fraction(model_prob, bo$odds), KELLY_STAKE_CEILING)

  if (is.na(ev_pct) || ev_pct < MIN_EV_PCT) {
    message(sprintf("[bet_alerts/WNBA] %s %s %s — EV=%.1f%% below threshold (%.1f%%)",
                    game_id, market, side, ev_pct %||% 0, MIN_EV_PCT))
    return(invisible(list(message = NULL, model_prob = model_prob, ev_pct = ev_pct,
                          kelly = kelly, fired = FALSE)))
  }
```

(Only the two `return(invisible(NULL))` lines become
`return(invisible(list(...)))` — everything else in this block is
unchanged, kept here just to pin the exact surrounding context.)

At the very end of the function, wrap the send/write section — change:

```r
  send_telegram(msg, creds)
  send_discord(msg, creds, channel_id = .BROADCAST_CHANNEL)

  # Write directly to open_bets.db — no Discord round-trip needed
  tryCatch({
```

to:

```r
  bet_side_value <- if (market == "prop") .encode_prop_bet_side(stat, side, point, player_name) else play

  if (send_alerts) {
  send_telegram(msg, creds)
  send_discord(msg, creds, channel_id = .BROADCAST_CHANNEL)

  # Write directly to open_bets.db — no Discord round-trip needed
  tryCatch({
```

and change the `INSERT` list's `play,` line (the `bet_side` value) to
`bet_side_value,`, and close the new `if (send_alerts) { ... }` block
right before the final `invisible(msg)` — change:

```r
  write_wnba_bet_history(
    game_date      = game_date,
    away_team      = away_team,
    home_team      = home_team,
    bet_side       = play,
    kelly_fraction = kelly,
    bet_amount     = kelly * 100   # Kelly units (bankroll = 100)
  )

  invisible(msg)
}
```

to:

```r
  write_wnba_bet_history(
    game_date      = game_date,
    away_team      = away_team,
    home_team      = home_team,
    bet_side       = play,
    kelly_fraction = kelly,
    bet_amount     = kelly * 100   # Kelly units (bankroll = 100)
  )
  }  # end if (send_alerts)

  invisible(list(message = msg, model_prob = model_prob, ev_pct = ev_pct,
                 kelly = kelly, fired = send_alerts))
}
```

- [ ] **Step 5: Manual verification (no automated test — this reshapes an existing function used by live totals/spreads alerts)**

Run a dry pass against a known settled game to confirm totals/spreads
behavior is unchanged:

```r
setwd("G:/My Drive/Scripting Projects/wnba_project/scripts")
source("db_setup.R"); source("odds_ingest.R"); source("wnba_stats_api.R")
source("bet_alerts.R")
con <- open_wnba_db()
gid <- dbGetQuery(con, "SELECT game_id FROM lines LIMIT 1")$game_id[1]
r <- emit_wnba_bet_alert(gid, "totals", "over", model_line = 165, mkt_line = 160,
                         con = con, creds = load_credentials(), send_alerts = FALSE)
str(r)   # expect a list with $message, $model_prob, $ev_pct, $kelly, $fired == FALSE
dbDisconnect(con)
```

Expected: no error, `r$fired` is `FALSE`, no Discord/Telegram message
sent, no `open_bets` row written (confirm via
`dbGetQuery(open_bets_con, "SELECT COUNT(*) FROM open_bets")` before/after
is unchanged).

- [ ] **Step 6: Commit**

```bash
git add scripts/bet_alerts.R
git commit -m "Extend emit_wnba_bet_alert() with market='prop' branch + send_alerts toggle"
```

---

### Task 9: `detect_prop_edges()` orchestrator

**Files:**
- Modify: `wnba_project/scripts/shadow_model/player_props.R`

**Interfaces:**
- Consumes: `compute_prop_projection()` (Task 4), `emit_wnba_bet_alert()`
  (Task 8), `player_prop_lines` / `player_box_scores` tables
- Produces: `detect_prop_edges(con, creds, send_alerts = TRUE, season = as.integer(format(Sys.Date(), "%Y")))`
  → `invisible(n_fired)`

- [ ] **Step 1: Implement `detect_prop_edges()`**

Append to `wnba_project/scripts/shadow_model/player_props.R`:

```r
# ── Orchestrator ───────────────────────────────────────────────────────────────

# For every (game, player, stat) with a posted line in player_prop_lines,
# compute a projection and evaluate both Over and Under. emit_wnba_bet_alert()
# handles the EV filter and Kelly sizing -- this function's job is just to
# figure out each player's opponent and hand off model_line/sd.
detect_prop_edges <- function(con, creds, send_alerts = TRUE,
                              season = as.integer(format(Sys.Date(), "%Y"))) {
  candidates <- dbGetQuery(con, "
    SELECT DISTINCT ppl.game_id, ppl.player_name, ppl.market,
           ppl.home_team, ppl.away_team
    FROM player_prop_lines ppl
    WHERE ppl.snapshot_type = (
      SELECT snapshot_type FROM player_prop_lines ppl2
      WHERE ppl2.game_id = ppl.game_id
      ORDER BY pulled_at DESC LIMIT 1
    )
  ")

  if (nrow(candidates) == 0) {
    message("[player_props] No prop line candidates to evaluate.")
    return(invisible(0L))
  }

  n_fired <- 0L
  for (i in seq_len(nrow(candidates))) {
    row  <- candidates[i, ]
    stat <- names(STAT_MARKET_MAP)[STAT_MARKET_MAP == row$market]
    if (length(stat) == 0) next

    player_team <- dbGetQuery(con, "
      SELECT team FROM player_box_scores WHERE player_name = ?
      ORDER BY game_date DESC LIMIT 1
    ", list(row$player_name))$team[1]

    opponent <- if (!is.na(player_team) && identical(player_team, row$home_team)) {
      row$away_team
    } else if (!is.na(player_team) && identical(player_team, row$away_team)) {
      row$home_team
    } else {
      ""   # unknown team assignment -- .lookup_def_factor() passes through at 1.0
    }

    proj <- compute_prop_projection(row$player_name, stat, opponent, con, season)
    if (is.null(proj)) next

    for (side in c("over", "under")) {
      res <- tryCatch(
        emit_wnba_bet_alert(
          game_id     = row$game_id,
          market      = "prop",
          side        = side,
          model_line  = proj$projected_mean,
          mkt_line    = NA_real_,
          con         = con,
          creds       = creds,
          player_name = row$player_name,
          stat        = stat,
          sd          = proj$baseline_sd,
          send_alerts = send_alerts
        ),
        error = function(e) {
          message("[player_props] alert error for ", row$player_name, " ", stat, " ", side,
                  ": ", e$message)
          NULL
        }
      )
      if (!is.null(res) && isTRUE(res$fired)) n_fired <- n_fired + 1L
    }
  }

  message(sprintf("[player_props] detect_prop_edges complete -- %d alert(s) fired", n_fired))
  invisible(n_fired)
}
```

- [ ] **Step 2: Dry-run verification**

Per the spec's verification plan, dry-run before any live alert:

```r
setwd("G:/My Drive/Scripting Projects/wnba_project/scripts")
source("db_setup.R"); source("odds_ingest.R"); source("wnba_stats_api.R")
source("bet_alerts.R")   # sources player_props.R internally
con <- open_wnba_db()
creds <- load_credentials(); key_state$init(creds)
sync_player_box_scores(con)
compute_team_def_factors(con)
n <- detect_prop_edges(con, creds, send_alerts = FALSE)
n   # count of candidate edges that would have fired
dbDisconnect(con)
```

Expected: no errors; `n` reflects real computed edges without sending
anything or writing to `open_bets`.

- [ ] **Step 3: Commit**

```bash
git add scripts/shadow_model/player_props.R
git commit -m "Add detect_prop_edges() -- player props orchestrator"
```

---

### Task 10: Wire into `run_pipeline.R`

**Files:**
- Modify: `wnba_project/scripts/run_pipeline.R`

**Interfaces:**
- Consumes: `sync_player_box_scores()`, `compute_team_def_factors()`,
  `fetch_player_prop_odds()`, `check_quota_headroom()`,
  `detect_prop_edges()` (all prior tasks)

- [ ] **Step 1: Source `player_props.R`**

At the top of `run_pipeline.R`, after the existing
`source(here("scripts", "bet_alerts.R"))` line (line 38) — `bet_alerts.R`
already sources `player_props.R` internally (Task 8, Step 1), so no
separate `source()` line is needed here; this step is just confirming
that dependency instead of adding a redundant one.

- [ ] **Step 2: Add box score sync + def factor refresh to Step 0 (10 AM ET)**

In the existing `Step 0` block (currently lines 153-184, the
`if (hour_et() >= SETTLE_HOUR && !has_run_today("settle", con))` block),
add right after the `on/off net rating` loop (after line 171's closing
`}` for `if (!is.null(teams) ...)`, before `mark_run_today("settle", con)`):

```r
  log_info("MORNING — syncing player box scores + defense factors")
  safe_run(sync_player_box_scores(con, SEASON), "player box score sync")
  safe_run(compute_team_def_factors(con, SEASON), "team defense factor refresh")

```

- [ ] **Step 3: Add prop odds fetch + quota check + edge detection at midday and near-tip**

After the existing `Step 2: Midday odds snapshot` block (ends at line 230),
add a new step:

```r
# ── Step 2b: Player prop odds + edge detection (midday) ─────────────────────
#
# Gated by PROP_ALERTS_ENABLED -- flip to TRUE only after confirming
# check_quota_headroom() has logged at least one clean run (see Task 5 /
# design doc's hard gate: don't fire live prop alerts until quota
# logging+alerting is verified working, not just present in the code).
PROP_ALERTS_ENABLED <- FALSE

if (hour_et() >= MIDDAY_HOUR) {
  today_str      <- format(now_et(), "%Y-%m-%d")
  today_game_ids <- tryCatch(
    dbGetQuery(con, "SELECT DISTINCT game_id FROM games WHERE DATE(commence_time) = ? OR DATE(commence_time, '-4 hours') = ?",
              list(today_str, today_str))$game_id,
    error = \(e) character(0)
  )

  if (length(today_game_ids) > 0) {
    log_info("MIDDAY — fetching player prop odds for ", length(today_game_ids), " game(s)")
    safe_run(fetch_player_prop_odds(con, today_game_ids, snapshot_type = "midday"),
             "player prop odds fetch")
    safe_run(check_quota_headroom(con, creds, channel_id = STEAM_CHANNEL_ID),
             "prop odds quota check")
    safe_run(detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED),
             "player prop edge detection")
  }
}

# ── Step 3b-prop: near-tip prop odds refresh ─────────────────────────────────

if (length(near_tip_games) > 0) {
  log_info("PRE-TIP — refreshing player prop odds for ", length(near_tip_games), " game(s)")
  safe_run(fetch_player_prop_odds(con, near_tip_games, snapshot_type = "closing"),
           "near-tip player prop odds fetch")
  safe_run(check_quota_headroom(con, creds, channel_id = STEAM_CHANNEL_ID),
           "prop odds quota check (near-tip)")
  safe_run(detect_prop_edges(con, creds, send_alerts = PROP_ALERTS_ENABLED),
           "player prop edge detection (near-tip)")
}

```

(Placed after `Step 3: Closing snapshot`, which is where `near_tip_games`
is already computed — line 234 — so this new block can reuse it directly
rather than recomputing.)

- [ ] **Step 4: Live pipeline smoke run**

```powershell
cd "G:\My Drive\Scripting Projects\wnba_project"
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" --vanilla scripts\run_pipeline.R
```

Expected: pipeline completes without error; log shows the new
"syncing player box scores", "fetching player prop odds", and
"player prop edge detection" lines; `PROP_ALERTS_ENABLED = FALSE` means
no live Discord/Telegram prop alerts fire yet, but `player_prop_lines`
and `odds_api_quota_log` should show real rows.

- [ ] **Step 5: Commit**

```bash
git add scripts/run_pipeline.R
git commit -m "Wire player props into run_pipeline.R (alerts gated off via PROP_ALERTS_ENABLED)"
```

---

### Task 11: Prop settlement in `bet_router`

**Files:**
- Modify: `bet_router/scripts/settler.R`

**Interfaces:**
- Consumes: `WNBA_DB` constant (already defined in
  `bet_router/scripts/parsers.R`), `.compute_profit_loss()` (already
  defined in `settler.R`, reused as-is)
- Produces: `.decode_prop_bet_side(bet_side)` → `NULL` or
  `list(stat, side, point, player_name)`;
  `settle_wnba_prop_bets(con_router, game_date)` → `invisible(n_settled)`

This is a change to a different repo (`bet_router`) than the rest of this
plan (`wnba_project`) — confirm with the user before pushing, per the
"actions affecting shared systems" guidance; commit locally is fine.

- [ ] **Step 1: Add `.decode_prop_bet_side()` and `settle_wnba_prop_bets()`**

In `bet_router/scripts/settler.R`, immediately after the existing
`settle_wnba_bets()` function's closing `}` (ends at line 320, right
before the `# ── PGA stake lookup ──` section header), add:

```r
# Mirrors .encode_prop_bet_side() in wnba_project/scripts/bet_alerts.R.
# Keep in sync -- format: "STAT|SIDE|POINT|PLAYER_NAME"
.decode_prop_bet_side <- function(bet_side) {
  parts <- strsplit(bet_side, "|", fixed = TRUE)[[1]]
  if (length(parts) < 4) return(NULL)
  list(
    stat        = tolower(parts[1]),
    side        = tolower(parts[2]),
    point       = suppressWarnings(as.numeric(parts[3])),
    player_name = paste(parts[-(1:3)], collapse = "|")
  )
}

# ── WNBA player prop settlement ───────────────────────────────────────────────
# Grades against wnba_project's player_box_scores table directly (not
# game_outcomes -- that's team-level totals/spreads only). Joined on
# (player_name, game_date), NOT game_id -- wehoop/ESPN game_ids (numeric,
# e.g. "401820329") and Odds API game_ids (hash, e.g. "a11188d4...") are
# two unrelated ID spaces with no crosswalk. A player plays at most one
# real-world WNBA game per day, so (player_name, game_date) is a safe and
# sufficient join key.
#
# stake/odds are read directly from open_bets (populated at alert-fire
# time by bet_alerts.R) rather than re-derived from the BET_HISTORY CSV
# the way settle_wnba_bets() does above -- that CSV-lookup path matches on
# bet_side text, which for totals/spreads equals open_bets.bet_side, but
# for props open_bets.bet_side is the pipe-encoded natural key while the
# CSV stores the human-readable play string. They're different strings,
# so reusing .wnba_lookup_stake() here would silently fail to match.
settle_wnba_prop_bets <- function(con_router, game_date) {
  if (!file.exists(WNBA_DB)) {
    message("[settler/WNBA-prop] DB not found: ", WNBA_DB)
    return(invisible(0L))
  }
  con_wnba <- tryCatch(
    dbConnect(SQLite(), WNBA_DB),
    error = function(e) { message("[settler/WNBA-prop] Connect failed: ", e$message); NULL }
  )
  if (is.null(con_wnba)) return(invisible(0L))
  on.exit(dbDisconnect(con_wnba), add = TRUE)

  open <- dbGetQuery(con_router, "
    SELECT id, bet_side, game_date, odds, stake
    FROM   open_bets
    WHERE  sport  = 'WNBA'
      AND  status = 'OPEN'
      AND  game_date = ?
      AND  bet_side LIKE '%|%|%|%'
  ", list(as.character(game_date)))

  if (nrow(open) == 0) {
    message(sprintf("[settler/WNBA-prop] No open WNBA prop bets for %s", game_date))
    return(invisible(0L))
  }

  n_settled <- 0L

  dbWithTransaction(con_router, {
    for (i in seq_len(nrow(open))) {
      row    <- open[i, ]
      parsed <- .decode_prop_bet_side(row$bet_side)
      if (is.null(parsed)) next

      box <- dbGetQuery(con_wnba, "
        SELECT pts, reb, ast FROM player_box_scores
        WHERE player_name = ? AND game_date = ?
      ", list(parsed$player_name, row$game_date))

      if (nrow(box) == 0) next   # not yet synced -- retry on next settle pass

      actual <- switch(parsed$stat,
        pts = box$pts[1],
        reb = box$reb[1],
        ast = box$ast[1],
        pra = box$pts[1] + box$reb[1] + box$ast[1],
        NA_real_
      )
      if (is.na(actual) || is.na(parsed$point)) next

      outcome <- if      (parsed$side == "over"  && actual > parsed$point) "WON"
                 else if (parsed$side == "over"  && actual < parsed$point) "LOST"
                 else if (parsed$side == "under" && actual < parsed$point) "WON"
                 else if (parsed$side == "under" && actual > parsed$point) "LOST"
                 else "PUSH"

      profit_loss <- .compute_profit_loss(row$stake, row$odds, outcome)
      db_status   <- if (outcome == "PUSH") "VOID" else outcome

      dbExecute(con_router, "
        UPDATE open_bets
        SET    status = ?, result = ?, profit_loss = ?, settled_at = datetime('now')
        WHERE  id = ?
      ", list(db_status, outcome, profit_loss, row$id))

      n_settled <- n_settled + 1L
      pl_str <- if (!is.na(profit_loss)) sprintf("  $%+.2f", profit_loss) else ""
      message(sprintf("   [WNBA-prop] %s %s %s %.1f -> actual %.0f -> %s%s",
                      parsed$player_name, toupper(parsed$stat), parsed$side,
                      parsed$point, actual, outcome, pl_str))
    }
  })

  message(sprintf("[settler/WNBA-prop] Settled %d of %d open prop bet(s) for %s",
                  n_settled, nrow(open), game_date))
  invisible(n_settled)
}
```

- [ ] **Step 2: Wire into the nightly settle call site AND the past-date sweep**

Find the existing nightly call site (around line 1054):

```r
  settle_wnba_bets(con_router, settle_date)
  settle_pga_bets(con_router, settle_date)
```

Change to:

```r
  settle_wnba_bets(con_router, settle_date)
  settle_wnba_prop_bets(con_router, settle_date)
  settle_pga_bets(con_router, settle_date)
```

Also find `settle_open_bets_sweep()` (around line 1070) — this is the
existing mechanism that satisfies the spec's "next morning's existing
settlement step... picks up any props still `status='OPEN'` with a
`game_date` in the past" requirement (it re-sweeps every past-date open
bet, not just yesterday's), so prop settlement must be added here too or
same-night misses (Task 11's header comment on the timing dependency)
never get retried:

```r
  for (d in open_dates) {
    settle_mlb_bets(con_router, d)
    settle_wnba_bets(con_router, d)
    settle_pga_bets(con_router, d)
```

Change to:

```r
  for (d in open_dates) {
    settle_mlb_bets(con_router, d)
    settle_wnba_bets(con_router, d)
    settle_wnba_prop_bets(con_router, d)
    settle_pga_bets(con_router, d)
```

- [ ] **Step 3: Manual verification**

Since prop bets don't exist yet in `open_bets` (Task 10's
`PROP_ALERTS_ENABLED = FALSE` means none have fired live), verify with a
synthetic row:

```r
setwd("G:/My Drive/Scripting Projects/bet_router")
source("scripts/parsers.R"); source("scripts/settler.R")
library(DBI); library(RSQLite)
con_router <- dbConnect(SQLite(), "C:/Users/Mike/sports_data/open_bets.db")

# Confirm decode works
str(.decode_prop_bet_side("PTS|OVER|24.5|Sabrina Ionescu"))
stopifnot(.decode_prop_bet_side("garbage") |> is.null())

dbDisconnect(con_router)
```

Expected: `.decode_prop_bet_side()` returns the expected list; malformed
input returns `NULL` without erroring. Full end-to-end settlement
verification happens naturally once `PROP_ALERTS_ENABLED` is flipped on
and real prop bets accumulate.

- [ ] **Step 4: Commit (do not push without explicit confirmation)**

```bash
git add scripts/settler.R
git commit -m "Add settle_wnba_prop_bets() -- grades player props via player_box_scores"
```

---

## Post-plan: enabling live alerts

`PROP_ALERTS_ENABLED` in `run_pipeline.R` (Task 10) stays `FALSE` after
this plan completes. Flip it to `TRUE` only after:
1. At least one full day of dry-run pipeline invocations with no errors.
2. Confirming `odds_api_quota_log` shows healthy remaining-quota numbers
   across the shared key pool (no key near the 500 floor).
3. Manually reviewing a sample of `detect_prop_edges()`'s dry-run output
   (`send_alerts = FALSE`) for sane `model_prob`/`ev_pct` values.

This is a deliberate manual step, not automated by this plan — matches
the spec's hard-gate intent.
