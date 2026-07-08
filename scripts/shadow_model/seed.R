# scripts/shadow_model/seed.R
# Historical data bootstrapper
#
# Seeds the pipeline DB with 2023 and 2024 WNBA season data so the
# shadow model has enough training examples before 2025 pipeline logs
# accumulate. Run this ONCE before train.R.
#
# What it writes:
#   - game_outcomes table: actual totals and spreads from historical box scores
#   - on_off_net_rating:   pre-computed on/off deltas for all historical teams
#   - game_log:            team game log for rest day calculations

library(wehoop)
library(dplyr)
library(tidyr)
library(lubridate)
library(DBI)
library(RSQLite)
library(here)
library(purrr)

source(here("scripts", "db_setup.R"))
source(here("scripts", "wnba_stats_api.R"))

DB_PATH <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"
SEASONS <- c(2023L, 2024L, 2025L, 2026L)

`%!in%` <- Negate(`%in%`)

# Open one connection for the whole script — closed explicitly at the end
con <- dbConnect(RSQLite::SQLite(), DB_PATH)

tryCatch({

  # Ensure schema is current (init_db opens/closes its own internal connection)
  init_db(DB_PATH)

  # ── Load historical box scores ──────────────────────────────────────────────

  message("Loading historical team box scores for seasons: ",
          paste(SEASONS, collapse = ", "))

  team_box <- map_dfr(SEASONS, function(s) {
    message("  Season: ", s)
    wehoop::load_wnba_team_box(seasons = s)
  })

  message("Loaded ", nrow(team_box), " team-game rows")

  # ── Build game_outcomes ─────────────────────────────────────────────────────

  message("Building game_outcomes...")

  outcomes <- team_box |>
    select(game_id, game_date, team_id, team_home_away, team_score, season) |>
    pivot_wider(
      names_from  = team_home_away,
      values_from = c(team_id, team_score)
    ) |>
    rename(
      home_team_id = team_id_home,
      away_team_id = team_id_away,
      home_score   = team_score_home,
      away_score   = team_score_away
    ) |>
    mutate(
      home_score    = as.integer(home_score),
      away_score    = as.integer(away_score),
      actual_total  = home_score + away_score,
      actual_spread = home_score - away_score,
      game_date     = as.character(game_date)
    ) |>
    filter(!is.na(home_score), !is.na(away_score)) |>
    select(game_id, game_date, home_team_id, away_team_id,
           home_score, away_score, actual_total, actual_spread, season)

  existing_ids <- dbGetQuery(con, "SELECT game_id FROM game_outcomes")$game_id
  new_outcomes <- outcomes |> filter(game_id %!in% existing_ids)

  if (nrow(new_outcomes) > 0) {
    dbAppendTable(con, "game_outcomes", new_outcomes)
    message("Inserted ", nrow(new_outcomes), " historical game outcomes")
  } else {
    message("game_outcomes already up to date")
  }

  # ── Seed game_log ───────────────────────────────────────────────────────────

  message("Seeding game_log...")

  game_log_rows <- team_box |>
    select(game_id, game_date, team_id, team_display_name, season) |>
    rename(team_name = team_display_name) |>
    mutate(
      matchup     = paste(game_id),
      game_date   = as.character(game_date),
      season      = as.character(season),
      ingested_at = format(now("UTC"), "%Y-%m-%d %H:%M:%S")
    ) |>
    distinct(game_id, team_id, .keep_all = TRUE)

  existing_log <- dbGetQuery(con,
    "SELECT game_id || team_id AS key FROM game_log")$key

  new_log <- game_log_rows |>
    filter(paste0(game_id, team_id) %!in% existing_log)

  if (nrow(new_log) > 0) {
    dbAppendTable(con, "game_log", new_log)
    message("Inserted ", nrow(new_log), " game log rows")
  } else {
    message("game_log already up to date")
  }

  # ── Seed on/off net ratings ─────────────────────────────────────────────────

  message("Computing historical on/off net ratings...")

  # Pre-load player and team box scores once per season to avoid 28 API calls
  walk(SEASONS, function(szn) {
    message("  Loading box scores for season: ", szn)
    pb <- tryCatch(wehoop::load_wnba_player_box(seasons = szn),
                   error = function(e) { message("  player_box failed: ", conditionMessage(e)); NULL })
    tb <- tryCatch(wehoop::load_wnba_team_box(seasons = szn),
                   error = function(e) { message("  team_box failed: ",   conditionMessage(e)); NULL })

    if (is.null(pb) || is.null(tb)) return(invisible(NULL))

    team_ids_szn <- tb |> distinct(team_id) |> pull(team_id)

    walk(team_ids_szn, function(tid) {
      result <- tryCatch(
        compute_on_off_net_rating(tid, season = szn,
                                  player_box = pb, team_box = tb),
        error = function(e) {
          message("  Skipping team ", tid, ": ", conditionMessage(e))
          NULL
        }
      )
      if (!is.null(result)) write_on_off_to_db(result, con)
    })
  })

  # ── Summary ─────────────────────────────────────────────────────────────────

  message("\n── Seed complete ────────────────────────────────────────────────")
  message("game_outcomes: ", dbGetQuery(con, "SELECT COUNT(*) FROM game_outcomes")[[1]])
  message("game_log rows: ", dbGetQuery(con, "SELECT COUNT(*) FROM game_log")[[1]])
  message("on_off rows:   ", dbGetQuery(con, "SELECT COUNT(*) FROM on_off_net_rating")[[1]])
  message("\nNext step: source('scripts/shadow_model/train.R')")

}, error = function(e) {
  message("SEED FAILED: ", conditionMessage(e))
}, finally = {
  dbDisconnect(con)
  message("DB connection closed.")
})
