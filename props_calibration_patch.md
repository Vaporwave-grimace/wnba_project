# Props Calibration Patch — `bet_alerts.R` + `db_setup.R`

## Context

`send_prop_digest()` in `player_props.R` is producing inflated edges (e.g. +59% EV,
+56% EV) due to three compounding issues identified via code review:

1. **No devig on implied probability** — EV is computed against the book's vigged
   price, not the fair probability. A prop posted -115/-115 has a 53.5% raw implied
   prob but a 50% fair prob. Every single edge is overstated by the vig spread.
2. **No main-line consensus filter** — `.best_prop_odds()` returns whatever point
   the best-ranked book posted, including alt lines (e.g. Under 8.5 when consensus
   is Under 14.5). `pnorm(8.5, mean=14.2, sd=3.1)` ≈ 1.0, producing a ghost edge.
3. **No book depth requirement** — a prop with only one soft book posting it is
   almost always an alt line or illiquid market, not a real mispricing.

All three fixes are in `bet_alerts.R`. Two new config params are seeded in
`db_setup.R` so they can be adjusted without a code deploy.

---

## File 1: `scripts/bet_alerts.R`

### Change 1 — Add two constants near the top (after `KELLY_STAKE_CEILING`)

```r
# Minimum number of distinct books that must post a prop line (on the
# requested side, at the consensus point) before we'll evaluate it.
# Seeded in model_config as prop_min_books; this module constant is the
# fallback when con is unavailable.  Mirrors steam_min_books pattern.
PROP_MIN_BOOKS <- 3L

# Maximum deviation from the median point across books before a row is
# treated as an alt line and discarded.  Half-point line moves shift by
# 0.5, so 1.5 covers normal market drift without catching true alt lines.
# Seeded in model_config as prop_main_line_tol.
PROP_MAIN_LINE_TOL <- 1.5
```

### Change 2 — Add `.get_prop_config()` helper (after `.get_prop_sd_scale()`)

Reads `prop_min_books` and `prop_main_line_tol` from `model_config` with
module-constant fallbacks, same pattern as `.get_wnba_sd()`.

```r
.get_prop_config <- function(con) {
  list(
    min_books     = tryCatch({
      v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'prop_min_books'")$value[1]
      if (is.null(v) || is.na(v)) PROP_MIN_BOOKS else as.integer(v)
    }, error = \(e) PROP_MIN_BOOKS),
    main_line_tol = tryCatch({
      v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'prop_main_line_tol'")$value[1]
      if (is.null(v) || is.na(v)) PROP_MAIN_LINE_TOL else as.numeric(v)
    }, error = \(e) PROP_MAIN_LINE_TOL)
  )
}
```

### Change 3 — Add `.devig_prop_prob()` helper (after `.prob_to_american()`)

```r
# Two-outcome multiplicative devig: scales each side's raw implied prob by
# their sum so they sum to 1.0, removing the book's vig.  Returns the fair
# probability for `odds_side`.  Falls back to raw implied prob if
# `odds_other` is NA — callers should treat that as illiquid and skip.
.devig_prop_prob <- function(odds_side, odds_other) {
  p1 <- .american_to_prob(odds_side)
  if (is.na(odds_other)) return(p1)
  p2    <- .american_to_prob(odds_other)
  total <- p1 + p2
  if (is.na(total) || total <= 0) return(p1)
  p1 / total
}
```

### Change 4 — Replace `.best_prop_odds()` entirely

The new version fetches both sides in one query, applies the consensus point
filter, enforces book depth, and returns `odds_other` + `book_count`.

**Replace the entire existing `.best_prop_odds()` function with:**

```r
# Best available line for a prop (player + market + outcome_name), from the
# most recent snapshot for the game.
#
# Returns list(book, odds, point, odds_other, book_count).
#   odds_other  — best-ranked opposite-side price at the consensus point (NA if missing)
#   book_count  — distinct books posting the requested side at the consensus point
#
# Returns book_count = 0 (and NA for everything else) when:
#   - no rows exist, or
#   - all rows are filtered as alt lines, or
#   - book_count < min_books (caller gates on this)
.best_prop_odds <- function(game_id, market, player_name, outcome_name, con,
                             min_books = PROP_MIN_BOOKS,
                             main_line_tol = PROP_MAIN_LINE_TOL) {
  BOOK_PREF  <- c("pinnacle", "betonlineag", "lowvig", "draftkings", "fanduel")
  other_name <- if (outcome_name == "Over") "Under" else "Over"
  empty      <- list(book = NA_character_, odds = NA_integer_, point = NA_real_,
                     odds_other = NA_integer_, book_count = 0L)

  rows <- tryCatch(
    dbGetQuery(con, "
      SELECT bookmaker, outcome_name, price, point
      FROM player_prop_lines
      WHERE game_id       = ?
        AND market        = ?
        AND player_name   = ?
        AND outcome_name  IN (?, ?)
        AND snapshot_type = (
          SELECT snapshot_type FROM player_prop_lines
          WHERE game_id = ? AND player_name = ? AND market = ?
          ORDER BY pulled_at DESC LIMIT 1
        )
    ", list(game_id, market, player_name,
            outcome_name, other_name,
            game_id, player_name, market)),
    error = function(e) data.frame()
  )
  if (nrow(rows) == 0) return(empty)

  # ── Consensus point filter ─────────────────────────────────────────────────
  # Compute median point per outcome_name across all books, then discard rows
  # outside main_line_tol of that median.  This drops alt lines (e.g. an
  # Under 8.5 when every other book has Under 14.5) without any per-stat
  # hardcoding.
  rows <- rows |>
    dplyr::group_by(outcome_name) |>
    dplyr::mutate(median_pt = median(point, na.rm = TRUE)) |>
    dplyr::filter(abs(point - median_pt) <= main_line_tol) |>
    dplyr::ungroup()

  if (nrow(rows) == 0) return(empty)

  side_rows  <- rows[rows$outcome_name == outcome_name, ]
  other_rows <- rows[rows$outcome_name == other_name,   ]

  if (nrow(side_rows) == 0) return(empty)

  # ── Book depth gate ────────────────────────────────────────────────────────
  book_count <- length(unique(side_rows$bookmaker))
  if (book_count < min_books) {
    return(modifyList(empty, list(book_count = book_count)))
  }

  # ── Book preference ranking ────────────────────────────────────────────────
  side_rows$rank  <- match(tolower(side_rows$bookmaker),  BOOK_PREF, nomatch = 99L)
  side_rows       <- side_rows[order(side_rows$rank), ]

  other_odds <- if (nrow(other_rows) > 0) {
    other_rows$rank <- match(tolower(other_rows$bookmaker), BOOK_PREF, nomatch = 99L)
    other_rows      <- other_rows[order(other_rows$rank), ]
    as.integer(round(other_rows$price[1]))
  } else NA_integer_

  list(
    book       = side_rows$bookmaker[1],
    odds       = as.integer(round(side_rows$price[1])),
    point      = side_rows$point[1],
    odds_other = other_odds,
    book_count = book_count
  )
}
```

### Change 5 — Update the `prop` branch of `emit_wnba_bet_alert()`

**Find** the existing `} else if (market == "prop") {` block (~lines 231–243).
**Replace it with:**

```r
  } else if (market == "prop") {
    stat_market  <- STAT_MARKET_MAP[[stat]]
    outcome_name <- if (side == "over") "Over" else "Under"
    cfg  <- .get_prop_config(con)
    bo   <- .best_prop_odds(game_id, stat_market, player_name, outcome_name, con,
                             min_books     = cfg$min_books,
                             main_line_tol = cfg$main_line_tol)

    # Book depth / alt-line gate — skip before any pnorm() call
    if (bo$book_count < cfg$min_books) {
      message(sprintf(
        "[bet_alerts/WNBA] %s %s %s — %d book(s) at consensus point (min=%d), skipping",
        player_name, stat, side, bo$book_count, cfg$min_books
      ))
      return(invisible(list(message = NULL, model_prob = NA_real_, ev_pct = NA_real_,
                            kelly = 0, fired = FALSE, play = NULL, fair_odds = NA_real_)))
    }

    point <- bo$point
    play  <- sprintf("%s %s %.1f %s", player_name,
                     if (side == "over") "Over" else "Under", point, toupper(stat))
    calibrated_sd <- sd * .get_prop_sd_scale(con, stat, 1.0)
    model_prob <- if (side == "over")
      pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = FALSE)
    else
      pnorm(point, mean = model_line, sd = calibrated_sd, lower.tail = TRUE)
  }
```

### Change 6 — Devig the implied probability in the EV calculation

**Find** the existing EV block (two lines, currently just after the market
branches, before the `model_prob <- min(...)` ceiling line):

```r
  implied_prob  <- .american_to_prob(bo$odds)
  ev_pct        <- (model_prob - implied_prob) / implied_prob * 100
```

**Replace with:**

```r
  # Props: devig both sides so implied_prob reflects the fair share, not the
  # vigged raw price.  A -115/-115 line has 53.5% raw implied prob per side
  # but 50% fair prob -- using the raw price overstates every edge by ~3-4pp.
  # Totals/spreads use Pinnacle consensus (~1% hold), close enough that raw
  # implied prob is acceptable there.
  implied_prob <- if (market == "prop")
    .devig_prop_prob(bo$odds, bo$odds_other)
  else
    .american_to_prob(bo$odds)
  ev_pct <- (model_prob - implied_prob) / implied_prob * 100
```

---

## File 2: `scripts/db_setup.R`

Seed `prop_min_books` and `prop_main_line_tol` into `model_config`, same
pattern as `steam_min_books` / `steam_min_books` seeded in Session 9.

**Find** the block that seeds steam thresholds (looks like):
```r
  dbExecute(con, "INSERT OR IGNORE INTO model_config (param, value) VALUES ('steam_min_move', 0.5)")
  dbExecute(con, "INSERT OR IGNORE INTO model_config (param, value) VALUES ('steam_min_books', 2)")
```

**Add immediately after:**
```r
  # Props calibration params (read by .get_prop_config() in bet_alerts.R)
  dbExecute(con, "INSERT OR IGNORE INTO model_config (param, value) VALUES ('prop_min_books', 3)")
  dbExecute(con, "INSERT OR IGNORE INTO model_config (param, value) VALUES ('prop_main_line_tol', 1.5)")
```

---

## Verification

After deploying, run `send_prop_digest()` directly and check:

1. **Count drops dramatically** — 94 picks → low single digits is the expected
   outcome; 6-10 real edges on a full slate day is plausible.
2. **No picks with Fair -400** — that fair odds value implies ~80% model_prob,
   which the `MODEL_PROB_CEILING <- 0.80` should now also be catching. Any
   surviving pick at Fair -400 means the ceiling is the only thing saving it,
   not the new filters — investigate that player's rolling window.
3. **All surviving picks have 3+ books** — log `bo$book_count` temporarily if
   you want to confirm.
4. **Realistic EV range** — legitimate props edges on a well-calibrated model
   run 5–15%. Anything above 20% after this patch warrants manual inspection.

---

## Tuning knobs (via `model_config`, no code deploy needed)

| param | default | effect |
|---|---|---|
| `prop_min_books` | 3 | Raise to 4-5 for stricter liquidity requirement |
| `prop_main_line_tol` | 1.5 | Lower to 1.0 to tighten alt-line filter; raise to 2.0 if legitimate half-point moves get dropped |
