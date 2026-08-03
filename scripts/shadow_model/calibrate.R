# scripts/shadow_model/calibrate.R
# Calibration curve and CLV summary
#
# Queries the clv_log for completed games and generates:
#   1. CLV distribution (did simulated bets beat the close?)
#   2. Calibration curve (model predictions vs. actual outcomes)
#   3. Market blindspot summary (where the model consistently diverges)
#
# Run interactively or schedule weekly after enough data accumulates.

library(dplyr)
library(tidyr)
library(ggplot2)
library(DBI)
library(RSQLite)
library(lubridate)
library(here)

DB_PATH     <- "C:/Users/Mike/sports_data/wnba_pipeline.sqlite"
REPORTS_DIR <- here("reports")
dir.create(REPORTS_DIR, showWarnings = FALSE)

con <- dbConnect(RSQLite::SQLite(), DB_PATH)

# ── Pull completed CLV log ────────────────────────────────────────────────────

clv <- tryCatch(
  dbGetQuery(con, "
    SELECT *
    FROM clv_log
    WHERE clv IS NOT NULL
      AND closing_line IS NOT NULL
  ") |> as_tibble() |>
    mutate(logged_at = ymd_hms(logged_at, tz = "UTC")),
  error = function(e) {
    dbDisconnect(con)
    stop("Could not query clv_log: ", conditionMessage(e))
  }
)

if (nrow(clv) == 0) {
  dbDisconnect(con)
  message("No completed CLV entries yet. Run the pipeline for a few weeks first.")
  stop("Nothing to calibrate yet.", call. = FALSE)
}

message("Analysing ", nrow(clv), " completed simulated positions")

# ── CLV distribution ──────────────────────────────────────────────────────────

# Positive CLV = closing line moved in our favour (beat the close)
clv_summary <- clv |>
  group_by(market) |>
  summarise(
    n            = n(),
    mean_clv     = mean(clv, na.rm = TRUE),
    median_clv   = median(clv, na.rm = TRUE),
    pct_positive = mean(clv > 0, na.rm = TRUE) * 100,
    rmse_vs_close= sqrt(mean((model_line - closing_line)^2, na.rm = TRUE)),
    .groups      = "drop"
  )

message("\n── CLV Summary ──────────────────────────────────────────────────")
print(clv_summary)

# ── Pull actual outcomes for calibration curve ────────────────────────────────

outcomes <- dbGetQuery(con, "
  SELECT game_id, actual_total, actual_spread
  FROM game_outcomes
") |> as_tibble()

clv_outcomes <- clv |>
  left_join(outcomes, by = "game_id") |>
  mutate(
    actual = case_when(
      market == "totals"  ~ actual_total,
      market == "spreads" ~ actual_spread
    ),
    residual = model_line - actual
  ) |>
  filter(!is.na(actual))

# ── Calibration curve ─────────────────────────────────────────────────────────

# Bin model predictions and compare mean actual outcome per bin
calibration_curve <- function(df, market_label) {
  df |>
    filter(market == market_label) |>
    mutate(pred_bin = cut(model_line,
                          breaks = quantile(model_line, probs = seq(0, 1, 0.1),
                                            na.rm = TRUE),
                          include.lowest = TRUE)) |>
    group_by(pred_bin) |>
    summarise(
      mean_pred   = mean(model_line, na.rm = TRUE),
      mean_actual = mean(actual,     na.rm = TRUE),
      n           = n(),
      .groups     = "drop"
    ) |>
    mutate(market = market_label)
}

cal_totals  <- calibration_curve(clv_outcomes, "totals")
cal_spreads <- calibration_curve(clv_outcomes, "spreads")
cal_all     <- bind_rows(cal_totals, cal_spreads)

# Plot
p_cal <- ggplot(cal_all, aes(x = mean_pred, y = mean_actual, size = n)) +
  geom_point(colour = "#2E86AB", alpha = 0.8) +
  geom_abline(linetype = "dashed", colour = "grey50") +
  facet_wrap(~market, scales = "free") +
  labs(
    title    = "WNBA Shadow Model — Calibration Curve",
    subtitle = paste0("n = ", nrow(clv_outcomes), " completed games"),
    x        = "Model Prediction",
    y        = "Actual Outcome",
    size     = "Games"
  ) +
  theme_minimal(base_size = 13)

ggsave(file.path(REPORTS_DIR, "calibration_curve.png"),
       p_cal, width = 10, height = 5, dpi = 150)
message("Calibration curve saved: reports/calibration_curve.png")

# ── Residual bias over time ───────────────────────────────────────────────────
# model_line - actual, binned weekly. Distinct from the calibration curve above
# (which checks whether predictions track outcomes across the *range* of
# predictions) -- this checks whether the model's error has a persistent
# directional lean over *time*, and whether that lean is growing, shrinking,
# or holding steady as more games accumulate. Investigated 2026-07-25: overall
# mean_residual (-2.2 to -2.5 pts) was not statistically distinguishable from
# zero at n~100/market (95% CI spanned zero both markets) -- not corrected,
# since doing so on noise would bake in a fake bias. This trend is how that
# conclusion gets checked as more data comes in, rather than re-running a
# one-off t-test by hand each time.
bias_trend <- clv_outcomes |>
  mutate(week = floor_date(logged_at, "week")) |>
  group_by(market, week) |>
  summarise(
    n             = n(),
    mean_residual = mean(residual, na.rm = TRUE),
    se            = sd(residual, na.rm = TRUE) / sqrt(n()),
    .groups       = "drop"
  ) |>
  mutate(
    ci_lo = mean_residual - 1.96 * se,
    ci_hi = mean_residual + 1.96 * se
  )

p_bias <- ggplot(bias_trend, aes(x = week, y = mean_residual, colour = market)) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
  geom_ribbon(aes(ymin = ci_lo, ymax = ci_hi, fill = market), alpha = 0.15, colour = NA) +
  geom_line(linewidth = 1) +
  geom_point(aes(size = n)) +
  labs(
    title    = "WNBA Shadow Model — Residual Bias Over Time",
    subtitle = "model_line - actual, weekly mean ± 95% CI. Ribbon crossing zero = not significant.",
    x        = NULL,
    y        = "Mean residual (pts)",
    colour   = "Market", fill = "Market", size = "Games"
  ) +
  theme_minimal(base_size = 13)

ggsave(file.path(REPORTS_DIR, "residual_bias_trend.png"),
       p_bias, width = 10, height = 5, dpi = 150)
message("Residual bias trend saved: reports/residual_bias_trend.png")

# Overall (not just weekly) significance per market — same t-test as the
# manual check, but reproduced here so it's part of the saved report going
# forward instead of a one-off.
residual_bias <- clv_outcomes |>
  group_by(market) |>
  summarise(
    n             = n(),
    mean_residual = mean(residual, na.rm = TRUE),
    p_value       = tryCatch(t.test(residual)$p.value, error = \(e) NA_real_),
    ci_lo         = tryCatch(t.test(residual)$conf.int[1], error = \(e) NA_real_),
    ci_hi         = tryCatch(t.test(residual)$conf.int[2], error = \(e) NA_real_),
    .groups       = "drop"
  ) |>
  mutate(significant = !is.na(p_value) & p_value < 0.05 & sign(ci_lo) == sign(ci_hi))

message("\n── Residual Bias (overall, per market) ────────────────────────────")
print(residual_bias)

# ── CLV over time ─────────────────────────────────────────────────────────────

p_clv <- clv |>
  arrange(logged_at) |>
  group_by(market) |>
  mutate(cumulative_clv = cumsum(clv)) |>
  ggplot(aes(x = logged_at, y = cumulative_clv, colour = market)) +
  geom_line(linewidth = 1) +
  geom_hline(yintercept = 0, linetype = "dashed", colour = "grey50") +
  labs(
    title    = "WNBA Shadow Model — Cumulative CLV",
    subtitle = "Positive = consistently beating the closing line",
    x        = NULL,
    y        = "Cumulative CLV (pts)",
    colour   = "Market"
  ) +
  theme_minimal(base_size = 13)

ggsave(file.path(REPORTS_DIR, "cumulative_clv.png"),
       p_clv, width = 10, height = 5, dpi = 150)
message("Cumulative CLV chart saved: reports/cumulative_clv.png")

# ── Market blindspot summary ──────────────────────────────────────────────────

# Bins where the model consistently over/under-predicts the market
blindspots <- cal_all |>
  mutate(bias = mean_pred - mean_actual) |>
  filter(abs(bias) > 2, n >= 5) |>
  arrange(desc(abs(bias)))

if (nrow(blindspots) > 0) {
  message("\n── Market blindspots (model bias > 2 pts, min 5 games) ──")
  print(blindspots |> select(market, pred_bin, mean_pred, mean_actual, bias, n))
} else {
  message("\nNo significant blindspots detected yet (need more data).")
}

# ── Full summary report ───────────────────────────────────────────────────────

report <- list(
  generated_at  = format(now("UTC"), "%Y-%m-%d %H:%M:%S"),
  n_positions   = nrow(clv),
  clv_summary   = clv_summary,
  blindspots    = blindspots,
  residual_rmse = clv_outcomes |>
    group_by(market) |>
    summarise(rmse = sqrt(mean(residual^2, na.rm = TRUE)), .groups = "drop"),
  residual_bias       = residual_bias,
  residual_bias_trend = bias_trend
)

saveRDS(report, file.path(REPORTS_DIR, "calibration_report.rds"))
message("\nFull report saved: reports/calibration_report.rds")
message("── Calibration complete ──────────────────────────────────────────")

dbDisconnect(con)
message("DB connection closed.")
