# scripts/action_network.R
# Action Network WNBA public betting / sharp money data.
#
# Sharp signal: when money% >> ticket% on one side, large wagers (sharp bets)
# are concentrated there despite few total bettors. This confirms that smart
# money is on that side — a second gate alongside steam detection.
#
# Uses Action Network's internal JSON API (same data as their /wnba/public-betting
# page). Falls back to NULL silently so the mispricing model runs unaffected
# if the endpoint changes or the request fails.
#
# Sharp threshold: money_pct - ticket_pct >= SHARP_GAP_MIN on the same side
# as the model's call → confirms the pick.

library(httr2)
library(dplyr)
library(purrr)
library(lubridate)

AN_API_BASE    <- "https://api.actionnetwork.com/web/v1"
SHARP_GAP_MIN  <- 20L   # money% must exceed ticket% by this many points to count

# ── Fetcher ───────────────────────────────────────────────────────────────────

# Returns a tibble with one row per game × market × side, or NULL on failure.
# Columns: home_team, away_team, market, side, ticket_pct, money_pct, sharp_score
# sharp_score = money_pct - ticket_pct (positive = sharp money on that side)

fetch_wnba_sharp_report <- function(date = Sys.Date()) {
  date_str <- format(date, "%Y%m%d")

  # Action Network internal endpoint — returns game list with betting splits
  resp <- tryCatch(
    request(AN_API_BASE) |>
      req_url_path_append("games") |>
      req_url_query(league = "wnba", date = date_str, book = "2") |>
      req_headers(
        "User-Agent"  = paste0("Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
                               "AppleWebKit/537.36 (KHTML, like Gecko) ",
                               "Chrome/124.0.0.0 Safari/537.36"),
        "Referer"     = "https://www.actionnetwork.com/",
        "Origin"      = "https://www.actionnetwork.com",
        "Accept"      = "application/json"
      ) |>
      req_timeout(15) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform(),
    error = function(e) {
      message("[action_network] Request error: ", e$message)
      NULL
    }
  )

  if (is.null(resp)) return(NULL)

  if (resp_status(resp) != 200L) {
    message("[action_network] HTTP ", resp_status(resp),
            " — endpoint may have changed")
    return(NULL)
  }

  body <- tryCatch(resp_body_json(resp, simplifyVector = FALSE),
                   error = \(e) NULL)
  if (is.null(body) || is.null(body$games)) {
    message("[action_network] Unexpected response structure")
    return(NULL)
  }

  rows <- map_dfr(body$games, function(g) {
    home <- g$teams$home$full_name %||% NA_character_
    away <- g$teams$away$full_name %||% NA_character_

    # Each game has `consensus` with totals + spreads betting splits
    consensus <- g$consensus
    if (is.null(consensus)) return(tibble())

    map_dfr(names(consensus), function(mkt) {
      splits <- consensus[[mkt]]
      if (is.null(splits)) return(tibble())

      map_dfr(names(splits), function(side) {
        s <- splits[[side]]
        if (is.null(s$tickets) || is.null(s$money)) return(tibble())
        tibble(
          home_team   = home,
          away_team   = away,
          market      = mkt,
          side        = side,
          ticket_pct  = as.numeric(s$tickets),
          money_pct   = as.numeric(s$money),
          sharp_score = as.numeric(s$money) - as.numeric(s$tickets)
        )
      })
    })
  })

  if (nrow(rows) == 0) {
    message("[action_network] No WNBA games found for ", date_str)
    return(NULL)
  }

  message("[action_network] ", nrow(rows), " betting split row(s) for ", date_str)
  rows
}

# ── Agreement checker ──────────────────────────────────────────────────────────

# Given a mispricing tibble row (market, side) and a game's team names,
# check whether Action Network sharp money confirms the model's side.
#
# For totals: side='under' confirmed when 'under' money% - ticket% >= SHARP_GAP_MIN
# For spreads: side='home'/'away' confirmed when that team's money% - ticket% >= gap
#
# Returns TRUE / FALSE. Returns FALSE on any data gap (non-fatal).

an_confirms <- function(model_row, an_data, home_t, away_t,
                         gap = SHARP_GAP_MIN) {
  if (is.null(an_data) || nrow(an_data) == 0) return(FALSE)

  mkt  <- model_row$market[1]
  side <- model_row$side[1]

  # Match game: fuzzy last-word match on team names.
  # Use local vars (not dplyr column names) so filter() sees the right values.
  last_word  <- function(x) tail(strsplit(tolower(x), " ")[[1]], 1)
  lw_home    <- last_word(home_t)
  lw_away    <- last_word(away_t)
  game_rows <- an_data |>
    filter(
      grepl(lw_home, tolower(home_team), fixed = TRUE) |
        grepl(lw_away, tolower(away_team), fixed = TRUE)
    )

  if (nrow(game_rows) == 0) return(FALSE)

  # Market label normalisation: AN may use "total" / "spread" (not "totals"/"spreads")
  mkt_match <- game_rows |>
    filter(grepl(sub("s$", "", mkt), market, ignore.case = TRUE))

  if (nrow(mkt_match) == 0) return(FALSE)

  # For totals: side is "over" or "under"
  # For spreads: side is "home" or "away"
  side_rows <- mkt_match |>
    filter(grepl(side, side, ignore.case = TRUE))

  if (nrow(side_rows) == 0) return(FALSE)

  any(side_rows$sharp_score >= gap, na.rm = TRUE)
}
