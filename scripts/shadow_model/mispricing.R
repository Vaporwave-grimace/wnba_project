# scripts/shadow_model/mispricing.R
# Pinnacle-deviation mispricing detector for WNBA totals.
#
# Edge hypothesis: soft books (DK, FanDuel) are slower than Pinnacle to price
# in injury news. When injury-adjusted Pinnacle diverges from a soft book by
# >= DEV_THRESHOLD points, AND steam confirms the direction, there is a
# structural mismatch worth betting.
#
# V1 covers totals only. Spreads require team-level injury attribution and
# will be added once totals CLV data validates the approach.

library(dplyr)
library(purrr)
library(DBI)
library(RSQLite)

SHARP_BOOK            <- "pinnacle"
# "caesars" removed 2026-07-09 — confirmed never present for WNBA under any
# region combo tested (live check against a real Odds API response); books
# get renamed/added over time so recheck before assuming a name is dead.
SOFT_BOOKS            <- c("draftkings", "fanduel", "betmgm", "betonlineag")
DEV_THRESHOLD_DEFAULT <- 1.5   # fallback when model_config not yet populated

# Load calibrated DEV_THRESHOLD from model_config; fall back to default.
.get_dev_threshold <- function(con) {
  tryCatch(
    dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'dev_threshold'")$value[1] %||%
      DEV_THRESHOLD_DEFAULT,
    error = \(e) DEV_THRESHOLD_DEFAULT
  )
}

# Injury impact per player — loaded dynamically so calibration can update them.
.get_injury_impact <- function(con) {
  defaults <- c(Out = -3.0, Doubtful = -2.0, Questionable = -1.0, GTD = -1.0)
  params   <- c(Out = "injury_impact_out", Doubtful = "injury_impact_doubtful",
                Questionable = "injury_impact_gtd", GTD = "injury_impact_gtd")
  vapply(names(defaults), function(status) {
    tryCatch(
      dbGetQuery(con, "SELECT value FROM model_config WHERE param = ?",
                 list(params[[status]]))$value[1] %||% defaults[[status]],
      error = \(e) defaults[[status]]
    )
  }, numeric(1))
}

# ── Line helpers ──────────────────────────────────────────────────────────────

# Most recent line for a game+market+book, preferring midday > opener > closing.
.best_line <- function(game_id, market, bookmaker, con) {
  for (snap in c("midday", "opener", "closing")) {
    row <- tryCatch(
      dbGetQuery(con, "
        SELECT point, price, outcome_name, snapshot_type
        FROM lines
        WHERE game_id       = ?
          AND market        = ?
          AND bookmaker     = ?
          AND snapshot_type = ?
        ORDER BY pulled_at DESC LIMIT 1
      ", list(game_id, market, bookmaker, snap)),
      error = \(e) data.frame()
    )
    if (nrow(row) > 0 && !is.na(row$point[1])) return(row)
  }
  NULL
}

# ── Injury adjustment ──────────────────────────────────────────────────────────

# `injuries_with_names`: output of fetch_all_injuries() left-joined with
#   fetch_espn_teams() on team_id so that team_name is present.
#
# Returns list(total_adj, n_injured, detail).
# total_adj is the signed point shift to apply to the Pinnacle total:
#   negative = expect fewer combined points (players out → lower scoring).

compute_injury_adjustment <- function(game_id, con, injuries_with_names = NULL,
                                      injury_impact = NULL) {
  zero <- list(home_adj = 0, away_adj = 0, total_adj = 0, n_injured = 0L,
               detail = character(0))
  if (is.null(injuries_with_names) || nrow(injuries_with_names) == 0) return(zero)
  if (!"team_name" %in% names(injuries_with_names)) return(zero)
  if (is.null(injury_impact)) injury_impact <- .get_injury_impact(con)

  meta <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT home_team, away_team FROM lines WHERE game_id = ? LIMIT 1
    ", list(game_id)) |> as_tibble(),
    error = \(e) tibble()
  )
  if (nrow(meta) == 0) return(zero)

  home_lower <- tolower(meta$home_team[1])
  away_lower <- tolower(meta$away_team[1])

  inj <- injuries_with_names |>
    filter(!is.na(status), status %in% names(injury_impact)) |>
    mutate(
      team_lower = tolower(team_name),
      is_home = vapply(team_lower, function(t)
        grepl(home_lower, t, fixed = TRUE) || grepl(t, home_lower, fixed = TRUE),
        logical(1)),
      is_away = vapply(team_lower, function(t)
        grepl(away_lower, t, fixed = TRUE) || grepl(t, away_lower, fixed = TRUE),
        logical(1)),
      in_game = is_home | is_away,
      impact  = injury_impact[status]
    ) |>
    filter(in_game, !is.na(impact))

  if (nrow(inj) == 0) return(zero)

  home_adj <- sum(inj$impact[inj$is_home], na.rm = TRUE)
  away_adj <- sum(inj$impact[inj$is_away], na.rm = TRUE)

  list(
    home_adj  = home_adj,
    away_adj  = away_adj,
    total_adj = home_adj + away_adj,
    n_injured = nrow(inj),
    detail    = paste0(inj$player_name, " (", inj$status, ")")
  )
}

# ── Core detection ─────────────────────────────────────────────────────────────

# Returns a tibble of mispricing opportunities (0–2 rows: one totals, one spreads),
# or NULL if nothing exceeds DEV_THRESHOLD.
#
# Columns: game_id, market, side, adj_pinnacle, soft_book, soft_line,
#          deviation_pts, n_injured

compute_mispricing <- function(game_id, con, injuries_with_names = NULL) {
  results       <- list()
  dev_threshold <- .get_dev_threshold(con)
  injury_impact <- .get_injury_impact(con)

  # Shared injury adjustment (home/away/total)
  inj <- compute_injury_adjustment(game_id, con, injuries_with_names, injury_impact)
  if (inj$n_injured > 0) {
    message(sprintf("[mispricing] %s — injury adj %.1f pts (%d player(s): %s)",
                    game_id, inj$total_adj, inj$n_injured,
                    paste(inj$detail, collapse = ", ")))
  }

  # ── Totals ───────────────────────────────────────────────────────────────────

  pin_tot <- .best_line(game_id, "totals", SHARP_BOOK, con)
  if (!is.null(pin_tot) && !is.na(pin_tot$point[1])) {
    adj_tot <- pin_tot$point[1] + inj$total_adj

    soft_tot <- map_dfr(SOFT_BOOKS, function(book) {
      r <- .best_line(game_id, "totals", book, con)
      if (!is.null(r) && nrow(r) > 0) tibble(bookmaker = book, soft_point = r$point[1])
    })

    if (nrow(soft_tot) > 0) {
      best_tot <- soft_tot |>
        mutate(deviation = soft_point - adj_tot, abs_dev = abs(deviation)) |>
        filter(abs_dev >= dev_threshold) |>
        arrange(desc(abs_dev)) |>
        slice(1)

      if (nrow(best_tot) > 0) {
        side_tot <- if (best_tot$deviation > 0) "under" else "over"
        message(sprintf("[mispricing] %s TOTALS %s — adj_pin=%.1f %s=%.1f dev=%+.1f",
                        game_id, toupper(side_tot), adj_tot,
                        best_tot$bookmaker, best_tot$soft_point, best_tot$deviation))
        results[["totals"]] <- tibble(
          game_id = game_id, market = "totals", side = side_tot,
          adj_pinnacle = adj_tot, soft_book = best_tot$bookmaker,
          soft_line = best_tot$soft_point, deviation_pts = best_tot$deviation,
          n_injured = inj$n_injured
        )
      } else {
        message(sprintf("[mispricing] %s totals max dev %.2f pts (below threshold)",
                        game_id, max(abs(soft_tot$soft_point - adj_tot), na.rm = TRUE)))
      }
    }
  }

  # ── Spreads ──────────────────────────────────────────────────────────────────
  # Compare home team's spread. Injury-adjusted Pinnacle spread:
  #   adj_spread = pinnacle_home_point - home_adj + away_adj
  # home player out  → home less favored → spread goes up (less negative)
  # away player out  → home more favored → spread goes down (more negative)

  meta <- tryCatch(
    dbGetQuery(con, "SELECT DISTINCT home_team FROM lines WHERE game_id = ? LIMIT 1",
               list(game_id)) |> as_tibble(),
    error = \(e) tibble()
  )

  pin_sp <- if (nrow(meta) > 0) .best_line(game_id, "spreads", SHARP_BOOK, con) else NULL

  if (!is.null(pin_sp) && nrow(meta) > 0) {
    home_team  <- meta$home_team[1]
    pin_home   <- pin_sp |> filter(trimws(outcome_name) == trimws(home_team))

    if (nrow(pin_home) > 0 && !is.na(pin_home$point[1])) {
      adj_sp <- pin_home$point[1] - inj$home_adj + inj$away_adj

      soft_sp <- map_dfr(SOFT_BOOKS, function(book) {
        r <- .best_line(game_id, "spreads", book, con)
        if (is.null(r) || nrow(r) == 0) return(NULL)
        hr <- r |> filter(trimws(outcome_name) == trimws(home_team))
        if (nrow(hr) > 0) tibble(bookmaker = book, soft_point = hr$point[1])
      })

      if (nrow(soft_sp) > 0) {
        best_sp <- soft_sp |>
          mutate(deviation = soft_point - adj_sp, abs_dev = abs(deviation)) |>
          filter(abs_dev >= dev_threshold) |>
          arrange(desc(abs_dev)) |>
          slice(1)

        if (nrow(best_sp) > 0) {
          # deviation > 0: soft book shows home less favored than adjusted → bet HOME
          # deviation < 0: soft book shows home more favored than adjusted → bet AWAY
          side_sp <- if (best_sp$deviation > 0) "home" else "away"
          message(sprintf("[mispricing] %s SPREADS %s — adj_pin=%.1f %s=%.1f dev=%+.1f",
                          game_id, toupper(side_sp), adj_sp,
                          best_sp$bookmaker, best_sp$soft_point, best_sp$deviation))
          results[["spreads"]] <- tibble(
            game_id = game_id, market = "spreads", side = side_sp,
            adj_pinnacle = adj_sp, soft_book = best_sp$bookmaker,
            soft_line = best_sp$soft_point, deviation_pts = best_sp$deviation,
            n_injured = inj$n_injured
          )
        }
      }
    }
  }

  if (length(results) == 0) return(NULL)
  bind_rows(results)
}
