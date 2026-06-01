' Launches the large centered Claude Sessions view with NO console window.
Set sh = CreateObject("Wscript.Shell")
userProfile = sh.ExpandEnvironmentStrings("%USERPROFILE%")
script = userProfile & "\.claude\sessions\session-view.ps1"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
