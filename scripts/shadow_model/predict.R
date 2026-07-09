# scripts/shadow_model/predict.R
# Steam-triggered inference layer
#
# Called by run_pipeline.R whenever steam is detected on a game.
# Builds features for the flagged game, runs both XGBoost models,
# and logs the simulated position to the clv_log table.
#
# CLV is computed retroactively by calibrate.R after games complete.

library(tidymodels)
library(dplyr)
library(lubridate)
library(DBI)
library(RSQLite)
library(here)

source(here("scripts", "shadow_model", "features.R"))

DB_PATH    <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"
MODELS_DIR <- here("models")

# ── Load models (cached in memory for the session) ────────────────────────────

.model_cache <- new.env(parent = emptyenv())

load_models <- function() {
  if (!exists("totals",  envir = .model_cache) ||
      !exists("spreads", envir = .model_cache)) {

    totals_path  <- file.path(MODELS_DIR, "totals_xgb.rds")
    spreads_path <- file.path(MODELS_DIR, "spreads_xgb.rds")

    if (!file.exists(totals_path) || !file.exists(spreads_path)) {
      stop("Models not found. Run scripts/shadow_model/train.R first.")
    }

    assign("totals",  readRDS(totals_path),  envir = .model_cache)
    assign("spreads", readRDS(spreads_path), envir = .model_cache)
    message("Models loaded from disk.")
  }

  list(
    totals  = get("totals",  envir = .model_cache),
    spreads = get("spreads", envir = .model_cache)
  )
}

# ── Predict for one game ──────────────────────────────────────────────────────

# Builds features for `game_id`, runs both models, and writes to clv_log.
# `market_line_at_bet`: the current consensus market line at time of steam detection.
# `steam_row`: the row from steam_movements that triggered this call.

run_prediction <- function(game_id, steam_row, con, team_box = NULL) {
  models <- tryCatch(load_models(), error = function(e) {
    message("Cannot predict — ", conditionMessage(e))
    return(NULL)
  })
  if (is.null(models)) return(invisible(NULL))

  # Build feature vector
  feats <- tryCatch(
    build_features(game_id, con, team_box),
    error = function(e) {
      message("Feature build failed for ", game_id, ": ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(feats)) return(invisible(NULL))

  now_str <- format(now("UTC"), "%Y-%m-%d %H:%M:%S")

  # Predict totals
  totals_feat <- feats |> filter(market == "totals")
  spreads_feat <- feats |> filter(market == "spreads")

  log_rows <- list()

  if (nrow(totals_feat) > 0) {
    pred_total <- predict(models$totals, new_data = totals_feat)$.pred

    # Market line at bet = current midday (or latest available) total
    mkt_total <- totals_feat$midday_line[1] %||% totals_feat$opener_line[1]

    log_rows[["totals"]] <- tibble(
      game_id           = game_id,
      market            = "totals",
      side              = if_else(steam_row$direction == "up", "over", "under"),
      model_line        = pred_total,
      market_line_at_bet= mkt_total,
      closing_line      = NA_real_,   # filled in by calibrate.R post-game
      clv               = NA_real_,   # filled in by calibrate.R
      logged_at         = now_str
    )
  }

  if (nrow(spreads_feat) > 0) {
    pred_spread <- predict(models$spreads, new_data = spreads_feat)$.pred

    mkt_spread <- spreads_feat$midday_line[1] %||% spreads_feat$opener_line[1]

    log_rows[["spreads"]] <- tibble(
      game_id           = game_id,
      market            = "spreads",
      side              = if_else(steam_row$direction == "up", "home", "away"),
      model_line        = pred_spread,
      market_line_at_bet= mkt_spread,
      closing_line      = NA_real_,
      clv               = NA_real_,
      logged_at         = now_str
    )
  }

  if (length(log_rows) == 0) return(invisible(NULL))

  combined <- bind_rows(log_rows)
  dbAppendTable(con, "clv_log", combined)

  tot_str <- if (!is.null(log_rows$totals))
    round(log_rows$totals$model_line, 1) else "—"
  spr_str <- if (!is.null(log_rows$spreads))
    round(log_rows$spreads$model_line, 1) else "—"
  message("CLV log updated for game ", game_id,
          " [totals pred: ", tot_str, " | spreads pred: ", spr_str, "]")

  invisible(combined)
}

# NOTE (2026-07-09): a `run_prediction_pregame()` function used to live here —
# schedule-triggered inference with trigger='pregame', for the pregame_model
# step in run_pipeline.R. That step was deleted in the mispricing refactor
# (commit b5eb4fd); removed the orphaned function too (its header comment
# falsely claimed it was still called from run_pipeline.R — confirmed via
# grep it wasn't, and clv_log has zero trigger='pregame' rows, ever). The
# steam-triggered path above (run_prediction()) is still live and unaffected.

# ── Post-game CLV update ──────────────────────────────────────────────────────

# After a game completes, update clv_log rows with the closing line and
# compute CLV = closing_line - market_line_at_bet.
# Call this from calibrate.R or run_pipeline.R after tip-off.

update_clv <- function(game_id, actual_total, actual_spread, con) {
  # Get closing lines
  closing <- dbGetQuery(con, "
    SELECT market, AVG(point) AS closing_line
    FROM lines
    WHERE game_id = ?
      AND snapshot_type = 'closing'
      AND market IN ('totals', 'spreads')
      AND bookmaker IN ('pinnacle','betonlineag','lowvig','fanduel','draftkings')
    GROUP BY market
  ", list(game_id)) |> as_tibble()

  for (mkt in c("totals", "spreads")) {
    cl <- closing |> filter(market == mkt) |> pull(closing_line)
    actual <- if (mkt == "totals") actual_total else actual_spread

    if (length(cl) == 0) next

    dbExecute(con, "
      UPDATE clv_log
      SET closing_line = ?,
          clv          = ? - market_line_at_bet
      WHERE game_id = ? AND market = ? AND clv IS NULL
    ", list(cl, cl, game_id, mkt))
  }

  message("CLV updated for game ", game_id)
}
