# scripts/run_retrain.R
# WNBA weekly model retrain entry point.
# Called by WNBA_Retrain Task Scheduler task (Sundays, 6 AM).
#
# Step 1: seed.R  — refresh game_outcomes + game_log from wehoop (idempotent)
# Step 2: train.R — retrain XGBoost totals + spreads models on expanded data

library(here)

message("── WNBA Weekly Retrain ──────────────────────────────────")
message("Started at: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))

message("\n[Step 1] Seeding game outcomes...")
source(here("scripts", "shadow_model", "seed.R"))

message("\n[Step 2] Training XGBoost models...")
source(here("scripts", "shadow_model", "train.R"))

message("\n── Retrain complete ─────────────────────────────────────")
message("Finished at: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
