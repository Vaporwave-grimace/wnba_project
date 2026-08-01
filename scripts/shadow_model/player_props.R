# scripts/shadow_model/player_props.R
# WNBA player props: rolling-average projections + opponent-defense
# adjustment, compared against live Odds API player-prop lines.
#
# Design doc: docs/superpowers/specs/2026-07-12-wnba-player-props-design.md
#
# Key functions:
#   sync_player_box_scores()  -- wehoop box score cache
#   compute_team_def_factors() -- opponent-allowed-stat factor
#   compute_prop_projection() -- rolling avg x def factor -> projected mean/sd
#   fetch_player_prop_odds()  -- Odds API per-event player prop pull
#   detect_prop_edges()       -- orchestrator, fires alerts via bet_alerts.R

library(wehoop)
library(dplyr)
library(DBI)
library(RSQLite)

ROLLING_WINDOW_GAMES     <- 10L
MIN_GAMES_FOR_DEF_FACTOR <- 5L
DEF_FACTOR_CLAMP         <- c(0.85, 1.15)

STAT_MARKET_MAP <- c(
  pts = "player_points",
  reb = "player_rebounds",
  ast = "player_assists",
  pra = "player_points_rebounds_assists"
)

# ── Box score sync ────────────────────────────────────────────────────────────

# Pulls the full season from wehoop every call (there's no incremental
# fetch available -- load_wnba_player_box() always returns the whole
# season) and INSERT OR IGNOREs against (game_id, player_name). Idempotent,
# no watermark, no gap risk.
sync_player_box_scores <- function(con, season = as.integer(format(Sys.Date(), "%Y"))) {
  message("[player_props] Syncing player box scores for season ", season)

  pb <- tryCatch(
    wehoop::load_wnba_player_box(seasons = season),
    error = function(e) {
      message("[player_props] wehoop fetch failed: ", e$message)
      NULL
    }
  )
  if (is.null(pb) || nrow(pb) == 0) return(invisible(0L))

  rows <- pb |>
    dplyr::transmute(
      game_id       = as.character(game_id),
      game_date     = as.character(game_date),
      player_name   = athlete_display_name,
      team          = team_display_name,
      opponent      = opponent_team_display_name,
      min           = suppressWarnings(as.numeric(minutes)),
      pts           = as.integer(points),
      reb           = as.integer(rebounds),
      ast           = as.integer(assists),
      team_abbr     = team_abbreviation,
      opponent_abbr = opponent_team_abbreviation,
      position      = athlete_position_abbreviation,
      home_away     = home_away,
      fga           = as.integer(field_goals_attempted),
      fta           = as.integer(free_throws_attempted),
      tov           = as.integer(turnovers)
    ) |>
    dplyr::filter(!is.na(player_name), !is.na(game_id))

  n_written <- 0L
  tryCatch({
    dbBegin(con)
    for (i in seq_len(nrow(rows))) {
      r <- rows[i, ]
      n_written <- n_written + dbExecute(con, "
        INSERT OR IGNORE INTO player_box_scores
          (game_id, game_date, player_name, team, opponent, min, pts, reb, ast,
           team_abbr, opponent_abbr, position, home_away, fga, fta, tov)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ", list(r$game_id, r$game_date, r$player_name, r$team, r$opponent,
              r$min, r$pts, r$reb, r$ast,
              r$team_abbr, r$opponent_abbr, r$position, r$home_away,
              r$fga, r$fta, r$tov))
    }
    dbCommit(con)
  }, error = function(e) {
    dbRollback(con)
    stop(e)
  })

  message(sprintf("[player_props] player_box_scores: %d new row(s) inserted (of %d fetched)",
                  n_written, nrow(rows)))
  invisible(n_written)
}

# ── Opponent defense factors ──────────────────────────────────────────────────

# Refreshes team_def_factors from player_box_scores. Grouped by each row's
# `opponent` column, NOT `team` -- a team's defense factor is what
# opposing players scored AGAINST them, not what their own players scored.
# ('opponent' reads ambiguous enough that a future edit could "fix" this
# to `team` without realizing that inverts the whole factor -- see the
# GROUP BY comment below.)
compute_team_def_factors <- function(con, season = as.integer(format(Sys.Date(), "%Y"))) {
  box <- dbGetQuery(con, "
    SELECT game_id, opponent, pts, reb, ast
    FROM player_box_scores
    WHERE game_date >= ? AND game_date <= ?
  ", list(paste0(season, "-01-01"), paste0(season, "-12-31")))

  if (nrow(box) == 0) {
    message("[player_props] No player_box_scores rows for season ", season)
    return(invisible(0L))
  }

  box$pra <- box$pts + box$reb + box$ast

  games_per_opp <- box |>
    dplyr::distinct(opponent, game_id) |>
    dplyr::count(opponent, name = "n_games")

  # defense factor: stat opponents scored AGAINST this team.
  agg <- box |>
    dplyr::group_by(opponent) |>          # GROUP BY opponent, not team -- see header comment
    dplyr::summarise(
      pts_allowed = mean(pts, na.rm = TRUE),
      reb_allowed = mean(reb, na.rm = TRUE),
      ast_allowed = mean(ast, na.rm = TRUE),
      pra_allowed = mean(pra, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::left_join(games_per_opp, by = "opponent")

  league_avg <- list(
    pts = mean(box$pts, na.rm = TRUE),
    reb = mean(box$reb, na.rm = TRUE),
    ast = mean(box$ast, na.rm = TRUE),
    pra = mean(box$pra, na.rm = TRUE)
  )

  n_written <- 0L
  for (i in seq_len(nrow(agg))) {
    row <- agg[i, ]
    for (stat in c("pts", "reb", "ast", "pra")) {
      allowed_avg <- row[[paste0(stat, "_allowed")]]
      la          <- league_avg[[stat]]

      factor <- if (row$n_games < MIN_GAMES_FOR_DEF_FACTOR ||
                    is.na(allowed_avg) || is.na(la) || la == 0) {
        1.0   # passthrough -- too few games to trust the sample
      } else {
        max(DEF_FACTOR_CLAMP[1], min(DEF_FACTOR_CLAMP[2], allowed_avg / la))
      }

      dbExecute(con, "
        INSERT OR REPLACE INTO team_def_factors
          (team, stat, allowed_avg, league_avg, factor, season, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
      ", list(row$opponent, stat, allowed_avg, la, factor, season))
      n_written <- n_written + 1L
    }
  }

  message(sprintf("[player_props] team_def_factors refreshed -- %d row(s) for season %d",
                  n_written, season))
  invisible(n_written)
}

.lookup_def_factor <- function(opponent, stat, con, season) {
  row <- dbGetQuery(con, "
    SELECT factor FROM team_def_factors WHERE team = ? AND stat = ? AND season = ?
  ", list(opponent, stat, season))
  if (nrow(row) == 0 || is.na(row$factor[1])) 1.0 else row$factor[1]
}

# ── Projection ─────────────────────────────────────────────────────────────────

# stat in {"pts","reb","ast","pra"}. Returns NULL if the player has fewer
# than 2 games logged (baseline_sd would be 0/NA -- see the zero-SD guard
# below; a degenerate SD feeding pnorm() is the same failure class as the
# injury_adj_cap incidents documented in CLAUDE.md).
compute_prop_projection <- function(player_name, stat, opponent, con,
                                    season = as.integer(format(Sys.Date(), "%Y"))) {
  stat <- tolower(stat)
  if (!stat %in% names(STAT_MARKET_MAP)) {
    stop("compute_prop_projection: stat must be one of pts/reb/ast/pra, got: ", stat)
  }

  games <- dbGetQuery(con, "
    SELECT game_date, pts, reb, ast
    FROM player_box_scores
    WHERE player_name = ?
    ORDER BY game_date DESC
  ", list(player_name))

  if (nrow(games) == 0) {
    message("[player_props] No game log for player: ", player_name)
    return(NULL)
  }

  stat_vals <- if (stat == "pra") games$pts + games$reb + games$ast else games[[stat]]

  n_avail     <- min(ROLLING_WINDOW_GAMES, length(stat_vals))
  window_vals <- stat_vals[seq_len(n_avail)]   # already DESC-ordered = most recent first

  baseline_mean <- mean(window_vals, na.rm = TRUE)
  baseline_sd   <- sd(window_vals, na.rm = TRUE)

  if (is.na(baseline_sd) || baseline_sd == 0) {
    message(sprintf("[player_props] Zero/NA SD for %s (%s) -- skipping (n=%d)",
                    player_name, stat, n_avail))
    return(NULL)
  }

  def_factor <- .lookup_def_factor(opponent, stat, con, season)

  list(
    player_name    = player_name,
    stat           = stat,
    opponent       = opponent,
    n_games        = n_avail,
    baseline_mean  = baseline_mean,
    baseline_sd    = baseline_sd,
    def_factor     = def_factor,
    projected_mean = baseline_mean * def_factor
  )
}

# ── Player prop odds fetch ────────────────────────────────────────────────────

PROP_MARKETS <- "player_points,player_rebounds,player_assists,player_points_rebounds_assists"

# One Odds API request per game (bulk endpoint doesn't support player
# props, same constraint MLB's 1st-inning markets hit). `game_ids` is
# supplied by the caller (run_pipeline.R already knows today's slate /
# near-tip games) rather than re-derived here, to avoid duplicating that
# lookup logic.
fetch_player_prop_odds <- function(con, game_ids, snapshot_type = "midday") {
  if (length(game_ids) == 0) {
    message("[player_props] No game_ids supplied -- nothing to fetch.")
    return(invisible(tibble::tibble()))
  }

  pulled_at <- format(lubridate::now("UTC"), "%Y-%m-%d %H:%M:%S")
  all_rows  <- list()

  for (gid in game_ids) {
    resp <- tryCatch(
      odds_request(
        path   = paste0("sports/", SPORT, "/events/", gid, "/odds"),
        params = list(regions = "us", markets = PROP_MARKETS, oddsFormat = "american")
      ),
      error = function(e) {
        message("[player_props] Odds API error for ", gid, ": ", e$message)
        NULL
      }
    )
    if (is.null(resp)) next

    game <- tryCatch(httr2::resp_body_json(resp, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(game) || length(game$bookmakers) == 0) next

    rows <- purrr::map_dfr(game$bookmakers, function(book) {
      purrr::map_dfr(book$markets, function(mkt) {
        purrr::map_dfr(mkt$outcomes, function(o) {
          tibble::tibble(
            game_id       = game$id,
            snapshot_type = snapshot_type,
            sport_key     = game$sport_key %||% SPORT,
            commence_time = game$commence_time,
            home_team     = game$home_team,
            away_team     = game$away_team,
            bookmaker     = book$key,
            market        = mkt$key,
            player_name   = o$description %||% NA_character_,
            outcome_name  = o$name,
            price         = o$price %||% NA_real_,
            point         = o$point %||% NA_real_,
            pulled_at     = pulled_at
          )
        })
      })
    })
    all_rows[[gid]] <- rows
  }

  odds_df <- dplyr::bind_rows(all_rows)
  if (nrow(odds_df) == 0) {
    message("[player_props] No player prop rows returned for any game.")
    return(invisible(odds_df))
  }

  for (i in seq_len(nrow(odds_df))) {
    row <- odds_df[i, ]
    dbExecute(con, "
      INSERT OR REPLACE INTO player_prop_lines
        (game_id, snapshot_type, sport_key, commence_time, home_team, away_team,
         bookmaker, market, player_name, outcome_name, price, point, pulled_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    ", unname(as.list(row)))
  }

  message(sprintf("[player_props] Saved %d prop line row(s) across %d game(s) [%s].",
                  nrow(odds_df), length(unique(odds_df$game_id)), snapshot_type))
  invisible(odds_df)
}

# ── Orchestrator ───────────────────────────────────────────────────────────────

# For every (game, player, stat) with a posted line in player_prop_lines,
# compute a projection and evaluate both Over and Under. emit_wnba_bet_alert()
# handles the EV filter and Kelly sizing -- this function's job is just to
# figure out each player's opponent and hand off model_line/sd.
#
# `datetime(commence_time) > datetime('now')` guards against stale candidates
# (both sides wrapped in datetime() to normalize commence_time's ISO8601
# "T...Z" format against datetime('now')'s space-separated one -- raw string
# comparison between the two looks right for cross-day cases but silently
# breaks for same-day ones, e.g. a game that already tipped off 8 hours ago
# today still compares as "future" because 'T' > ' ' lexicographically at
# that character position, regardless of the actual clock time on either
# side). Rows never get deleted from player_prop_lines, so without this a completed
# game's old book line gets compared against today's *updated* rolling
# average, producing fake "edges" that are pure staleness artifacts (not a
# real mispricing). Previously this was only prevented by run_pipeline.R's
# caller-side today_game_ids/near_tip_games gating, not by this function
# itself -- confirmed live 2026-07-25: a direct manual call to the sibling
# function send_prop_digest() (same unfiltered query, bypassing that outer
# gate) evaluated 20 games back to 07-13 and produced 370 fake "edges."
# Added here so both callers are safe even if invoked directly.

# Pure, side-effect-free: groups dry-run-evaluated candidates by
# (game_id, player_name, side) and keeps only the max-ev_pct row per group.
# pra = pts+reb+ast exactly, so a bias in one stat shows up across all four --
# this collapses that redundancy down to the single highest-EV derivative.
# Single-player correlation collapse: yield a maximum of 1 play per player
# per slate (prioritizing highest EV prop edge overall). No DB/network access --
# kept standalone specifically so it's directly unit-testable against a
# synthetic data frame.
.collapse_correlated_prop_edges <- function(evaluated_df) {
  evaluated_df |>
    dplyr::group_by(player_name) |>
    dplyr::slice_max(ev_pct, n = 1, with_ties = FALSE) |>
    dplyr::ungroup()
}

detect_prop_edges <- function(con, creds, send_alerts = TRUE,
                              season = as.integer(format(Sys.Date(), "%Y"))) {
  candidates <- dbGetQuery(con, "
    SELECT DISTINCT ppl.game_id, ppl.player_name, ppl.market,
           ppl.home_team, ppl.away_team
    FROM player_prop_lines ppl
    WHERE ppl.snapshot_type = (
      SELECT snapshot_type FROM player_prop_lines ppl2
      WHERE ppl2.game_id = ppl.game_id
      ORDER BY pulled_at DESC LIMIT 1
    )
    AND (ppl.commence_time IS NULL OR datetime(ppl.commence_time) BETWEEN datetime('now', '-2 hours') AND datetime('now', '+24 hours'))
    AND ppl.player_name IS NOT NULL
    AND TRIM(ppl.player_name) NOT IN ('', 'Unknown Player', 'Unknown', 'N/A')
  ")

  if (nrow(candidates) == 0) {
    message("[player_props] No prop line candidates to evaluate.")
    return(invisible(0L))
  }

  # ── Pass 1: dry-run every candidate/side, never firing ──────────────────────
  # Reuses emit_wnba_bet_alert()'s send_alerts=FALSE side-effect-free contract
  # (the same one send_prop_digest() already depends on) so this pass can
  # never write to open_bets/BET_HISTORY or post to Discord/Telegram.
  evaluated <- list()
  for (i in seq_len(nrow(candidates))) {
    row  <- candidates[i, ]
    stat <- names(STAT_MARKET_MAP)[STAT_MARKET_MAP == row$market]
    if (length(stat) == 0) next

    player_team <- dbGetQuery(con, "
      SELECT team FROM player_box_scores WHERE player_name = ?
      ORDER BY game_date DESC LIMIT 1
    ", list(row$player_name))$team[1]

    opponent <- if (!is.na(player_team) && identical(player_team, row$home_team)) {
      row$away_team
    } else if (!is.na(player_team) && identical(player_team, row$away_team)) {
      row$home_team
    } else {
      ""   # unknown team assignment -- .lookup_def_factor() passes through at 1.0
    }

    proj <- compute_prop_projection(row$player_name, stat, opponent, con, season)
    if (is.null(proj)) next

    for (side in c("over", "under")) {
      res <- tryCatch(
        emit_wnba_bet_alert(
          game_id     = row$game_id,
          market      = "prop",
          side        = side,
          model_line  = proj$projected_mean,
          mkt_line    = NA_real_,
          con         = con,
          creds       = creds,
          player_name = row$player_name,
          stat        = stat,
          sd          = proj$baseline_sd,
          send_alerts = FALSE
        ),
        error = function(e) {
          message("[player_props] dry-run error for ", row$player_name, " ", stat, " ", side,
                  ": ", e$message)
          NULL
        }
      )
      if (is.null(res) || is.null(res$play) || is.na(res$ev_pct)) next

      evaluated[[length(evaluated) + 1]] <- data.frame(
        game_id     = row$game_id,
        player_name = row$player_name,
        stat        = stat,
        side        = side,
        ev_pct      = res$ev_pct,
        model_line  = proj$projected_mean,
        sd          = proj$baseline_sd,
        stringsAsFactors = FALSE
      )
    }
  }

  if (length(evaluated) == 0) {
    message("[player_props] detect_prop_edges: no candidates cleared EV threshold.")
    return(invisible(0L))
  }

  # ── Pass 2: collapse correlated same-player/game/side picks ─────────────────
  winners <- .collapse_correlated_prop_edges(dplyr::bind_rows(evaluated))

  # ── Pass 3: real-fire only the winners ──────────────────────────────────────
  n_fired <- 0L
  for (i in seq_len(nrow(winners))) {
    w <- winners[i, ]
    res <- tryCatch(
      emit_wnba_bet_alert(
        game_id     = w$game_id,
        market      = "prop",
        side        = w$side,
        model_line  = w$model_line,
        mkt_line    = NA_real_,
        con         = con,
        creds       = creds,
        player_name = w$player_name,
        stat        = w$stat,
        sd          = w$sd,
        send_alerts = send_alerts
      ),
      error = function(e) {
        message("[player_props] alert error for ", w$player_name, " ", w$stat, " ", w$side,
                ": ", e$message)
        NULL
      }
    )
    if (!is.null(res) && isTRUE(res$fired)) n_fired <- n_fired + 1L
  }

  message(sprintf("[player_props] detect_prop_edges complete -- %d alert(s) fired", n_fired))
  invisible(n_fired)
}

# ── Daily curated digest ───────────────────────────────────────────────────────
#
# Posts one plain-text summary of today's best currently-live prop edges
# (>= min_ev) to Discord. Reuses the exact same candidate query and
# projection/EV computation as detect_prop_edges() -- the only differences
# are send_alerts = FALSE (no individual alert fires, no open_bets write, no
# BET_HISTORY write -- all gated behind emit_wnba_bet_alert()'s own
# `if (send_alerts)` block) and collecting every evaluated edge instead of
# just counting fired ones.
#
# Does NOT call emit_broadcast() -- that produces the structured "PIPELINE:
# WNBA" block bet_router auto-ingests from #auto-bet-broadcast. Reusing it
# here would create duplicate open_bets rows for picks already logged by the
# original real-time alert. This posts a plain string via send_discord()
# instead, which bet_router's parser does not match.
send_prop_digest <- function(con, creds, min_ev = 6.0,
                             season = as.integer(format(Sys.Date(), "%Y"))) {
  # commence_time filter -- see the matching comment on detect_prop_edges()'s
  # identical query above; this sibling had the same gap and is what actually
  # produced the 370-fake-pick incident (2026-07-25) when called directly.
  candidates <- dbGetQuery(con, "
    SELECT DISTINCT ppl.game_id, ppl.player_name, ppl.market,
           ppl.home_team, ppl.away_team
    FROM player_prop_lines ppl
    WHERE ppl.snapshot_type = (
      SELECT snapshot_type FROM player_prop_lines ppl2
      WHERE ppl2.game_id = ppl.game_id
      ORDER BY pulled_at DESC LIMIT 1
    )
    AND (ppl.commence_time IS NULL OR datetime(ppl.commence_time) BETWEEN datetime('now', '-2 hours') AND datetime('now', '+24 hours'))
    AND ppl.player_name IS NOT NULL
    AND TRIM(ppl.player_name) NOT IN ('', 'Unknown Player', 'Unknown')
  ")

  if (nrow(candidates) == 0) {
    message("[player_props] Digest: no prop line candidates to evaluate.")
    return(invisible(0L))
  }

  evaluated <- list()
  for (i in seq_len(nrow(candidates))) {
    row  <- candidates[i, ]
    stat <- names(STAT_MARKET_MAP)[STAT_MARKET_MAP == row$market]
    if (length(stat) == 0) next

    player_team <- dbGetQuery(con, "
      SELECT team FROM player_box_scores WHERE player_name = ?
      ORDER BY game_date DESC LIMIT 1
    ", list(row$player_name))$team[1]

    opponent <- if (!is.na(player_team) && identical(player_team, row$home_team)) {
      row$away_team
    } else if (!is.na(player_team) && identical(player_team, row$away_team)) {
      row$home_team
    } else {
      ""
    }

    proj <- compute_prop_projection(row$player_name, stat, opponent, con, season)
    if (is.null(proj)) next

    for (side in c("over", "under")) {
      res <- tryCatch(
        emit_wnba_bet_alert(
          game_id     = row$game_id,
          market      = "prop",
          side        = side,
          model_line  = proj$projected_mean,
          mkt_line    = NA_real_,
          con         = con,
          creds       = creds,
          player_name = row$player_name,
          stat        = stat,
          sd          = proj$baseline_sd,
          send_alerts = FALSE
        ),
        error = function(e) {
          message("[player_props] Digest eval error for ", row$player_name, " ", stat, " ", side,
                  ": ", e$message)
          NULL
        }
      )
      if (!is.null(res) && !is.null(res$play) && !is.null(res$ev_pct) && !is.na(res$ev_pct) && res$ev_pct >= min_ev) {
        evaluated[[length(evaluated) + 1L]] <- data.frame(
          game_id     = row$game_id,
          player_name = row$player_name,
          stat        = stat,
          side        = side,
          ev_pct      = res$ev_pct,
          play        = res$play,
          fair_odds   = res$fair_odds,
          stringsAsFactors = FALSE
        )
      }
    }
  }

  if (length(evaluated) == 0) {
    message(sprintf("[player_props] Digest: no edges >= %.1f%% EV today.", min_ev))
    return(invisible(0L))
  }

  # Collapse correlated same-player picks down to max 1 per player
  winners <- .collapse_correlated_prop_edges(dplyr::bind_rows(evaluated))
  winners <- winners[order(winners$ev_pct, decreasing = TRUE), ]

  lines_out <- vapply(seq_len(nrow(winners)), function(i) {
    w <- winners[i, ]
    sprintf("%d. %s — Fair %+d | Edge %+.1f%%", i, w$play, as.integer(w$fair_odds), w$ev_pct)
  }, character(1))

  header <- sprintf("📋 **WNBA Daily Top Props** — %s (%d pick%s ≥%.0f%% EV)",
                    format(lubridate::with_tz(Sys.time(), "America/New_York"), "%I:%M %p ET"), nrow(winners),
                    if (nrow(winners) == 1) "" else "s", min_ev)

  msg <- paste(c(header, lines_out), collapse = "\n")

  tryCatch(
    send_discord(msg, creds, channel_id = .BROADCAST_CHANNEL),
    error = function(e) message("[player_props] Digest Discord send failed: ", e$message)
  )

  message(sprintf("[player_props] Digest sent -- %d pick(s) >= %.1f%% EV", nrow(winners), min_ev))
  invisible(nrow(winners))
}
