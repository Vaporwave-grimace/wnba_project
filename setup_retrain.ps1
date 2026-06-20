# setup_retrain.ps1 — registers WNBA_Retrain weekly Task Scheduler task
#
# Run once in an admin PowerShell:
#   powershell -ExecutionPolicy Bypass -File ".\setup_retrain.ps1"
#
# To remove:
#   Unregister-ScheduledTask -TaskName "WNBA_Retrain" -Confirm:$false

param(
    [string]$ProjectRoot = "G:\My Drive\Scripting Projects\wnba_project",
    [string]$TaskName    = "WNBA_Retrain",
    [string]$DayOfWeek   = "Sunday",
    [string]$StartTime   = "06:00"
)

$RunnerScript = Join-Path $ProjectRoot "run_retrain.ps1"
$LogDir       = Join-Path $ProjectRoot "logs"

if (-not (Test-Path $RunnerScript)) {
    Write-Error "Runner script not found: $RunnerScript"
    exit 1
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing existing task '$TaskName'..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$userId     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$startBound = (Get-Date -Format "yyyy-MM-dd") + "T${StartTime}:00"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>WNBA Shadow Model - weekly retrain. Seeds latest game outcomes from wehoop then retrains XGBoost totals + spreads models. Runs every $DayOfWeek at $StartTime.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startBound</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek>
        <WeeksInterval>1</WeeksInterval>
        <DaysOfWeek><$DayOfWeek /></DaysOfWeek>
      </ScheduleByWeek>
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
    <ExecutionTimeLimit>PT90M</ExecutionTimeLimit>
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
    Write-Host "Task '$TaskName' registered successfully." -ForegroundColor Green
    Write-Host "  Schedule:  Every $DayOfWeek at $StartTime"
    Write-Host "  Runner:    $RunnerScript"
    Write-Host "  Log:       $LogDir\retrain.log"
    Write-Host ""
    Write-Host "Bootstrap the models first (run once in R):"
    Write-Host "  setwd('G:/My Drive/Scripting Projects/wnba_project')"
    Write-Host "  source('scripts/shadow_model/seed.R')"
    Write-Host "  source('scripts/shadow_model/train.R')"
    Write-Host ""
    Write-Host "Or trigger the scheduled task immediately:"
    Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
    Write-Host ""
    Write-Host "To check status:  Get-ScheduledTaskInfo -TaskName '$TaskName'"
    Write-Host "To remove:        Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
} else {
    Write-Error "Task registration failed."
    exit 1
}
