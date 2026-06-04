# scripts/wnba_stats_api.R
# WNBA stats layer — powered by the wehoop package
#
# Uses ESPN-backed wehoop functions only (load_wnba_* / espn_wnba_*).
# stats.wnba.com endpoints (wnba_*) are unreliable and excluded.
#
# Key functions:
#   fetch_game_log()            — season player box scores (ESPN)
#   fetch_team_box()            — season team box scores (ESPN)
#   fetch_pbp()                 — play-by-play for a single game (ESPN)
#   compute_on_off_net_rating() — 6th/7th player delta from game-level box scores
#   write_on_off_to_db()        — persist results to SQLite
#   write_pbp_to_db()           — persist PBP rows to SQLite

library(wehoop)
library(dplyr)
library(tidyr)
library(purrr)
library(DBI)
library(RSQLite)
library(lubridate)

DB_PATH <- here::here("data", "wnba_pipeline.sqlite")
SEASON  <- 2025L   # integer year for load_wnba_* functions

# ── Game Log ──────────────────────────────────────────────────────────────────

# Player-level box scores — one row per player per game.
fetch_game_log <- function(season = SEASON) {
  message("Fetching player box scores for season: ", season)
  wehoop::load_wnba_player_box(seasons = season)
}

# Team-level box scores — one row per team per game.
fetch_team_box <- function(season = SEASON) {
  message("Fetching team box scores for season: ", season)
  wehoop::load_wnba_team_box(seasons = season)
}

# ── Play-by-Play ──────────────────────────────────────────────────────────────

# Returns ESPN PBP event log for a single game.
fetch_pbp <- function(game_id) {
  message("Fetching PBP for game: ", game_id)
  wehoop::espn_wnba_pbp(game_id = game_id)
}

# ── On/Off Net Rating ─────────────────────────────────────────────────────────
#
# Computes the on/off net rating delta for a team's 6th and 7th rotation
# players using game-level box score data from ESPN (no stats.wnba.com needed).
#
# Method:
#   1. Load player box scores for the season.
#   2. Rank players by average minutes → identify 6th and 7th rotation players.
#   3. Load team box scores for the season (contains team net rating per game).
#   4. Split games: those where either bench player played vs. those where neither did.
#   5. Compare mean team net rating across the two groups.
#
# `player_box` and `team_box` can be pre-loaded and passed in to avoid
# redundant API calls when computing across multiple teams.

compute_on_off_net_rating <- function(team_id,
                                      season      = SEASON,
                                      player_box  = NULL,
                                      team_box    = NULL) {
  message("Computing on/off net rating for team: ", team_id)

  if (is.null(player_box)) player_box <- fetch_game_log(season)
  if (is.null(team_box))   team_box   <- fetch_team_box(season)

  # ── Step 1: rank players by average minutes ──────────────────────────────

  team_players <- player_box |>
    filter(team_id == !!as.character(team_id)) |>
    mutate(minutes = as.numeric(minutes)) |>
    filter(!is.na(minutes), minutes > 0)

  if (nrow(team_players) == 0) {
    warning("No player data found for team_id: ", team_id)
    return(NULL)
  }

  player_avg_min <- team_players |>
    group_by(athlete_id, athlete_display_name) |>
    summarise(avg_min = mean(minutes, na.rm = TRUE),
              games   = n(),
              .groups = "drop") |>
    arrange(desc(avg_min))

  if (nrow(player_avg_min) < 7) {
    warning("Fewer than 7 rotation players for team_id: ", team_id)
    return(NULL)
  }

  bench_6_7     <- player_avg_min |> slice(6:7)
  bench_ids     <- bench_6_7$athlete_id

  # ── Step 2: classify games by bench player workload ──────────────────────

  # "Heavy" bench game = either player logged >= 15 minutes.
  # "Light" bench game = neither player logged >= 15 minutes.
  # This is more meaningful than pure presence/absence since bench players
  # dress for nearly every game but their workload varies significantly.
  BENCH_MIN_THRESHOLD <- 15

  bench_presence <- team_players |>
    filter(athlete_id %in% bench_ids) |>
    group_by(game_id) |>
    summarise(bench_played = any(minutes >= BENCH_MIN_THRESHOLD, na.rm = TRUE),
              .groups = "drop")

  # ── Step 3: team net rating per game ─────────────────────────────────────

  team_games <- team_box |>
    filter(team_id == !!as.character(team_id)) |>
    mutate(net_rating = as.numeric(team_score) - as.numeric(opponent_team_score)) |>
    select(game_id, net_rating) |>
    filter(!is.na(net_rating))

  if (nrow(team_games) == 0) {
    warning("No team net rating data for team_id: ", team_id)
    return(NULL)
  }

  # ── Step 4: join and compare ──────────────────────────────────────────────

  combined <- team_games |>
    left_join(bench_presence, by = "game_id") |>
    mutate(bench_played = coalesce(bench_played, FALSE))

  with_bench    <- combined |> filter( bench_played)
  without_bench <- combined |> filter(!bench_played)

  if (nrow(with_bench) == 0 || nrow(without_bench) == 0) {
    warning("Insufficient game splits for team_id: ", team_id,
            " (with: ", nrow(with_bench), ", without: ", nrow(without_bench), ")")
    return(NULL)
  }

  list(
    team_id            = as.character(team_id),
    season             = as.character(season),
    rotation_player_6  = bench_6_7$athlete_display_name[1],
    rotation_player_7  = bench_6_7$athlete_display_name[2],
    net_rating_with    = mean(with_bench$net_rating,    na.rm = TRUE),
    net_rating_without = mean(without_bench$net_rating, na.rm = TRUE),
    delta              = mean(without_bench$net_rating, na.rm = TRUE) -
                         mean(with_bench$net_rating,    na.rm = TRUE),
    computed_at        = format(now("UTC"), "%Y-%m-%d %H:%M:%S")
  )
}

# ── DB Write Helpers ──────────────────────────────────────────────────────────

write_on_off_to_db <- function(result, con) {
  if (is.null(result)) return(invisible(NULL))
  dbAppendTable(con, "on_off_net_rating", as.data.frame(result))
  message("Wrote on/off delta for team ", result$team_id, " to DB.")
}

write_pbp_to_db <- function(pbp_df, con) {
  if (nrow(pbp_df) == 0) return(invisible(NULL))
  pbp_df <- pbp_df |>
    mutate(ingested_at = format(now("UTC"), "%Y-%m-%d %H:%M:%S"))
  dbAppendTable(con, "play_by_play", pbp_df)
  message("Wrote ", nrow(pbp_df), " PBP rows to DB.")
}
