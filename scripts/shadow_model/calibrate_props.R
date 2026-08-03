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
# with a stricter window guard: requires a FULL ROLLING_WINDOW_GAMES-game
# prior history before returning a projection (vs the live function which
# will happily project with as few as 2 games). This deliberate strengthening
# prevents immature windows from polluting the residual calculation with
# noise unrelated to genuine model bias. Consequence: compute_prop_sd_residuals()
# will only draw from player-games with a full 10-game history; players with
# fewer prior games are silently excluded from the calibration population,
# even though the live model does project for them. Also restricted to games
# strictly before as_of_date (no cutoff in live function, which would leak
# future games into the replay). Kept as a private, calibration-only helper
# so the live function stays untouched.
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

# Simple "g1"-style sample skewness (third standardized moment): population
# third-moment numerator over sample SD cubed. Matches the standard, widely
# used definition (e.g. moments::skewness()'s default). Returns NA for
# fewer than 3 finite values or when SD is 0/NA (a constant residual has
# undefined skewness, not zero).
.sample_skewness <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n < 3) return(NA_real_)
  m <- mean(x)
  s <- sd(x)
  if (is.na(s) || s == 0) return(NA_real_)
  (sum((x - m)^3) / n) / s^3
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
      skewness      = .sample_skewness(residual),
      .groups       = "drop"
    )
}

# ── Calibration ───────────────────────────────────────────────────────────────

#' Guardrailed upsert of wnba_prop_sd_scale_{pts,reb,ast,pra} to model_config.
calibrate_prop_sd <- function(con, min_n = MIN_N_APPLY_PROP, max_delta = MAX_SD_SCALE_DELTA) {
  residuals <- compute_prop_sd_residuals(con)
  if (nrow(residuals) == 0) {
    message("[calibrate] prop_sd: no player_box_scores rows yet")
    return(invisible(FALSE))
  }

  applied <- FALSE
  for (stat in c("pts", "reb", "ast", "pra")) {
    row <- filter(residuals, stat == !!stat)
    if (nrow(row) == 0) next

    param   <- sprintf("wnba_prop_sd_scale_%s", stat)
    default <- 1.0

    if (row$n[1] < min_n) {
      message(sprintf("[calibrate] prop_sd/%s: n=%d < min_n=%d -- skipping",
                      stat, row$n[1], min_n))
      next
    }

    current <- tryCatch({
      v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?", list(param))$value[1]
      if (is.null(v) || is.na(v)) default else v
    }, error = \(e) default)

    new_scale <- row$empirical_sd[1] / row$mean_raw_sd[1]
    delta     <- new_scale - current
    if (abs(delta) > max_delta) {
      new_scale <- current + sign(delta) * max_delta
      message(sprintf("[calibrate] prop_sd/%s: capping delta to %.2f -> %.3f",
                      stat, max_delta, new_scale))
    }

    .set_config_param(
      con, param, new_scale,
      n_games = row$n[1],
      notes = sprintf("empirical scale = empirical_sd/raw_window_sd, mean_residual=%.2f (bias check)",
                      row$mean_residual[1])
    )
    applied <- TRUE
  }
  invisible(applied)
}

#' Morning orchestrator -- called from run_pipeline.R.
calibrate_prop_sd_run <- function(con) {
  calibrate_prop_sd(con)
}

MIN_N_APPLY_PROP_SKEW <- 500L
MAX_SKEW_DELTA        <- 0.15
SKEW_CLAMP            <- c(-0.75, 0.75)

#' Guardrailed upsert of wnba_prop_skew_{pts,reb,ast,pra} to model_config.
calibrate_prop_skew <- function(con, min_n = MIN_N_APPLY_PROP_SKEW, max_delta = MAX_SKEW_DELTA) {
  residuals <- compute_prop_sd_residuals(con)
  if (nrow(residuals) == 0) {
    message("[calibrate] prop_skew: no player_box_scores rows yet")
    return(invisible(FALSE))
  }

  applied <- FALSE
  for (stat in c("pts", "reb", "ast", "pra")) {
    row <- filter(residuals, stat == !!stat)
    if (nrow(row) == 0 || is.na(row$skewness[1])) next

    param   <- sprintf("wnba_prop_skew_%s", stat)
    default <- 0.0

    if (row$n[1] < min_n) {
      message(sprintf("[calibrate] prop_skew/%s: n=%d < min_n=%d -- defaulting to 0.0 (symmetric normal)",
                      stat, row$n[1], min_n))
      .set_config_param(
        con, param, default,
        n_games = row$n[1],
        notes = "insufficient n, defaulted to 0.0"
      )
      next
    }

    current <- tryCatch({
      v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?", list(param))$value[1]
      if (is.null(v) || is.na(v)) default else v
    }, error = \(e) default)

    new_skew <- row$skewness[1]
    delta    <- new_skew - current
    if (abs(delta) > max_delta) {
      new_skew <- current + sign(delta) * max_delta
      message(sprintf("[calibrate] prop_skew/%s: capping delta to %.2f -> %.3f",
                      stat, max_delta, new_skew))
    }
    new_skew <- max(SKEW_CLAMP[1], min(SKEW_CLAMP[2], new_skew))

    .set_config_param(
      con, param, new_skew,
      n_games = row$n[1],
      notes = sprintf("empirical residual skewness, clamped to [%.1f, %.1f]",
                      SKEW_CLAMP[1], SKEW_CLAMP[2])
    )
    applied <- TRUE
  }
  invisible(applied)
}

#' Morning orchestrator -- called from run_pipeline.R.
calibrate_prop_skew_run <- function(con) {
  calibrate_prop_skew(con)
}
