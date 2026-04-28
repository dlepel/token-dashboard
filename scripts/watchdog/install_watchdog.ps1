# =============================================================================
# Install TokenDashboard-Watchdog scheduled task.
#
# Run ONCE from an elevated PowerShell prompt:
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   powershell -File install_watchdog.ps1
#
# What it does:
#   1. Removes any prior 'ClaudeTokenDashboard' or 'TokenDashboard-Watchdog' task
#   2. Creates state directories under %LOCALAPPDATA%\TokenDashboard\watchdog\
#   3. Registers Scheduled Task 'TokenDashboard-Watchdog' to run every 1 min
#      as the current user via S4U logon (works whether signed in or not; no
#      password stored)
#   4. Kicks off the first run, which will bring the dashboard up
#   5. Prints heartbeat for verification
#
# Uninstall:
#   powershell -File install_watchdog.ps1 -Uninstall
# =============================================================================

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$TaskName       = "TokenDashboard-Watchdog"
$LegacyTaskName = "ClaudeTokenDashboard"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WatchdogPs1 = Join-Path $ScriptDir "watchdog.ps1"
$RepoRoot    = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Launcher    = Join-Path $RepoRoot "start_token_dashboard.vbs"
$StateDir    = Join-Path $env:LOCALAPPDATA "TokenDashboard\watchdog"
$HeartbeatFile = Join-Path $StateDir "heartbeat.json"

function Assert-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw "This script must be run from an elevated PowerShell prompt (Run as Administrator)."
    }
}

if ($Uninstall) {
    Assert-Admin
    foreach ($name in @($TaskName, $LegacyTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Unregistered scheduled task '$name'." -ForegroundColor Green
        }
    }
    Write-Host "Done." -ForegroundColor Green
    exit 0
}

Assert-Admin

# ---- Sanity checks ----------------------------------------------------------

if (-not (Test-Path $WatchdogPs1)) {
    throw "Cannot find $WatchdogPs1. Run this from <repo>\scripts\watchdog\."
}
Write-Host "Found watchdog.ps1 at $WatchdogPs1" -ForegroundColor Green

if (-not (Test-Path $Launcher)) {
    throw "Cannot find launcher at $Launcher. Make sure start_token_dashboard.vbs exists at the repo root."
}
Write-Host "Found launcher at $Launcher" -ForegroundColor Green

# ---- State dirs -------------------------------------------------------------

foreach ($d in @($StateDir, (Join-Path $StateDir "logs"))) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "Created $d" -ForegroundColor Green
    }
}

# ---- Remove any prior task (current name AND the legacy broken one) --------

foreach ($name in @($TaskName, $LegacyTaskName)) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Removed prior scheduled task '$name'." -ForegroundColor Yellow
    }
}

# ---- Build scheduled task --------------------------------------------------

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchdogPs1`""

# RepetitionDuration: cannot use [TimeSpan]::MaxValue on PowerShell 5.1 because
# Windows Task Scheduler's XML schema rejects P99999999DT23H59M59S. Use a 25-year
# bound (9125 days) which is below the schema cap.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 9125)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3)

$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType S4U `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Probes localhost:8080 every minute; restarts token-dashboard via start_token_dashboard.vbs if down." | Out-Null

Write-Host "Registered scheduled task '$TaskName' for user $currentUser (S4U, runs every 1 min)." -ForegroundColor Green

# ---- Kick off the first run immediately ------------------------------------

Write-Host ""
Write-Host "Running watchdog once now to bring the dashboard up..." -ForegroundColor Cyan
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WatchdogPs1 -Verbose

# ---- Show heartbeat --------------------------------------------------------

Write-Host ""
if (Test-Path $HeartbeatFile) {
    Write-Host "Heartbeat:" -ForegroundColor Green
    Get-Content $HeartbeatFile | Write-Host
} else {
    Write-Host "Warning: no heartbeat file yet. Check logs at $StateDir\logs\" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Verify:" -ForegroundColor Green
Write-Host "  * http://localhost:8080 should respond in a browser"
Write-Host "  * Scheduled Task '$TaskName' visible in Task Scheduler (Get-ScheduledTask $TaskName)"
Write-Host "  * Watchdog log at $StateDir\logs\$(Get-Date -Format 'yyyy-MM-dd').log"
Write-Host "  * Dashboard log at $RepoRoot\logs\dashboard.log"
