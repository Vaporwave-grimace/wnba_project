# scripts/shadow_model/features.R
# Feature engineering layer for the WNBA shadow model
#
# Two entry points:
#   build_features(game_id, con)        — single game, used at prediction time
#   build_training_set(con, seasons)    — all historical games, used for training
#
# Feature set:
#   Market:   opener/midday line, movement deltas, velocity, steam flag
#   Roster:   pace (home/away), rest days (home/away), on/off delta
#   Injury:   discrepancy flags for each team
#   Target:   actual_total, actual_spread (training only)

library(dplyr)
library(tidyr)
library(lubridate)
library(wehoop)
library(DBI)
library(RSQLite)

DB_PATH <- here::here("data", "wnba_pipeline.sqlite")

# ── Market features ───────────────────────────────────────────────────────────

# Pull opener and midday lines for a game and compute movement features.
# Returns one row per market (totals / spreads).
market_features <- function(game_id, con) {
  lines <- dbGetQuery(con, "
    SELECT snapshot_type, market, outcome_name, point, pulled_at
    FROM lines
    WHERE game_id = ?
      AND market IN ('totals', 'spreads')
      AND bookmaker IN ('pinnacle','betonlineag','lowvig','fanduel','draftkings')
    ORDER BY pulled_at
  ", list(game_id)) |> as_tibble()

  if (nrow(lines) == 0) return(NULL)

  # Median line per snapshot × market (consensus across sharp books)
  consensus <- lines |>
    group_by(snapshot_type, market) |>
    summarise(line = median(point, na.rm = TRUE),
              pulled_at = min(pulled_at),
              .groups = "drop")

  # Pivot to wide: one row per market
  wide <- consensus |>
    pivot_wider(
      names_from  = snapshot_type,
      values_from = c(line, pulled_at),
      names_glue  = "{snapshot_type}_{.value}"
    ) |>
    mutate(
      # Movement deltas
      delta_open_mid  = midday_line  - opener_line,
      delta_mid_close = closing_line - midday_line,
      delta_open_close= closing_line - opener_line,

      # Velocity: points moved per hour (opener → midday)
      hours_open_mid = as.numeric(difftime(
        ymd_hms(midday_pulled_at),
        ymd_hms(opener_pulled_at),
        units = "hours"
      )),
      line_velocity = if_else(hours_open_mid > 0,
                              abs(delta_open_mid) / hours_open_mid,
                              NA_real_)
    ) |>
    select(market, opener_line, midday_line, closing_line,
           delta_open_mid, delta_mid_close, delta_open_close, line_velocity)

  wide
}

# ── Steam features ─────────────────────────────────────────────────────────────

steam_features <- function(game_id, con) {
  steam <- dbGetQuery(con, "
    SELECT market, direction, magnitude, books_moved
    FROM steam_movements
    WHERE game_id = ?
    ORDER BY detected_at DESC
  ", list(game_id)) |> as_tibble()

  if (nrow(steam) == 0) {
    return(tibble(
      market             = c("totals", "spreads"),
      steam_detected     = FALSE,
      steam_magnitude    = 0,
      steam_books_moved  = 0L,
      steam_direction    = NA_character_
    ))
  }

  steam |>
    group_by(market) |>
    slice_max(magnitude, n = 1, with_ties = FALSE) |>
    ungroup() |>
    mutate(
      steam_detected    = TRUE,
      steam_magnitude   = magnitude,
      steam_books_moved = books_moved
    ) |>
    select(market, steam_detected, steam_magnitude, steam_books_moved,
           steam_direction = direction)
}

# ── Roster features (pace + rest) ─────────────────────────────────────────────

# Pull team-level pace and rest days from wehoop box scores.
# `team_box` should be a pre-loaded data frame from load_wnba_team_box().
roster_features <- function(game_id, team_box) {
  game_rows <- team_box |>
    filter(game_id == !!game_id) |>
    arrange(team_home_away)   # "away" < "home"

  if (nrow(game_rows) < 2) return(NULL)

  away <- game_rows |> filter(team_home_away == "away")
  home <- game_rows |> filter(team_home_away == "home")

  # Rest days: days since previous game for each team
  calc_rest <- function(tid, gdate, tbox) {
    prev <- tbox |>
      filter(team_id == tid, game_date < gdate) |>
      arrange(desc(game_date)) |>
      slice(1)
    if (nrow(prev) == 0) return(NA_real_)
    as.numeric(difftime(as.Date(gdate), as.Date(prev$game_date), units = "days"))
  }

  game_date <- home$game_date[1]

  tibble(
    home_pace      = as.numeric(home$pace[1]),
    away_pace      = as.numeric(away$pace[1]),
    home_rest_days = calc_rest(home$team_id[1], game_date, team_box),
    away_rest_days = calc_rest(away$team_id[1], game_date, team_box),
    home_team_id   = home$team_id[1],
    away_team_id   = away$team_id[1],
    game_date      = game_date
  )
}

# ── On/Off features ───────────────────────────────────────────────────────────

on_off_features <- function(home_team_id, away_team_id, con) {
  pull_delta <- function(tid) {
    row <- dbGetQuery(con, "
      SELECT delta FROM on_off_net_rating
      WHERE team_id = ?
      ORDER BY computed_at DESC
      LIMIT 1
    ", list(as.character(tid))) |> as_tibble()
    if (nrow(row) == 0) NA_real_ else row$delta[1]
  }

  tibble(
    home_on_off_delta = pull_delta(home_team_id),
    away_on_off_delta = pull_delta(away_team_id)
  )
}

# ── Injury features ───────────────────────────────────────────────────────────

injury_features <- function(game_id, home_team_id, away_team_id, con) {
  disc <- dbGetQuery(con, "
    SELECT player_name, flagged_at
    FROM injury_discrepancies
    WHERE game_id = ?
  ", list(game_id)) |> as_tibble()

  # Match discrepancy players to team via injury_reports
  if (nrow(disc) == 0) {
    return(tibble(injury_flag_home = 0L, injury_flag_away = 0L))
  }

  reports <- dbGetQuery(con, "
    SELECT player_name, team_id
    FROM injury_reports
    WHERE player_name IN (?)
  ", list(paste(disc$player_name, collapse = "','"))) |> as_tibble()

  flagged <- disc |>
    left_join(reports, by = "player_name")

  tibble(
    injury_flag_home = as.integer(any(flagged$team_id == as.character(home_team_id), na.rm = TRUE)),
    injury_flag_away = as.integer(any(flagged$team_id == as.character(away_team_id), na.rm = TRUE))
  )
}

# ── Single-game feature vector ────────────────────────────────────────────────

# Builds a complete feature row for one game.
# Returns a tibble with one row per market (totals / spreads).
build_features <- function(game_id, con, team_box = NULL) {
  if (is.null(team_box)) {
    team_box <- wehoop::load_wnba_team_box(seasons = as.integer(format(Sys.Date(), "%Y")))
  }

  mkt   <- market_features(game_id, con)
  if (is.null(mkt)) {
    message("No line data for game: ", game_id)
    return(NULL)
  }

  stm   <- steam_features(game_id, con)
  ros   <- roster_features(game_id, team_box)
  if (is.null(ros)) {
    message("No roster data for game: ", game_id)
    return(NULL)
  }

  oo    <- on_off_features(ros$home_team_id, ros$away_team_id, con)
  inj   <- injury_features(game_id, ros$home_team_id, ros$away_team_id, con)

  mkt |>
    left_join(stm, by = "market") |>
    bind_cols(ros |> select(-home_team_id, -away_team_id)) |>
    bind_cols(oo) |>
    bind_cols(inj) |>
    mutate(
      game_id           = game_id,
      steam_detected    = as.integer(coalesce(steam_detected, FALSE)),
      steam_magnitude   = coalesce(steam_magnitude, 0),
      steam_books_moved = coalesce(steam_books_moved, 0L)
    )
}

# ── Training set builder ──────────────────────────────────────────────────────

# Assembles features + actual outcomes for all games in the DB.
# `actual_outcomes` is a data frame with columns: game_id, actual_total, actual_spread.
build_training_set <- function(con, actual_outcomes, team_box) {
  game_ids <- dbGetQuery(con, "SELECT DISTINCT game_id FROM lines") |> pull(game_id)

  message("Building features for ", length(game_ids), " games...")

  rows <- purrr::map_dfr(game_ids, function(gid) {
    tryCatch(
      build_features(gid, con, team_box),
      error = function(e) {
        message("  Skipping ", gid, ": ", conditionMessage(e))
        NULL
      }
    )
  })

  rows |>
    left_join(actual_outcomes, by = "game_id") |>
    filter(!is.na(actual_total) | !is.na(actual_spread))
}
