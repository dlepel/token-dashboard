# =============================================================================
# Token Dashboard Watchdog
# -----------------------------------------------------------------------------
# Runs every minute via Windows Scheduled Task (installed by install_watchdog.ps1).
# Probes localhost:8080, diagnoses why it's down if it is, and restarts via the
# repo's start_token_dashboard.vbs launcher (which captures Python stdout/stderr
# to <repo>\logs\dashboard.log).
#
# State files:
#   %LOCALAPPDATA%\TokenDashboard\watchdog\heartbeat.json
#   %LOCALAPPDATA%\TokenDashboard\watchdog\history.json
#   %LOCALAPPDATA%\TokenDashboard\watchdog\watchdog.running    (lock)
#   %LOCALAPPDATA%\TokenDashboard\watchdog\logs\YYYY-MM-DD.log (per-day watchdog log)
#
# Safe to run manually:
#   powershell -NoProfile -ExecutionPolicy Bypass -File watchdog.ps1 -Verbose
# =============================================================================

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$WatchdogVersion = "1.0.0"

# ---- Paths (resolved relative to this script's location) -------------------

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Launcher  = Join-Path $RepoRoot "start_token_dashboard.vbs"
$ScriptFile = Join-Path $RepoRoot "cli.py"

$StateDir      = Join-Path $env:LOCALAPPDATA "TokenDashboard\watchdog"
$LogsDir       = Join-Path $StateDir "logs"
$HeartbeatFile = Join-Path $StateDir "heartbeat.json"
$HistoryFile   = Join-Path $StateDir "history.json"
$LockFile      = Join-Path $StateDir "watchdog.running"

foreach ($dir in @($StateDir, $LogsDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

$Today  = Get-Date -Format "yyyy-MM-dd"
$LogFile = Join-Path $LogsDir "$Today.log"

# ---- Logging ---------------------------------------------------------------

function Write-WdLog {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    if ($Verbose -or $Level -eq "ERROR" -or $Level -eq "FATAL") {
        Write-Host $line
    }
}

# ---- Single-instance lock --------------------------------------------------

if (Test-Path $LockFile) {
    $lockAge = ((Get-Date) - (Get-Item $LockFile).LastWriteTime).TotalMinutes
    if ($lockAge -lt 5) {
        Write-WdLog "INFO" "Another watchdog instance is running (lock age $([math]::Round($lockAge,1)) min). Exiting."
        exit 0
    } else {
        Write-WdLog "WARN" "Stale lock file (age $([math]::Round($lockAge,1)) min). Removing and continuing."
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}
Set-Content -Path $LockFile -Value (Get-Date -Format "o") -Force

try {

    # ---- Server definition (single-server watchdog) ------------------------

    $Server = @{
        Name       = "token_dashboard"
        Label      = "Token Dashboard"
        Port       = if ($env:PORT) { [int]$env:PORT } else { 8080 }
        Launcher   = $Launcher
        ScriptFile = $ScriptFile
    }

    # ---- Helper: TCP probe -------------------------------------------------

    function Test-Port {
        param([int]$Port)
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $task = $c.ConnectAsync("127.0.0.1", $Port)
            $ok = $task.Wait(2000)
            if ($ok -and $c.Connected) { $c.Close(); return $true }
            $c.Close()
            return $false
        } catch {
            return $false
        }
    }

    # ---- Helper: diagnose why it's down ------------------------------------

    function Get-ServerDiagnosis {
        param($Srv)
        $diag = [ordered]@{
            python_found        = $false
            python_path         = $null
            launcher_present    = (Test-Path $Srv.Launcher)
            script_present      = (Test-Path $Srv.ScriptFile)
            port_bound_by_pid   = $null
            port_bound_by_exe   = $null
            orphan_python_pids  = @()
            reason              = $null
        }

        $pyCandidates = @(
            "$env:USERPROFILE\AppData\Local\Programs\Python\Python314\python.exe",
            "$env:USERPROFILE\AppData\Local\Programs\Python\Python313\python.exe",
            "$env:USERPROFILE\AppData\Local\Programs\Python\Python312\python.exe",
            "C:\Python314\python.exe",
            "C:\Python313\python.exe",
            "C:\Python312\python.exe",
            "C:\Program Files\Python314\python.exe",
            "C:\Program Files\Python313\python.exe",
            "C:\Program Files\Python312\python.exe"
        )
        foreach ($p in $pyCandidates) {
            if (Test-Path $p) { $diag.python_found = $true; $diag.python_path = $p; break }
        }

        $conn = Get-NetTCPConnection -LocalPort $Srv.Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $diag.port_bound_by_pid = $conn.OwningProcess
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc) { $diag.port_bound_by_exe = $proc.ProcessName }
        }

        $pyProcs = Get-Process | Where-Object { $_.Name -in @("python","pythonw") } -ErrorAction SilentlyContinue
        if ($pyProcs) {
            foreach ($p in $pyProcs) {
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
                if ($cmd -and ($cmd -match 'token-dashboard|cli\.py')) {
                    $diag.orphan_python_pids += $p.Id
                }
            }
        }

        if (-not $diag.launcher_present)     { $diag.reason = "launcher_missing: $($Srv.Launcher)" }
        elseif (-not $diag.script_present)   { $diag.reason = "cli_missing: $($Srv.ScriptFile)" }
        elseif (-not $diag.python_found)     { $diag.reason = "python_not_found" }
        elseif ($diag.port_bound_by_pid -and $diag.port_bound_by_exe -notin @("python","pythonw")) {
            $diag.reason = "port_held_by_non_python: $($diag.port_bound_by_exe) (pid $($diag.port_bound_by_pid))"
        }
        elseif ($diag.port_bound_by_pid -and $diag.port_bound_by_exe -in @("python","pythonw")) {
            $diag.reason = "stuck_python_holding_port: pid $($diag.port_bound_by_pid)"
        }
        else {
            $diag.reason = "not_running"
        }

        return $diag
    }

    # ---- Helper: restart via the .vbs launcher -----------------------------

    function Invoke-ServerRestart {
        param($Srv, $Diag)

        if ($Diag.reason -like "stuck_python_holding_port*") {
            Write-WdLog "WARN" "$($Srv.Label): killing stuck python pid $($Diag.port_bound_by_pid)"
            Stop-Process -Id $Diag.port_bound_by_pid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        if ($Diag.reason -like "port_held_by_non_python*") {
            Write-WdLog "FATAL" "$($Srv.Label): port $($Srv.Port) held by $($Diag.port_bound_by_exe); cannot auto-fix."
            return $false
        }

        if (-not $Diag.launcher_present) {
            Write-WdLog "FATAL" "$($Srv.Label): launcher missing at $($Srv.Launcher)"
            return $false
        }

        Write-WdLog "INFO" "$($Srv.Label): starting via $($Srv.Launcher)"
        try {
            Start-Process -FilePath "wscript.exe" -ArgumentList "`"$($Srv.Launcher)`"" -WindowStyle Hidden
        } catch {
            Write-WdLog "ERROR" "$($Srv.Label): launcher start failed: $($_.Exception.Message)"
            return $false
        }

        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            if (Test-Port $Srv.Port) {
                Write-WdLog "INFO" "$($Srv.Label): back up after $($i + 1)s"
                return $true
            }
        }

        Write-WdLog "ERROR" "$($Srv.Label): did not respond within 15s after restart"
        return $false
    }

    # ---- Load history ------------------------------------------------------

    $history = @{}
    if (Test-Path $HistoryFile) {
        try { $history = Get-Content $HistoryFile -Raw | ConvertFrom-Json -AsHashtable } catch { $history = @{} }
    }
    if (-not $history.ContainsKey($Server.Name)) {
        $history[$Server.Name] = @{
            last_up              = $null
            last_down            = $null
            last_restart_at      = $null
            restart_attempts     = @()
            status               = "unknown"
            consecutive_failures = 0
            last_diagnosis       = $null
        }
    }

    # ---- Main check --------------------------------------------------------

    $now = Get-Date
    $nowIso = $now.ToString("o")
    $cutoffHour = $now.AddHours(-1)
    $h = $history[$Server.Name]
    $up = Test-Port $Server.Port

    if ($up) {
        if ($h.status -ne "running") {
            Write-WdLog "INFO" "$($Server.Label) is up on port $($Server.Port)."
        }
        $h.status = "running"
        $h.last_up = $nowIso
        $h.consecutive_failures = 0
        $h.last_diagnosis = $null
    } else {
        $h.last_down = $nowIso
        $h.status = "down"
        $diag = Get-ServerDiagnosis -Srv $Server
        $h.last_diagnosis = $diag
        Write-WdLog "WARN" "$($Server.Label) down on port $($Server.Port). Reason: $($diag.reason)"

        # Throttle: max 6 restart attempts per hour
        $recent = @($h.restart_attempts | Where-Object {
            try { (Get-Date $_) -gt $cutoffHour } catch { $false }
        })
        if ($recent.Count -ge 6) {
            Write-WdLog "ERROR" "$($Server.Label): 6 restart attempts in the last hour; throttling until :00."
            $h.status = "failed"
        } else {
            $h.restart_attempts += $nowIso
            $h.last_restart_at = $nowIso
            $ok = Invoke-ServerRestart -Srv $Server -Diag $diag

            if ($ok) {
                $h.status = "running"
                $h.consecutive_failures = 0
                $h.last_up = (Get-Date).ToString("o")
            } else {
                $h.consecutive_failures += 1
                if ($h.consecutive_failures -ge 2) {
                    $h.status = "failed"
                    Write-WdLog "FATAL" "$($Server.Label) failed to restart ($($h.consecutive_failures) consecutive). Reason: $($diag.reason)"
                }
            }
        }
    }

    # ---- Prune restart_attempts older than 2 hours -------------------------

    $pruneCutoff = $now.AddHours(-2)
    $h.restart_attempts = @($h.restart_attempts | Where-Object {
        try { (Get-Date $_) -gt $pruneCutoff } catch { $false }
    })

    # ---- Atomic write: history --------------------------------------------

    $tmp = "$HistoryFile.tmp"
    ($history | ConvertTo-Json -Depth 10) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $HistoryFile -Force

    # ---- Atomic write: heartbeat ------------------------------------------

    $heartbeat = [ordered]@{
        last_run_at      = $nowIso
        watchdog_version = $WatchdogVersion
        ps_version       = $PSVersionTable.PSVersion.ToString()
        server           = $Server.Name
        port             = $Server.Port
        status           = $h.status
        last_up          = $h.last_up
        last_down        = $h.last_down
        last_restart_at  = $h.last_restart_at
    }
    $tmp = "$HeartbeatFile.tmp"
    ($heartbeat | ConvertTo-Json) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $HeartbeatFile -Force

} finally {
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
}
