# fix_chatbot_dup.ps1
# Read-only diagnostic + targeted cleanup for the duplicate chatbot_server.py problem.
#
# What it does:
#   1. Lists Startup folder contents
#   2. Removes any chatbot/start_chatbot* shortcut from Startup folder
#   3. Kills BOTH chatbot_server.py processes (watchdog will restart cleanly)
#   4. Reports final state to fix_chatbot_dup_output.txt in this folder
#
# It does NOT:
#   - Modify any Python file (that is done separately by apply_singleton_guard.py)
#   - Touch the watchdog or any other server
#
# Run from a regular PowerShell prompt:
#   PowerShell -ExecutionPolicy Bypass -File "C:\Scripts\GitHub\token-dashboard\fix_chatbot_dup.ps1"

$ErrorActionPreference = 'Continue'
$out = 'C:\Scripts\GitHub\token-dashboard\fix_chatbot_dup_output.txt'
$report = New-Object System.Collections.Generic.List[string]

function Add-Line { param([string]$s) $report.Add($s) }

Add-Line "Chatbot duplicate cleanup - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"

# ---- 1. Startup folder inventory --------------------------------------------
$StartupDir = [Environment]::GetFolderPath('Startup')
Add-Line ""
Add-Line "=== Startup folder ==="
Add-Line "Path: $StartupDir"
if (Test-Path $StartupDir) {
    $items = Get-ChildItem $StartupDir -Force -ErrorAction SilentlyContinue
    if ($items) {
        $items | Select-Object Name, Length, LastWriteTime |
            Format-Table -AutoSize | Out-String | ForEach-Object { Add-Line $_ }
    } else {
        Add-Line "(empty)"
    }
} else {
    Add-Line "(folder does not exist)"
}

# ---- 2. Remove chatbot/start_chatbot Startup-folder entries -----------------
Add-Line ""
Add-Line "=== Removing chatbot Startup-folder entries ==="
$removed = @()
if (Test-Path $StartupDir) {
    $matches = Get-ChildItem $StartupDir -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'chatbot|start_chatbot'
    }
    if ($matches) {
        foreach ($m in $matches) {
            try {
                Remove-Item $m.FullName -Force -ErrorAction Stop
                $removed += $m.Name
                Add-Line "Removed: $($m.Name)"
            } catch {
                Add-Line "Could not remove $($m.Name): $($_.Exception.Message)"
            }
        }
    }
}
if (-not $removed) { Add-Line "(none found)" }

# ---- 3. Kill chatbot_server.py processes ------------------------------------
Add-Line ""
Add-Line "=== Killing chatbot_server.py processes ==="
$pyProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('python','pythonw') }
$killed = @()
foreach ($p in $pyProcs) {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($cmd -match 'chatbot_server\.py') {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            $killed += "PID $($p.Id) (started $($p.StartTime))"
            Add-Line "Killed PID $($p.Id) (started $($p.StartTime))"
        } catch {
            Add-Line "Could not kill PID $($p.Id): $($_.Exception.Message)"
        }
    }
}
if (-not $killed) { Add-Line "(no chatbot_server processes running)" }

# ---- 4. Wait briefly, then snapshot final state -----------------------------
Start-Sleep -Seconds 3

Add-Line ""
Add-Line "=== Final state (3s after kill) ==="
Add-Line "Live python/pythonw processes:"
$livePy = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('python','pythonw') }
if ($livePy) {
    foreach ($p in $livePy) {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
        Add-Line "  PID $($p.Id) ($($p.Name)) - started $($p.StartTime)"
        Add-Line "    $cmd"
    }
} else {
    Add-Line "  (none)"
}

Add-Line ""
Add-Line "Listeners on :5050, :5051, :8080:"
$listeners = Get-NetTCPConnection -State Listen -LocalPort 5050,5051,8080 -ErrorAction SilentlyContinue
if ($listeners) {
    foreach ($l in $listeners) {
        $proc = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
        Add-Line "  $($l.LocalAddress):$($l.LocalPort) - PID $($l.OwningProcess) ($($proc.Name))"
    }
} else {
    Add-Line "  (none)"
}

# ---- Write output ------------------------------------------------------------
$report | Out-File -FilePath $out -Encoding utf8

Write-Host "---"
$report | ForEach-Object { Write-Host $_ }
Write-Host "---"
Write-Host ""
Write-Host "Output saved to: $out" -ForegroundColor Green
Write-Host "The watchdog runs every minute and will restart chatbot_server within 1-2 minutes."
Write-Host "Verify with: Get-NetTCPConnection -LocalPort 5051 -State Listen"
