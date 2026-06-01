' Launches the Claude Sessions tray app with NO visible console window.
Set sh = CreateObject("Wscript.Shell")
userProfile = sh.ExpandEnvironmentStrings("%USERPROFILE%")
script = userProfile & "\.claude\sessions\session-tray.ps1"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
