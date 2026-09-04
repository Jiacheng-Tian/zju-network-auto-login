[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun,
    [string]$CurrentUrl
)

Import-Module (Join-Path $PSScriptRoot 'ZjuNetworkAuth.psm1') -Force

$configuration = Get-ZjuAuthConfiguration -ConfigPath $ConfigPath

function Write-ZjuAuthLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $logDirectory = Split-Path -Parent $configuration.LogPath
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString(
        'o',
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    Add-Content -LiteralPath $configuration.LogPath -Value "$timestamp $Message" -Encoding UTF8
}

try {
    if ([string]::IsNullOrWhiteSpace($CurrentUrl)) {
        if ($DryRun) {
            throw 'CurrentUrl is required in dry-run mode so no network request is made.'
        }

        $response = Invoke-WebRequest -Uri $configuration.PortalUrl -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction Stop
        $responseUrl = $configuration.PortalUrl
        if ($null -ne $response.BaseResponse -and $null -ne $response.BaseResponse.ResponseUri) {
            $responseUrl = $response.BaseResponse.ResponseUri.AbsoluteUri
        }

        $refreshTarget = Get-ZjuAuthMetaRefreshTarget -Content $response.Content -BaseUri $responseUrl
        if ($null -ne $refreshTarget) {
            $CurrentUrl = $refreshTarget
        }
        else {
            $CurrentUrl = $responseUrl
        }
    }

    $lastAttempt = Get-ZjuAuthLastAttempt -StatePath $configuration.StatePath
    $decision = Get-ZjuAuthDecision -CurrentUrl $CurrentUrl -LastAttempt $lastAttempt -Now (Get-Date) -CooldownSeconds $configuration.CooldownSeconds

    switch ($decision) {
        'AlreadyOnline' {
            $outcome = 'AlreadyOnline'
        }
        'Cooldown' {
            $outcome = 'Cooldown'
        }
        'UnexpectedUrl' {
            throw "Refusing to automate an unexpected destination: $CurrentUrl"
        }
        'Authenticate' {
            if ($DryRun) {
                $outcome = 'WouldAuthenticate'
            }
            else {
                $arguments = Get-ZjuChromeLaunchArguments -PortalUrl $CurrentUrl -ProfileDirectory $configuration.ChromeProfile
                Start-Process -FilePath $configuration.ChromeExecutable -ArgumentList $arguments
                Set-ZjuAuthLastAttempt -StatePath $configuration.StatePath -AttemptedAt (Get-Date)
                $outcome = 'Authenticate'
            }
        }
    }

    Write-ZjuAuthLog -Message $outcome
    return $outcome
}
catch {
    $originalError = $_
    try {
        Write-ZjuAuthLog -Message "Error: $($originalError.Exception.Message)"
    }
    catch {
    }
    throw $originalError
}
