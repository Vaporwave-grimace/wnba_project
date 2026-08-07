# ATS Classification Fix — Build Spec

**Status:** Ready for implementation  
**Affected repos:** `wnba_project`, `bet_router` (dashboard panel suppression only)  
**Affected DBs:** `C:\Users\Mike\sports_data\wnba_pipeline.sqlite`, `C:\Users\Mike\sports_data\open_bets.db`

---

## Problem Summary

The ATS bucketing logic has no market-type filter. Two separate classification failures result:

**WNBA:** The evaluator regex matches `AST` and misidentifies player prop bets (Assists) as team spread bets. Prop line values (2.5, 3.5 assists) are parsed as point spread margins and land in spread buckets, producing nonsense metrics with extreme swings at tiny sample sizes (N = 4–8).

**MLB:** `open_bets.db` contains no full-game spread bets — only NRFI/YRFI 1st-inning binary bets. These have `score_diff = NULL`, and `ABS(NULL) < 2` causes every MLB bet to fall into the synthetic 0–2pt ATS bucket. The MLB ATS panel is entirely fabricated from misrouted NRFI/YRFI results.

**Confirmed misclassifications:**

| Sport | Entry | Incorrectly Bucketed As |
|---|---|---|
| WNBA | `AST\|OVER\|1.5\|...` | 0–2pt ATS |
| WNBA | `AST\|UNDER\|2.5\|...` | 2–3pt ATS |
| WNBA | `AST\|OVER\|3.5\|...` | 3–5pt ATS |
| MLB | `NRFI` / `YRFI` (score_diff = NULL) | 0–2pt ATS |

---

## Root Causes

1. **No market-type filter** — ATS bucketing runs against all bets regardless of `market` or `bet_type`, pulling in props and binary bets.
2. **AST string collision (WNBA)** — The evaluator regex matches `AST` as a prefix and conflates Assists props with ATS spread bets.
3. **NULL spread fall-through (MLB)** — `ABS(NULL)` evaluates as less than any threshold, routing all NRFI/YRFI bets into 0–2pt.
4. **Small N amplification** — Corrupt entries in low-sample buckets produce 0%/12.5%/25% swings that surface as alerts.

---

## Required Changes

### Fix 1 — ATS Market Filter (primary fix)

Locate the ATS calculation function (likely in `wnba_project/scripts/` — search for spread bucket logic or the ATS reporting section of the pipeline/reporting script).

Restrict ATS calculations to genuine spread bets using a **positive filter**, not a negative exclusion:

**R:**
```r
# Before: no market filter (or loose string match)
ats_bets <- bets

# After: explicit positive filter
ats_bets <- bets[bets$market == "SPREAD" | bets$bet_type == "FULL_GAME_SPREAD", ]
```

**SQL alternative** (if calculated at query time):
```sql
-- Before
SELECT * FROM bets WHERE result IS NOT NULL

-- After
SELECT * FROM bets
WHERE result IS NOT NULL
  AND (market = 'SPREAD' OR bet_type = 'FULL_GAME_SPREAD')
```

Use whichever layer the ATS calculation currently lives in. Do not use a negative `AST|` exclusion — fix at the market level so prop strings are irrelevant.

---

### Fix 2 — Evaluator Regex Disambiguation (secondary fix)

Locate the regex or string match that classifies bet type as ATS. It currently matches on `AST` loosely. Tighten it to require full token boundaries or an explicit market check.

**R example:**
```r
# Before (loose — matches AST|OVER|... as ATS)
is_ats <- grepl("ATS", side_string)

# After (require word boundary or explicit market field)
is_ats <- bets$market == "SPREAD" | bets$bet_type == "FULL_GAME_SPREAD"
```

Do not rely on `side_string` pattern matching to determine bet type. Use the `market` or `bet_type` column. If those columns don't exist or aren't populated for all rows, that's a schema gap to flag — do not work around it with string matching.

---

### Fix 3 — Minimum-N Guard on Bucketed Display

In the ATS bucketed reporting output (wherever spread buckets are rendered — Discord message, HTML report, or summary table), suppress or caveat any bucket with fewer than 10 bets.

```r
# After computing bucket stats:
ats_buckets <- ats_buckets[ats_buckets$n >= 10, ]

# Or: flag low-N buckets instead of dropping them
ats_buckets$display_note <- ifelse(ats_buckets$n < 10, "(small sample)", "")
```

The threshold (10) is a starting point — adjust based on what feels meaningful given typical WNBA slate sizes.

---

## Verification

After implementing, verify in `wnba_pipeline.sqlite`:

```sql
-- Should return 0 rows after fix
SELECT *
FROM bets
WHERE (side LIKE 'AST|%' OR market_type LIKE '%ASSIST%')
  AND bet_type IN ('FULL_GAME_SPREAD', 'SPREAD');

-- ATS bucket counts should now only reflect real spread bets
SELECT spread_bucket, COUNT(*) as n, ROUND(AVG(won), 3) as win_pct
FROM bets
WHERE market = 'SPREAD' OR bet_type = 'FULL_GAME_SPREAD'
GROUP BY spread_bucket
ORDER BY spread_bucket;
```

Expected: no prop strings in ATS results, no buckets with N < 10 showing in output.

---

## Notes for Claude Code

- Find the ATS evaluator by searching for `spread_bucket` or `grepl.*ATS` in `wnba_project/scripts/`
- The same market filter must be applied wherever ATS bucketing runs for any sport — search `bet_router` and all pipeline scripts for the bucket logic, not just `wnba_project`
- If `market` and `bet_type` columns are inconsistently populated, surface that — don't paper over it
- Behavior of all non-ATS metrics must stay identical
- The dashboard ATS panel must be suppressed entirely for any sport with zero qualifying spread bets after filtering — do not render an empty or zero-row ATS section; omit the panel for that sport
- Do not delete or modify NRFI/YRFI bet records — the data is correct, only the routing is wrong
