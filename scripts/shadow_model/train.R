# scripts/shadow_model/train.R
# XGBoost model training for the WNBA shadow model
#
# Trains two separate tidymodels workflows:
#   - totals_fit:  predicts actual game total (home + away score)
#   - spreads_fit: predicts actual game spread (home margin)
#
# Training set is built from seeded game_outcomes + roster features.
# Market features (line movement, steam) are NA for historical games
# and imputed by the recipe — they gain weight as live pipeline data accumulates.
# Re-run weekly to refit on the expanding window.

library(tidymodels)
library(xgboost)
library(vip)
library(dplyr)
library(lubridate)
library(here)
library(DBI)
library(RSQLite)

DB_PATH    <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"
MODELS_DIR <- here("models")
dir.create(MODELS_DIR, showWarnings = FALSE)

# ── Build training set from seeded data ───────────────────────────────────────

build_historical_training_set <- function(con, team_box) {

  # Outcomes — one row per game with home/away IDs and actual scores
  outcomes <- dbGetQuery(con, "
    SELECT game_id, game_date, home_team_id, away_team_id,
           actual_total, actual_spread, season
    FROM game_outcomes
    WHERE actual_total IS NOT NULL
  ") |> as_tibble()

  message("  Outcomes loaded: ", nrow(outcomes), " games")

  # On/off deltas — most recent per team
  on_off <- dbGetQuery(con, "
    SELECT team_id, delta, computed_at
    FROM on_off_net_rating
  ") |>
    as_tibble() |>
    group_by(team_id) |>
    slice_max(computed_at, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(team_id, delta)

  # Rest days — days since previous game per team per game
  game_log <- dbGetQuery(con, "
    SELECT game_id, game_date, team_id FROM game_log
  ") |> as_tibble() |>
    mutate(game_date = as.Date(game_date))

  calc_rest <- function(outcomes_df, log_df) {
    map_dfr(seq_len(nrow(outcomes_df)), function(i) {
      row       <- outcomes_df[i, ]
      gdate     <- as.Date(row$game_date)

      rest_for  <- function(tid) {
        prev <- log_df |>
          filter(team_id == tid, game_date < gdate) |>
          arrange(desc(game_date)) |>
          slice(1)
        if (nrow(prev) == 0) return(NA_real_)
        as.numeric(gdate - prev$game_date)
      }

      tibble(
        game_id        = row$game_id,
        home_rest_days = rest_for(row$home_team_id),
        away_rest_days = rest_for(row$away_team_id)
      )
    })
  }

  message("  Computing rest days...")
  rest <- calc_rest(outcomes, game_log)

  # Pace — average pace per team from team box (season-level mean)
  pace <- team_box |>
    mutate(pace = as.numeric(field_goals_attempted) +
                  0.44 * as.numeric(free_throws_attempted) -
                  as.numeric(offensive_rebounds) +
                  as.numeric(turnovers)) |>
    group_by(team_id) |>
    summarise(avg_pace = mean(pace, na.rm = TRUE), .groups = "drop")

  # Normalise team IDs to character before joining
  on_off <- on_off |> mutate(team_id = as.character(team_id))
  pace   <- pace   |> mutate(team_id = as.character(team_id))

  # Join everything — one row per game (not split by market yet)
  features <- outcomes |>
    left_join(rest, by = "game_id") |>
    left_join(on_off |> rename(home_team_id = team_id,
                               home_on_off_delta = delta),
              by = "home_team_id") |>
    left_join(on_off |> rename(away_team_id = team_id,
                               away_on_off_delta = delta),
              by = "away_team_id") |>
    left_join(pace  |> rename(home_team_id = team_id,
                               home_pace = avg_pace),
              by = "home_team_id") |>
    left_join(pace  |> rename(away_team_id = team_id,
                               away_pace = avg_pace),
              by = "away_team_id") |>
    mutate(
      # Market features are NA for historical games — imputed in recipe
      opener_line       = NA_real_,
      midday_line       = NA_real_,
      delta_open_mid    = NA_real_,
      delta_mid_close   = NA_real_,
      delta_open_close  = NA_real_,
      line_velocity     = NA_real_,
      steam_detected    = NA_real_,
      steam_magnitude   = NA_real_,
      steam_books_moved = NA_real_,
      closing_line      = NA_real_,
      injury_flag_home  = 0L,
      injury_flag_away  = 0L
    )

  # Pull OddsPortal closing totals for historical games.
  # Populated by oddsportal_scraper.R — NA until that backfill runs.
  op_closing <- tryCatch(
    dbGetQuery(con, "
      SELECT game_id, AVG(point) AS closing_line
      FROM lines
      WHERE snapshot_type = 'closing'
        AND bookmaker     = 'oddsportal'
        AND market        = 'totals'
      GROUP BY game_id
    ") |> as_tibble(),
    error = function(e) tibble(game_id = character(), closing_line = numeric())
  )

  if (nrow(op_closing) > 0L) {
    features <- features |>
      left_join(op_closing |> rename(op_total = closing_line), by = "game_id") |>
      mutate(closing_line = coalesce(op_total, closing_line)) |>
      select(-op_total)
    message("  OddsPortal closing lines: ",
            sum(!is.na(features$closing_line)), " of ", nrow(features), " games")
  }

  message("  Feature set: ", nrow(features), " games, ",
          sum(!is.na(features$home_on_off_delta)), " with on/off data, ",
          sum(!is.na(features$home_pace)), " with pace data")

  features
}

# ── Load data ─────────────────────────────────────────────────────────────────

con <- dbConnect(RSQLite::SQLite(), DB_PATH)

training_raw <- tryCatch({

  message("Loading team box scores...")
  team_box <- wehoop::load_wnba_team_box(seasons = c(2023L, 2024L, 2025L))

  message("Building training set...")
  build_historical_training_set(con, team_box)

}, error = function(e) {
  stop("Failed to build training set: ", conditionMessage(e))
}, finally = {
  dbDisconnect(con)
  message("DB connection closed.")
})

message("Training set: ", nrow(training_raw), " games")

# ── Shared predictor columns ──────────────────────────────────────────────────

PREDICTORS <- c(
  "opener_line", "midday_line", "closing_line",
  "delta_open_mid", "delta_mid_close", "delta_open_close",
  "line_velocity",
  "steam_detected", "steam_magnitude", "steam_books_moved",
  "home_pace", "away_pace",
  "home_rest_days", "away_rest_days",
  "home_on_off_delta", "away_on_off_delta",
  "injury_flag_home", "injury_flag_away"
)

# ── XGBoost workflow builder ──────────────────────────────────────────────────

build_workflow <- function(train_df, target_col) {
  df <- train_df |>
    select(all_of(c(PREDICTORS, target_col))) |>
    filter(!is.na(.data[[target_col]])) |>
    rename(outcome = all_of(target_col))

  if (nrow(df) < 20) stop("Insufficient rows for target: ", target_col)

  set.seed(42)
  splits <- initial_split(df, prop = 0.8)
  train  <- training(splits)
  folds  <- vfold_cv(train, v = 5)

  rec <- recipe(outcome ~ ., data = train) |>
    step_impute_median(all_numeric_predictors()) |>
    step_zv(all_predictors())

  spec <- boost_tree(
    trees          = tune(),
    tree_depth     = tune(),
    learn_rate     = tune(),
    loss_reduction = tune(),
    min_n          = tune()
  ) |>
    set_engine("xgboost") |>
    set_mode("regression")

  wf <- workflow() |>
    add_recipe(rec) |>
    add_model(spec)

  grid <- grid_space_filling(
    trees(range          = c(100L, 800L)),
    tree_depth(range     = c(3L, 8L)),
    learn_rate(range     = c(-3, -1)),
    loss_reduction(),
    min_n(range          = c(5L, 30L)),
    size = 30L
  )

  message("  Tuning (5-fold CV, 30 candidates)...")

  tune_res <- tune_grid(
    wf,
    resamples = folds,
    grid      = grid,
    metrics   = metric_set(rmse, mae, rsq),
    control   = control_grid(save_pred = TRUE, verbose = FALSE)
  )

  best_params <- select_best(tune_res, metric = "rmse")
  message("  Best CV RMSE: ",
          round(show_best(tune_res, metric = "rmse")$mean[1], 3))

  final_wf  <- finalize_workflow(wf, best_params)
  final_fit <- last_fit(final_wf, splits)
  metrics   <- collect_metrics(final_fit)

  message("  Test RMSE: ", round(metrics$.estimate[metrics$.metric == "rmse"], 3))
  message("  Test R²:   ", round(metrics$.estimate[metrics$.metric == "rsq"],  3))

  list(
    fit          = extract_workflow(final_fit),
    tune_res     = tune_res,
    test_metrics = metrics,
    test_preds   = collect_predictions(final_fit)
  )
}

# ── Train: totals ─────────────────────────────────────────────────────────────

message("\n── Training totals model (", nrow(training_raw), " games) ──")
totals_result <- build_workflow(training_raw, "actual_total")
saveRDS(totals_result$fit, file.path(MODELS_DIR, "totals_xgb.rds"))
message("Saved: models/totals_xgb.rds")

# ── Train: spreads ────────────────────────────────────────────────────────────

message("\n── Training spreads model (", nrow(training_raw), " games) ──")
spreads_result <- build_workflow(training_raw, "actual_spread")
saveRDS(spreads_result$fit, file.path(MODELS_DIR, "spreads_xgb.rds"))
message("Saved: models/spreads_xgb.rds")

# ── Variable importance ───────────────────────────────────────────────────────

message("\n── Totals: top features ──")
print(vip(extract_fit_parsnip(totals_result$fit), num_features = 10L))

message("\n── Spreads: top features ──")
print(vip(extract_fit_parsnip(spreads_result$fit), num_features = 10L))

# ── Save metadata ─────────────────────────────────────────────────────────────

meta <- list(
  trained_at        = format(now("UTC"), "%Y-%m-%d %H:%M:%S"),
  n_games           = nrow(training_raw),
  totals_test_rmse  = totals_result$test_metrics$.estimate[
    totals_result$test_metrics$.metric == "rmse"],
  spreads_test_rmse = spreads_result$test_metrics$.estimate[
    spreads_result$test_metrics$.metric == "rmse"]
)

saveRDS(meta, file.path(MODELS_DIR, "training_meta.rds"))
message("\nTraining complete. ", nrow(training_raw),
        " games | metadata saved to models/training_meta.rds")
