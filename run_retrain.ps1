# run_retrain.ps1 — WNBA weekly model retrain runner
# Called by WNBA_Retrain Task Scheduler task (Sundays 6 AM).
# Seeds latest WNBA game outcomes then retrains XGBoost models.
# DO NOT run this to register the task — use setup_retrain.ps1.

param(
    [string]$ProjectRoot = "G:\My Drive\Scripting Projects\wnba_project",
    [string]$RScript     = "C:\Program Files\R\R-4.6.0\bin\Rscript.exe"
)

$LogDir  = Join-Path $ProjectRoot "logs"
$LogFile = Join-Path $LogDir "retrain.log"
$RFile   = Join-Path $ProjectRoot "scripts\run_retrain.R"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts UTC] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# Self-healing R path
if (-not (Test-Path $RScript)) {
    $found = Get-ChildItem "C:\Program Files\R" -Recurse -Filter "Rscript.exe" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1 -ExpandProperty FullName
    if ($found) {
        $RScript = $found
        Write-Log "Rscript auto-detected at: $RScript"
    } else {
        Write-Log "Rscript.exe not found. Check R installation." "ERROR"
        exit 1
    }
}

Write-Log "────────────────────────────────────────"
Write-Log "WNBA Weekly Retrain starting"
Write-Log "R:      $RScript"
Write-Log "Script: $RFile"

$startTime = Get-Date

$proc = Start-Process `
    -FilePath         $RScript `
    -ArgumentList     "`"$RFile`"" `
    -WorkingDirectory $ProjectRoot `
    -RedirectStandardOutput (Join-Path $LogDir "retrain_stdout.log") `
    -RedirectStandardError  (Join-Path $LogDir "retrain_stderr.log") `
    -NoNewWindow `
    -PassThru

$proc.WaitForExit()
$exitCode = if ($null -eq $proc.ExitCode) { 0 } else { [int]$proc.ExitCode }

$stdout = Get-Content (Join-Path $LogDir "retrain_stdout.log") -ErrorAction SilentlyContinue
$stderr = Get-Content (Join-Path $LogDir "retrain_stderr.log") -ErrorAction SilentlyContinue
if ($stdout) { $stdout | ForEach-Object { Add-Content -Path $LogFile -Value "  [R] $_" } }
if ($stderr) { $stderr | ForEach-Object { Add-Content -Path $LogFile -Value "  [R:ERR] $_" } }

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

if ($exitCode -eq 0) {
    Write-Log "Retrain complete in ${elapsed}s (exit 0)"
} else {
    Write-Log "Retrain FAILED in ${elapsed}s (exit $exitCode)" "ERROR"
}

Write-Log "────────────────────────────────────────"
exit $exitCode
