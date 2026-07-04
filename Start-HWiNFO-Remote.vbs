' ============================================================================
' Start-HWiNFO-Remote.vbs  (v1.42)
'
' This launches Start-HWiNFO-Remote.bat completely invisibly (no CMD window),
' WITHOUT requesting UAC elevation here. Report finding #16: a UAC prompt
' inside an unattended autostart path either blocks forever waiting for a
' click nobody sees, or silently fails - neither is acceptable for an
' autostart item. If administrator rights are required (they are, for
' shutdown.exe and for managing other processes), set this up via
' Install-ScheduledTask.ps1 instead of placing this .vbs in shell:startup.
' That script registers a Scheduled Task with "Run with highest privileges"
' checked, so elevation is granted once at setup time, not on every login.
'
' Path rule: the .bat is resolved relative to THIS file's own location, so
' the .vbs and .bat (and the .ps1 they launch) must live in the same folder.
' ============================================================================
Set WshShell = CreateObject("WScript.Shell")
batPath = Replace(WScript.ScriptFullName, ".vbs", ".bat")
WshShell.Run Chr(34) & batPath & Chr(34), 0, False
