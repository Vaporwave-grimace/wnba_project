# scripts/db_setup.R
# Initializes the WNBA pipeline SQLite database.
# Run this once before any ingestion scripts.
# Safe to re-run — all tables use CREATE IF NOT EXISTS.

library(DBI)
library(RSQLite)

DB_PATH <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"

open_wnba_db <- function(path = DB_PATH) {
  con <- dbConnect(RSQLite::SQLite(), path)
  dbExecute(con, "PRAGMA foreign_keys = ON")
  con
}

init_db <- function(path = DB_PATH) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  con <- open_wnba_db(path)
  on.exit(dbDisconnect(con))

  # ── Market tables ────────────────────────────────────────────────────────────

  # Game registry — one row per game_id; lines FKs into this
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS games (
      game_id        TEXT PRIMARY KEY,
      commence_time  TEXT,
      home_team      TEXT,
      away_team      TEXT
    )
  ")

  # Snapshot of opening and closing lines per game
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS lines (
      game_id        TEXT,
      snapshot_type  TEXT,    -- 'opener', 'midday', 'closing'
      sport_key      TEXT,
      commence_time  TEXT,
      home_team      TEXT,
      away_team      TEXT,
      bookmaker      TEXT,
      market         TEXT,    -- 'spreads', 'totals', 'h2h'
      outcome_name   TEXT,
      price          REAL,
      point          REAL,
      pulled_at      TEXT,
      PRIMARY KEY (game_id, snapshot_type, bookmaker, market, outcome_name),
      FOREIGN KEY (game_id) REFERENCES games(game_id)
    )
  ")

  # Backfill from existing lines data (idempotent — INSERT OR IGNORE)
  dbExecute(con, "
    INSERT OR IGNORE INTO games (game_id, commence_time, home_team, away_team)
    SELECT DISTINCT game_id, commence_time, home_team, away_team FROM lines
  ")

  # Steam movement log — rapid cross-book line shifts
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS steam_movements (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      game_id        TEXT,
      market         TEXT,
      outcome_name   TEXT,
      direction      TEXT,    -- 'up' or 'down'
      magnitude      REAL,    -- size of move in points
      books_moved    INTEGER, -- number of books that moved
      detected_at    TEXT
    )
  ")
  # Idempotent migration: add outcome_name if DB was created before this column existed
  existing_cols <- dbListFields(con, "steam_movements")
  if (!"outcome_name" %in% existing_cols) {
    dbExecute(con, "ALTER TABLE steam_movements ADD COLUMN outcome_name TEXT")
    message("[db_setup] Migrated steam_movements: added outcome_name column")
  }

  # Steam dedup log — one row per (game, market, outcome, direction) while unresolved.
  # Prevents re-alerting the same move on every 30-min poll cycle.
  # Resolved when closing snapshot fires for that game.
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS steam_log (
      id              INTEGER PRIMARY KEY,
      game_id         TEXT,
      market          TEXT,
      outcome_name    TEXT,
      direction       TEXT,
      magnitude       REAL,
      books_moved     INTEGER,
      first_detected  TEXT,
      last_seen       TEXT,
      alert_sent      INTEGER DEFAULT 0,
      resolved        INTEGER DEFAULT 0
    )
  ")
  dbExecute(con, "
    CREATE UNIQUE INDEX IF NOT EXISTS idx_steam_log_dedup
    ON steam_log (game_id, market, outcome_name, direction)
    WHERE resolved = 0
  ")

  # ── Roster / stats tables ─────────────────────────────────────────────────────

  # Season game log — one row per team per game
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS game_log (
      game_id        TEXT,
      game_date      TEXT,
      team_id        TEXT,
      team_name      TEXT,
      matchup        TEXT,
      wl             TEXT,
      season         TEXT,
      ingested_at    TEXT DEFAULT (datetime('now')),
      PRIMARY KEY (game_id, team_id)
    )
  ")

  # Raw play-by-play events
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS play_by_play (
      game_id        TEXT,
      eventnum       TEXT,
      period         TEXT,
      pctimestring   TEXT,
      homedescription TEXT,
      neutraldescription TEXT,
      visitordescription TEXT,
      score          TEXT,
      scoremargin    TEXT,
      ingested_at    TEXT DEFAULT (datetime('now')),
      PRIMARY KEY (game_id, eventnum)
    )
  ")

  # 5-man lineup efficiency snapshots
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS lineup_net_ratings (
      team_id        TEXT,
      team_name      TEXT,
      group_name     TEXT,
      net_rating     REAL,
      min            REAL,
      season         TEXT,
      pulled_at      TEXT DEFAULT (datetime('now'))
    )
  ")

  # On/off net rating delta log — one row per team per run
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS on_off_net_rating (
      team_id              TEXT,
      season               TEXT,
      rotation_player_6    TEXT,
      rotation_player_7    TEXT,
      net_rating_with      REAL,
      net_rating_without   REAL,
      delta                REAL,
      computed_at          TEXT DEFAULT (datetime('now'))
    )
  ")

  # ── Alert / injury tables ─────────────────────────────────────────────────────

  # Injury report log
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS injury_reports (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      player_name    TEXT,
      team           TEXT,
      status         TEXT,    -- 'Out', 'Questionable', 'Probable', 'GTD'
      reported_at    TEXT,
      source         TEXT,    -- 'ESPN', 'WNBA.com', etc.
      ingested_at    TEXT DEFAULT (datetime('now'))
    )
  ")

  # Injury discrepancy alerts — flagged when line moves before report
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS injury_discrepancies (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      game_id         TEXT,
      player_name     TEXT,
      injury_reported_at TEXT,
      line_moved_at   TEXT,
      line_delta      REAL,
      lag_minutes     REAL,   -- report_time - line_move_time (negative = line moved first)
      flagged_at      TEXT DEFAULT (datetime('now'))
    )
  ")

  # ── Outcomes table ────────────────────────────────────────────────────────────

  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS game_outcomes (
      game_id       TEXT PRIMARY KEY,
      game_date     TEXT,
      home_team_id  TEXT,
      away_team_id  TEXT,
      home_score    INTEGER,
      away_score    INTEGER,
      actual_total  REAL,
      actual_spread REAL,
      season        INTEGER,
      seeded_at     TEXT DEFAULT (datetime('now'))
    )
  ")

  # ── Shadow model tables ───────────────────────────────────────────────────────

  # CLV capture log — one row per simulated bet
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS clv_log (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      game_id        TEXT,
      market         TEXT,
      side           TEXT,
      model_line     REAL,    -- line at time of simulated bet
      closing_line   REAL,    -- final market price
      clv            REAL,    -- closing_line - model_line (positive = beat the close)
      logged_at      TEXT DEFAULT (datetime('now'))
    )
  ")

  # Idempotent migrations for clv_log
  clv_cols <- dbListFields(con, "clv_log")
  if (!"steam_direction" %in% clv_cols) {
    dbExecute(con, "ALTER TABLE clv_log ADD COLUMN steam_direction TEXT")
    message("[db_setup] Migrated clv_log: added steam_direction column")
  }
  if (!"market_line_at_bet" %in% clv_cols) {
    dbExecute(con, "ALTER TABLE clv_log ADD COLUMN market_line_at_bet REAL")
    message("[db_setup] Migrated clv_log: added market_line_at_bet column")
  }
  if (!"trigger" %in% clv_cols) {
    dbExecute(con, "ALTER TABLE clv_log ADD COLUMN trigger TEXT DEFAULT 'steam'")
    message("[db_setup] Migrated clv_log: added trigger column")
  }

  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS pipeline_runs (
      step      TEXT,
      run_date  TEXT,
      ran_at    TEXT DEFAULT (datetime('now')),
      PRIMARY KEY (step, run_date)
    )
  ")

  # Tunable model parameters — one row per param, auto-updated by calibration.
  # Mirrors the MLB model_config pattern so calibrate_mispricing.R can
  # read/write DEV_THRESHOLD and INJURY_IMPACT weights without code changes.
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS model_config (
      param       TEXT PRIMARY KEY,
      value       REAL NOT NULL,
      updated_at  TEXT DEFAULT (datetime('now')),
      n_games     INTEGER,
      brier_before REAL,
      brier_after  REAL,
      notes       TEXT
    )
  ")

  # Seed default params if table was just created (INSERT OR IGNORE = idempotent)
  defaults <- list(
    list("dev_threshold",       1.5,   "initial seed — Pinnacle deviation gate (pts)"),
    list("injury_adj_cap",      6.0,   "initial seed — per-side injury adj clamp (pts); prevents multi-player stacking from producing unrealistic total swings"),
    list("injury_impact_out",   -3.0,  "initial seed — Out player scoring impact"),
    list("injury_impact_doubtful", -2.0, "initial seed"),
    list("injury_impact_gtd",   -1.0,  "initial seed — GTD/Questionable impact"),
    list("steam_min_move",  0.5, "initial seed — matches STEAM_MIN_MOVE default in odds_ingest.R"),
    list("steam_min_books", 2,   "initial seed — matches STEAM_MIN_BOOKS default in odds_ingest.R")
  )
  for (d in defaults) {
    dbExecute(con,
      "INSERT OR IGNORE INTO model_config (param, value, notes) VALUES (?, ?, ?)",
      d)
  }

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

  # Idempotent migration: gate_passed column on clv_log
  # 1 = alert fired (passed steam/AN gate), 0 = detected but not alerted
  clv_cols <- dbListFields(con, "clv_log")
  if (!"gate_passed" %in% clv_cols) {
    dbExecute(con, "ALTER TABLE clv_log ADD COLUMN gate_passed INTEGER DEFAULT 0")
    message("[db_setup] Migrated clv_log: added gate_passed column")
  }

  message("Database initialized at: ", path)
  invisible(path)
}

# ── Pipeline state helpers ────────────────────────────────────────────────────

has_run_today <- function(step, con, date = format(Sys.Date(), "%Y-%m-%d")) {
  tryCatch(
    dbGetQuery(con, "SELECT COUNT(*) AS n FROM pipeline_runs WHERE step = ? AND run_date = ?",
               list(step, date))$n > 0,
    error = \(e) FALSE
  )
}

mark_run_today <- function(step, con, date = format(Sys.Date(), "%Y-%m-%d")) {
  tryCatch(
    dbExecute(con, "INSERT OR IGNORE INTO pipeline_runs (step, run_date) VALUES (?, ?)",
              list(step, date)),
    error = \(e) invisible(NULL)
  )
}

# Run directly to initialize
if (!interactive()) {
  init_db()
}
