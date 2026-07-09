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

# DISABLED 2026-07-09 — the injury table is no longer static HTML. It's a
# Webix virtualized data grid (confirmed via a Firecrawl JS-rendered fetch):
# a frozen player-name pane plus a separately-indexed scrollable pane for
# team/pos/injury/status/est-return, nested <a>/<span> markup inside every
# cell, and — critically — virtualized rendering means a single page
# snapshot may not even contain every player without simulating scroll.
# rvest's html_table() finds zero <table> elements and silently returns
# empty, which is why this had returned nothing since deployment. A robust
# fix needs a real headless browser driving actual scroll events, not a
# scrape — not attempted here given ESPN (injury_alert.R, fixed same
# session) now provides comprehensive real injury data on its own. Returns
# empty immediately so callers merge safely via merge_injury_sources()
# without wasting an HTTP round-trip on a scrape that cannot succeed.
fetch_rotowire_injuries <- function() {
  message("[rotowire] Disabled — HTML table scraping cannot work against ",
          "RotoWire's current virtualized grid UI. See comment above. ",
          "Relying on ESPN alone.")
  tibble()
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
