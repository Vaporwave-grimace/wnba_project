# scripts/bet_alerts.R — WNBA bet alert emission
# ─────────────────────────────────────────────────────────────────────────────
# Called from run_pipeline.R after shadow model predictions.
# Fires a structured Discord alert when model edge >= MIN_EV_PCT,
# and appends a row to the daily BET_HISTORY_WNBA_YYYYMMDD.csv.
# ─────────────────────────────────────────────────────────────────────────────

library(httr2)
library(lubridate)
library(DBI)
library(RSQLite)

source(here::here("scripts", "broadcast_schema.R"))

WNBA_EXPORTS_DIR <- here::here("exports")

# Minimum EV% to fire an alert
MIN_EV_PCT <- 3.0

# Assumed scoring SDs for model_prob approximation via normal CDF.
# Calibrate against calibration_report.rds once enough games accumulate.
.WNBA_TOTAL_SD  <- 8.0
.WNBA_SPREAD_SD <- 5.0

# Discord channel: #auto-bet-broadcast
.BROADCAST_CHANNEL <- "1499488823598387412"

# ── Helpers ───────────────────────────────────────────────────────────────────

.american_to_prob <- function(odds) {
  if (is.na(odds)) return(NA_real_)
  if (odds > 0) 100 / (odds + 100) else abs(odds) / (abs(odds) + 100)
}

.prob_to_american <- function(p) {
  if (is.na(p) || p <= 0 || p >= 1) return(NA_integer_)
  if (p >= 0.5) as.integer(round(-p / (1 - p) * 100))
  else          as.integer(round((1 - p) / p * 100))
}

# Half Kelly by default — full Kelly is too aggressive on an uncalibrated model.
# Returns the fraction of bankroll to risk (0 if edge is negative).
.kelly_fraction <- function(model_prob, odds, fraction = 0.5) {
  if (anyNA(c(model_prob, odds)) || model_prob <= 0 || model_prob >= 1) return(0)
  b <- if (odds > 0) odds / 100 else 100 / abs(odds)  # net decimal odds
  f <- (model_prob * b - (1 - model_prob)) / b
  max(0, min(1, f)) * fraction
}

# Best available line for a specific market + outcome_name, from the most
# recent snapshot for the game.  Returns list(book, odds, point).
.best_book_odds <- function(game_id, market, outcome_name, con) {
  BOOK_PREF <- c("pinnacle", "betonlineag", "lowvig",
                 "draftkings", "fanduel")
  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT bookmaker, price, point
      FROM lines
      WHERE game_id      = ?
        AND market       = ?
        AND outcome_name = ?
        AND snapshot_type = (
          SELECT snapshot_type FROM lines
          WHERE game_id = ?
          ORDER BY pulled_at DESC LIMIT 1
        )
    ", list(game_id, market, outcome_name, game_id)),
    error = function(e) data.frame()
  )
  if (nrow(rows) == 0)
    return(list(book = NA_character_, odds = NA_integer_, point = NA_real_))
  rows$rank <- match(tolower(rows$bookmaker), BOOK_PREF, nomatch = 99L)
  rows <- rows[order(rows$rank), ]
  list(book  = rows$bookmaker[1],
       odds  = as.integer(round(rows$price[1])),
       point = rows$point[1])
}

# Game metadata: home_team, away_team, commence_time
.game_meta <- function(game_id, con) {
  tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT home_team, away_team, commence_time
      FROM lines WHERE game_id = ? LIMIT 1
    ", list(game_id)),
    error = function(e) data.frame()
  )
}

# ── Main emitter ──────────────────────────────────────────────────────────────

# `market`     : "totals" | "spreads"
# `side`       : "over"|"under" (totals) or "home"|"away" (spreads)
# `model_line` : model's predicted total or spread (home−away perspective)
# `mkt_line`   : market consensus line at time of prediction
# Returns the emitted message string, or NULL if below threshold / no odds.

emit_wnba_bet_alert <- function(game_id, market, side, model_line, mkt_line,
                                con, creds, steam_confirmed = FALSE) {
  meta <- .game_meta(game_id, con)
  if (nrow(meta) == 0) {
    message("[bet_alerts/WNBA] No game meta for ", game_id)
    return(invisible(NULL))
  }

  home_team <- meta$home_team[1]
  away_team <- meta$away_team[1]

  # ── Odds lookup + play string + model_prob ──────────────────────────────────

  if (market == "totals") {
    outcome_name <- if (side == "over") "Over" else "Under"
    bo    <- .best_book_odds(game_id, "totals", outcome_name, con)
    point <- if (!is.na(bo$point)) bo$point else mkt_line
    play  <- sprintf("%s %.1f", outcome_name, point)
    sd    <- .WNBA_TOTAL_SD
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = sd, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = sd, lower.tail = TRUE)

  } else {
    # spreads: outcome_name = team name; point = team's spread (neg = favored)
    outcome_name <- if (side == "home") home_team else away_team
    bo    <- .best_book_odds(game_id, "spreads", outcome_name, con)
    point <- if (!is.na(bo$point)) bo$point else mkt_line
    play  <- sprintf("%s %+.1f", outcome_name, point)
    sd    <- .WNBA_SPREAD_SD
    # Win condition: team covers its spread
    # home bet: actual_spread + point > 0  → P(actual_spread > -point)
    # away bet: -actual_spread + point > 0 → P(actual_spread < point)
    model_prob <- if (side == "home")
      pnorm(-point, mean = model_line, sd = sd, lower.tail = FALSE)
    else
      pnorm(point,  mean = model_line, sd = sd, lower.tail = TRUE)
  }

  if (is.na(bo$odds)) {
    message(sprintf("[bet_alerts/WNBA] No odds found for %s %s %s",
                    game_id, market, side))
    return(invisible(NULL))
  }

  # ── EV filter ────────────────────────────────────────────────────────────────

  implied_prob  <- .american_to_prob(bo$odds)
  ev_pct        <- (model_prob - implied_prob) / implied_prob * 100
  fair_odds     <- .prob_to_american(model_prob)
  kelly         <- .kelly_fraction(model_prob, bo$odds)

  if (is.na(ev_pct) || ev_pct < MIN_EV_PCT) {
    message(sprintf("[bet_alerts/WNBA] %s %s %s — EV=%.1f%% below threshold (%.1f%%)",
                    game_id, market, side, ev_pct %||% 0, MIN_EV_PCT))
    return(invisible(NULL))
  }

  # ── Metadata ─────────────────────────────────────────────────────────────────

  game_time_et <- tryCatch({
    format(with_tz(ymd_hms(meta$commence_time[1], tz = "UTC"), "America/New_York"),
           "%I:%M %p ET")
  }, error = function(e) NA_character_)

  snap_type <- tryCatch(
    dbGetQuery(con, "
      SELECT snapshot_type FROM lines WHERE game_id = ?
      ORDER BY pulled_at DESC LIMIT 1
    ", list(game_id))$snapshot_type[1],
    error = function(e) NA_character_
  )
  window <- switch(snap_type %||% "",
    "opener"  = "Opening",
    "midday"  = "Midday",
    "closing" = "Closing",
    "Live"
  )

  confidence <- if (steam_confirmed || ev_pct >= 6) "HIGH" else "MEDIUM"
  edge_str   <- sprintf("%+.1f%%", ev_pct)
  # Must convert to ET before taking the date — commence_time is UTC, and any
  # game tipping off after 8 PM ET is already past midnight UTC. Taking as.Date()
  # on the raw UTC timestamp silently rolls those games to "tomorrow", which
  # creates a second, distinct game_date for the same real-world bet — and since
  # open_bets' natural key includes game_date, that duplicate sails right past
  # the (game_date, away_team, home_team, bet_side, pipeline) dedup index instead
  # of being caught by it. Confirmed live 2026-07-10: Sky@Sparks (10:10 PM ET /
  # 02:10 UTC next day) posted twice, once per date value.
  game_date  <- tryCatch(
    format(with_tz(ymd_hms(meta$commence_time[1], tz = "UTC"), "America/New_York"), "%Y-%m-%d"),
    error = function(e) as.character(Sys.Date())
  )

  # ── Build + post alert ───────────────────────────────────────────────────────

  msg <- emit_broadcast(
    pipeline   = "WNBA",
    sport      = "WNBA",
    play       = play,
    teams      = sprintf("%s vs %s", away_team, home_team),
    book       = bo$book,
    odds       = bo$odds,
    fair_odds  = fair_odds,
    edge       = edge_str,
    ev         = edge_str,
    confidence = confidence,
    model_prob = model_prob,
    game_time  = game_time_et,
    window     = window
  )

  send_telegram(msg, creds)
  send_discord(msg, creds, channel_id = .BROADCAST_CHANNEL)

  # Write directly to open_bets.db — no Discord round-trip needed
  tryCatch({
    router_db <- "C:/Users/Mike/sports_data/open_bets.db"
    if (file.exists(router_db)) {
      rcon <- DBI::dbConnect(RSQLite::SQLite(), router_db)
      on.exit(DBI::dbDisconnect(rcon), add = TRUE)
      DBI::dbExecute(rcon, "
        INSERT OR IGNORE INTO open_bets
          (sport, pipeline, game_date, away_team, home_team,
           bet_side, odds, fair_odds, model_prob, ev_pct,
           game_time, status, fired_at, window, confidence, line_status,
           stake, kelly_fraction)
        VALUES
          ('WNBA','WNBA',?,?,?,?,?,?,?,?,?,'OPEN',datetime('now'),?,?,'CONFIRMED',?,?)
      ", list(
        game_date, away_team, home_team,
        play,
        if (!is.na(bo$odds))    as.integer(bo$odds)    else NA,
        if (!is.na(fair_odds))  as.integer(fair_odds)  else NA,
        if (!is.na(model_prob)) as.numeric(model_prob) else NA,
        if (!is.na(ev_pct))     as.numeric(ev_pct)     else NA,
        if (!is.na(game_time_et)) game_time_et          else NA,
        window, confidence,
        round(kelly * 100, 2), round(kelly, 4)
      ))
      message(sprintf("[bet_alerts/WNBA] -> open_bets: %s  %s @ %s", play, away_team, home_team))
    }
  }, error = function(e) {
    message("[bet_alerts/WNBA] open_bets direct write failed (non-fatal): ", e$message)
  })

  message(sprintf("[bet_alerts/WNBA] Alert posted: %s | %s | EV=%+.1f%%",
                  game_id, play, ev_pct))

  write_wnba_bet_history(
    game_date      = game_date,
    away_team      = away_team,
    home_team      = home_team,
    bet_side       = play,
    kelly_fraction = kelly,
    bet_amount     = kelly * 100   # Kelly units (bankroll = 100)
  )

  invisible(msg)
}

# ── BET_HISTORY CSV ───────────────────────────────────────────────────────────

write_wnba_bet_history <- function(game_date, away_team, home_team,
                                   bet_side, kelly_fraction = 0,
                                   bet_amount = kelly_fraction * 100) {
  dir.create(WNBA_EXPORTS_DIR, showWarnings = FALSE, recursive = TRUE)
  date_str <- format(as.Date(game_date), "%Y%m%d")
  csv_path <- file.path(WNBA_EXPORTS_DIR,
                        paste0("BET_HISTORY_WNBA_", date_str, ".csv"))

  row <- data.frame(
    away_team      = away_team,
    home_team      = home_team,
    game_date      = as.character(game_date),
    bet_side       = bet_side,
    kelly_fraction = round(kelly_fraction, 4),
    bet_amount     = round(bet_amount, 2),
    stringsAsFactors = FALSE
  )

  if (file.exists(csv_path)) {
    existing <- read.csv(csv_path, stringsAsFactors = FALSE)
    dup <- tolower(existing$away_team) == tolower(away_team) &
           tolower(existing$home_team) == tolower(home_team) &
           tolower(existing$bet_side)  == tolower(bet_side)
    if (any(dup)) {
      message("[bet_alerts/WNBA] BET_HISTORY duplicate — skipping: ", bet_side)
      return(invisible(csv_path))
    }
    row <- rbind(existing, row)
  }

  write.csv(row, csv_path, row.names = FALSE)
  message("[bet_alerts/WNBA] BET_HISTORY written: ", basename(csv_path))
  invisible(csv_path)
}
