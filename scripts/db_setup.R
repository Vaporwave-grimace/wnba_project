# scripts/db_setup.R
# Initializes the WNBA pipeline SQLite database.
# Run this once before any ingestion scripts.
# Safe to re-run — all tables use CREATE IF NOT EXISTS.

library(DBI)
library(RSQLite)

DB_PATH <- here::here("data", "wnba_pipeline.sqlite")

init_db <- function(path = DB_PATH) {
  dir.create(dirname(path), showWarnings = FALSE, recursive = TRUE)
  con <- dbConnect(RSQLite::SQLite(), path)
  on.exit(dbDisconnect(con))

  # ── Market tables ────────────────────────────────────────────────────────────

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
      PRIMARY KEY (game_id, snapshot_type, bookmaker, market, outcome_name)
    )
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

  # Idempotent migration: add steam_direction to clv_log for directional CLV computation
  clv_cols <- dbListFields(con, "clv_log")
  if (!"steam_direction" %in% clv_cols) {
    dbExecute(con, "ALTER TABLE clv_log ADD COLUMN steam_direction TEXT")
    message("[db_setup] Migrated clv_log: added steam_direction column")
  }

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

  message("Database initialized at: ", path)
  invisible(path)
}

# Run directly to initialize
if (!interactive()) {
  init_db()
}
