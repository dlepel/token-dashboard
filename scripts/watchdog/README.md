# Token Dashboard Watchdog

A Windows watchdog that keeps the token-dashboard server bound to port 8080. Probes the port every minute, restarts via the repo's `start_token_dashboard.vbs` launcher if down, and captures the Python process's stdout/stderr to `<repo>/logs/dashboard.log` so future failures leave a traceback.

## Why

The default scheduled-task approach (one trigger at log-on, no restart-on-failure) leaves the dashboard dead until the next sign-in if anything kills the Python process. This watchdog replaces that pattern with a 1-minute probe-and-restart loop modeled on the JobSearch server-watchdog pattern.

## Files

```
scripts/watchdog/
  watchdog.ps1            Main probe-and-restart script (runs every minute)
  install_watchdog.ps1    Installer / uninstaller for the scheduled task
  README.md               This file

start_token_dashboard.vbs The launcher the watchdog calls (also usable manually)
logs/dashboard.log        Python stdout/stderr (gitignored)
```

State files live under `%LOCALAPPDATA%\TokenDashboard\watchdog\`:

```
heartbeat.json            Last watchdog run timestamp + status
history.json              Restart attempts, consecutive failures, last diagnosis
watchdog.running          Single-instance lock (5-min stale rule)
logs/YYYY-MM-DD.log       Per-day watchdog log (probe results, restart events)
```

## Install

From an **elevated PowerShell** prompt (Run as Administrator):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
cd C:\Scripts\GitHub\token-dashboard\scripts\watchdog
powershell -File install_watchdog.ps1
```

The installer:

1. Removes any prior `ClaudeTokenDashboard` task (the broken one) and any existing `TokenDashboard-Watchdog` task.
2. Creates state directories under `%LOCALAPPDATA%\TokenDashboard\watchdog\`.
3. Registers `TokenDashboard-Watchdog` to run every 1 minute via S4U logon (works whether you're signed in or not, no stored password).
4. Runs the watchdog once to bring the dashboard up immediately.
5. Prints the heartbeat file for verification.

## Verify

```powershell
# Task is registered:
Get-ScheduledTask -TaskName TokenDashboard-Watchdog

# Last run result:
Get-ScheduledTaskInfo -TaskName TokenDashboard-Watchdog | Format-List LastRunTime, LastTaskResult, NextRunTime

# Heartbeat:
Get-Content $env:LOCALAPPDATA\TokenDashboard\watchdog\heartbeat.json

# Port is bound:
Get-NetTCPConnection -LocalPort 8080 -State Listen

# Dashboard responds:
Invoke-WebRequest http://localhost:8080/api/overview -UseBasicParsing
```

## Logs

**Watchdog log** (probe results, restart attempts, diagnosis):

```
%LOCALAPPDATA%\TokenDashboard\watchdog\logs\YYYY-MM-DD.log
```

**Dashboard log** (Python stdout/stderr — tracebacks land here):

```
<repo>\logs\dashboard.log
```

## Diagnosis reasons

When the dashboard is down, the watchdog classifies the cause and writes it to `history.json` and the daily log:

| Reason | Meaning | Auto-fix |
|---|---|---|
| `not_running` | Port unbound, no process holding it. Normal restart case. | Yes, via launcher |
| `stuck_python_holding_port: pid N` | A python process holds 8080 but isn't responding. | Yes, kill + relaunch |
| `port_held_by_non_python: <name>` | Something else (Tomcat, Jenkins, etc.) grabbed 8080. | No, manual intervention |
| `python_not_found` | None of the candidate Python paths exist. | No, install Python |
| `launcher_missing` / `cli_missing` | Repo files moved or deleted. | No, fix the repo |

## Throttling

The watchdog limits restart attempts to 6 per hour per server. If hit, it sets status to `failed` and skips restart attempts until the rolling hour passes. The window resets automatically.

## Uninstall

```powershell
powershell -File install_watchdog.ps1 -Uninstall
```

This unregisters both `TokenDashboard-Watchdog` and the legacy `ClaudeTokenDashboard` task. State files under `%LOCALAPPDATA%\TokenDashboard\watchdog\` are not deleted (preserves history); remove that folder manually if you want a clean slate.

## Manual run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File watchdog.ps1 -Verbose
```

This runs one probe-and-restart cycle and exits, with verbose output to the console.
