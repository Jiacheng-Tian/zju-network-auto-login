[CmdletBinding()]
param(
    [string]$TaskName = 'ZJU Network Auto Login',
    [string]$ConfigPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runnerPath = Join-Path $repositoryRoot 'scripts\Invoke-ZjuNetworkAuth.ps1'
$modulePath = Join-Path $repositoryRoot 'scripts\ZjuNetworkAuth.psm1'
$extensionDirectory = Join-Path $repositoryRoot 'chrome-extension'

foreach ($requiredPath in @($runnerPath, $modulePath, $extensionDirectory)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required repository path does not exist: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $repositoryConfigPath = Join-Path $repositoryRoot 'config.json'
    if (Test-Path -LiteralPath $repositoryConfigPath -PathType Leaf) {
        $ConfigPath = $repositoryConfigPath
    }
}

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file does not exist: $ConfigPath"
    }
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
}

Import-Module $modulePath -Force
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskXml = Get-ZjuAuthTaskXml -TaskName $TaskName -UserSid $userSid -RunnerPath $runnerPath -ConfigPath $ConfigPath
$temporaryTaskXmlPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ZjuNetworkAutoLogin-$PID.xml")

try {
    [System.IO.File]::WriteAllText($temporaryTaskXmlPath, $taskXml, [System.Text.Encoding]::Unicode)
    & schtasks.exe /Create /TN $TaskName /XML $temporaryTaskXmlPath /F
    if ($LASTEXITCODE -ne 0) {
        throw "schtasks.exe failed while registering task '$TaskName' (exit code $LASTEXITCODE)."
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryTaskXmlPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryTaskXmlPath -Force
    }
}

Write-Output "Registered current-user task: $TaskName"
Write-Output "Chrome extension directory: $extensionDirectory"
