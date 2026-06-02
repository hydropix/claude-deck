' Launches the ClaudeDeck statistics dashboard with NO console window.
Set sh = CreateObject("Wscript.Shell")
userProfile = sh.ExpandEnvironmentStrings("%USERPROFILE%")
script = userProfile & "\.claude\sessions\session-stats.ps1"
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """", 0, False
