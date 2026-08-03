# run_check_0728_props.ps1 — one-time follow-up task
# Registered by WNBA_Check0728Props (Task Scheduler) for 2026-07-27 evening.
# Checks whether player prop lines have posted for the 2026-07-28 slate and
# re-checks injury report freshness. See check_0728_props_prompt.txt for the
# full self-contained task prompt.

$WorkDir = "G:\My Drive\Scripting Projects\wnba_project"
$Claude  = "C:\Users\Mike\.local\bin\claude.exe"
$Prompt  = Get-Content -Path (Join-Path $WorkDir "scripts\check_0728_props_prompt.txt") -Raw

Set-Location $WorkDir
& $Claude -p $Prompt --allowedTools Bash,Read
