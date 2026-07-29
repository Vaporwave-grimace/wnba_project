# WNBA Props Devig/Consensus-Line/Book-Depth Patch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three compounding bugs inflating WNBA player-prop EV (no devig, no
consensus-line filter, no book-depth requirement) in `scripts/bet_alerts.R`, with
two new tunables seeded in `model_config`.

**Architecture:** `db_setup.R` seeds `prop_min_books`/`prop_main_line_tol`
defaults. `bet_alerts.R` gains three helpers (`.get_prop_config()`,
`.devig_prop_prob()`, a rewritten `.best_prop_odds()` that adds a consensus-point
filter + book-depth count + opposite-side price) and the `emit_wnba_bet_alert()`
prop branch is updated to gate on book depth and devig its EV calculation.

**Tech Stack:** R, DBI/RSQLite, dplyr (already a project dependency; new code
uses fully-qualified `dplyr::` calls, no new `library()` call needed).

## Global Constraints

- `PROP_MIN_BOOKS <- 3L` — minimum distinct books required at the consensus point
  before a prop side is evaluated.
- `PROP_MAIN_LINE_TOL <- 1.5` — max deviation from the median point across books
  before a row is treated as an alt line and discarded.
- `model_config` params: `prop_min_books` (default `3`), `prop_main_line_tol`
  (default `1.5`) — read via `.get_prop_config(con)`, module constants are the
  fallback when `con` is unavailable or the row is missing.
- Totals/spreads EV calculation is unchanged — devig applies to `market == "prop"`
  only.
- `compute_prop_projection()`, `calibrate_props.R`, `.get_prop_sd_scale()` (all
  from the previous branch) are untouched.
- No test framework beyond this repo's `check()`/`pass()`/`fail()` convention —
  real temp SQLite files, no mocking.

---

### Task 1: Seed `prop_min_books`/`prop_main_line_tol` in `model_config`

**Files:**
- Modify: `scripts/db_setup.R:267-280` (the `defaults` list + loop)
- Test: `scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Produces: two new rows in `model_config` after `init_db()` runs —
  `('prop_min_books', 3, ...)` and `('prop_main_line_tol', 1.5, ...)`. Task 2's
  `.get_prop_config()` reads these by exact param name.

**Before you start:** `scripts/db_setup.R` currently has an unrelated, pre-existing
uncommitted change sitting in the working tree (a `player_box_scores` migration
for Base44 card-display columns, around `db_setup.R:302-322` — added by other,
unrelated work, not part of this patch). Isolate it first so your commit doesn't
sweep it in:

```bash
cd "g:/My Drive/Scripting Projects/wnba_project"
git status --short scripts/db_setup.R
```

If it shows `M scripts/db_setup.R`, commit that pre-existing content on its own
BEFORE starting Step 1 below:

```bash
git add scripts/db_setup.R
git commit -m "feat: migrate player_box_scores with Base44 card-display columns"
```

(If `git status --short scripts/db_setup.R` shows nothing, someone already
isolated it — skip straight to Step 1.)

- [ ] **Step 1: Write the failing test**

Append to `scripts/shadow_model/test_player_props.R`, in the "Task 1: player props
schema" section (right after the existing `check("odds_api_quota_log table
exists", ...)` block, before `check("init_db is safe to re-run (idempotent)",
...)`):

```r
check("prop_min_books seeded in model_config with default 3", {
  v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'prop_min_books'")$value
  stopifnot(length(v) == 1, abs(v - 3) < 1e-9)
})
check("prop_main_line_tol seeded in model_config with default 1.5", {
  v <- dbGetQuery(con, "SELECT value FROM model_config WHERE param = 'prop_main_line_tol'")$value
  stopifnot(length(v) == 1, abs(v - 1.5) < 1e-9)
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — both new checks report `length(v) == 1` is not `TRUE` (no rows
exist yet for either param).

- [ ] **Step 3: Write minimal implementation**

In `scripts/db_setup.R`, modify the `defaults` list (currently lines 267-275) by
adding two entries. The full block becomes:

```r
  defaults <- list(
    list("dev_threshold",       1.5,   "initial seed — Pinnacle deviation gate (pts)"),
    list("injury_adj_cap",      6.0,   "initial seed — per-side injury adj clamp (pts); prevents multi-player stacking from producing unrealistic total swings"),
    list("injury_impact_out",   -3.0,  "initial seed — Out player scoring impact"),
    list("injury_impact_doubtful", -2.0, "initial seed"),
    list("injury_impact_gtd",   -1.0,  "initial seed — GTD/Questionable impact"),
    list("steam_min_move",  0.5, "initial seed — matches STEAM_MIN_MOVE default in odds_ingest.R"),
    list("steam_min_books", 2,   "initial seed — matches STEAM_MIN_BOOKS default in odds_ingest.R"),
    list("prop_min_books",      3,   "initial seed — matches PROP_MIN_BOOKS default in bet_alerts.R"),
    list("prop_main_line_tol",  1.5, "initial seed — matches PROP_MAIN_LINE_TOL default in bet_alerts.R")
  )
```

(Only the two new `list(...)` entries at the end are new — everything above them
is unchanged, shown here for exact context so you can locate and edit the block
without ambiguity.)

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/db_setup.R scripts/shadow_model/test_player_props.R
git commit -m "feat: seed prop_min_books/prop_main_line_tol in model_config"
```

---

### Task 2: Devig/consensus-filter/book-depth helpers in `bet_alerts.R`

**Files:**
- Modify: `scripts/bet_alerts.R` (add constants + 2 new helpers + replace
  `.best_prop_odds()`)
- Modify: `scripts/shadow_model/test_player_props.R` (fix 4 existing fixtures,
  append new helper-level tests)

**Interfaces:**
- Consumes: `model_config` rows from Task 1 (`prop_min_books`,
  `prop_main_line_tol`), read through `.get_prop_config(con)`.
- Produces:
  - `.get_prop_config(con)` → `list(min_books = <integer>, main_line_tol =
    <numeric>)`
  - `.devig_prop_prob(odds_side, odds_other)` → `<numeric>` fair probability for
    `odds_side` (falls back to raw implied prob if `odds_other` is `NA`)
  - `.best_prop_odds(game_id, market, player_name, outcome_name, con, min_books =
    PROP_MIN_BOOKS, main_line_tol = PROP_MAIN_LINE_TOL)` → `list(book, odds,
    point, odds_other, book_count)`. Task 3 consumes `book_count` (to gate) and
    `odds_other` (to devig).

**Why this task must also fix existing fixtures:** replacing `.best_prop_odds()`
changes its behavior immediately, before Task 3 adds an explicit gate message —
once fewer than `min_books` books exist, the function now returns `book = NA`,
`odds = NA`, `point = NA` (not just the old real values), which the *existing*,
not-yet-modified `emit_wnba_bet_alert()` prop branch already handles via its
`is.na(bo$odds)` early return (line 247) — just silently, as "no odds found"
instead of a real alert. Every current single-book fixture would start failing
this task's own test run if left unfixed.

- [ ] **Step 1: Write the failing tests**

First, fix the 4 existing fixtures in `scripts/shadow_model/test_player_props.R`
so they have 3+ books per side wherever the test expects a real result. Each
diff below is additive (new `player_prop_lines` rows) — do not remove any
existing row.

**Fixture fix A — Task 8 (`game8`, around line 333-340):** the existing
`INSERT` has one row (`pinnacle`, Over, 7.5). Change it to:

```r
dbExecute(con8, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 7.5, datetime('now')),
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Over', -105, 7.5, datetime('now')),
    ('game8', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Over', -110, 7.5, datetime('now'))
")
```

**Fixture fix B — Task 9 (`game9`, around line 394-403):** the existing `INSERT`
has two rows (`pinnacle` Over + Under, both at 7.5). Change it to:

```r
dbExecute(con9, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, commence_time, pulled_at)
  VALUES
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Over', -105, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Over', -110, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Under', -500, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Under', -450, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9', 'midday', 'player_points', 'Some Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Under', -480, 7.5, datetime('now', '+2 hours'), datetime('now'))
")
```

**Fixture fix C — Task 9b (`game9b`, around line 442-449):** the existing
`INSERT` has one row (`pinnacle`, Over, 8.5). Change it to:

```r
dbExecute(con9, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, commence_time, pulled_at)
  VALUES
    ('game9b', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Backup Scorer', 'Over', -110, 8.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9b', 'midday', 'player_points', 'Some Team', 'Rival Team', 'draftkings',
     'Backup Scorer', 'Over', -105, 8.5, datetime('now', '+2 hours'), datetime('now')),
    ('game9b', 'midday', 'player_points', 'Some Team', 'Rival Team', 'fanduel',
     'Backup Scorer', 'Over', -108, 8.5, datetime('now', '+2 hours'), datetime('now'))
")
```

**Fixture fix D — Task 10 (`game10`, around line 502-509):** the existing
`INSERT` has one row (`pinnacle`, Over, 13.5). Change it to:

```r
dbExecute(con10, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game10', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Steady Scorer', 'Over', 120, 13.5, datetime('now')),
    ('game10', 'midday', 'player_points', 'Home Team', 'Rival Team', 'draftkings',
     'Steady Scorer', 'Over', -105, 13.5, datetime('now')),
    ('game10', 'midday', 'player_points', 'Home Team', 'Rival Team', 'fanduel',
     'Steady Scorer', 'Over', -110, 13.5, datetime('now'))
")
```

Now append new helper-level tests as a new "Task 11" section in
`scripts/shadow_model/test_player_props.R`, right before the file's final
`cat(sprintf(...))` summary block (move that block to the end again after
appending, as usual):

```r
# ── Task 11: devig / consensus-line / book-depth helpers ─────────────────────
section("Task 11: .devig_prop_prob() / .get_prop_config() / .best_prop_odds()")

check(".devig_prop_prob(-115, -115) returns exactly 0.5 (symmetric vig removed)", {
  p <- .devig_prop_prob(-115, -115)
  stopifnot(abs(p - 0.5) < 1e-9)
})
check(".devig_prop_prob falls back to raw implied prob when odds_other is NA", {
  p <- .devig_prop_prob(-115, NA_real_)
  stopifnot(abs(p - .american_to_prob(-115)) < 1e-9)
})
check(".get_prop_config falls back to module constants with con = NULL", {
  cfg <- .get_prop_config(NULL)
  stopifnot(cfg$min_books == PROP_MIN_BOOKS, abs(cfg$main_line_tol - PROP_MAIN_LINE_TOL) < 1e-9)
})

tmp_db11 <- tempfile(fileext = ".sqlite")
init_db(tmp_db11)
con11 <- open_wnba_db(tmp_db11)

check(".get_prop_config reads seeded model_config values", {
  cfg <- .get_prop_config(con11)
  stopifnot(cfg$min_books == 3L, abs(cfg$main_line_tol - 1.5) < 1e-9)
})

# 3 books at the consensus point (14.5) + 1 alt-line book (8.5) for the same
# player/market/side -- the alt-line book must be filtered out by the
# consensus-point check, not just outvoted by preference ranking.
dbExecute(con11, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'pinnacle',
     'Test Player', 'Under', -110, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'draftkings',
     'Test Player', 'Under', -105, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'fanduel',
     'Test Player', 'Under', -108, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'betmgm',
     'Test Player', 'Under', 250, 8.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'pinnacle',
     'Test Player', 'Over', -108, 14.5, datetime('now')),
    ('game11', 'midday', 'player_rebounds', 'Home Team', 'Away Team', 'draftkings',
     'Test Player', 'Over', -102, 14.5, datetime('now'))
")

check("consensus-point filter excludes the alt-line book from book_count", {
  bo <- .best_prop_odds('game11', 'player_rebounds', 'Test Player', 'Under', con11)
  stopifnot(bo$book_count == 3L)
  stopifnot(abs(bo$point - 14.5) < 1e-9)
})
check("odds_other reflects the opposite side's best-ranked price at the consensus point", {
  # 'Over' rows: pinnacle -108, draftkings -102, both at 14.5. pinnacle ranks
  # first in BOOK_PREF, so odds_other must be pinnacle's -108, not draftkings'
  # -102 -- proves real selection, not just presence.
  bo <- .best_prop_odds('game11', 'player_rebounds', 'Test Player', 'Under', con11)
  stopifnot(!is.na(bo$odds_other))
  stopifnot(bo$odds_other == -108L)
})
# Only 2 books for this player/side -- below the default min_books (3). Also
# no opposite-side ('Under') rows at all for this player/market.
dbExecute(con11, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game11b', 'midday', 'player_assists', 'Home Team', 'Away Team', 'pinnacle',
     'Thin Player', 'Over', -110, 5.5, datetime('now')),
    ('game11b', 'midday', 'player_assists', 'Home Team', 'Away Team', 'draftkings',
     'Thin Player', 'Over', -105, 5.5, datetime('now'))
")
check("book_count below min_books returns NA book/odds/point (caller must gate)", {
  bo <- .best_prop_odds('game11b', 'player_assists', 'Thin Player', 'Over', con11)
  stopifnot(bo$book_count == 2L)
  stopifnot(is.na(bo$odds), is.na(bo$point))
})
check("odds_other is NA when no opposite-side rows exist at all", {
  bo <- .best_prop_odds('game11b', 'player_assists', 'Thin Player', 'Over', con11)
  stopifnot(is.na(bo$odds_other))
})

dbDisconnect(con11)
file.remove(tmp_db11)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `.devig_prop_prob`/`.get_prop_config` checks fail with "could
not find function"; `.best_prop_odds` checks fail because the current function
has no `odds_other`/`book_count` fields and applies no consensus filter (the
`Test Player` check would see `book_count` undefined — R errors accessing a
missing list element with `$`, giving `NULL` not `3L`, so `stopifnot` fails).

- [ ] **Step 3: Write minimal implementation**

In `scripts/bet_alerts.R`, add two constants right after `KELLY_STAKE_CEILING`
(currently line 70, before the `.BROADCAST_CHANNEL` line):

```r

# Minimum number of distinct books that must post a prop line (on the
# requested side, at the consensus point) before we'll evaluate it. Seeded
# in model_config as prop_min_books; this module constant is the fallback
# when con is unavailable. Mirrors the steam_min_books pattern.
PROP_MIN_BOOKS <- 3L

# Maximum deviation from the median point across books before a row is
# treated as an alt line and discarded. Half-point line moves shift by 0.5,
# so 1.5 covers normal market drift without catching true alt lines. Seeded
# in model_config as prop_main_line_tol.
PROP_MAIN_LINE_TOL <- 1.5
```

Add `.get_prop_config()` right after `.get_prop_sd_scale()` (currently ends at
line 53, before the `MODEL_PROB_CEILING` comment block):

```r

# Reads prop_min_books/prop_main_line_tol from model_config with module-constant
# fallbacks, same pattern as .get_wnba_sd().
.get_prop_config <- function(con) {
  list(
    min_books = tryCatch({
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

Note: `.get_prop_config(NULL)` must also work (Task 11's test calls it with
`con = NULL`) — `dbGetQuery(NULL, ...)` throws an error, which the `tryCatch`
already catches, falling back to the module constants. No extra `is.null(con)`
guard needed here (unlike `.get_wnba_sd()`/`.get_prop_sd_scale()`, which check
`is.null(con)` first purely as a fast path — the `tryCatch` alone is sufficient
correctness-wise).

Add `.devig_prop_prob()` right after `.prob_to_american()` (currently lines
82-86, before `.encode_prop_bet_side()`):

```r

# Two-outcome multiplicative devig: scales each side's raw implied prob by
# their sum so they sum to 1.0, removing the book's vig. Returns the fair
# probability for odds_side. Falls back to raw implied prob if odds_other is
# NA -- callers should treat that as illiquid/one-sided and use the result
# accordingly (it is not itself a skip signal).
.devig_prop_prob <- function(odds_side, odds_other) {
  p1 <- .american_to_prob(odds_side)
  if (is.na(odds_other)) return(p1)
  p2    <- .american_to_prob(odds_other)
  total <- p1 + p2
  if (is.na(total) || total <= 0) return(p1)
  p1 / total
}
```

Replace the entire existing `.best_prop_odds()` function (currently lines
144-169) with:

```r
# Best available line for a prop (player + market + outcome_name), from the
# most recent snapshot for the game.
#
# Returns list(book, odds, point, odds_other, book_count).
#   odds_other  -- best-ranked opposite-side price at the consensus point (NA if missing)
#   book_count  -- distinct books posting the requested side at the consensus point
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
  # outside main_line_tol of that median. This drops alt lines (e.g. an Under
  # 8.5 when every other book has Under 14.5) without any per-stat hardcoding.
  rows <- rows |>
    dplyr::group_by(outcome_name) |>
    dplyr::mutate(median_pt = median(point, na.rm = TRUE)) |>
    dplyr::filter(abs(point - median_pt) <= main_line_tol) |>
    dplyr::ungroup()

  if (nrow(rows) == 0) return(empty)

  side_rows  <- rows[rows$outcome_name == outcome_name, ]
  other_rows <- rows[rows$outcome_name == other_name,   ]

  if (nrow(side_rows) == 0) return(empty)

  # ── Book depth gate ─────────────────────────────────────────────────────────
  book_count <- length(unique(side_rows$bookmaker))
  if (book_count < min_books) {
    return(modifyList(empty, list(book_count = book_count)))
  }

  # ── Book preference ranking ──────────────────────────────────────────────────
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

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)` (this includes Tasks 8, 9, 10 with their fixed
fixtures, and the new Task 11 section).

- [ ] **Step 5: Commit**

```bash
git add scripts/bet_alerts.R scripts/shadow_model/test_player_props.R
git commit -m "feat: add devig/consensus-line/book-depth helpers to bet_alerts.R"
```

---

### Task 3: Wire the book-depth gate + devig into `emit_wnba_bet_alert()`

**Files:**
- Modify: `scripts/bet_alerts.R` (prop branch + EV block)
- Test: `scripts/shadow_model/test_player_props.R` (append one new test)

**Interfaces:**
- Consumes: `.get_prop_config()`, `.best_prop_odds()`'s `book_count`/`odds_other`
  fields, `.devig_prop_prob()` (all from Task 2).
- Produces: no new functions — this task changes `emit_wnba_bet_alert()`'s
  internal behavior only. No other task depends on anything new here.

- [ ] **Step 1: Write the failing test**

Append to `scripts/shadow_model/test_player_props.R`, as a new "Task 12" section,
right before the file's final summary block (move it to the end again):

```r
# ── Task 12: book-depth gate fires through the full emitter ──────────────────
section("Task 12: emit_wnba_bet_alert() prop book-depth gate")

tmp_db12 <- tempfile(fileext = ".sqlite")
init_db(tmp_db12)
con12 <- open_wnba_db(tmp_db12)

dbExecute(con12, "
  INSERT INTO games (game_id, commence_time, home_team, away_team)
  VALUES ('game12', '2026-06-10T23:00:00Z', 'Home Team', 'Rival Team')
")
dbExecute(con12, "
  INSERT INTO lines (game_id, snapshot_type, home_team, away_team, commence_time)
  VALUES ('game12', 'midday', 'Home Team', 'Rival Team', '2026-06-10T23:00:00Z')
")
# Only 1 book -- below the default min_books (3).
dbExecute(con12, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, pulled_at)
  VALUES
    ('game12', 'midday', 'player_points', 'Home Team', 'Rival Team', 'pinnacle',
     'Thin Coverage Player', 'Over', 120, 7.5, datetime('now'))
")

fake_creds12 <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                     discord_bot_token = "x", discord_webhook_url = "x")

check("book-depth gate returns NA model_prob / NULL play / fired=FALSE for a thin market", {
  res <- suppressMessages(emit_wnba_bet_alert(
    game_id = "game12", market = "prop", side = "over",
    model_line = 11, mkt_line = NA_real_,
    con = con12, creds = fake_creds12,
    player_name = "Thin Coverage Player", stat = "pts", sd = 1.9,
    send_alerts = FALSE
  ))
  stopifnot(is.na(res$model_prob))
  stopifnot(is.null(res$play))
  stopifnot(isFALSE(res$fired))
})

dbDisconnect(con12)
file.remove(tmp_db12)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `res$model_prob` is a real (non-NA) number today, because the
current prop branch computes `pnorm()` unconditionally without checking
`bo$book_count` first.

- [ ] **Step 3: Write minimal implementation**

In `scripts/bet_alerts.R`, replace the entire `} else if (market == "prop") {`
block (currently lines 231-243):

```r
  } else if (market == "prop") {
    stat_market  <- STAT_MARKET_MAP[[stat]]
    outcome_name <- if (side == "over") "Over" else "Under"
    bo    <- .best_prop_odds(game_id, stat_market, player_name, outcome_name, con)
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

with:

```r
  } else if (market == "prop") {
    stat_market  <- STAT_MARKET_MAP[[stat]]
    outcome_name <- if (side == "over") "Over" else "Under"
    cfg <- .get_prop_config(con)
    bo  <- .best_prop_odds(game_id, stat_market, player_name, outcome_name, con,
                            min_books     = cfg$min_books,
                            main_line_tol = cfg$main_line_tol)

    # Book depth / alt-line gate -- skip before any pnorm() call
    if (bo$book_count < cfg$min_books) {
      message(sprintf(
        "[bet_alerts/WNBA] %s %s %s -- %d book(s) at consensus point (min=%d), skipping",
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

Then replace the EV block (currently lines 256-257):

```r
  implied_prob  <- .american_to_prob(bo$odds)
  ev_pct        <- (model_prob - implied_prob) / implied_prob * 100
```

with:

```r
  # Props: devig both sides so implied_prob reflects the fair share, not the
  # vigged raw price. A -115/-115 line has 53.5% raw implied prob per side but
  # 50% fair prob -- using the raw price overstates every edge by ~3-4pp.
  # Totals/spreads use Pinnacle consensus (~1% hold), close enough that raw
  # implied prob is acceptable there.
  implied_prob <- if (market == "prop")
    .devig_prop_prob(bo$odds, bo$odds_other)
  else
    .american_to_prob(bo$odds)
  ev_pct <- (model_prob - implied_prob) / implied_prob * 100
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)`

Also run the previous branch's calibration test suite to confirm nothing there
broke (it shares `bet_alerts.R`):

Run: `Rscript scripts/shadow_model/test_calibrate_props.R`
Expected: `ALL PASS -- 0 error(s)`

- [ ] **Step 5: Commit**

```bash
git add scripts/bet_alerts.R scripts/shadow_model/test_player_props.R
git commit -m "feat: gate props on book depth and devig EV in emit_wnba_bet_alert()"
```

---

## Manual Verification (post-implementation, live data)

Not automated — run once against the real `wnba_pipeline.sqlite` to confirm the
patch actually shrinks the inflated-edge problem before relying on it live:

```r
setwd("g:/My Drive/Scripting Projects/wnba_project")
source("scripts/db_setup.R")
source("scripts/shadow_model/features.R")
source("scripts/shadow_model/predict.R")
source("scripts/shadow_model/mispricing.R")
source("scripts/injury_alert.R")
source("scripts/bet_alerts.R")

con <- open_wnba_db()
creds <- jsonlite::fromJSON("credentials.json")
n <- send_prop_digest(con, creds, min_ev = 6.0)
cat("Digest picks at >=6% EV:", n, "\n")
dbDisconnect(con)
```

Confirm: pick count drops sharply from the pre-patch baseline (94 picks) —
single digits on a normal slate is the expected outcome. Confirm no surviving
pick shows a fair price implying ~80% model_prob (that would mean
`MODEL_PROB_CEILING` is the only thing saving it, not these new filters —
investigate that player's rolling window if so). Confirm remaining picks are in
a plausible 5-15% EV range.
