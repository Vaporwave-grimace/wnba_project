# scripts/test_pipeline.R
# Pipeline smoke test — run this before the first full pipeline run.
#
# Tests (in order):
#   1. Required packages present
#   2. Credentials file loads and is well-formed
#   3. DB initializes cleanly
#   4. The Odds API responds, returns WNBA games, AND includes Pinnacle
#      (regions must include "eu" — this is the actual regression guard for
#      the 2026-07-09 bug where the mispricing model never got Pinnacle data)
#   5. stats.wnba.com responds and returns data
#   6. ESPN API responds AND fetch_all_injuries() parses real non-Active
#      statuses (not just HTTP 200 — that alone missed the 2026-07-09 bug
#      where the status field always resolved to "Active")
#   7. Action Network endpoint responds (split data requires their PRO tier —
#      0 rows with real splits is expected, not a failure)
#   8. RotoWire fails safe (known disabled — see rotowire_injuries.R)
#   9. Telegram bot is reachable
#
# Run with:  Rscript scripts/test_pipeline.R

library(here)

pass <- function(label) cat(sprintf("  [PASS] %s\n", label))
fail <- function(label, reason) cat(sprintf("  [FAIL] %s — %s\n", label, reason))
section <- function(label) cat(sprintf("\n── %s ──\n", label))

errors <- 0L

check <- function(label, expr) {
  tryCatch({
    result <- expr
    pass(label)
    invisible(result)
  }, error = function(e) {
    fail(label, conditionMessage(e))
    errors <<- errors + 1L
    invisible(NULL)
  })
}

# ── 1. Packages ───────────────────────────────────────────────────────────────
section("1. Required packages")

required_pkgs <- c("httr2", "dplyr", "purrr", "tidyr", "jsonlite",
                   "DBI", "RSQLite", "lubridate", "here", "wehoop")

for (pkg in required_pkgs) {
  check(pkg, {
    if (!requireNamespace(pkg, quietly = TRUE))
      stop("not installed — run: install.packages('", pkg, "')")
    TRUE
  })
}

# ── 2. Credentials ────────────────────────────────────────────────────────────
section("2. Credentials")

creds <- check("credentials.json loads", {
  jsonlite::fromJSON(here("scripts", "credentials.json"))
})

if (!is.null(creds)) {
  check("odds_api_keys present (10 keys)", {
    keys <- creds$odds_api_keys
    if (length(keys) != 10) stop("expected 10 keys, got ", length(keys))
    TRUE
  })
  check("telegram_bot_token present", {
    if (is.null(creds$telegram_bot_token) || nchar(creds$telegram_bot_token) < 10)
      stop("missing or malformed")
    TRUE
  })
  check("discord_webhook_url present", {
    if (!grepl("^https://discord.com/api/webhooks/", creds$discord_webhook_url))
      stop("missing or malformed")
    TRUE
  })
}

# ── 3. Database ───────────────────────────────────────────────────────────────
section("3. Database")

source(here("scripts", "db_setup.R"))

con <- check("DB initializes", {
  init_db()
  DBI::dbConnect(RSQLite::SQLite(), DB_PATH)
})

if (!is.null(con)) {
  check("All tables exist", {
    expected <- c("lines", "steam_movements", "game_log", "play_by_play",
                  "lineup_net_ratings", "on_off_net_rating",
                  "injury_reports", "injury_discrepancies", "clv_log")
    actual <- DBI::dbListTables(con)
    missing <- setdiff(expected, actual)
    if (length(missing) > 0) stop("missing tables: ", paste(missing, collapse = ", "))
    TRUE
  })
  DBI::dbDisconnect(con)
}

# ── 4. The Odds API ───────────────────────────────────────────────────────────
section("4. The Odds API")

library(httr2)
library(jsonlite)

odds_key <- creds$odds_api_keys[[1]]

check("WNBA sport key exists", {
  resp <- request("https://api.the-odds-api.com/v4/sports") |>
    req_url_query(apiKey = odds_key) |>
    req_perform()
  sports <- resp_body_json(resp, simplifyVector = TRUE)
  if (!any(grepl("wnba", sports$key))) stop("basketball_wnba not found in sports list")
  TRUE
})

odds_data <- check("WNBA odds endpoint returns data", {
  # regions MUST include "eu" — Pinnacle (the sharp-book reference the whole
  # mispricing model depends on) is only returned under "eu", never "us"
  # alone. Confirmed live 2026-07-09 after finding the mispricing model had
  # never fired once because of this exact regions="us"-only mistake in
  # odds_ingest.R. Keep this in sync with fetch_wnba_odds()'s default there.
  resp <- request("https://api.the-odds-api.com/v4/sports/basketball_wnba/odds") |>
    req_url_query(
      apiKey     = odds_key,
      regions    = "us,eu",
      markets    = "spreads,totals",
      oddsFormat = "american"
    ) |>
    req_perform()
  remaining <- resp_header(resp, "x-requests-remaining")
  cat(sprintf("     x-requests-remaining: %s\n", remaining %||% "N/A"))
  data <- resp_body_json(resp, simplifyVector = FALSE)
  cat(sprintf("     Games returned: %d\n", length(data)))
  data
})

if (!is.null(odds_data) && length(odds_data) > 0) {
  check("Response has expected fields", {
    g <- odds_data[[1]]
    required <- c("id", "commence_time", "home_team", "away_team", "bookmakers")
    missing  <- setdiff(required, names(g))
    if (length(missing) > 0) stop("missing fields: ", paste(missing, collapse = ", "))
    cat(sprintf("     Sample: %s @ %s\n", g$away_team, g$home_team))
    TRUE
  })

  check("Pinnacle present in at least one game's bookmakers", {
    # This is the actual regression guard for the 2026-07-09 Pinnacle bug —
    # asserting HTTP 200 alone (as this file did before) would NOT have
    # caught it, since the request succeeded fine, it just never included
    # Pinnacle. If this ever fails again, check the `regions` param above
    # AND fetch_wnba_odds()'s default in odds_ingest.R.
    has_pinnacle <- any(vapply(odds_data, function(g) {
      any(vapply(g$bookmakers %||% list(), function(b) identical(b$key, "pinnacle"), logical(1)))
    }, logical(1)))
    if (!has_pinnacle) stop("no game had a Pinnacle line — mispricing model would silently get nothing")
    TRUE
  })
}

# ── 5. wehoop (WNBA stats) ────────────────────────────────────────────────────
section("5. wehoop — WNBA stats")

library(wehoop)

game_log <- check("load_wnba_player_box() returns data", {
  df <- wehoop::load_wnba_player_box(seasons = 2025L)
  if (nrow(df) == 0) stop("empty result")
  cat(sprintf("     Player box rows: %d\n", nrow(df)))
  df
})

check("wnba_leaguedashlineups() returns data", {
  result <- wehoop::wnba_leaguedashlineups(
    season         = "2024-25",
    season_type    = "Regular Season",
    group_quantity = 5,
    measure_type   = "Advanced",
    per_mode       = "Per100Possessions"
  )
  df <- purrr::keep(result, is.data.frame) |> purrr::pluck(1)
  if (is.null(df) || nrow(df) == 0) stop("empty result")
  cat(sprintf("     Lineup rows: %d\n", nrow(df)))
  TRUE
})

# ── 6. ESPN API ───────────────────────────────────────────────────────────────
section("6. ESPN API")

espn_teams <- check("ESPN teams endpoint responds", {
  resp <- request("https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/teams") |>
    req_headers("User-Agent" = "Mozilla/5.0") |>
    req_perform()
  body  <- resp_body_json(resp, simplifyVector = FALSE)
  teams <- body$sports[[1]]$leagues[[1]]$teams
  cat(sprintf("     Teams returned: %d\n", length(teams)))
  teams
})

if (!is.null(espn_teams) && length(espn_teams) > 0) {
  check("Team roster endpoint responds (first team)", {
    tid  <- espn_teams[[1]]$team$id
    resp <- request(paste0(
      "https://site.api.espn.com/apis/site/v2/sports/basketball/wnba/teams/",
      tid, "/roster"
    )) |>
      req_headers("User-Agent" = "Mozilla/5.0") |>
      req_perform()
    body <- resp_body_json(resp, simplifyVector = FALSE)
    cats <- body$athletes
    cat(sprintf("     Roster groups: %d\n", length(cats)))
    TRUE
  })
}

# This calls the REAL fetch_all_injuries() end-to-end, not just an HTTP 200
# check — a plain "did the request succeed" assertion (as this file had
# before) would NOT have caught the 2026-07-09 bug where ESPN's status field
# always parsed to "Active" regardless of real injury status: the request
# succeeded fine every single time, it just parsed to the wrong value.
source(here("scripts", "injury_alert.R"))

check("fetch_all_injuries() parses at least one real non-Active status", {
  inj <- fetch_all_injuries()
  cat(sprintf("     Injured players found: %d\n", nrow(inj)))
  if (nrow(inj) > 0) cat(sprintf("     Sample: %s (%s)\n", inj$player_name[1], inj$status[1]))
  # Don't hard-fail on 0 (a genuinely healthy league week is possible), but do
  # fail if the status parsing regresses to literally always "Active" despite
  # nonzero rows, which is the exact shape of bug this test exists to catch.
  if (nrow(inj) > 0 && all(inj$status == "Active"))
    stop("all parsed statuses are 'Active' — status field parsing likely broken again")
  TRUE
})

# ── 7. Action Network ─────────────────────────────────────────────────────────
section("7. Action Network")

source(here("scripts", "action_network.R"))

check("scoreboard endpoint responds (not the old dead games? endpoint)", {
  an_data <- fetch_wnba_sharp_report()
  if (is.null(an_data) || nrow(an_data) == 0) stop("no rows returned — endpoint may be down again")
  n_split <- sum(!is.na(an_data$sharp_score))
  cat(sprintf("     Rows: %d  |  with real split data: %d\n", nrow(an_data), n_split))
  # Real split % data is an Action Network PRO-tier feature (confirmed
  # 2026-07-09 via their own page's "Save Big on PRO!" upsell) — 0 is the
  # expected, not-broken state without a paid plan. This check only confirms
  # the endpoint itself still responds with well-formed rows.
  if (n_split == 0)
    cat("     (0 with split data is expected — PRO-tier feature, not a failure)\n")
  TRUE
})

# ── 8. RotoWire (known disabled) ──────────────────────────────────────────────
section("8. RotoWire (known disabled)")

source(here("scripts", "rotowire_injuries.R"))

check("fetch_rotowire_injuries() fails safe (returns empty, doesn't error)", {
  # Deliberately disabled 2026-07-09 — the injury page is a Webix virtualized
  # grid that rvest's html_table() cannot parse (see rotowire_injuries.R for
  # the full investigation). This check exists only to confirm the disabled
  # stub keeps returning an empty tibble gracefully, not to test real scraping.
  rw <- fetch_rotowire_injuries()
  if (!is.data.frame(rw)) stop("expected a data frame/tibble, got: ", class(rw)[1])
  if (nrow(rw) != 0) cat("     NOTE: RotoWire returned non-empty data — has it been re-enabled?\n")
  TRUE
})

# ── 9. Telegram ───────────────────────────────────────────────────────────────
section("9. Telegram")

check("Bot is reachable (getMe)", {
  token <- creds$telegram_bot_token
  resp  <- request(paste0("https://api.telegram.org/bot", token, "/getMe")) |>
    req_perform()
  body <- resp_body_json(resp)
  if (!isTRUE(body$ok)) stop("API returned ok=false")
  cat(sprintf("     Bot username: @%s\n", body$result$username))
  TRUE
})

check("Test message sends to chat", {
  token   <- creds$telegram_bot_token
  chat_id <- creds$telegram_chat_id
  resp <- request(paste0("https://api.telegram.org/bot", token, "/sendMessage")) |>
    req_body_json(list(
      chat_id = chat_id,
      text    = "WNBA Pipeline: smoke test OK"
    )) |>
    req_perform()
  body <- resp_body_json(resp)
  if (!isTRUE(body$ok)) stop("message send failed")
  TRUE
})

# ── 10. Discord ───────────────────────────────────────────────────────────────
section("10. Discord")

check("Test message sends to webhook", {
  resp <- request(creds$discord_webhook_url) |>
    req_body_json(list(content = "WNBA Pipeline: smoke test OK")) |>
    req_perform()
  if (!resp_status(resp) %in% c(200L, 204L))
    stop("unexpected status: ", resp_status(resp))
  TRUE
})

# ── Summary ───────────────────────────────────────────────────────────────────
section("Summary")

if (errors == 0L) {
  cat("  All checks passed. Pipeline is ready to run.\n")
  cat("  Next step: Rscript scripts/run_pipeline.R\n")
} else {
  cat(sprintf("  %d check(s) failed. Resolve the above before running the pipeline.\n", errors))
}
