# scripts/wnba_settle.R — Fetch completed WNBA game scores → game_outcomes
# ─────────────────────────────────────────────────────────────────────────────
# Called from run_pipeline.R at the 9 AM open window.
# Queries the Odds API scores endpoint (same game_id format as the lines table)
# and writes home_score, away_score, actual_total, actual_spread to
# game_outcomes so settle_wnba_bets() in bet_router can determine W/L/PUSH.
#
# Idempotent: INSERT OR IGNORE on game_id PRIMARY KEY.
# Uses the shared key_state + odds_request() from odds_ingest.R.
# ─────────────────────────────────────────────────────────────────────────────

library(DBI)
library(RSQLite)

SCORES_DAYS_BACK <- 3L   # fetch up to 3 days of completed results per run

# ── Main entry point ──────────────────────────────────────────────────────────

wnba_settle_run <- function(con = NULL, days_from = SCORES_DAYS_BACK) {
  close_on_exit <- is.null(con)
  if (is.null(con)) {
    con <- dbConnect(RSQLite::SQLite(), DB_PATH)
    if (close_on_exit) on.exit(dbDisconnect(con), add = TRUE)
  }

  if (!exists("odds_request", mode = "function")) {
    message("[wnba_settle] odds_request() not available — source odds_ingest.R first")
    return(invisible(0L))
  }

  message(sprintf("[wnba_settle] Fetching completed WNBA scores (daysFrom=%d) ...",
                  days_from))

  resp <- tryCatch(
    odds_request("/sports/basketball_wnba/scores",
                 list(daysFrom = days_from, dateFormat = "iso")),
    error = function(e) {
      message("[wnba_settle] Odds API error: ", e$message)
      NULL
    }
  )
  if (is.null(resp)) return(invisible(0L))

  games <- tryCatch(
    resp_body_json(resp, simplifyVector = FALSE),
    error = function(e) {
      message("[wnba_settle] JSON parse error: ", e$message)
      list()
    }
  )

  n_written <- 0L

  for (g in games) {
    if (!isTRUE(g$completed)) next
    if (is.null(g$scores) || length(g$scores) == 0) next

    # Scores list: [{name: "Team A", score: "85"}, {name: "Team B", score: "92"}]
    score_map <- setNames(
      vapply(g$scores, function(s) as.integer(s$score), integer(1)),
      vapply(g$scores, function(s) s$name, character(1))
    )

    home_score <- score_map[[g$home_team]]
    away_score <- score_map[[g$away_team]]

    if (is.na(home_score) || is.na(away_score)) {
      message(sprintf("[wnba_settle] Skipping %s @ %s — score missing",
                      g$away_team, g$home_team))
      next
    }

    game_date <- tryCatch(
      as.character(as.Date(g$commence_time)),
      error = function(e) as.character(Sys.Date())
    )
    season <- as.integer(substr(game_date, 1, 4))

    rows_before <- dbGetQuery(con,
      "SELECT COUNT(*) AS n FROM game_outcomes WHERE game_id = ?",
      list(g$id))$n

    if (rows_before > 0L) next   # already written

    dbExecute(con, "
      INSERT OR IGNORE INTO game_outcomes
        (game_id, game_date, home_team_id, away_team_id,
         home_score, away_score, actual_total, actual_spread, season)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ", list(
      g$id,
      game_date,
      g$home_team,
      g$away_team,
      home_score,
      away_score,
      home_score + away_score,       # actual_total
      home_score - away_score,       # actual_spread (positive = home won)
      season
    ))

    n_written <- n_written + 1L
    message(sprintf("[wnba_settle] %s @ %s: %d–%d (total=%d, spread=%+d)  [%s]",
                    g$away_team, g$home_team,
                    away_score, home_score,
                    home_score + away_score,
                    home_score - away_score,
                    game_date))
  }

  message(sprintf("[wnba_settle] Done — %d new result(s) written to game_outcomes",
                  n_written))
  invisible(n_written)
}
