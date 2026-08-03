# run_bias_trend_comparison.ps1 — one-time follow-up task
# Registered by BiasTrendComparison_2026-08-01 (Task Scheduler) for 2026-08-01.
# Re-runs calibrate.R and asks Claude Code to compare the new residual-bias
# trend against the 2026-07-25 baseline snapshot. See
# bias_trend_comparison_prompt.txt for the full self-contained task prompt.

$WorkDir = "G:\My Drive\Scripting Projects\wnba_project"
$Claude  = "C:\Users\Mike\.local\bin\claude.exe"
$Prompt  = Get-Content -Path (Join-Path $WorkDir "scripts\bias_trend_comparison_prompt.txt") -Raw

Set-Location $WorkDir
& $Claude -p $Prompt --allowedTools Bash,Read,Write
