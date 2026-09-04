Set-StrictMode -Version 2.0

function ConvertTo-ZjuSafeHttpsUri {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Url
    )

    if ([string]::IsNullOrEmpty($Url)) {
        return $null
    }

    foreach ($character in $Url.ToCharArray()) {
        if ([char]::IsWhiteSpace($character) -or [char]::IsControl($character)) {
            return $null
        }
    }

    try {
        $uri = [uri]$Url
    }
    catch {
        return $null
    }

    if (-not $uri.IsAbsoluteUri -or
        $uri.Scheme -ne 'https' -or
        $uri.Host -ne 'net.zju.edu.cn' -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not $uri.IsDefaultPort) {
        return $null
    }

    return $uri
}

function Test-ZjuSuccessPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ($Path -eq '/srun_portal_success' -or
        $Path.StartsWith('/srun_portal_success/', [System.StringComparison]::Ordinal))
}

function Test-ZjuChromeProfileName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ProfileDirectory
    )

    return ($ProfileDirectory -cmatch '\A(?:Default|Profile [1-9][0-9]*)\z')
}

function Test-ZjuPortalUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Url
    )

    $uri = ConvertTo-ZjuSafeHttpsUri -Url $Url
    if ($null -eq $uri) {
        return $false
    }

    return ($uri.AbsolutePath.StartsWith('/srun_portal_') -and
        -not (Test-ZjuSuccessPath -Path $uri.AbsolutePath))
}

function Get-ZjuAuthMetaRefreshTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$BaseUri
    )

    $baseUriObject = ConvertTo-ZjuSafeHttpsUri -Url $BaseUri
    if ($null -eq $baseUriObject) {
        return $null
    }

    foreach ($tagMatch in [regex]::Matches($Content, '(?is)<meta\b[^>]*>')) {
        $tag = $tagMatch.Value
        if (-not [regex]::IsMatch($tag, '(?is)\bhttp-equiv\s*=\s*["'']?\s*refresh\s*["'']?')) {
            continue
        }

        $contentMatch = [regex]::Match(
            $tag,
            '(?is)\bcontent\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))'
        )
        if (-not $contentMatch.Success) {
            continue
        }

        $refreshContent = $null
        for ($index = 1; $index -le 3; $index++) {
            if ($contentMatch.Groups[$index].Success) {
                $refreshContent = $contentMatch.Groups[$index].Value
                break
            }
        }

        $urlMatch = [regex]::Match($refreshContent, '(?is)(?:^|;)\s*url\s*=\s*(?<target>.+?)\s*$')
        if (-not $urlMatch.Success) {
            continue
        }

        $targetText = [System.Net.WebUtility]::HtmlDecode($urlMatch.Groups['target'].Value.Trim())
        $targetText = $targetText.Trim('"', "'")

        foreach ($character in $targetText.ToCharArray()) {
            if ([char]::IsWhiteSpace($character) -or [char]::IsControl($character)) {
                $targetText = $null
                break
            }
        }
        if ($null -eq $targetText) {
            continue
        }

        try {
            $targetUri = [uri]::new($baseUriObject, $targetText)
        }
        catch {
            continue
        }

        if ($targetUri.Scheme -eq $baseUriObject.Scheme -and
            $targetUri.Host -eq $baseUriObject.Host -and
            $targetUri.Port -eq $baseUriObject.Port -and
            [string]::IsNullOrEmpty($targetUri.UserInfo) -and
            $targetUri.IsDefaultPort) {
            return $targetUri.AbsoluteUri
        }
    }

    return $null
}

function Test-ZjuAuthCooldown {
    [CmdletBinding()]
    param(
        $LastAttempt,

        [Parameter(Mandatory = $true)]
        [datetime]$Now,

        [Parameter(Mandatory = $true)]
        [int]$CooldownSeconds
    )

    if ($null -eq $LastAttempt -or $CooldownSeconds -le 0) {
        return $false
    }

    $elapsedSeconds = ($Now - [datetime]$LastAttempt).TotalSeconds
    return ($elapsedSeconds -ge 0 -and $elapsedSeconds -lt $CooldownSeconds)
}

function Get-ZjuAuthDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentUrl,

        $LastAttempt,

        [Parameter(Mandatory = $true)]
        [datetime]$Now,

        [Parameter(Mandatory = $true)]
        [int]$CooldownSeconds
    )

    $uri = ConvertTo-ZjuSafeHttpsUri -Url $CurrentUrl
    if ($null -ne $uri -and
        (Test-ZjuSuccessPath -Path $uri.AbsolutePath)) {
        return 'AlreadyOnline'
    }

    if (-not (Test-ZjuPortalUrl -Url $CurrentUrl)) {
        return 'UnexpectedUrl'
    }

    if (Test-ZjuAuthCooldown -LastAttempt $LastAttempt -Now $Now -CooldownSeconds $CooldownSeconds) {
        return 'Cooldown'
    }

    return 'Authenticate'
}

function Get-ZjuAuthLastAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.PSObject.Properties.Name -notcontains 'LastAttempt' -or
            [string]::IsNullOrWhiteSpace([string]$state.LastAttempt)) {
            return $null
        }

        $lastAttempt = [datetime]::MinValue
        $parsed = [datetime]::TryParse(
            [string]$state.LastAttempt,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$lastAttempt
        )
    }
    catch {
        return $null
    }

    if (-not $parsed) {
        return $null
    }

    return $lastAttempt
}

function Set-ZjuAuthLastAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [datetime]$AttemptedAt
    )

    $stateDirectory = Split-Path -Parent $StatePath
    if (-not [string]::IsNullOrWhiteSpace($stateDirectory) -and
        -not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $temporaryPath = "$StatePath.$PID.tmp"
    try {
        @{
            LastAttempt = $AttemptedAt.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        } | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8

        Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ZjuChromeCandidatePaths {
    [CmdletBinding()]
    param()

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $roots = @(
        $env:ProgramFiles
        $programFilesX86
        $env:LOCALAPPDATA
    )

    foreach ($root in $roots) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            Join-Path $root 'Google\Chrome\Application\chrome.exe'
        }
    }
}

function Test-ZjuChromeExecutablePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $leafName = Split-Path -Leaf -Path $Path
    $parentPath = Split-Path -Parent -Path $Path
    return ([string]::Equals($leafName, 'chrome.exe', [System.StringComparison]::OrdinalIgnoreCase) -and
        [regex]::IsMatch($parentPath, '(?i)(?:^|[\\/])Google[\\/]Chrome[\\/]Application$'))
}

function Resolve-ZjuChromeExecutable {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$ChromeExecutable
    )

    if (-not [string]::IsNullOrWhiteSpace($ChromeExecutable)) {
        if (-not (Test-Path -LiteralPath $ChromeExecutable -PathType Leaf)) {
            throw "Configured Google Chrome executable does not exist: $ChromeExecutable"
        }

        try {
            $configuredFullPath = [System.IO.Path]::GetFullPath($ChromeExecutable)
        }
        catch {
            throw "Configured Google Chrome executable is not a safe Google Chrome executable: $ChromeExecutable"
        }

        $matchesCandidate = $false
        foreach ($candidate in Get-ZjuChromeCandidatePaths) {
            try {
                $candidateFullPath = [System.IO.Path]::GetFullPath($candidate)
            }
            catch {
                continue
            }

            if ([string]::Equals(
                    $configuredFullPath,
                    $candidateFullPath,
                    [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-ZjuChromeExecutablePath -Path $candidate)) {
                $matchesCandidate = $true
                break
            }
        }

        if (-not $matchesCandidate) {
            throw "Configured Google Chrome executable is not a safe Google Chrome executable: $ChromeExecutable"
        }

        return $ChromeExecutable
    }

    foreach ($candidate in Get-ZjuChromeCandidatePaths) {
        if (Test-ZjuChromeExecutablePath -Path $candidate) {
            return $candidate
        }
    }

    throw 'No Google Chrome installation was found in ProgramFiles, ProgramFiles(x86), or LOCALAPPDATA.'
}

function Test-ZjuAbsoluteWindowsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ($Path -match '\A(?:[A-Za-z]:[\\/]|\\\\)')
}

function Get-ZjuDefaultDataDirectory {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; the ZJU network authentication data directory cannot be determined.'
    }

    return Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin'
}

function Get-ZjuAuthConfiguration {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    $portalUrl = 'https://net.zju.edu.cn'
    $cooldownSeconds = 300
    $chromeExecutable = ''
    $chromeProfile = 'Default'

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw "Configuration file does not exist: $ConfigPath"
        }

        $configured = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($configured.PSObject.Properties.Name -contains 'PortalUrl') {
            $portalUrl = [string]$configured.PortalUrl
        }
        if ($configured.PSObject.Properties.Name -contains 'CooldownSeconds') {
            $cooldownSeconds = [int]$configured.CooldownSeconds
        }
        if ($configured.PSObject.Properties.Name -contains 'ChromeExecutable') {
            $chromeExecutable = [string]$configured.ChromeExecutable
        }
        if ($configured.PSObject.Properties.Name -contains 'ChromeProfile') {
            $chromeProfile = [string]$configured.ChromeProfile
        }
    }

    $portalUri = ConvertTo-ZjuSafeHttpsUri -Url $portalUrl
    if ($null -eq $portalUri -or (Test-ZjuSuccessPath -Path $portalUri.AbsolutePath)) {
        throw 'PortalUrl must be a safe HTTPS URL on net.zju.edu.cn.'
    }
    if ($cooldownSeconds -le 0) {
        throw 'CooldownSeconds must be a positive integer.'
    }
    if (-not (Test-ZjuChromeProfileName -ProfileDirectory $chromeProfile)) {
        throw 'ChromeProfile must be a simple Chrome profile directory name.'
    }

    $dataDirectory = Get-ZjuDefaultDataDirectory
    [pscustomobject]@{
        PortalUrl = $portalUrl
        CooldownSeconds = $cooldownSeconds
        ChromeExecutable = Resolve-ZjuChromeExecutable -ChromeExecutable $chromeExecutable
        ChromeProfile = $chromeProfile
        StatePath = Join-Path $dataDirectory 'state.json'
        LogPath = Join-Path $dataDirectory 'logs\activity.log'
    }
}

function Get-ZjuChromeLaunchArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PortalUrl,

        [string]$ProfileDirectory = 'Default'
    )

    $portalUri = ConvertTo-ZjuSafeHttpsUri -Url $PortalUrl
    if ($null -eq $portalUri -or -not (Test-ZjuPortalUrl -Url $portalUri.AbsoluteUri)) {
        throw 'Refusing to launch Chrome for a URL outside the ZJU login portal.'
    }
    if (-not (Test-ZjuChromeProfileName -ProfileDirectory $ProfileDirectory)) {
        throw 'ProfileDirectory must be a simple Chrome profile directory name.'
    }

    return @(
        ('--profile-directory="{0}"' -f $ProfileDirectory)
        '--new-window'
        $portalUri.AbsoluteUri
    )
}

function Get-ZjuAuthTaskXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [string]$UserSid,

        [Parameter(Mandatory = $true)]
        [string]$RunnerPath,

        [string]$ConfigPath
    )

    if (-not (Test-ZjuAbsoluteWindowsPath -Path $RunnerPath)) {
        throw 'RunnerPath must be an absolute path.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and
        -not (Test-ZjuAbsoluteWindowsPath -Path $ConfigPath)) {
        throw 'ConfigPath must be an absolute path.'
    }

    if ($RunnerPath.IndexOf('"') -ge 0 -or
        $RunnerPath.IndexOfAny([char[]]@([char]10, [char]13, [char]0)) -ge 0) {
        throw 'RunnerPath contains characters that cannot be quoted safely.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and
        ($ConfigPath.IndexOf('"') -ge 0 -or
        $ConfigPath.IndexOfAny([char[]]@([char]10, [char]13, [char]0)) -ge 0)) {
        throw 'ConfigPath contains characters that cannot be quoted safely.'
    }

    $escapedTaskName = [System.Security.SecurityElement]::Escape($TaskName)
    $escapedUserSid = [System.Security.SecurityElement]::Escape($UserSid)
    $escapedRunnerPath = [System.Security.SecurityElement]::Escape($RunnerPath)
    $escapedWorkingDirectory = [System.Security.SecurityElement]::Escape((Split-Path -Parent $RunnerPath))
    $configArgument = ''
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $escapedConfigPath = [System.Security.SecurityElement]::Escape($ConfigPath)
        $configArgument = " -ConfigPath &quot;$escapedConfigPath&quot;"
    }

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$escapedTaskName</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NCSI/Operational"&gt;&lt;Select Path="Microsoft-Windows-NCSI/Operational"&gt;*[System[EventID=4038]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="CurrentUser">
      <UserId>$escapedUserSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="CurrentUser">
    <Exec>
      <Command>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File &quot;$escapedRunnerPath&quot;$configArgument</Arguments>
      <WorkingDirectory>$escapedWorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

Export-ModuleMember -Function @(
    'Test-ZjuPortalUrl'
    'Get-ZjuAuthMetaRefreshTarget'
    'Test-ZjuAuthCooldown'
    'Get-ZjuAuthDecision'
    'Get-ZjuAuthLastAttempt'
    'Set-ZjuAuthLastAttempt'
    'Get-ZjuChromeCandidatePaths'
    'Resolve-ZjuChromeExecutable'
    'Get-ZjuDefaultDataDirectory'
    'Get-ZjuAuthConfiguration'
    'Get-ZjuChromeLaunchArguments'
    'Get-ZjuAuthTaskXml'
)
