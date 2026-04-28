' start_token_dashboard.vbs
' Launches token-dashboard silently with stdout/stderr captured to logs/dashboard.log
' (relative to this script's own folder, so it works in any clone location).
'
' To start manually:  wscript "<repo>\start_token_dashboard.vbs"
' To verify running:  open http://127.0.0.1:8080
' Log file:           <repo>\logs\dashboard.log

Dim objShell, objFSO
Dim userProfile, scriptDir, logsDir, logFile
Dim pythonExe, pythonwExe
Dim candidates, c, q, ts, cmd

Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

userProfile = objShell.ExpandEnvironmentStrings("%USERPROFILE%")
scriptDir   = objFSO.GetParentFolderName(WScript.ScriptFullName)
logsDir     = scriptDir & "\logs"
logFile     = logsDir & "\dashboard.log"
q           = Chr(34)

If Not objFSO.FolderExists(logsDir) Then objFSO.CreateFolder(logsDir)

candidates = Array( _
  userProfile & "\AppData\Local\Programs\Python\Python314\python.exe", _
  userProfile & "\AppData\Local\Programs\Python\Python313\python.exe", _
  userProfile & "\AppData\Local\Programs\Python\Python312\python.exe", _
  "C:\Python314\python.exe", _
  "C:\Python313\python.exe", _
  "C:\Python312\python.exe", _
  "C:\Program Files\Python314\python.exe", _
  "C:\Program Files\Python313\python.exe", _
  "C:\Program Files\Python312\python.exe" _
)

pythonExe = ""
For Each c In candidates
  If objFSO.FileExists(c) Then pythonExe = c : Exit For
Next

If pythonExe = "" Then
  Set ts = objFSO.OpenTextFile(logFile, 8, True)
  ts.WriteLine Now & " [FATAL] Python not found. Tried: " & Join(candidates, " | ")
  ts.Close
  WScript.Quit 1
End If

' Prefer pythonw.exe (no console window) when available; fall back to python.exe.
pythonwExe = Replace(pythonExe, "python.exe", "pythonw.exe")
If Not objFSO.FileExists(pythonwExe) Then pythonwExe = pythonExe

objShell.CurrentDirectory = scriptDir

' Marker line so log readers can see when the launcher fired.
Set ts = objFSO.OpenTextFile(logFile, 8, True)
ts.WriteLine Now & " [INFO] Launching token-dashboard via " & pythonwExe
ts.Close

' Wrap in cmd /c to enable >> redirection. cmd's "old behavior" with multiple
' quote characters is to strip the leading and trailing quote, leaving the
' inner command intact (with redirection operators handled by the shell).
cmd = "cmd.exe /c " & q & q & pythonwExe & q & " " & q & scriptDir & "\cli.py" & q & " dashboard --no-open >> " & q & logFile & q & " 2>&1" & q
objShell.Run cmd, 0, False

Set objFSO = Nothing : Set objShell = Nothing
