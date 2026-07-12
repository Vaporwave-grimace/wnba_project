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
