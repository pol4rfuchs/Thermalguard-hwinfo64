' ============================================================================
' Start-HWiNFO-Remote.vbs
' Starts the .bat elevated (Admin) and completely invisible (no CMD window)
' Placement: Task Scheduler (no UAC) OR shell:startup (confirm UAC once)
' ============================================================================
Set WshShell = CreateObject("WScript.Shell")
Set objShell = CreateObject("Shell.Application")

batPath = Replace(WScript.ScriptFullName, ".vbs", ".bat")

' Starts cmd.exe /c "batPath" elevated — invisible via ShellExecute runas
objShell.ShellExecute "cmd.exe", "/c """ & batPath & """", "", "runas", 0
