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
  tryCatch({
    dbBegin(con)
    for (i in seq_len(nrow(rows))) {
      r <- rows[i, ]
      n_written <- n_written + dbExecute(con, "
        INSERT OR IGNORE INTO player_box_scores
          (game_id, game_date, player_name, team, opponent, min, pts, reb, ast)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ", list(r$game_id, r$game_date, r$player_name, r$team, r$opponent,
              r$min, r$pts, r$reb, r$ast))
    }
    dbCommit(con)
  }, error = function(e) {
    dbRollback(con)
    stop(e)
  })

  message(sprintf("[player_props] player_box_scores: %d new row(s) inserted (of %d fetched)",
                  n_written, nrow(rows)))
  invisible(n_written)
}
