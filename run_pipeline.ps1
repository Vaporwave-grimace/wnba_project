# run_pipeline.ps1
# WNBA Pipeline — PowerShell runner
#
# Called by Windows Task Scheduler every 30 minutes.
# Wraps the R pipeline with PowerShell-level logging and guards.
#
# DO NOT run this manually to set up the schedule.
# Use setup_schedule.ps1 to register the Task Scheduler job.

param(
    [string]$ProjectRoot = "G:\My Drive\Scripting Projects\wnba_project",
    [string]$RScript     = "C:\Program Files\R\R-4.6.0\bin\Rscript.exe"
)

# ── Paths ─────────────────────────────────────────────────────────────────────

$LogDir  = Join-Path $ProjectRoot "logs"
$LogFile = Join-Path $LogDir "scheduler.log"
$PidFile = Join-Path $LogDir "pipeline.pid"
$RFile   = Join-Path $ProjectRoot "scripts\run_pipeline.R"

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts UTC] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# ── Guard: skip if a run is already in progress ───────────────────────────────

if (Test-Path $PidFile) {
    $existingPid = Get-Content $PidFile -ErrorAction SilentlyContinue
    if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
        Write-Log "Pipeline already running (PID $existingPid). Skipping this invocation." "WARN"
        exit 0
    } else {
        # Stale PID file — clean it up
        Remove-Item $PidFile -Force
    }
}

# ── Validate R installation ───────────────────────────────────────────────────

if (-not (Test-Path $RScript)) {
    # Try to find Rscript anywhere in Program Files
    $found = Get-ChildItem "C:\Program Files\R" -Recurse -Filter "Rscript.exe" -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1 -ExpandProperty FullName

    if ($found) {
        $RScript = $found
        Write-Log "Rscript found at: $RScript"
    } else {
        Write-Log "Rscript.exe not found. Update the RScript parameter in run_pipeline.ps1." "ERROR"
        exit 1
    }
}

# ── Run ───────────────────────────────────────────────────────────────────────

Write-Log "────────────────────────────────────────"
Write-Log "Starting pipeline run"
Write-Log "R:       $RScript"
Write-Log "Script:  $RFile"
Write-Log "Root:    $ProjectRoot"

$startTime = Get-Date

# Launch Rscript, redirect stdout+stderr into the log, and write PID file
$proc = Start-Process `
    -FilePath $RScript `
    -ArgumentList "`"$RFile`"" `
    -WorkingDirectory $ProjectRoot `
    -RedirectStandardOutput (Join-Path $LogDir "r_stdout.log") `
    -RedirectStandardError  (Join-Path $LogDir "r_stderr.log") `
    -NoNewWindow `
    -PassThru

$proc.Id | Set-Content $PidFile
Write-Log "R process started (PID $($proc.Id))"

# Wait for R to finish
$proc.WaitForExit()
$exitCode = $proc.ExitCode

# Append R output to main log
$stdout = Get-Content (Join-Path $LogDir "r_stdout.log") -ErrorAction SilentlyContinue
$stderr = Get-Content (Join-Path $LogDir "r_stderr.log") -ErrorAction SilentlyContinue

if ($stdout) { $stdout | ForEach-Object { Add-Content -Path $LogFile -Value "  [R] $_" } }
if ($stderr) { $stderr | ForEach-Object { Add-Content -Path $LogFile -Value "  [R:ERR] $_" } }

# Clean up PID file
Remove-Item $PidFile -Force -ErrorAction SilentlyContinue

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

if ($exitCode -eq 0) {
    Write-Log "Pipeline run complete in ${elapsed}s (exit 0)"
} else {
    Write-Log "Pipeline run FAILED in ${elapsed}s (exit $exitCode)" "ERROR"
}

Write-Log "────────────────────────────────────────"
exit $exitCode
