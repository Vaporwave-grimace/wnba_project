# scripts/shadow_model/calibrate_props.R
# Morning auto-calibration for the WNBA player-prop SD. Mirrors
# calibrate_mispricing.R's calibrate_wnba_sd() pattern, adapted for props:
# unlike totals/spreads (a single static SD), props already have a live
# per-player rolling SD that carries real signal, so this calibrates a
# *scale factor* on top of it rather than replacing it outright.
#
# Workflow:
#   1. compute_prop_sd_residuals() — causal retroactive replay against
#      player_box_scores, per-stat empirical residual SD + mean bias check
#   2. calibrate_prop_sd()         — guardrailed upsert of the scale to model_config
#   3. calibrate_prop_sd_run()     — morning orchestrator (called from run_pipeline.R)

library(dplyr)
library(DBI)
library(RSQLite)
library(here)

source(here("scripts", "shadow_model", "player_props.R"))
source(here("scripts", "shadow_model", "calibrate_mispricing.R"))   # .set_config_param()

MIN_N_APPLY_PROP    <- 100L
MAX_SD_SCALE_DELTA  <- 0.25

# ── Causal replay ─────────────────────────────────────────────────────────────

# Mirrors compute_prop_projection()'s exact mean/SD/def-factor math, but
# restricted to games strictly before as_of_date -- player_props.R's own
# compute_prop_projection() has no cutoff param and always queries full
# history, which would leak future games into a historical replay. Kept
# as a private, calibration-only helper so the live function stays untouched.
.compute_prop_projection_asof <- function(player_name, stat, opponent, con, season, as_of_date) {
  stat <- tolower(stat)
  games <- dbGetQuery(con, "
    SELECT game_date, pts, reb, ast
    FROM player_box_scores
    WHERE player_name = ? AND game_date < ?
    ORDER BY game_date DESC
  ", list(player_name, as_of_date))

  if (nrow(games) < ROLLING_WINDOW_GAMES) return(NULL)

  stat_vals <- if (stat == "pra") games$pts + games$reb + games$ast else games[[stat]]
  n_avail     <- min(ROLLING_WINDOW_GAMES, length(stat_vals))
  window_vals <- stat_vals[seq_len(n_avail)]

  baseline_mean <- mean(window_vals, na.rm = TRUE)
  baseline_sd   <- sd(window_vals, na.rm = TRUE)
  if (is.na(baseline_sd) || baseline_sd == 0) return(NULL)

  def_factor <- .lookup_def_factor(opponent, stat, con, season)

  list(n_games = n_avail, baseline_mean = baseline_mean, baseline_sd = baseline_sd,
       def_factor = def_factor, projected_mean = baseline_mean * def_factor)
}

# ── Residuals ─────────────────────────────────────────────────────────────────

#' Per-stat empirical residual SD + bias check, from a causal retroactive
#' replay of every player_box_scores row across all history.
compute_prop_sd_residuals <- function(con) {
  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT game_date, player_name, opponent,
             CAST(strftime('%Y', game_date) AS INTEGER) AS season,
             pts, reb, ast
      FROM player_box_scores
      ORDER BY player_name, game_date
    ") |> as_tibble(),
    error = \(e) tibble()
  )
  if (nrow(rows) == 0) return(tibble())

  out <- list()
  for (stat in c("pts", "reb", "ast", "pra")) {
    for (i in seq_len(nrow(rows))) {
      row <- rows[i, ]
      actual <- if (stat == "pra") row$pts + row$reb + row$ast else row[[stat]]
      if (is.na(actual)) next

      proj <- tryCatch(
        .compute_prop_projection_asof(row$player_name, stat, row$opponent, con,
                                       row$season, row$game_date),
        error = \(e) NULL
      )
      if (is.null(proj)) next

      out[[length(out) + 1]] <- tibble(
        stat     = stat,
        residual = actual - proj$projected_mean,
        raw_sd   = proj$baseline_sd
      )
    }
  }
  if (length(out) == 0) return(tibble())

  bind_rows(out) |>
    group_by(stat) |>
    summarise(
      n             = n(),
      empirical_sd  = sd(residual, na.rm = TRUE),
      mean_residual = mean(residual, na.rm = TRUE),
      mean_raw_sd   = mean(raw_sd, na.rm = TRUE),
      .groups       = "drop"
    )
}
