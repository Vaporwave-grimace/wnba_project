# setup_schedule.ps1
# WNBA Pipeline — Task Scheduler registration
#
# Run once (bypass execution policy if needed):
#   powershell -ExecutionPolicy Bypass -File ".\setup_schedule.ps1"
#
# To remove the task later:
#   Unregister-ScheduledTask -TaskName "WNBA Pipeline" -Confirm:$false

param(
    [string]$ProjectRoot = "G:\My Drive\Scripting Projects\wnba_project",
    [string]$TaskName    = "WNBA Pipeline",
    [int]   $IntervalMin = 30,
    [string]$StartTime   = "08:00",
    [string]$EndTime     = "23:30"
)

$RunnerScript = Join-Path $ProjectRoot "run_pipeline.ps1"
$LogDir       = Join-Path $ProjectRoot "logs"

# ── Validate ──────────────────────────────────────────────────────────────────

if (-not (Test-Path $RunnerScript)) {
    Write-Error "Runner script not found: $RunnerScript"
    exit 1
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ── Remove existing task ──────────────────────────────────────────────────────

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# ── Action ────────────────────────────────────────────────────────────────────

$action = New-ScheduledTaskAction `
    -Execute   "powershell.exe" `
    -Argument  "-NonInteractive -ExecutionPolicy Bypass -File `"$RunnerScript`"" `
    -WorkingDirectory $ProjectRoot

# ── Trigger + XML registration ────────────────────────────────────────────────
# PowerShell 5.1 can't set Repetition.Interval on a CimInstance after creation.
# Using XML task import is the reliable workaround for daily + repeat interval.

$startDT     = [datetime]::ParseExact($StartTime, "HH:mm", $null)
$endDT       = [datetime]::ParseExact($EndTime,   "HH:mm", $null)
$span        = $endDT - $startDT
$durationIso = "PT$([int]$span.TotalHours)H$($span.Minutes)M"   # e.g. PT15H30M
$intervalIso = "PT${IntervalMin}M"                               # e.g. PT30M
$startBound  = (Get-Date -Format "yyyy-MM-dd") + "T${StartTime}:00"
$userId      = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>WNBA Pipeline: odds ingestion, injury alerts, steam detection. Every $IntervalMin min, $StartTime-$EndTime daily.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <Repetition>
        <Interval>$intervalIso</Interval>
        <Duration>$durationIso</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$startBound</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userId</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT20M</ExecutionTimeLimit>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NonInteractive -ExecutionPolicy Bypass -File "$RunnerScript"</Arguments>
      <WorkingDirectory>$ProjectRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$task = Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force -ErrorAction Stop

if ($task) {
    Write-Host ""
    Write-Host "✓ Task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "  Schedule:  Every $IntervalMin minutes, $StartTime – $EndTime daily"
    Write-Host "  Runner:    $RunnerScript"
    Write-Host "  Logs:      $LogDir\scheduler.log"
    Write-Host ""
    Write-Host "To run immediately:  Start-ScheduledTask -TaskName '$TaskName'"
    Write-Host "To check status:     Get-ScheduledTaskInfo -TaskName '$TaskName'"
    Write-Host "To remove:           Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
} else {
    Write-Error "Task registration failed."
    exit 1
}
