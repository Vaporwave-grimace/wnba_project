# scripts/rotowire_injuries.R
# RotoWire WNBA injury feed — faster and more complete than ESPN.
#
# RotoWire posts injury updates 15-30 min ahead of the official WNBA report
# and includes GTD/probable designations ESPN sometimes omits.
# Results are merged with ESPN injuries in run_pipeline.R before the
# mispricing model runs, giving the best available injury picture.

library(httr2)
library(rvest)
library(dplyr)
library(lubridate)

ROTOWIRE_URL <- "https://www.rotowire.com/wnba/injury-report.php"

# Status normalization — RotoWire uses slightly different labels than ESPN
.normalize_status <- function(s) {
  s <- trimws(s)
  case_when(
    grepl("^out$",          s, ignore.case = TRUE) ~ "Out",
    grepl("^doubtful$",     s, ignore.case = TRUE) ~ "Doubtful",
    grepl("^questionable$", s, ignore.case = TRUE) ~ "Questionable",
    grepl("^gtd$|game.time decision", s, ignore.case = TRUE) ~ "GTD",
    grepl("^probable$",     s, ignore.case = TRUE) ~ "Probable",
    TRUE ~ s
  )
}

# ── Scraper ───────────────────────────────────────────────────────────────────

# Returns a tibble with columns compatible with fetch_all_injuries() output:
#   player_name, team_name, status, injury_type, source, reported_at
# Returns empty tibble on any error so callers can merge safely.

fetch_rotowire_injuries <- function() {
  resp <- tryCatch(
    request(ROTOWIRE_URL) |>
      req_headers(
        "User-Agent" = paste0("Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
                              "AppleWebKit/537.36 (KHTML, like Gecko) ",
                              "Chrome/124.0.0.0 Safari/537.36"),
        "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language" = "en-US,en;q=0.9"
      ) |>
      req_timeout(20) |>
      req_retry(max_tries = 2, backoff = \(i) 3 * i) |>
      req_perform(),
    error = function(e) {
      message("[rotowire] Request failed: ", e$message)
      NULL
    }
  )

  if (is.null(resp) || resp_status(resp) != 200L) {
    message("[rotowire] HTTP ", if (!is.null(resp)) resp_status(resp) else "error",
            " — skipping RotoWire injuries")
    return(tibble())
  }

  page <- tryCatch(read_html(resp_body_string(resp)), error = \(e) NULL)
  if (is.null(page)) return(tibble())

  # RotoWire injury report uses a standard HTML table with class "rt-table" or similar.
  # Try html_table() first; fall back to row/cell extraction if structure changed.
  tables <- tryCatch(html_table(page, fill = TRUE), error = \(e) list())

  inj_tbl <- NULL
  for (t in tables) {
    cols <- tolower(names(t))
    if (any(grepl("player", cols)) && any(grepl("status|injury", cols))) {
      inj_tbl <- t
      break
    }
  }

  if (is.null(inj_tbl) || nrow(inj_tbl) == 0) {
    message("[rotowire] Injury table not found — page structure may have changed")
    return(tibble())
  }

  # Normalize column names to standard snake_case
  names(inj_tbl) <- tolower(trimws(names(inj_tbl))) |>
    gsub("\\s+", "_", x = _) |>
    gsub("[^a-z0-9_]", "", x = _)

  # Column aliases — RotoWire has changed its column names a few times
  col_map <- c(
    player = "player_name", name = "player_name",
    team   = "team_name",
    pos    = "position",
    injury = "injury_type", type = "injury_type",
    status = "status",
    updated = "updated_at", date = "updated_at"
  )
  for (old in names(col_map)) {
    if (old %in% names(inj_tbl) && !col_map[[old]] %in% names(inj_tbl))
      names(inj_tbl)[names(inj_tbl) == old] <- col_map[[old]]
  }

  required <- c("player_name", "status")
  if (!all(required %in% names(inj_tbl))) {
    message("[rotowire] Missing required columns after normalization: ",
            paste(setdiff(required, names(inj_tbl)), collapse = ", "))
    return(tibble())
  }

  now_str <- format(now("UTC"), "%Y-%m-%d %H:%M:%S")

  result <- inj_tbl |>
    as_tibble() |>
    filter(!is.na(status), nchar(trimws(status)) > 0) |>
    mutate(
      status      = .normalize_status(status),
      source      = "RotoWire",
      reported_at = now_str
    ) |>
    filter(status %in% c("Out", "Doubtful", "Questionable", "GTD")) |>
    select(any_of(c("player_name", "team_name", "position",
                    "injury_type", "status", "updated_at",
                    "source", "reported_at")))

  message("[rotowire] ", nrow(result), " injury report(s) fetched")
  result
}

# ── Merge helper ──────────────────────────────────────────────────────────────

# Merge RotoWire and ESPN injury data frames. For players appearing in both,
# take the more severe status (Out > Doubtful > Questionable > GTD > Probable).
# `espn_df` must have columns: player_name, team_name (after ESPN join), status.
# `rw_df` is the output of fetch_rotowire_injuries().

merge_injury_sources <- function(espn_df, rw_df) {
  SEVERITY <- c(Out = 4L, Doubtful = 3L, Questionable = 2L, GTD = 2L, Probable = 1L)

  combined <- bind_rows(
    if (!is.null(espn_df) && nrow(espn_df) > 0) espn_df else tibble(),
    if (!is.null(rw_df)   && nrow(rw_df)   > 0) rw_df   else tibble()
  )

  if (nrow(combined) == 0) return(tibble())

  combined |>
    mutate(severity = SEVERITY[status] %||% 0L) |>
    group_by(player_name) |>
    slice_max(severity, n = 1, with_ties = FALSE) |>
    ungroup() |>
    select(-severity)
}
