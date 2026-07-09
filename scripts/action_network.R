# scripts/action_network.R
# Action Network WNBA public betting / sharp money data.
#
# Sharp signal: when money% >> ticket% on one side, large wagers (sharp bets)
# are concentrated there despite few total bettors. This confirms that smart
# money is on that side — a second gate alongside steam detection.
#
# Sharp threshold: money_pct - ticket_pct >= SHARP_GAP_MIN on the same side
# as the model's call → confirms the pick.
#
# KNOWN LIMITATION (found + fixed 2026-07-09, but not fully restored):
# The original endpoint (games?league=wnba&date=...&book=2) 404s — confirmed
# live. The real endpoint is scoreboard/wnba (below), which DOES return real
# games/odds, but every single betting-split field (*_public, *_money) comes
# back null across every game and every book_id tested. Action Network's own
# public-betting page confirms why: its embedded __NEXT_DATA__ includes a
# `"proUpsell": "Save Big on PRO!"` banner — split data is a paid PRO-tier
# feature, not available from any free/public endpoint. Fixed the dead
# endpoint and parsing so this stops hitting a 404 and returns a well-formed
# (if all-NA) result instead, and so this starts working immediately if
# Action Network PRO is ever purchased — but the secondary confirmation gate
# cannot actually contribute today. an_confirms() correctly returns FALSE in
# this state (same functional behavior as before the fix), just for an
# honest reason now instead of a wrong endpoint.

library(httr2)
library(dplyr)
library(purrr)
library(lubridate)

AN_API_BASE    <- "https://api.actionnetwork.com/web/v1/scoreboard/wnba"
SHARP_GAP_MIN  <- 20L   # money% must exceed ticket% by this many points to count

# ── Fetcher ───────────────────────────────────────────────────────────────────

# Returns a tibble with one row per game × book × market × side, or NULL on
# failure. Columns: home_team, away_team, market, side, ticket_pct, money_pct,
# sharp_score. sharp_score = money_pct - ticket_pct (positive = sharp money on
# that side). ticket_pct/money_pct/sharp_score will be NA_real_ unless Action
# Network PRO exposes real split data (see limitation note above).
#
# `date` is accepted for interface stability but unused — the scoreboard
# endpoint returns the current/near-term slate directly, no date filter param.

fetch_wnba_sharp_report <- function(date = Sys.Date()) {
  resp <- tryCatch(
    request(AN_API_BASE) |>
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
    teams <- g$teams
    if (is.null(teams) || length(teams) < 2) return(tibble())
    home <- Filter(function(t) identical(t$id, g$home_team_id), teams)
    away <- Filter(function(t) identical(t$id, g$away_team_id), teams)
    home_name <- if (length(home) > 0) home[[1]]$full_name %||% NA_character_ else NA_character_
    away_name <- if (length(away) > 0) away[[1]]$full_name %||% NA_character_ else NA_character_

    if (is.null(g$odds) || length(g$odds) == 0) return(tibble())

    map_dfr(g$odds, function(o) {
      bind_rows(
        tibble(market = "totals", side = "over",
               ticket_pct = as.numeric(o$total_over_public %||% NA),
               money_pct  = as.numeric(o$total_over_money  %||% NA)),
        tibble(market = "totals", side = "under",
               ticket_pct = as.numeric(o$total_under_public %||% NA),
               money_pct  = as.numeric(o$total_under_money  %||% NA)),
        tibble(market = "spreads", side = "home",
               ticket_pct = as.numeric(o$spread_home_public %||% NA),
               money_pct  = as.numeric(o$spread_home_money  %||% NA)),
        tibble(market = "spreads", side = "away",
               ticket_pct = as.numeric(o$spread_away_public %||% NA),
               money_pct  = as.numeric(o$spread_away_money  %||% NA))
      ) |>
        mutate(
          home_team   = home_name,
          away_team   = away_name,
          sharp_score = money_pct - ticket_pct,
          .before = 1
        )
    })
  })

  if (nrow(rows) == 0) {
    message("[action_network] No WNBA games found")
    return(NULL)
  }

  n_with_splits <- sum(!is.na(rows$sharp_score))
  message("[action_network] ", nrow(rows), " row(s), ", n_with_splits,
          " with real split data (PRO-tier data — expect 0 without a paid plan)")
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

  mkt         <- model_row$market[1]
  target_side <- model_row$side[1]

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
  # BUG FIXED 2026-07-09: this was `filter(grepl(side, side, ...))` with a
  # local var also named `side` — dplyr's data mask resolves BOTH references
  # to the `side` COLUMN (column names shadow same-named local vars inside
  # filter()), so it degenerated into "does each row's side match itself",
  # which is trivially true for any non-empty string. Every row always
  # passed regardless of the model's actual target side. Exact same bug class
  # already fixed once for the team-matching logic above (hence `lw_home`/
  # `lw_away` instead of `home`/`away`) but missed here.
  side_rows <- mkt_match |>
    filter(grepl(target_side, side, ignore.case = TRUE))

  if (nrow(side_rows) == 0) return(FALSE)

  any(side_rows$sharp_score >= gap, na.rm = TRUE)
}
