' start_token_dashboard.vbs
' Launches token-dashboard silently at login. No console window.
' To start manually: wscript "C:\Scripts\GitHub\token-dashboard\start_token_dashboard.vbs"
' To verify running: open http://127.0.0.1:8080

Dim objShell, objFSO, userProfile, pythonExe, scriptPath
Set objShell = CreateObject("WScript.Shell")
Set objFSO   = CreateObject("Scripting.FileSystemObject")

userProfile = objShell.ExpandEnvironmentStrings("%USERPROFILE%")

Dim candidates : candidates = Array( _
  userProfile & "\AppData\Local\Programs\Python\Python314\python.exe", _
  userProfile & "\AppData\Local\Programs\Python\Python313\python.exe", _
  "C:\Python314\python.exe", _
  "C:\Python313\python.exe" _
)
pythonExe = ""
Dim c
For Each c In candidates
  If objFSO.FileExists(c) Then pythonExe = c : Exit For
Next
If pythonExe = "" Then
  MsgBox "Python not found.", vbCritical, "Token Dashboard"
  WScript.Quit 1
End If

objShell.CurrentDirectory = "C:\Scripts\GitHub\token-dashboard"
objShell.Run """" & pythonExe & """ ""C:\Scripts\GitHub\token-dashboard\cli.py"" dashboard --no-open", 0, False

Set objFSO = Nothing : Set objShell = Nothing
