Option Explicit

Dim shell, fso, scriptDir, powerShellPath, guiScript, command, installMode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
guiScript = fso.BuildPath(scriptDir, "ModLocket.ps1")
installMode = ""

If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "install" Then installMode = " -Install"
End If

command = Chr(34) & powerShellPath & Chr(34) & _
          " -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
          Chr(34) & guiScript & Chr(34) & installMode

' Window style 0 keeps the PowerShell host invisible; the WinForms UI remains visible.
shell.Run command, 0, False
