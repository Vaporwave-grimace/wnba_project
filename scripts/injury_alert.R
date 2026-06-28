# scripts/injury_alert.R
# Injury discrepancy alerter
#
# Handles:
#   - Polling ESPN's unofficial API for WNBA injury/roster status
#   - Detecting status changes and timestamping them
#   - Comparing injury report timestamps against line movement timestamps
#   - Flagging cases where the line moved BEFORE the injury was reported
#   - Sending alerts via Telegram and Discord

library(httr2)
library(dplyr)
library(purrr)
library(jsonlite)
library(DBI)
library(RSQLite)
library(lubridate)

DB_PATH    <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"
CREDS_PATH <- here::here("scripts", "credentials.json")

ESPN_BASE  <- "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba"

# Minimum line move (points) to consider pairing with an injury report
LINE_MOVE_THRESHOLD <- 0.5

# Discrepancy window: how many minutes before a report we look for line movement
DISC_WINDOW_MINS <- 90

# ── Credentials ───────────────────────────────────────────────────────────────

load_credentials <- function(path = CREDS_PATH) {
  fromJSON(path)
}

# ── ESPN API ──────────────────────────────────────────────────────────────────

espn_get <- function(path, params = list()) {
  resp <- request(ESPN_BASE) |>
    req_url_path_append(path) |>
    req_url_query(!!!params) |>
    req_headers(
      "User-Agent"   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
      "Accept"       = "application/json"
    ) |>
    req_retry(max_tries = 3, backoff = \(i) 2 ^ i) |>
    req_perform()

  resp_body_json(resp, simplifyVector = FALSE)
}

# Fetch all WNBA team IDs from ESPN
fetch_espn_teams <- function() {
  body  <- espn_get("teams")
  teams <- body$sports[[1]]$leagues[[1]]$teams

  map_dfr(teams, \(t) tibble(
    team_id   = t$team$id,
    team_name = t$team$displayName,
    team_abbr = t$team$abbreviation
  ))
}

# Fetch roster with injury status for a single team.
# Returns one row per player; includes `injury_status` and `injury_type`.
fetch_team_roster <- function(team_id) {
  body     <- espn_get(paste0("teams/", team_id, "/roster"))
  athletes <- body$athletes

  empty <- tibble(team_id = character(), player_id = character(),
                  player_name = character(), status = character(),
                  injury_type = character())

  if (is.null(athletes) || length(athletes) == 0) return(empty)

  # ESPN returns athletes as either:
  #   (a) a list of groups, each with $items — the historic format
  #   (b) a flat list of player objects — newer format seen in some seasons
  # Detect by checking whether the first element has an $items field.
  first <- athletes[[1]]
  if (!is.null(first$items)) {
    # Grouped format (a)
    player_list <- unlist(lapply(athletes, function(g) g$items %||% list()),
                          recursive = FALSE)
  } else {
    # Flat format (b) — athletes IS the player list
    player_list <- athletes
  }

  if (length(player_list) == 0) return(empty)

  map_dfr(player_list, function(a) {
    # ESPN returns status as either:
    #   (old) a list {type: {description: "Active"}}
    #   (new) a plain character string "Active"
    p_status <- tryCatch({
      s <- a$status
      if (is.character(s))        s                         # new flat format
      else if (!is.null(s$type))  s$type$description %||% "Active"  # old nested
      else "Active"
    }, error = function(e) "Active")

    injury_type <- tryCatch(a$injuries[[1]]$type$description %||% NA_character_,
                            error = function(e) NA_character_)
    tibble(
      team_id     = as.character(team_id),
      player_id   = a$id %||% NA_character_,
      player_name = a$fullName %||% NA_character_,
      status      = p_status,
      injury_type = injury_type
    )
  })
}

# Poll all teams and return a full league-wide injury snapshot.
fetch_all_injuries <- function() {
  teams <- fetch_espn_teams()
  message("Fetching rosters for ", nrow(teams), " WNBA teams...")

  rosters <- map_dfr(teams$team_id, function(tid) {
    Sys.sleep(0.5)  # be polite between team fetches
    fetch_team_roster(tid)
  })

  # Guard: ESPN sometimes returns empty athlete groups, leaving rosters with no cols
  if (nrow(rosters) == 0 || !"status" %in% names(rosters)) {
    message("[injury] No roster data returned — ESPN API may have changed structure.")
    return(tibble(
      player_name = character(), team_id   = character(),
      status      = character(), injury_type = character(),
      source      = character(), reported_at = character()
    ))
  }

  rosters |>
    filter(status != "Active") |>
    mutate(
      source      = "ESPN",
      reported_at = format(now("UTC"), "%Y-%m-%d %H:%M:%S")
    )
}

# ── Persist Injuries ──────────────────────────────────────────────────────────

# Compares a fresh injury snapshot against what's already in the DB.
# Only saves rows where the player's status has CHANGED (new report or upgrade/downgrade).
# Returns the new/changed rows so the caller can immediately check for discrepancies.
save_new_injuries <- function(fresh_df, con) {
  if (nrow(fresh_df) == 0) return(tibble())

  existing <- dbGetQuery(con, "
    SELECT player_name, status
    FROM injury_reports
    WHERE reported_at = (
      SELECT MAX(reported_at) FROM injury_reports AS ir2
      WHERE ir2.player_name = injury_reports.player_name
    )
  ") |> as_tibble()

  # Flag players whose status has changed or who are newly injured
  new_entries <- fresh_df |>
    left_join(existing, by = "player_name", suffix = c("_new", "_old")) |>
    filter(is.na(status_old) | status_new != status_old) |>
    rename(status = status_new) |>
    select(player_name, team_id, status, injury_type, source, reported_at)

  if (nrow(new_entries) == 0) {
    message("No new injury status changes detected.")
    return(tibble())
  }

  message(nrow(new_entries), " new injury report(s) detected:")
  walk(seq_len(nrow(new_entries)), \(i) {
    message("  ", new_entries$player_name[i], " — ", new_entries$status[i])
  })

  dbAppendTable(con, "injury_reports", new_entries)
  new_entries
}

# ── Discrepancy Detection ─────────────────────────────────────────────────────

# For each newly reported injury, look back in the steam_movements and lines
# tables for line movement that preceded the report within DISC_WINDOW_MINS.
#
# A discrepancy is flagged when:
#   - A line moved >= LINE_MOVE_THRESHOLD points
#   - The move was detected BEFORE the injury report timestamp
#   - The gap is within DISC_WINDOW_MINS
#
# This doesn't require knowing exactly which game the player is in —
# we look at all games with a commence_time on the same date as the injury.

check_discrepancies <- function(new_injuries, con) {
  if (nrow(new_injuries) == 0) return(tibble())

  discrepancies <- map_dfr(seq_len(nrow(new_injuries)), function(i) {
    injury <- new_injuries[i, ]
    report_time <- ymd_hms(injury$reported_at, tz = "UTC")
    window_start <- report_time - minutes(DISC_WINDOW_MINS)

    # Pull steam movements in the window before the report
    steam <- dbGetQuery(con, "
      SELECT *
      FROM steam_movements
      WHERE detected_at >= ?
        AND detected_at <  ?
    ", list(
      format(window_start, "%Y-%m-%d %H:%M:%S"),
      format(report_time,  "%Y-%m-%d %H:%M:%S")
    )) |> as_tibble()

    if (nrow(steam) == 0) return(tibble())

    # Flag movements that meet the threshold
    flagged <- steam |>
      filter(magnitude >= LINE_MOVE_THRESHOLD) |>
      mutate(
        player_name        = injury$player_name,
        injury_reported_at = injury$reported_at,
        line_moved_at      = detected_at,
        lag_minutes        = as.numeric(difftime(
          report_time,
          ymd_hms(detected_at, tz = "UTC"),
          units = "mins"
        )),
        flagged_at = format(now("UTC"), "%Y-%m-%d %H:%M:%S")
      ) |>
      select(game_id, player_name, injury_reported_at, line_moved_at,
             line_delta = magnitude, lag_minutes, flagged_at)

    flagged
  })

  if (nrow(discrepancies) == 0) {
    message("No discrepancies detected.")
    return(tibble())
  }

  message("DISCREPANCY FLAGGED: line moved before injury report for ",
          paste(unique(discrepancies$player_name), collapse = ", "))

  dbAppendTable(con, "injury_discrepancies", discrepancies)
  discrepancies
}

# ── Alert Layer ───────────────────────────────────────────────────────────────

send_telegram <- function(message_text, creds) {
  if (!nzchar(message_text %||% "")) {
    message("[send_telegram] Skipping empty message.")
    return(invisible(FALSE))
  }
  token   <- creds$telegram_bot_token
  chat_id <- creds$telegram_chat_id

  resp <- request(paste0("https://api.telegram.org/bot", token, "/sendMessage")) |>
    req_body_json(list(
      chat_id    = chat_id,
      text       = message_text,
      parse_mode = "Markdown"
    )) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()

  if (resp_status(resp) == 200L) {
    message("[send_telegram] Alert sent.")
    return(invisible(TRUE))
  }

  # Markdown parse error — retry as plain text (symbols appear literally, acceptable)
  if (resp_status(resp) == 400L) {
    message("[send_telegram] Markdown rejected (400) — retrying as plain text.")
    resp2 <- request(paste0("https://api.telegram.org/bot", token, "/sendMessage")) |>
      req_body_json(list(chat_id = chat_id, text = message_text)) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(resp2) == 200L) {
      message("[send_telegram] Alert sent (plain text fallback).")
      return(invisible(TRUE))
    }
    message("[send_telegram] Plain text fallback also failed: HTTP ", resp_status(resp2))
    return(invisible(FALSE))
  }

  message("[send_telegram] Alert failed: HTTP ", resp_status(resp))
  invisible(FALSE)
}

send_discord <- function(message_text, creds,
                         channel_id = "1499488823598387412") {
  if (!nzchar(message_text %||% "")) {
    message("[send_discord] Skipping empty message.")
    return(invisible(FALSE))
  }
  # Discord 2000-char limit
  if (nchar(message_text) > 1990L) {
    message_text <- paste0(substr(message_text, 1L, 1987L), "...")
  }

  # Prefer bot token (shows as WNBA bot); fall back to webhook
  if (!is.null(creds$discord_bot_token)) {
    resp <- request(paste0("https://discord.com/api/v10/channels/",
                           channel_id, "/messages")) |>
      req_headers(Authorization  = paste("Bot", creds$discord_bot_token),
                  `Content-Type` = "application/json") |>
      req_body_json(list(content = message_text)) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()

    if (resp_status(resp) %in% c(200L, 204L)) {
      message("[send_discord] Alert sent (bot).")
      return(invisible(TRUE))
    }
    message("[send_discord] Bot post failed (HTTP ", resp_status(resp),
            ") — falling back to webhook")
  }

  resp <- request(creds$discord_webhook_url) |>
    req_body_json(list(content = message_text)) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()

  if (resp_status(resp) %in% c(200L, 204L)) {
    message("[send_discord] Alert sent (webhook).")
    return(invisible(TRUE))
  }

  message("[send_discord] Alert failed: HTTP ", resp_status(resp))
  invisible(FALSE)
}

# Format a discrepancy row into a human-readable alert string
format_discrepancy_alert <- function(disc_row, injury_status) {
  paste0(
    "⚠️ *INJURY DISCREPANCY*\n",
    "*Player:* ", disc_row$player_name, " (", injury_status, ")\n",
    "*Game:* ", disc_row$game_id, "\n",
    "*Line moved:* ", disc_row$line_moved_at, " UTC\n",
    "*Injury reported:* ", disc_row$injury_reported_at, " UTC\n",
    "*Lead time:* ", round(disc_row$lag_minutes, 1), " min before report\n",
    "*Move size:* ", round(disc_row$line_delta, 2), " pts"
  )
}

# Send alerts for all flagged discrepancies
alert_discrepancies <- function(discrepancies, new_injuries, creds) {
  if (nrow(discrepancies) == 0) return(invisible(NULL))

  for (i in seq_len(nrow(discrepancies))) {
    row    <- discrepancies[i, ]
    status <- new_injuries |>
      filter(player_name == row$player_name) |>
      pull(status) |>
      first() %||% "Unknown"

    msg <- format_discrepancy_alert(row, status)
    send_telegram(msg, creds)
    send_discord(msg, creds)
    Sys.sleep(1)  # avoid rate limiting between alerts
  }
}

# Format a steam detection alert
format_steam_alert <- function(steam_row, home_team = NULL, away_team = NULL) {
  game_label <- if (!is.null(home_team) && !is.null(away_team)) {
    paste0(away_team, " @ ", home_team)
  } else {
    steam_row$game_id
  }
  paste0(
    "\U0001f525 *STEAM DETECTED*\n",
    "*Game:* ", game_label, "\n",
    "*Market:* ", steam_row$market, " — ", steam_row$outcome_name, "\n",
    "*Direction:* ", toupper(steam_row$direction), "\n",
    "*Move:* ", round(steam_row$magnitude, 2), " pts across ",
    steam_row$books_moved, " sharp book(s)\n",
    "*Detected:* ", steam_row$detected_at, " UTC"
  )
}

# Format a new injury notification (no discrepancy — just FYI)
format_injury_alert <- function(injury_row) {
  paste0(
    "\U0001f915 *INJURY REPORT*\n",
    "*Player:* ", injury_row$player_name, "\n",
    "*Status:* ", injury_row$status,
    if (!is.na(injury_row$injury_type)) paste0(" (", injury_row$injury_type, ")") else "",
    "\n*Reported:* ", injury_row$reported_at, " UTC"
  )
}

# ── Orchestration ─────────────────────────────────────────────────────────────

# Full injury check cycle:
#   1. Poll ESPN for current injury status across all teams
#   2. Detect and save status changes
#   3. Check for line movement that preceded each new report
#   4. Alert on discrepancies (and optionally all new injuries)
#
# Usage:
#   creds <- load_credentials()
#   con   <- dbConnect(RSQLite::SQLite(), DB_PATH)
#   run_injury_check(con, creds)
#   dbDisconnect(con)

run_injury_check <- function(con, creds, alert_all_injuries = FALSE) {
  message("\n── Injury check: ", format(now("UTC"), "%Y-%m-%d %H:%M:%S"), " UTC ──")

  fresh       <- fetch_all_injuries()
  new_entries <- save_new_injuries(fresh, con)

  # Optionally alert on all new injury reports regardless of discrepancy
  if (alert_all_injuries && nrow(new_entries) > 0) {
    for (i in seq_len(nrow(new_entries))) {
      msg <- format_injury_alert(new_entries[i, ])
      send_telegram(msg, creds)
      send_discord(msg, creds)
      Sys.sleep(1)
    }
  }

  # Check for and alert on discrepancies
  discrepancies <- check_discrepancies(new_entries, con)
  alert_discrepancies(discrepancies, new_entries, creds)

  invisible(list(new_injuries = new_entries, discrepancies = discrepancies))
}
