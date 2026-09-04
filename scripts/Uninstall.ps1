[CmdletBinding()]
param(
    [string]$TaskName = 'ZJU Network Auto Login'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

& schtasks.exe /Query /TN $TaskName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "Scheduled task not found: $TaskName"
    return
}

& schtasks.exe /Delete /TN $TaskName /F
if ($LASTEXITCODE -ne 0) {
    throw "schtasks.exe failed while removing task '$TaskName' (exit code $LASTEXITCODE)."
}

Write-Output "Removed scheduled task: $TaskName"
