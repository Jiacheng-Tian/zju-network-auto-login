[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$distDirectory = Join-Path $repositoryRoot 'dist'
$archivePath = Join-Path $distDirectory 'zju-network-auto-login-v1.0.0.zip'
$stagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("zju-network-auto-login-$([guid]::NewGuid().ToString('N'))")
$releaseFiles = @(
    'scripts\Install.ps1'
    'scripts\Invoke-ZjuNetworkAuth.ps1'
    'scripts\Uninstall.ps1'
    'scripts\ZjuNetworkAuth.psm1'
    'chrome-extension\content.js'
    'chrome-extension\manifest.json'
    'config.example.json'
    'README.md'
    'LICENSE'
)

foreach ($releaseFile in $releaseFiles) {
    $sourcePath = Join-Path $repositoryRoot $releaseFile
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required release file is missing: $sourcePath"
    }
}

try {
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $distDirectory -Force | Out-Null

    foreach ($releaseFile in $releaseFiles) {
        $sourcePath = Join-Path $repositoryRoot $releaseFile
        $stagingPath = Join-Path $stagingDirectory $releaseFile
        $stagingParent = Split-Path -Parent $stagingPath
        if (-not (Test-Path -LiteralPath $stagingParent -PathType Container)) {
            New-Item -ItemType Directory -Path $stagingParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $stagingPath -Force
    }

    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archivePath -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $actualEntries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('/', '\') })
        $expectedEntries = @($releaseFiles | Sort-Object)
        $actualEntries = @($actualEntries | Sort-Object)
        if (($actualEntries -join "`n") -ne ($expectedEntries -join "`n")) {
            throw "Release archive entries do not match the explicit release allowlist. Actual: $($actualEntries -join ', ')"
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}

Write-Output $archivePath
