# broadcast_schema.R — structured broadcast format for #auto-bet-broadcast
# ─────────────────────────────────────────────────────────────────────────────
# Emitter only — the parser lives in bet_router/scripts/broadcast_schema.R.
# Keep in sync with:
#   bet_router/scripts/broadcast_schema.R
#   mlb_NRFI_YRFI/scripts/broadcast_schema.R
#   pga_project/scripts/broadcast_schema.R
# ─────────────────────────────────────────────────────────────────────────────

emit_broadcast <- function(pipeline, sport, play, teams, book, odds,
                           fair_odds, edge, ev, confidence, model_prob,
                           game_time, window) {
  fair_str <- if (suppressWarnings(is.na(as.integer(fair_odds)))) "NA"
              else sprintf("%d", as.integer(fair_odds))
  lines <- c(
    sprintf("PIPELINE: %s",     as.character(pipeline)),
    sprintf("SPORT: %s",        as.character(sport)),
    sprintf("PLAY: %s",         as.character(play)),
    sprintf("TEAMS: %s",        as.character(teams)),
    sprintf("BOOK: %s",         as.character(book)),
    sprintf("ODDS: %d",         as.integer(odds)),
    sprintf("FAIR_ODDS: %s",    fair_str),
    sprintf("EDGE: %s",         as.character(edge)),
    sprintf("EV: %s",           as.character(ev)),
    sprintf("CONFIDENCE: %s",   as.character(confidence)),
    sprintf("MODEL_PROB: %.3f", as.numeric(model_prob)),
    sprintf("GAME_TIME: %s",    as.character(game_time)),
    sprintf("WINDOW: %s",       as.character(window))
  )
  paste(lines, collapse = "\n")
}
