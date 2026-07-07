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

SHARP_BOOK    <- "pinnacle"
SOFT_BOOKS    <- c("draftkings", "fanduel", "caesars", "betmgm", "betonlineag")
DEV_THRESHOLD <- 1.5   # minimum point gap to flag (calibrate after 4-6 weeks)

# Injury impact on the combined game total (points per player).
# Both teams' injured players reduce the total; calibrate against actual results.
INJURY_IMPACT <- c(
  "Out"          = -3.0,
  "Doubtful"     = -2.0,
  "Questionable" = -1.0,
  "GTD"          = -1.0
)

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

compute_injury_adjustment <- function(game_id, con, injuries_with_names = NULL) {
  zero <- list(total_adj = 0, n_injured = 0L, detail = character(0))
  if (is.null(injuries_with_names) || nrow(injuries_with_names) == 0) return(zero)
  if (!"team_name" %in% names(injuries_with_names)) return(zero)

  meta <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT home_team, away_team FROM lines WHERE game_id = ? LIMIT 1
    ", list(game_id)) |> as_tibble(),
    error = \(e) tibble()
  )
  if (nrow(meta) == 0) return(zero)

  game_teams <- c(tolower(meta$home_team[1]), tolower(meta$away_team[1]))

  inj <- injuries_with_names |>
    filter(!is.na(status), status %in% names(INJURY_IMPACT)) |>
    mutate(
      team_lower = tolower(team_name),
      # Bidirectional substring match: team "Las Vegas Aces" matches "aces" in either direction
      in_game = vapply(team_lower, function(t) {
        any(vapply(game_teams, function(g) {
          grepl(g, t, fixed = TRUE) || grepl(t, g, fixed = TRUE)
        }, logical(1)))
      }, logical(1)),
      impact = INJURY_IMPACT[status]
    ) |>
    filter(in_game, !is.na(impact))

  if (nrow(inj) == 0) return(zero)

  list(
    total_adj = sum(inj$impact, na.rm = TRUE),
    n_injured = nrow(inj),
    detail    = paste0(inj$player_name, " (", inj$status, ")")
  )
}

# ── Core detection ─────────────────────────────────────────────────────────────

# Returns a one-row tibble describing the mispricing, or NULL if no deviation
# exceeds DEV_THRESHOLD.
#
# Columns: game_id, market, side, adj_pinnacle, soft_book, soft_line,
#          deviation_pts, n_injured

compute_mispricing <- function(game_id, con, injuries_with_names = NULL) {

  # Sharp reference line
  pin <- .best_line(game_id, "totals", SHARP_BOOK, con)
  if (is.null(pin)) {
    message("[mispricing] No Pinnacle totals line for ", game_id)
    return(NULL)
  }

  # Injury-adjusted Pinnacle line
  inj      <- compute_injury_adjustment(game_id, con, injuries_with_names)
  adj_line <- pin$point[1] + inj$total_adj

  if (inj$n_injured > 0) {
    message(sprintf("[mispricing] %s — injury adj %.1f pts (%d player(s): %s)",
                    game_id, inj$total_adj, inj$n_injured,
                    paste(inj$detail, collapse = ", ")))
  }

  # Soft book comparison — one point per book (Over/Under share the same point)
  soft_rows <- map_dfr(SOFT_BOOKS, function(book) {
    r <- .best_line(game_id, "totals", book, con)
    if (!is.null(r) && nrow(r) > 0) tibble(bookmaker = book, soft_point = r$point[1])
  })

  if (nrow(soft_rows) == 0) {
    message("[mispricing] No soft book lines for ", game_id)
    return(NULL)
  }

  # Pick the soft book with the largest deviation from the adjusted Pinnacle line
  best <- soft_rows |>
    mutate(
      deviation = soft_point - adj_line,
      abs_dev   = abs(deviation)
    ) |>
    filter(abs_dev >= DEV_THRESHOLD) |>
    arrange(desc(abs_dev)) |>
    slice(1)

  if (nrow(best) == 0) {
    message(sprintf("[mispricing] %s — max dev %.2f pts (below %.1f threshold)",
                    game_id,
                    max(abs(soft_rows$soft_point - adj_line), na.rm = TRUE),
                    DEV_THRESHOLD))
    return(NULL)
  }

  # soft_point > adj_pinnacle → soft book is too high → bet UNDER on soft book
  # soft_point < adj_pinnacle → soft book is too low  → bet OVER  on soft book
  side <- if (best$deviation > 0) "under" else "over"

  message(sprintf("[mispricing] %s TOTALS %s — adj_pin=%.1f %s=%.1f dev=%+.1f",
                  game_id, toupper(side), adj_line,
                  best$bookmaker, best$soft_point, best$deviation))

  tibble(
    game_id       = game_id,
    market        = "totals",
    side          = side,
    adj_pinnacle  = adj_line,
    soft_book     = best$bookmaker,
    soft_line     = best$soft_point,
    deviation_pts = best$deviation,
    n_injured     = inj$n_injured
  )
}
