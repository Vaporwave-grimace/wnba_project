# scripts/logger.R
# Simple file-based logger for the WNBA pipeline.
# Writes timestamped entries to logs/pipeline.log.
# All other scripts source this file for consistent logging.

LOG_DIR  <- here::here("logs")
LOG_FILE <- file.path(LOG_DIR, "pipeline.log")

dir.create(LOG_DIR, showWarnings = FALSE, recursive = TRUE)

log_msg <- function(..., level = "INFO") {
  ts  <- format(now("UTC"), "%Y-%m-%d %H:%M:%S")
  msg <- paste0("[", ts, " UTC] [", level, "] ", paste(..., sep = " "))
  message(msg)
  cat(msg, "\n", file = LOG_FILE, append = TRUE)
}

log_info  <- function(...) log_msg(..., level = "INFO")
log_warn  <- function(...) log_msg(..., level = "WARN")
log_error <- function(...) log_msg(..., level = "ERROR")

# Wraps an expression in tryCatch, logs any error, and returns NULL on failure.
# Allows the pipeline to continue even if one component fails.
safe_run <- function(expr, label = "unnamed step") {
  tryCatch(
    expr,
    error = function(e) {
      log_error(label, "failed:", conditionMessage(e))
      NULL
    }
  )
}
