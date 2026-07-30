# WNBA Prop Multi-Market Correlation Collapse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `detect_prop_edges()` so that correlated same-player,
same-game, same-side picks across `pts`/`reb`/`ast`/`pra` collapse to a single
fired alert (the highest-EV one), fixing over-sized aggregate Kelly exposure to
one underlying projection signal.

**Architecture:** `detect_prop_edges()`'s external signature and return value
are unchanged. Internals restructure into three passes: dry-run every
candidate (`send_alerts = FALSE`, reusing the side-effect-free contract
`send_prop_digest()` already depends on), collapse the survivors via a new
pure, side-effect-free helper `.collapse_correlated_prop_edges()` (groups by
`(game_id, player_name, side)`, keeps the max-`ev_pct` winner per group via
`dplyr::slice_max()`), then real-fire only the winners.

**Tech Stack:** R, dplyr (already attached in `player_props.R`), DBI/RSQLite.

## Global Constraints

- `detect_prop_edges(con, creds, send_alerts = TRUE, season = ...)`'s
  signature and invisible-integer-count return value are unchanged — no
  caller (`run_pipeline.R`) needs to change.
- Grouping key is exactly `(game_id, player_name, side)` — an `Over` pick and
  an `Under` pick for the same player/game are independent and never compete.
- `send_prop_digest()` is untouched — still shows every candidate
  independently, no grouping applied there.
- Winner = max `ev_pct` within a group. No stake-scaling alternative.
- `.collapse_correlated_prop_edges()` must be a standalone, pure function (no
  DB access, no side effects) — this is what makes it directly unit-testable
  without any DB/stub setup.
- **No test in this plan may call `detect_prop_edges()` or
  `emit_wnba_bet_alert()` with `send_alerts = TRUE` against the REAL,
  unstubbed `emit_wnba_bet_alert()`.** That function's `open_bets` write uses
  a hardcoded path (`C:/Users/Mike/sports_data/open_bets.db`) that genuinely
  exists on the development machine — calling through to it with
  `send_alerts = TRUE` writes real fake rows into the live production betting
  database. The one test in this plan that needs `send_alerts = TRUE`
  semantics stubs `emit_wnba_bet_alert()` itself first (reassignment, restored
  via `on.exit()`, the same pattern already used for `send_discord()`
  elsewhere in this test file) so the real function body is never reached.
- Each winning candidate is evaluated twice in the real (unstubbed) code path
  (once dry, once real) — acceptable, matches the existing cost pattern of
  `detect_prop_edges()`/`send_prop_digest()` already redundantly evaluating
  the same candidates today. `sd`/`model_line` are cached from the dry-run
  pass and reused for the real-fire call.
- No test framework beyond this repo's `check()`/`pass()`/`fail()` convention.

---

### Task 1: Extract `.collapse_correlated_prop_edges()` and restructure `detect_prop_edges()`

**Files:**
- Modify: `scripts/shadow_model/player_props.R:330-398` (the entire
  `detect_prop_edges()` function body — add the new helper right before it)
- Test: `scripts/shadow_model/test_player_props.R` (append)

**Interfaces:**
- Consumes: `compute_prop_projection()`, `emit_wnba_bet_alert()` (both
  unchanged, from `player_props.R`/`bet_alerts.R`), `STAT_MARKET_MAP`.
- Produces: `.collapse_correlated_prop_edges(evaluated_df)` — takes a data
  frame with columns `game_id, player_name, stat, side, ev_pct, model_line,
  sd` and returns the same-shape data frame containing only the max-`ev_pct`
  row per `(game_id, player_name, side)` group. No other task/file depends on
  this function; `detect_prop_edges()` keeps its exact existing external
  signature and return type.

- [ ] **Step 1: Write the failing pure-function unit test**

Append to `scripts/shadow_model/test_player_props.R`, as a new "Task 13"
section, right before the file's final summary block (move that block to the
end again, as usual):

```r
# ── Task 13: .collapse_correlated_prop_edges() pure grouping logic ───────────
section("Task 13: .collapse_correlated_prop_edges() pure grouping logic")

check("keeps only the max-ev_pct row per (game_id, player_name, side) group; independent groups untouched", {
  synthetic <- data.frame(
    game_id     = c("game1", "game1", "game1", "game2"),
    player_name = c("PlayerA", "PlayerA", "PlayerA", "PlayerB"),
    stat        = c("pts", "pra", "pra", "pts"),
    side        = c("over", "over", "under", "over"),
    ev_pct      = c(50, 15, 60, 10),
    model_line  = c(11, 17, 17, 20),
    sd          = c(2.28, 2.28, 2.28, 3.0),
    stringsAsFactors = FALSE
  )
  winners <- .collapse_correlated_prop_edges(synthetic)

  stopifnot(nrow(winners) == 3L)

  over_a <- winners[winners$game_id == "game1" & winners$side == "over", ]
  stopifnot(nrow(over_a) == 1L, over_a$stat == "pts", abs(over_a$ev_pct - 50) < 1e-9)

  under_a <- winners[winners$game_id == "game1" & winners$side == "under", ]
  stopifnot(nrow(under_a) == 1L, under_a$stat == "pra", abs(under_a$ev_pct - 60) < 1e-9)

  over_b <- winners[winners$game_id == "game2", ]
  stopifnot(nrow(over_b) == 1L, over_b$stat == "pts", abs(over_b$ev_pct - 10) < 1e-9)
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — `could not find function ".collapse_correlated_prop_edges"`.

- [ ] **Step 3: Write the minimal implementation for the pure function**

In `scripts/shadow_model/player_props.R`, add this immediately before the
`detect_prop_edges <- function(...)` line (i.e. right after the existing
comment block that already precedes it — do not remove or alter that comment,
just insert the new function and its own comment above `detect_prop_edges`):

```r
# Pure, side-effect-free: groups dry-run-evaluated candidates by
# (game_id, player_name, side) and keeps only the max-ev_pct row per group.
# pra = pts+reb+ast exactly, so a bias in one stat shows up across all four --
# this collapses that redundancy down to the single highest-EV derivative.
# Over and Under are never grouped together (a real, independent signal in
# opposite directions is not noise, not redundancy). No DB/network access --
# kept standalone specifically so it's directly unit-testable against a
# synthetic data frame, with no risk of touching emit_wnba_bet_alert()'s
# hardcoded production open_bets.db path.
.collapse_correlated_prop_edges <- function(evaluated_df) {
  evaluated_df |>
    dplyr::group_by(game_id, player_name, side) |>
    dplyr::slice_max(ev_pct, n = 1, with_ties = FALSE) |>
    dplyr::ungroup()
}

```

- [ ] **Step 4: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)` (Task 13's pure-function test now passes;
`detect_prop_edges()` itself is not yet wired to use it).

- [ ] **Step 5: Commit the pure function**

```bash
git add scripts/shadow_model/player_props.R scripts/shadow_model/test_player_props.R
git commit -m "feat: add pure .collapse_correlated_prop_edges() grouping helper"
```

- [ ] **Step 6: Write the failing integration-wiring test**

Append to `scripts/shadow_model/test_player_props.R`, as a new "Task 14"
section, right before the file's final summary block (move it to the end
again):

```r
# ── Task 14: detect_prop_edges() wires the collapse helper end-to-end ────────
section("Task 14: detect_prop_edges() real-fires only the collapsed winners")

tmp_db14b <- tempfile(fileext = ".sqlite")
init_db(tmp_db14b)
con14b <- open_wnba_db(tmp_db14b)

# Real player_box_scores fixture so compute_prop_projection() succeeds for
# both pts and pra (reb/ast are hardcoded constants by seed_player_games(),
# so pra inherits pts's real variance -- same fixture shape as Tasks 4/8/9/10/
# 13b above). The exact market lines/prices don't matter here since
# emit_wnba_bet_alert() itself is stubbed below -- only candidate discovery
# (which markets exist for this game/player) matters.
seed_player_games(con14b, "Wired Test Player", c(10,10, 8,12,9,11,10,13,7,10,12,8))

dbExecute(con14b, "
  INSERT INTO player_prop_lines
    (game_id, snapshot_type, market, home_team, away_team, bookmaker,
     player_name, outcome_name, price, point, commence_time, pulled_at)
  VALUES
    ('game16', 'midday', 'player_points', 'Some Team', 'Rival Team', 'pinnacle',
     'Wired Test Player', 'Over', -110, 7.5, datetime('now', '+2 hours'), datetime('now')),
    ('game16', 'midday', 'player_points_rebounds_assists', 'Some Team', 'Rival Team', 'pinnacle',
     'Wired Test Player', 'Over', -110, 16.5, datetime('now', '+2 hours'), datetime('now'))
")

fake_creds14b <- list(telegram_bot_token = "x", telegram_chat_id = "x",
                      discord_bot_token = "x", discord_webhook_url = "x")

check("only the higher-EV correlated candidate (pts, not pra) real-fires; the independent Under candidate fires too", {
  # Stub emit_wnba_bet_alert() itself (not just send_discord()) so the real
  # function body -- and its hardcoded production open_bets.db write -- is
  # NEVER reached, even with send_alerts = TRUE below. Canned ev_pct per
  # (stat, side) deterministically makes pts win the Over group; pra/under
  # has no competing candidate so it always "wins" its own group trivially.
  original_emit <- emit_wnba_bet_alert
  emit_wnba_bet_alert <<- function(game_id, market, side, model_line, mkt_line,
                                    con, creds, steam_confirmed = FALSE,
                                    player_name = NULL, stat = NULL, sd = NULL,
                                    send_alerts = TRUE) {
    ev <- if (stat == "pts" && side == "over") 50
          else if (stat == "pra" && side == "over") 15
          else if (stat == "pra" && side == "under") 60
          else NA_real_
    if (is.na(ev)) {
      return(invisible(list(message = NULL, model_prob = NA_real_, ev_pct = NA_real_,
                            kelly = 0, fired = FALSE, play = NULL, fair_odds = NA_real_)))
    }
    play_str <- sprintf("%s %s %s", player_name, if (side == "over") "Over" else "Under", toupper(stat))
    invisible(list(message = if (send_alerts) "posted" else NULL,
                  model_prob = 0.6, ev_pct = ev, kelly = 0.01,
                  fired = send_alerts, play = play_str, fair_odds = -150))
  }
  on.exit(emit_wnba_bet_alert <<- original_emit, add = TRUE)

  n <- suppressWarnings(suppressMessages(
    detect_prop_edges(con14b, fake_creds14b, send_alerts = TRUE, season = 2026L)
  ))

  # Only 2 real-fires expected: pts-over (winner of the Over group) and
  # pra-under (no competing candidate) -- NOT 3, which would mean pra-over
  # also fired and no collapse happened.
  stopifnot(n == 2L)
})

dbDisconnect(con14b)
file.remove(tmp_db14b)
```

- [ ] **Step 7: Run test to verify it fails**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: FAIL — with the current (pre-restructure) `detect_prop_edges()`,
all 3 real candidates (pts-over, pra-over, pra-under — pts-under has no
seeded market row at all, so the stub's `NA` branch would apply if it were
ever called, but no `player_points` `Under` candidate exists for it to be
called with in the first place) fire independently, so `n == 3`, not `2`.

- [ ] **Step 8: Write the minimal implementation wiring the helper in**

In `scripts/shadow_model/player_props.R`, replace the entire
`detect_prop_edges()` function (from the `detect_prop_edges <- function(...)`
line through its closing `}`) with:

```r
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
    AND datetime(ppl.commence_time) > datetime('now')
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
```

- [ ] **Step 9: Run test to verify it passes**

Run: `Rscript scripts/shadow_model/test_player_props.R`
Expected: `ALL PASS -- 0 error(s)` (all of Tasks 8/9/9b/10/11/12/13/14 pass —
Tasks 8/9/9b/10/11/12 are pre-existing and must remain unaffected by this
restructure since `detect_prop_edges()`'s external behavior for a
single-candidate-per-group case is unchanged).

- [ ] **Step 10: Commit**

```bash
git add scripts/shadow_model/player_props.R scripts/shadow_model/test_player_props.R
git commit -m "feat: wire correlation collapse into detect_prop_edges()"
```

---

## Manual Verification (post-implementation, live data)

Not automated — run once against real, currently-posted prop lines to confirm
the collapse behaves sensibly before relying on it live:

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
n <- detect_prop_edges(con, creds, send_alerts = FALSE)  # dry run, no real posts
cat("Would fire:", n, "alert(s)\n")
dbDisconnect(con)
```

Confirm the count is not obviously higher than the number of distinct players
with a real edge that day (i.e. no player shows up more than once per side).
