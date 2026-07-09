# scripts/shadow_model/calibrate_mispricing.R
# Morning auto-calibration for the Pinnacle-deviation mispricing model.
#
# Workflow:
#   1. fill_mispricing_clv()      — attach actual_total to clv_log mispricing rows
#   2. sweep_dev_threshold()      — grid search optimal DEV_THRESHOLD
#   3. auto_apply_dev_threshold() — guardrailed upsert to model_config
#   4. calibrate_injury_impact()  — directional accuracy of injury adjustments
#   5. calibrate_mispricing_run() — morning orchestrator (called from run_pipeline.R)
#
# Guardrails mirror the MLB pipeline pattern:
#   MIN_N_APPLY=30, MIN_WR_IMPROVEMENT=0.02, MAX_THRESHOLD_DELTA=0.5

library(dplyr)
library(purrr)
library(DBI)
library(RSQLite)
library(httr2)

# ROI at standard -110 juice (decimal = 100/110 = 0.909 payout per dollar wagered)
JUICE_DECIMAL      <- 1.9091   # $1 wagered returns $1.9091 if won
MIN_N_APPLY        <- 30L
MIN_WR_IMPROVEMENT <- 0.02     # 2 pp win-rate uplift required before applying
MAX_THRESHOLD_DELTA <- 0.5     # max change in DEV_THRESHOLD per calibration run

# ── DB helpers ────────────────────────────────────────────────────────────────

.set_config_param <- function(con, param, value, n_games = NULL,
                               wr_before = NULL, wr_after = NULL, notes = NULL) {
  dbExecute(con, "
    INSERT INTO model_config (param, value, updated_at, n_games, brier_before,
                               brier_after, notes)
    VALUES (?, ?, datetime('now'), ?, ?, ?, ?)
    ON CONFLICT(param) DO UPDATE SET
      value      = excluded.value,
      updated_at = excluded.updated_at,
      n_games    = excluded.n_games,
      brier_before = excluded.brier_before,
      brier_after  = excluded.brier_after,
      notes      = excluded.notes
  ", list(param, value, n_games, wr_before, wr_after, notes))
  message(sprintf("[calibrate] model_config '%s' → %.3f  (n=%s)", param,
                  value, if (!is.null(n_games)) n_games else "?"))
}

# ── CLV fill ──────────────────────────────────────────────────────────────────

# Back-fill closing_line on clv_log rows from mispricing trigger using
# game_outcomes.actual_total. Returns number of rows updated.

fill_mispricing_clv <- function(con) {
  n <- tryCatch(
    dbExecute(con, "
      UPDATE clv_log
      SET closing_line = (
        SELECT go.actual_total
        FROM game_outcomes go
        WHERE go.game_id = clv_log.game_id
        LIMIT 1
      )
      WHERE trigger = 'mispricing'
        AND market    = 'totals'
        AND closing_line IS NULL
        AND game_id IN (SELECT game_id FROM game_outcomes)
    "),
    error = \(e) {
      message("[calibrate] fill_mispricing_clv error: ", e$message)
      0L
    }
  )
  message(sprintf("[calibrate] fill_mispricing_clv: %d row(s) updated", n))
  invisible(n)
}

# ── Backtest ──────────────────────────────────────────────────────────────────

# Replay historical lines vs actual totals to evaluate a given threshold.
# Returns a tibble with one row per (game_id, bookmaker) evaluation where a
# mispricing >= threshold was detected for the "totals" market.
#
# Columns: game_id, adj_pin, soft_book, soft_line, deviation, side, actual, won

backtest_mispricing <- function(con, threshold = 1.5) {
  # Pull all available game_outcomes joined to the lines table
  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT l.game_id, l.bookmaker, l.snapshot_type,
             l.point AS soft_point, l.outcome_name,
             go.actual_total
      FROM lines l
      JOIN game_outcomes go ON l.game_id = go.game_id
      WHERE l.market   = 'totals'
        AND l.bookmaker != 'pinnacle'
        AND l.point    IS NOT NULL
        AND go.actual_total IS NOT NULL
    "),
    error = function(e) {
      message("[calibrate] backtest query error: ", e$message)
      data.frame()
    }
  )

  if (nrow(rows) == 0) {
    message("[calibrate] backtest_mispricing: no data — game_outcomes may be empty")
    return(tibble())
  }

  # Pinnacle reference per game
  pin <- tryCatch(
    dbGetQuery(con, "
      SELECT DISTINCT game_id, point AS pin_point
      FROM lines
      WHERE bookmaker = 'pinnacle' AND market = 'totals' AND point IS NOT NULL
    "),
    error = \(e) data.frame()
  )

  if (nrow(pin) == 0) {
    message("[calibrate] No Pinnacle totals lines found")
    return(tibble())
  }

  rows <- rows |>
    left_join(pin, by = "game_id") |>
    filter(!is.na(pin_point)) |>
    mutate(
      deviation = soft_point - pin_point,
      side      = if_else(deviation > 0, "under", "over"),
      won       = case_when(
        abs(deviation) < threshold            ~ NA,    # below threshold — skip
        side == "under" & actual_total < pin_point ~ TRUE,
        side == "over"  & actual_total > pin_point ~ TRUE,
        TRUE                                          ~ FALSE
      )
    ) |>
    filter(!is.na(won), abs(deviation) >= threshold) |>
    select(game_id, adj_pin = pin_point, soft_book = bookmaker,
           soft_line = soft_point, deviation, side, actual = actual_total, won)

  message(sprintf("[calibrate] backtest_mispricing(threshold=%.2f): %d qualifying rows",
                  threshold, nrow(rows)))
  as_tibble(rows)
}

# ── Grid sweep ────────────────────────────────────────────────────────────────

# Sweep DEV_THRESHOLD over a grid; return win rate and ROI at each step.
# min_n = minimum qualifying bets to report a grid point.

sweep_dev_threshold <- function(con,
                                grid   = seq(0.5, 3.0, by = 0.25),
                                min_n  = 20L) {
  map_dfr(grid, function(thr) {
    bt <- tryCatch(backtest_mispricing(con, threshold = thr), error = \(e) tibble())
    if (nrow(bt) == 0) return(tibble())

    # Deduplicate: one bet per game (best deviation)
    bt_dedup <- bt |>
      group_by(game_id) |>
      arrange(desc(abs(deviation))) |>
      slice(1) |>
      ungroup()

    n  <- nrow(bt_dedup)
    if (n < min_n) return(tibble())

    wr  <- mean(bt_dedup$won, na.rm = TRUE)
    roi <- wr * (JUICE_DECIMAL - 1) - (1 - wr)
    tibble(threshold = thr, n = n, win_rate = wr, roi = roi)
  })
}

# ── Auto-apply ────────────────────────────────────────────────────────────────

# Apply optimal DEV_THRESHOLD if guardrails pass.
# current_wr and sweep_results come from sweep_dev_threshold().

auto_apply_dev_threshold <- function(con, sweep_results,
                                     current_threshold = 1.5,
                                     current_wr        = NULL,
                                     min_n             = MIN_N_APPLY,
                                     min_improvement   = MIN_WR_IMPROVEMENT,
                                     max_delta         = MAX_THRESHOLD_DELTA) {
  if (is.null(sweep_results) || nrow(sweep_results) == 0) {
    message("[calibrate] auto_apply: no sweep results")
    return(invisible(FALSE))
  }

  best <- sweep_results |>
    filter(n >= min_n) |>
    arrange(desc(win_rate)) |>
    slice(1)

  if (nrow(best) == 0) {
    message(sprintf("[calibrate] auto_apply: no grid point has n >= %d", min_n))
    return(invisible(FALSE))
  }

  opt_thr <- best$threshold[1]
  opt_wr  <- best$win_rate[1]
  n_games <- best$n[1]

  if (!is.null(current_wr) && (opt_wr - current_wr) < min_improvement) {
    message(sprintf(
      "[calibrate] auto_apply: skip — optimal WR %.3f vs current %.3f (need +%.2f pp improvement)",
      opt_wr, current_wr, min_improvement))
    return(invisible(FALSE))
  }

  if (abs(opt_thr - current_threshold) > max_delta) {
    # Apply incrementally
    direction <- sign(opt_thr - current_threshold)
    opt_thr   <- current_threshold + direction * max_delta
    message(sprintf("[calibrate] auto_apply: capping delta to %.1f pts → new threshold %.2f",
                    max_delta, opt_thr))
  }

  .set_config_param(
    con, "dev_threshold", opt_thr,
    n_games  = n_games,
    wr_before = current_wr,
    wr_after  = opt_wr,
    notes = sprintf("auto-calibrated from backtest sweep, best WR=%.3f", opt_wr)
  )
  invisible(TRUE)
}

# ── Steam threshold backtest + calibration (V1: totals only) ─────────────────
#
# Same rationale as the mispricing model's own totals-first scope: spreads
# need the win-check to account for which team's outcome_name moved, which
# isn't validated yet. Totals first; spreads once totals confirms the approach.
#
# Replays historical opener->midday and midday->closing line movements from
# the raw `lines` table (not `steam_movements`, which only reflects whatever
# threshold was live at capture time) at a given (min_move, min_books) grid
# point, using SHARP_BOOKS only, then checks whether betting the confirmed
# direction would have won against game_outcomes.actual_total.

MAX_STEAM_MOVE_DELTA  <- 0.5   # max change in steam_min_move per calibration run
MAX_STEAM_BOOKS_DELTA <- 1L    # max change in steam_min_books per calibration run

#' Backtest steam accuracy at a given threshold for the totals market.
#' Returns tibble: game_id, direction, point_at_alert, actual_total, won.
backtest_steam <- function(con, min_move = 0.5, min_books = 2L) {
  # outcome_name filter is required: totals carries both "Over" and "Under"
  # rows sharing the same point value. Without filtering to one, the join
  # below becomes many-to-many (2 early rows x 2 late rows per book) and
  # silently double/quad-counts every movement. Mirrors detect_steam()'s own
  # join keys in odds_ingest.R, which include outcome_name for this reason.
  lines_df <- tryCatch(
    dbGetQuery(con, "
      SELECT game_id, snapshot_type, bookmaker, point
      FROM lines
      WHERE market = 'totals'
        AND bookmaker IN ('pinnacle', 'betonlineag', 'lowvig')
        AND outcome_name = 'Over'
        AND point IS NOT NULL
    ") |> as_tibble(),
    error = \(e) tibble()
  )
  if (nrow(lines_df) == 0) return(tibble())

  outcomes <- tryCatch(
    dbGetQuery(con,
      "SELECT game_id, actual_total FROM game_outcomes WHERE actual_total IS NOT NULL"
    ) |> as_tibble(),
    error = \(e) tibble()
  )
  if (nrow(outcomes) == 0) return(tibble())

  # One comparison window: early snapshot vs. late snapshot, sharp books only.
  eval_pair <- function(early_type, late_type) {
    early <- lines_df |> filter(snapshot_type == early_type) |>
      select(game_id, bookmaker, point_early = point)
    late  <- lines_df |> filter(snapshot_type == late_type) |>
      select(game_id, bookmaker, point_late = point)

    moves <- inner_join(early, late, by = c("game_id", "bookmaker"),
                        relationship = "one-to-one") |>
      mutate(move = point_late - point_early) |>
      filter(abs(move) >= min_move)

    if (nrow(moves) == 0) return(tibble())

    moves |>
      mutate(direction = if_else(move > 0, "up", "down")) |>
      group_by(game_id, direction) |>
      summarise(books_moved = n(), point_at_alert = mean(point_late), .groups = "drop") |>
      filter(books_moved >= min_books)
  }

  # opener->midday and midday->closing are independent signal opportunities
  # (each would fire its own alert_steam_flags() call live) — don't dedupe
  # across them, evaluate each on its own like the live system would.
  signals <- bind_rows(
    eval_pair("opener", "midday"),
    eval_pair("midday", "closing")
  )
  if (nrow(signals) == 0) return(tibble())

  signals |>
    inner_join(outcomes, by = "game_id") |>
    mutate(
      won = case_when(
        direction == "down" ~ actual_total < point_at_alert,
        direction == "up"   ~ actual_total > point_at_alert,
        TRUE                ~ NA
      )
    ) |>
    filter(!is.na(won)) |>
    select(game_id, direction, point_at_alert, actual_total, won)
}

#' Grid sweep over (min_move, min_books). Returns win rate/ROI per grid point
#' with n >= min_n qualifying signals.
sweep_steam_thresholds <- function(con,
                                   move_grid  = seq(0.25, 1.5, by = 0.25),
                                   books_grid = c(2L, 3L),
                                   min_n      = 20L) {
  grid <- expand.grid(min_move = move_grid, min_books = books_grid)
  map_dfr(seq_len(nrow(grid)), function(i) {
    mv <- grid$min_move[i]; bk <- grid$min_books[i]
    bt <- tryCatch(backtest_steam(con, min_move = mv, min_books = bk), error = \(e) tibble())
    if (nrow(bt) == 0 || nrow(bt) < min_n) return(tibble())

    wr  <- mean(bt$won, na.rm = TRUE)
    roi <- wr * (JUICE_DECIMAL - 1) - (1 - wr)
    tibble(min_move = mv, min_books = bk, n = nrow(bt), win_rate = wr, roi = roi)
  })
}

#' Apply optimal (min_move, min_books) if guardrails pass. Same guardrail
#' philosophy as auto_apply_dev_threshold(): min_n, min_improvement, capped
#' per-run delta on each param independently.
auto_apply_steam_thresholds <- function(con, sweep_results,
                                        current_move    = STEAM_MIN_MOVE,
                                        current_books   = STEAM_MIN_BOOKS,
                                        current_wr      = NULL,
                                        min_n           = MIN_N_APPLY,
                                        min_improvement = MIN_WR_IMPROVEMENT) {
  if (is.null(sweep_results) || nrow(sweep_results) == 0) {
    message("[calibrate] steam auto_apply: no sweep results")
    return(invisible(FALSE))
  }

  best <- sweep_results |> filter(n >= min_n) |> arrange(desc(win_rate)) |> slice(1)
  if (nrow(best) == 0) {
    message(sprintf("[calibrate] steam auto_apply: no grid point has n >= %d", min_n))
    return(invisible(FALSE))
  }

  opt_move  <- best$min_move[1]
  opt_books <- best$min_books[1]
  opt_wr    <- best$win_rate[1]
  n_games   <- best$n[1]

  if (!is.null(current_wr) && (opt_wr - current_wr) < min_improvement) {
    message(sprintf(
      "[calibrate] steam auto_apply: skip — optimal WR %.3f vs current %.3f (need +%.2f pp improvement)",
      opt_wr, current_wr, min_improvement))
    return(invisible(FALSE))
  }

  if (abs(opt_move - current_move) > MAX_STEAM_MOVE_DELTA) {
    opt_move <- current_move + sign(opt_move - current_move) * MAX_STEAM_MOVE_DELTA
    message(sprintf("[calibrate] steam auto_apply: capping min_move delta → %.2f", opt_move))
  }
  if (abs(opt_books - current_books) > MAX_STEAM_BOOKS_DELTA) {
    opt_books <- current_books + sign(opt_books - current_books) * MAX_STEAM_BOOKS_DELTA
    message(sprintf("[calibrate] steam auto_apply: capping min_books delta → %d", opt_books))
  }

  .set_config_param(con, "steam_min_move", opt_move, n_games = n_games,
                    wr_before = current_wr, wr_after = opt_wr,
                    notes = sprintf("auto-calibrated from backtest sweep, best WR=%.3f", opt_wr))
  .set_config_param(con, "steam_min_books", opt_books, n_games = n_games,
                    wr_before = current_wr, wr_after = opt_wr,
                    notes = sprintf("auto-calibrated from backtest sweep, best WR=%.3f", opt_wr))
  invisible(TRUE)
}

# ── Injury impact calibration ─────────────────────────────────────────────────

# Evaluate whether injury-adjusted lines moved in the right direction vs actuals.
# For each settled game where injuries were recorded in clv_log detail:
#   predicted_direction = sign(injury_adj) → expect fewer/more points
#   actual_direction    = actual_total - pinnacle_point (before adjustment)
# Returns directional accuracy per status tier.

calibrate_injury_impact <- function(con, min_n = 20L) {
  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT cl.game_id, cl.clv AS gate_passed, cl.closing_line AS actual_total,
             cl.model_line AS adj_pin, go.actual_total AS true_total
      FROM clv_log cl
      JOIN game_outcomes go ON cl.game_id = go.game_id
      WHERE cl.trigger   = 'mispricing'
        AND cl.market    = 'totals'
        AND cl.gate_passed = 1
        AND cl.model_line IS NOT NULL
        AND go.actual_total IS NOT NULL
    "),
    error = function(e) {
      message("[calibrate] injury impact query error: ", e$message)
      data.frame()
    }
  )

  if (nrow(rows) < min_n) {
    message(sprintf(
      "[calibrate] calibrate_injury_impact: only %d rows (need %d) — skipping",
      nrow(rows), min_n))
    return(invisible(NULL))
  }

  rows <- rows |>
    mutate(
      # adj_pin already has the injury adjustment baked in; pinnacle_raw = adj_pin - adj
      # We can't recover the exact per-player adj from clv_log, so we measure
      # whether the ALERT direction was correct (which IS the injury-adjusted side).
      alert_correct = (true_total < adj_pin)  # gate_passed rows are "under" side bets
    )

  wr <- mean(rows$alert_correct, na.rm = TRUE)
  n  <- nrow(rows)

  message(sprintf(
    "[calibrate] injury_impact: %d alerted totals bets, WR = %.1f%%",
    n, wr * 100))

  # If directional accuracy is low, the injury constants may be off.
  # For now, log a warning — threshold auto-tune covers most of this already.
  if (wr < 0.48) {
    message("[calibrate] WARNING: injury-adjusted under bets < 48% WR — ",
            "consider reducing INJURY_IMPACT constants")
  }

  invisible(tibble(n = n, win_rate = wr))
}

# ── Morning orchestrator ──────────────────────────────────────────────────────

# Called from run_pipeline.R during SETTLE_HOUR step (morning calibration).
# Fills CLV, runs sweep, applies if guardrails pass, evaluates injury accuracy.

calibrate_mispricing_run <- function(con, creds = NULL, send_alert = FALSE) {
  message("[calibrate] Starting mispricing calibration run")

  fill_mispricing_clv(con)

  current_threshold <- tryCatch(
    dbGetQuery(con,
      "SELECT value FROM model_config WHERE param = 'dev_threshold'")$value[1],
    error = \(e) 1.5
  ) %||% 1.5

  # Baseline win rate at current threshold
  bt_current <- tryCatch(
    backtest_mispricing(con, threshold = current_threshold),
    error = \(e) tibble()
  )
  current_wr <- if (nrow(bt_current) > 0) mean(bt_current$won, na.rm = TRUE) else NULL

  # Sweep
  sweep <- tryCatch(
    sweep_dev_threshold(con, grid = seq(0.5, 3.0, by = 0.25), min_n = 20L),
    error = \(e) tibble()
  )

  if (nrow(sweep) > 0) {
    message("[calibrate] Threshold sweep results:")
    walk(seq_len(nrow(sweep)), function(i) {
      message(sprintf("  thr=%.2f  n=%d  WR=%.1f%%  ROI=%+.1f%%",
                      sweep$threshold[i], sweep$n[i],
                      sweep$win_rate[i] * 100, sweep$roi[i] * 100))
    })

    applied <- auto_apply_dev_threshold(
      con, sweep,
      current_threshold = current_threshold,
      current_wr        = current_wr
    )
  } else {
    applied <- FALSE
    message("[calibrate] No sweep results — insufficient data")
  }

  # ── Steam thresholds (totals only, V1) ────────────────────────────────────
  current_steam_move <- tryCatch(
    dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'steam_min_move'")$value[1],
    error = \(e) STEAM_MIN_MOVE
  ) %||% STEAM_MIN_MOVE
  current_steam_books <- tryCatch(
    dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'steam_min_books'")$value[1],
    error = \(e) STEAM_MIN_BOOKS
  ) %||% STEAM_MIN_BOOKS

  bt_steam_current <- tryCatch(
    backtest_steam(con, min_move = current_steam_move, min_books = current_steam_books),
    error = \(e) tibble()
  )
  current_steam_wr <- if (nrow(bt_steam_current) > 0) mean(bt_steam_current$won, na.rm = TRUE) else NULL

  steam_sweep <- tryCatch(
    sweep_steam_thresholds(con, min_n = 20L),
    error = \(e) tibble()
  )

  steam_applied <- FALSE
  if (nrow(steam_sweep) > 0) {
    message("[calibrate] Steam threshold sweep results:")
    walk(seq_len(nrow(steam_sweep)), function(i) {
      message(sprintf("  move>=%.2f books>=%d  n=%d  WR=%.1f%%  ROI=%+.1f%%",
                      steam_sweep$min_move[i], steam_sweep$min_books[i], steam_sweep$n[i],
                      steam_sweep$win_rate[i] * 100, steam_sweep$roi[i] * 100))
    })

    steam_applied <- auto_apply_steam_thresholds(
      con, steam_sweep,
      current_move  = current_steam_move,
      current_books = current_steam_books,
      current_wr    = current_steam_wr
    )
  } else {
    message("[calibrate] No steam sweep results — insufficient data ",
            "(expected until Pinnacle data accumulates post-2026-07-09 region fix)")
  }

  calibrate_injury_impact(con, min_n = 20L)

  if (send_alert && !is.null(creds)) {
    new_thr <- tryCatch(
      dbGetQuery(con,
        "SELECT value FROM model_config WHERE param = 'dev_threshold'")$value[1],
      error = \(e) current_threshold
    ) %||% current_threshold

    new_steam_move <- tryCatch(
      dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'steam_min_move'")$value[1],
      error = \(e) current_steam_move
    ) %||% current_steam_move
    new_steam_books <- tryCatch(
      dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'steam_min_books'")$value[1],
      error = \(e) current_steam_books
    ) %||% current_steam_books

    n_total <- if (nrow(sweep) > 0) max(sweep$n, na.rm = TRUE) else 0L
    n_steam_total <- if (nrow(steam_sweep) > 0) max(steam_sweep$n, na.rm = TRUE) else 0L
    msg <- paste0(
      "\U1F4CA *WNBA Mispricing Calibration*\n",
      sprintf("Threshold: %.2f pts %s\n", new_thr,
              if (applied) sprintf("(updated from %.2f)", current_threshold) else "(unchanged)"),
      if (!is.null(current_wr)) sprintf("Current WR: %.1f%%\n", current_wr * 100) else "",
      if (nrow(sweep) > 0) {
        best_row <- slice_max(sweep, win_rate, n = 1)
        sprintf("Best grid: %.2f pts → WR %.1f%% / ROI %+.1f%%\n",
                best_row$threshold[1], best_row$win_rate[1] * 100,
                best_row$roi[1] * 100)
      } else "",
      sprintf("N qualifying bets: %d\n\n", n_total),
      "\U0001F525 *Steam thresholds (totals V1)*\n",
      sprintf("Move >= %.2f, Books >= %d  %s\n", new_steam_move, as.integer(new_steam_books),
              if (steam_applied) sprintf("(updated from %.2f/%d)", current_steam_move, as.integer(current_steam_books))
              else "(unchanged)"),
      if (!is.null(current_steam_wr)) sprintf("Current steam-alone WR: %.1f%%\n", current_steam_wr * 100) else "",
      if (nrow(steam_sweep) > 0) {
        best_steam <- slice_max(steam_sweep, win_rate, n = 1)
        sprintf("Best grid: move>=%.2f books>=%d → WR %.1f%% / ROI %+.1f%%\n",
                best_steam$min_move[1], best_steam$min_books[1],
                best_steam$win_rate[1] * 100, best_steam$roi[1] * 100)
      } else "",
      sprintf("N qualifying signals: %d", n_steam_total)
    )

    tryCatch(
      httr2::request("https://api.telegram.org") |>
        httr2::req_url_path_append("bot", creds$telegram_bot_token, "sendMessage") |>
        httr2::req_body_json(list(
          chat_id    = creds$telegram_chat_id,
          text       = msg,
          parse_mode = "Markdown"
        )) |>
        httr2::req_error(is_error = \(r) FALSE) |>
        httr2::req_perform(),
      error = \(e) invisible(NULL)
    )
  }

  message("[calibrate] Mispricing calibration complete")
  invisible(list(
    applied       = applied,       sweep       = sweep,
    steam_applied = steam_applied, steam_sweep = steam_sweep
  ))
}
