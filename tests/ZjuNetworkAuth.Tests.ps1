$modulePath = Join-Path $PSScriptRoot '..\scripts\ZjuNetworkAuth.psm1'
$runnerPath = Join-Path $PSScriptRoot '..\scripts\Invoke-ZjuNetworkAuth.ps1'
$extensionDirectory = Join-Path $PSScriptRoot '..\chrome-extension'
$manifestPath = Join-Path $extensionDirectory 'manifest.json'
$contentScriptPath = Join-Path $extensionDirectory 'content.js'
$exampleConfigPath = Join-Path $PSScriptRoot '..\config.example.json'

function Get-TestExceptionMessage {
    param([scriptblock]$ScriptBlock)

    try {
        $null = & $ScriptBlock
    }
    catch {
        return $_.Exception.Message
    }

    return $null
}
function New-TestChromeExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [string]$LeafName = 'chrome.exe'
    )

    $chromePath = Join-Path $Root "Google\Chrome\Application\$LeafName"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $chromePath) | Out-Null
    Set-Content -LiteralPath $chromePath -Value 'test executable'
    return $chromePath
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\scripts\ZjuNetworkAuth.psm1'
    $runnerPath = Join-Path $PSScriptRoot '..\scripts\Invoke-ZjuNetworkAuth.ps1'
    $extensionDirectory = Join-Path $PSScriptRoot '..\chrome-extension'
    $manifestPath = Join-Path $extensionDirectory 'manifest.json'
    $contentScriptPath = Join-Path $extensionDirectory 'content.js'
    $exampleConfigPath = Join-Path $PSScriptRoot '..\config.example.json'

    function Get-TestExceptionMessage {
        param([scriptblock]$ScriptBlock)

        try {
            $null = & $ScriptBlock
        }
        catch {
            return $_.Exception.Message
        }

        return $null
    }

    function New-TestChromeExecutable {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Root,

            [string]$LeafName = 'chrome.exe'
        )

        $chromePath = Join-Path $Root "Google\Chrome\Application\$LeafName"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $chromePath) | Out-Null
        Set-Content -LiteralPath $chromePath -Value 'test executable'
        return $chromePath
    }

    Import-Module $modulePath -Force
}

Describe 'ZjuNetworkAuth module surface' {
    It 'exports only the active Task 1 functions' {
        $expected = @(
            'Get-ZjuAuthConfiguration'
            'Get-ZjuAuthDecision'
            'Get-ZjuAuthLastAttempt'
            'Get-ZjuAuthMetaRefreshTarget'
            'Get-ZjuAuthTaskXml'
            'Get-ZjuChromeCandidatePaths'
            'Get-ZjuChromeLaunchArguments'
            'Get-ZjuDefaultDataDirectory'
            'Resolve-ZjuChromeExecutable'
            'Set-ZjuAuthLastAttempt'
            'Test-ZjuAuthCooldown'
            'Test-ZjuPortalUrl'
        )
        $actual = @(Get-Command -Module ZjuNetworkAuth -CommandType Function | Select-Object -ExpandProperty Name | Sort-Object)

        ($actual -join '|') | Should -Be ($expected -join '|')
    }
}
Describe 'Test-ZjuPortalUrl' {
    It 'accepts only an HTTPS ZJU login portal URL' {
        Test-ZjuPortalUrl -Url 'https://net.zju.edu.cn/srun_portal_pc?ac_id=80&theme=zju' | Should -Be $true
    }

    It 'rejects success paths and descendants everywhere' {
        Test-ZjuPortalUrl -Url 'https://net.zju.edu.cn/srun_portal_success?ac_id=80' | Should -Be $false
        Test-ZjuPortalUrl -Url 'https://net.zju.edu.cn/srun_portal_success/' | Should -Be $false
        Test-ZjuPortalUrl -Url 'https://net.zju.edu.cn/srun_portal_success/details' | Should -Be $false
    }

    It 'rejects unsafe origins and ambiguous URL text' {
        Test-ZjuPortalUrl -Url 'http://net.zju.edu.cn/srun_portal_page' | Should -Be $false
        Test-ZjuPortalUrl -Url 'https://example.com/srun_portal_pc' | Should -Be $false
        Test-ZjuPortalUrl -Url 'ftp://net.zju.edu.cn/srun_portal_pc' | Should -Be $false
        Test-ZjuPortalUrl -Url 'https://operator@net.zju.edu.cn/srun_portal_pc' | Should -Be $false
        Test-ZjuPortalUrl -Url 'https://net.zju.edu.cn:444/srun_portal_pc' | Should -Be $false
        Test-ZjuPortalUrl -Url ' https://net.zju.edu.cn/srun_portal_pc' | Should -Be $false
        Test-ZjuPortalUrl -Url ('https://net.zju.edu.cn/srun_portal_pc' + [char]10 + '--incognito') | Should -Be $false
        Test-ZjuPortalUrl -Url 'not a URL' | Should -Be $false
    }
}

Describe 'Get-ZjuAuthMetaRefreshTarget' {
    It 'resolves and decodes a same-origin meta refresh target' {
        $content = '<meta http-equiv="refresh" content="0;url=/srun_portal_pc?ac_id=79&amp;theme=zju">'

        Get-ZjuAuthMetaRefreshTarget -Content $content -BaseUri 'https://net.zju.edu.cn/index_1.html' |
            Should -Be 'https://net.zju.edu.cn/srun_portal_pc?ac_id=79&theme=zju'
    }

    It 'returns nothing without a refresh or for a different origin' {
        Get-ZjuAuthMetaRefreshTarget -Content '<html></html>' -BaseUri 'https://net.zju.edu.cn/index_1.html' | Should -Be $null
        Get-ZjuAuthMetaRefreshTarget -Content '<meta http-equiv="refresh" content="0;url=https://example.com/">' -BaseUri 'https://net.zju.edu.cn/' | Should -Be $null
        Get-ZjuAuthMetaRefreshTarget -Content '<meta http-equiv="refresh" content="0;url=http://net.zju.edu.cn/srun_portal_pc">' -BaseUri 'https://net.zju.edu.cn/' | Should -Be $null
    }
}

Describe 'Cooldown and decision behavior' {
    BeforeAll {
        $now = [datetime]'2026-09-02T14:20:00'
        $portalUrl = 'https://net.zju.edu.cn/srun_portal_pc?ac_id=80&theme=zju'
    }

    It 'treats only attempts inside the cooldown window as active' {
        Test-ZjuAuthCooldown -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be $false
        Test-ZjuAuthCooldown -LastAttempt $now.AddSeconds(-299) -Now $now -CooldownSeconds 300 | Should -Be $true
        Test-ZjuAuthCooldown -LastAttempt $now.AddSeconds(-300) -Now $now -CooldownSeconds 300 | Should -Be $false
    }

    It 'returns the safe authentication decisions' {
        Get-ZjuAuthDecision -CurrentUrl 'https://net.zju.edu.cn/srun_portal_success?ac_id=80' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'AlreadyOnline'
        Get-ZjuAuthDecision -CurrentUrl 'https://net.zju.edu.cn/srun_portal_success/' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'AlreadyOnline'
        Get-ZjuAuthDecision -CurrentUrl 'https://net.zju.edu.cn/srun_portal_success/details' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'AlreadyOnline'
        Get-ZjuAuthDecision -CurrentUrl $portalUrl -LastAttempt $now.AddSeconds(-299) -Now $now -CooldownSeconds 300 | Should -Be 'Cooldown'
        Get-ZjuAuthDecision -CurrentUrl $portalUrl -LastAttempt $now.AddSeconds(-300) -Now $now -CooldownSeconds 300 | Should -Be 'Authenticate'
        Get-ZjuAuthDecision -CurrentUrl 'https://example.com/' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'UnexpectedUrl'
        Get-ZjuAuthDecision -CurrentUrl 'http://net.zju.edu.cn/srun_portal_pc' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'UnexpectedUrl'
        Get-ZjuAuthDecision -CurrentUrl 'https://operator@net.zju.edu.cn/srun_portal_pc' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'UnexpectedUrl'
        Get-ZjuAuthDecision -CurrentUrl 'https://net.zju.edu.cn:444/srun_portal_pc' -LastAttempt $null -Now $now -CooldownSeconds 300 | Should -Be 'UnexpectedUrl'
    }
}

Describe 'ZJU authentication state persistence' {
    It 'returns no timestamp when the state file does not exist' {
        Get-ZjuAuthLastAttempt -StatePath (Join-Path $TestDrive 'missing-state.json') | Should -Be $null
    }

    It 'persists and reads the last authentication attempt from a real file' {
        $statePath = Join-Path $TestDrive 'nested\state.json'
        $attempt = [datetime]'2026-09-02T14:13:55'

        Set-ZjuAuthLastAttempt -StatePath $statePath -AttemptedAt $attempt

        Test-Path -LiteralPath $statePath | Should -Be $true
        Get-ZjuAuthLastAttempt -StatePath $statePath | Should -Be $attempt
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter '*.tmp').Count | Should -Be 0
    }

    It 'treats malformed JSON and timestamps as no previous attempt' {
        $malformedPath = Join-Path $TestDrive 'malformed-state.json'
        Set-Content -LiteralPath $malformedPath -Value '{not-json' -Encoding UTF8
        Get-ZjuAuthLastAttempt -StatePath $malformedPath | Should -Be $null

        $invalidTimestampPath = Join-Path $TestDrive 'invalid-timestamp-state.json'
        @{ LastAttempt = 'not-a-timestamp' } | ConvertTo-Json | Set-Content -LiteralPath $invalidTimestampPath -Encoding UTF8
        Get-ZjuAuthLastAttempt -StatePath $invalidTimestampPath | Should -Be $null
    }

    It 'cleans its same-directory PID temp file when the atomic move fails' {
        $statePath = Join-Path $TestDrive 'failed-write\state.json'
        $stateDirectory = Split-Path -Parent $statePath
        $attempt = [datetime]'2026-09-02T14:13:55'
        Mock -CommandName Move-Item -ModuleName ZjuNetworkAuth -MockWith {
            throw 'simulated move failure'
        }

        Get-TestExceptionMessage {
            Set-ZjuAuthLastAttempt -StatePath $statePath -AttemptedAt $attempt
        } | Should -Match 'simulated move failure'

        @(Get-ChildItem -LiteralPath $stateDirectory -Filter "state.json.$PID*.tmp").Count | Should -Be 0
        Should -Invoke -CommandName Move-Item -ModuleName ZjuNetworkAuth -Times 1 -ParameterFilter {
            $Force -and $LiteralPath -like "*.$PID.tmp" -and
            (Split-Path -Parent $LiteralPath) -eq $stateDirectory
        }
    }
}

Describe 'Chrome discovery and default data paths' {
    It 'uses a portable LOCALAPPDATA data directory and fails clearly when unavailable' {
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            Get-ZjuDefaultDataDirectory | Should -Be (Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin')

            $env:LOCALAPPDATA = $null
            Get-TestExceptionMessage { Get-ZjuDefaultDataDirectory } | Should -Match 'LOCALAPPDATA'
        }
        finally {
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'builds candidates from ProgramFiles, ProgramFiles(x86), and LOCALAPPDATA without a user-specific path' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'ProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'ProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'

            $candidates = @(Get-ZjuChromeCandidatePaths)

            $candidates.Count | Should -Be 3
            $candidates[0] | Should -Be (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
            $candidates[1] | Should -Be (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
            $candidates[2] | Should -Be (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
            (Get-Content -LiteralPath $modulePath -Raw) | Should -Not -Match 'C:\\Users\\[^\\]+'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'accepts an existing configured Chrome path and rejects a missing one' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'ConfiguredProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'ConfiguredProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'ConfiguredLocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA -LeafName 'ChRoMe.ExE'

            Resolve-ZjuChromeExecutable -ChromeExecutable $chromePath | Should -Be $chromePath
            Get-TestExceptionMessage {
                Resolve-ZjuChromeExecutable -ChromeExecutable (Join-Path $TestDrive 'missing-chrome.exe')
            } | Should -Match 'does not exist'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'rejects existing files outside the Chrome executable path contract' {
        $notepadPath = New-TestChromeExecutable -Root (Join-Path $TestDrive 'notepad-root') -LeafName 'notepad.exe'
        $arbitraryPath = Join-Path $TestDrive 'temp\chrome.exe'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $arbitraryPath) | Out-Null
        Set-Content -LiteralPath $arbitraryPath -Value 'test executable'
        $outsideChromePath = New-TestChromeExecutable -Root (Join-Path $TestDrive 'outside-chrome-root')

        foreach ($unsafePath in @($notepadPath, $arbitraryPath, $outsideChromePath)) {
            Get-TestExceptionMessage {
                Resolve-ZjuChromeExecutable -ChromeExecutable $unsafePath
            } | Should -Match 'safe Google Chrome executable'
        }
    }

    It 'returns the first existing auto-detection candidate and errors when none exist' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'EmptyProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'EmptyProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalWithChrome'
            $chromePath = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $chromePath) | Out-Null
            Set-Content -LiteralPath $chromePath -Value 'test executable'

            Resolve-ZjuChromeExecutable | Should -Be $chromePath

            Remove-Item -LiteralPath $chromePath
            Get-TestExceptionMessage { Resolve-ZjuChromeExecutable } | Should -Match 'Google Chrome installation'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }
}
Describe 'Get-ZjuAuthConfiguration' {
    It 'returns portable defaults and auto-detects Chrome' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'EmptyProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'EmptyProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $chromePath) | Out-Null
            Set-Content -LiteralPath $chromePath -Value 'test executable'

            $config = Get-ZjuAuthConfiguration
            $dataDirectory = Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin'

            $config.PortalUrl | Should -Be 'https://net.zju.edu.cn'
            $config.CooldownSeconds | Should -Be 300
            $config.ChromeExecutable | Should -Be $chromePath
            $config.ChromeProfile | Should -Be 'Default'
            $config.StatePath | Should -Be (Join-Path $dataDirectory 'state.json')
            $config.LogPath | Should -Be (Join-Path $dataDirectory 'logs\activity.log')
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'applies supported overrides while keeping state and logs in the portable data directory' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'ConfiguredProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'ConfiguredProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'config.json'
            @{
                PortalUrl = 'https://net.zju.edu.cn/srun_portal_pc'
                CooldownSeconds = 900
                ChromeExecutable = $chromePath
                ChromeProfile = 'Profile 2'
                StatePath = 'ignored-state.json'
                LogPath = 'ignored-log.txt'
            } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

            $config = Get-ZjuAuthConfiguration -ConfigPath $configPath
            $dataDirectory = Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin'

            $config.PortalUrl | Should -Be 'https://net.zju.edu.cn/srun_portal_pc'
            $config.CooldownSeconds | Should -Be 900
            $config.ChromeExecutable | Should -Be $chromePath
            $config.ChromeProfile | Should -Be 'Profile 2'
            $config.StatePath | Should -Be (Join-Path $dataDirectory 'state.json')
            $config.LogPath | Should -Be (Join-Path $dataDirectory 'logs\activity.log')
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'treats an empty ChromeExecutable override as auto-detection' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'EmptyProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'EmptyProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $chromePath) | Out-Null
            Set-Content -LiteralPath $chromePath -Value 'test executable'
            $configPath = Join-Path $TestDrive 'config.json'
            @{ ChromeExecutable = '' } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

            (Get-ZjuAuthConfiguration -ConfigPath $configPath).ChromeExecutable | Should -Be $chromePath
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'rejects missing config files, invalid portal hosts, and nonpositive cooldowns' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'ConfiguredProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'ConfiguredProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            Get-TestExceptionMessage {
                Get-ZjuAuthConfiguration -ConfigPath (Join-Path $TestDrive 'missing.json')
            } | Should -Match 'does not exist'

            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $badHostPath = Join-Path $TestDrive 'bad-host.json'
            @{ PortalUrl = 'https://example.com/srun_portal_pc'; ChromeExecutable = $chromePath } | ConvertTo-Json | Set-Content -LiteralPath $badHostPath -Encoding UTF8
            Get-TestExceptionMessage {
                Get-ZjuAuthConfiguration -ConfigPath $badHostPath
            } | Should -Match 'net\.zju\.edu\.cn'

            $badCooldownPath = Join-Path $TestDrive 'bad-cooldown.json'
            @{ CooldownSeconds = 0; ChromeExecutable = $chromePath } | ConvertTo-Json | Set-Content -LiteralPath $badCooldownPath -Encoding UTF8
            Get-TestExceptionMessage {
                Get-ZjuAuthConfiguration -ConfigPath $badCooldownPath
            } | Should -Match 'positive'

            foreach ($unsafePortalUrl in @(
                'http://net.zju.edu.cn'
                'https://operator@net.zju.edu.cn'
                'https://net.zju.edu.cn:444'
                ('https://net.zju.edu.cn' + [char]10 + '--incognito')
            )) {
                $unsafePortalPath = Join-Path $TestDrive ("unsafe-portal-{0}.json" -f [guid]::NewGuid())
                @{
                    PortalUrl = $unsafePortalUrl
                    ChromeExecutable = $chromePath
                } | ConvertTo-Json | Set-Content -LiteralPath $unsafePortalPath -Encoding UTF8

                Get-TestExceptionMessage {
                    Get-ZjuAuthConfiguration -ConfigPath $unsafePortalPath
                } | Should -Match 'PortalUrl'
            }
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'rejects unsafe Chrome profile directory names' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'ConfiguredProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'ConfiguredProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA

            foreach ($profileName in @(
                ''
                'Profile --incognito'
                'Profile 4 --incognito'
                'Profile 0'
                'Profile -1'
                'Profile\1'
                'Profile/1'
                'Default 4'
                'Other'
                ('Profile' + [char]10 + '2')
            )) {
                $configPath = Join-Path $TestDrive ("unsafe-profile-{0}.json" -f [guid]::NewGuid())
                @{
                    ChromeExecutable = $chromePath
                    ChromeProfile = $profileName
                } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

                Get-TestExceptionMessage {
                    Get-ZjuAuthConfiguration -ConfigPath $configPath
                } | Should -Match 'ChromeProfile'
            }
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'reads a BOM-less UTF-8 configuration containing a non-ASCII Chrome path' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'ConfiguredProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'ConfiguredProgramFilesX86'
            $unicodeDirectoryName = -join @([char]0x6D4F, [char]0x89C8, [char]0x5668)
            $env:LOCALAPPDATA = Join-Path $TestDrive $unicodeDirectoryName
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'utf8-config.json'
            $json = @{
                ChromeExecutable = $chromePath
                ChromeProfile = 'Profile 3'
            } | ConvertTo-Json
            [System.IO.File]::WriteAllText(
                $configPath,
                $json,
                (New-Object System.Text.UTF8Encoding($false))
            )

            $config = Get-ZjuAuthConfiguration -ConfigPath $configPath

            $config.ChromeExecutable | Should -Be $chromePath
            $config.ChromeProfile | Should -Be 'Profile 3'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }
}

Describe 'Chrome launch arguments and scheduled task XML' {
    It 'uses the configured profile and canonical safe URL in a new window' {
        $portalUrl = 'HTTPS://NET.ZJU.EDU.CN/srun_portal_pc/../srun_portal_page?ac_id=79&theme=zju'
        $arguments = Get-ZjuChromeLaunchArguments -PortalUrl $portalUrl -ProfileDirectory 'Profile 2'

        $arguments.Count | Should -Be 3
        $arguments[0] | Should -Be '--profile-directory="Profile 2"'
        $arguments[1] | Should -Be '--new-window'
        $arguments[2] | Should -Be ([uri]$portalUrl).AbsoluteUri
    }

    It 'refuses unsafe portal URLs and profile directory names' {
        foreach ($portalUrl in @(
            'http://net.zju.edu.cn/srun_portal_pc'
            'https://operator@net.zju.edu.cn/srun_portal_pc'
            'https://net.zju.edu.cn:444/srun_portal_pc'
            'https://net.zju.edu.cn/srun_portal_success/'
            ('https://net.zju.edu.cn/srun_portal_pc' + [char]10 + '--incognito')
        )) {
            Get-TestExceptionMessage {
                Get-ZjuChromeLaunchArguments -PortalUrl $portalUrl -ProfileDirectory 'Default'
            } | Should -Match 'Refusing'
        }

        foreach ($profileName in @(
            ''
            'Profile --incognito'
            'Profile 4 --incognito'
            'Profile 0'
            'Profile -1'
            'Profile\1'
            'Profile/1'
            'Default 4'
            'Other'
            ('Profile' + [char]10 + '2')
        )) {
            Get-TestExceptionMessage {
                Get-ZjuChromeLaunchArguments -PortalUrl 'https://net.zju.edu.cn/srun_portal_pc' -ProfileDirectory $profileName
            } | Should -Match 'ProfileDirectory'
        }
    }

    It 'creates current-user NCSI XML with dynamic safely quoted runner and config paths' {
        $runner = Join-Path $TestDrive 'relocated & auth\Invoke-ZjuNetworkAuth.ps1'
        $configPath = Join-Path $TestDrive 'relocated & auth\custom config.json'
        $xmlText = Get-ZjuAuthTaskXml -TaskName 'ZJU Network Authentication' -UserSid 'S-1-5-21-100-200-300-1001' -RunnerPath $runner -ConfigPath $configPath
        [xml]$taskXml = $xmlText

        $xmlText | Should -Match 'Microsoft-Windows-NCSI/Operational'
        $xmlText | Should -Match 'EventID=4038'
        $xmlText | Should -Match 'InteractiveToken'
        $xmlText | Should -Match 'IgnoreNew'
        $taskXml.Task.Actions.Exec.Arguments | Should -Match '-WindowStyle Hidden'
        $taskXml.Task.Actions.Exec.Arguments | Should -Match ([regex]::Escape($runner))
        $taskXml.Task.Actions.Exec.Arguments | Should -Match ('-ConfigPath "' + [regex]::Escape($configPath) + '"')
        $taskXml.Task.Actions.Exec.WorkingDirectory | Should -Be (Split-Path -Parent $runner)

        $withoutConfig = Get-ZjuAuthTaskXml -TaskName 'ZJU Network Authentication' -UserSid 'S-1-5-21-100-200-300-1001' -RunnerPath $runner
        ([xml]$withoutConfig).Task.Actions.Exec.Arguments | Should -Not -Match '-ConfigPath'
    }

    It 'rejects a relative runner path for scheduled task XML' {
        Get-TestExceptionMessage {
            Get-ZjuAuthTaskXml -TaskName 'ZJU Network Authentication' -UserSid 'S-1-5-21-100-200-300-1001' -RunnerPath 'scripts\Invoke-ZjuNetworkAuth.ps1'
        } | Should -Match 'RunnerPath must be an absolute path'
    }

    It 'rejects a relative config path for scheduled task XML' {
        Get-TestExceptionMessage {
            Get-ZjuAuthTaskXml -TaskName 'ZJU Network Authentication' -UserSid 'S-1-5-21-100-200-300-1001' -RunnerPath 'C:\Zju\Invoke-ZjuNetworkAuth.ps1' -ConfigPath 'config.json'
        } | Should -Match 'ConfigPath must be an absolute path'
    }
}

Describe 'Chrome extension manifest and content-script safety' {
    It 'is Manifest V3 with no permissions and only the HTTPS ZJU host match' {
        Test-Path -LiteralPath $manifestPath | Should -Be $true
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $matches = @($manifest.content_scripts[0].matches)

        $manifest.manifest_version | Should -Be 3
        ($manifest.PSObject.Properties.Name -contains 'permissions') | Should -Be $false
        $matches.Count | Should -Be 1
        ($matches -contains 'https://net.zju.edu.cn/*') | Should -Be $true
        ($matches -contains 'http://net.zju.edu.cn/*') | Should -Be $false
    }

    It 'uses a per-tab guard and polls only the approved portal path for 30 seconds' {
        Test-Path -LiteralPath $contentScriptPath | Should -Be $true
        $script = Get-Content -LiteralPath $contentScriptPath -Raw

        $script | Should -Match "startsWith\('/srun_portal_'\)"
        $script | Should -Match "=== '/srun_portal_success'"
        $script | Should -Match 'window\.sessionStorage\.getItem\(attemptKey\)'
        $script | Should -Match 'window\.sessionStorage\.setItem\(attemptKey'
        $script | Should -Match 'const pollIntervalMilliseconds = 500;'
        $script | Should -Match 'const timeoutMilliseconds = 30000;'
    }

    It 'checks deadline and current path before its sole query, then clears the timer before one click' {
        $script = Get-Content -LiteralPath $contentScriptPath -Raw
        $pollIndex = $script.IndexOf('window.setInterval')
        $deadlineIndex = $script.IndexOf('Date.now() - startedAt >= timeoutMilliseconds')
        $currentPathIndex = $script.IndexOf('const currentPath = window.location.pathname')
        $queryIndex = $script.IndexOf("document.querySelector('#login-account')")
        $initialProtocolIndex = $script.IndexOf("window.location.protocol === 'https:'")
        $pollProtocolIndex = $script.IndexOf("window.location.protocol === 'https:'", $initialProtocolIndex + 1)
        $initialPortIndex = $script.IndexOf("window.location.port === ''")
        $pollPortIndex = $script.IndexOf("window.location.port === ''", $initialPortIndex + 1)
        $clearIndex = $script.IndexOf('window.clearInterval(intervalId);', $queryIndex)
        $clickIndex = $script.IndexOf('loginButton.click();')

        ([regex]::Matches($script, 'document\.querySelector').Count) | Should -Be 1
        ([regex]::Matches($script, 'loginButton\.click\(\)').Count) | Should -Be 1
        ([regex]::Matches($script, "window\.location\.port === ''").Count) | Should -Be 2
        ($initialProtocolIndex -ge 0 -and $initialProtocolIndex -lt $pollIndex) | Should -Be $true
        ($pollProtocolIndex -gt $pollIndex -and $pollProtocolIndex -lt $queryIndex) | Should -Be $true
        ($initialPortIndex -ge 0 -and $initialPortIndex -lt $pollIndex) | Should -Be $true
        ($pollPortIndex -gt $pollIndex -and $pollPortIndex -lt $queryIndex) | Should -Be $true
        ($deadlineIndex -ge 0 -and $deadlineIndex -lt $queryIndex) | Should -Be $true
        ($currentPathIndex -ge 0 -and $currentPathIndex -lt $queryIndex) | Should -Be $true
        ($clearIndex -ge 0 -and $clearIndex -lt $clickIndex) | Should -Be $true
    }

    It 'does not access credentials, cookies, logout controls, or network APIs' {
        $script = Get-Content -LiteralPath $contentScriptPath -Raw

        $script | Should -Not -Match 'password|username|credential|document\.cookie|logout|fetch\(|XMLHttpRequest'
    }
}

Describe 'Example configuration' {
    It 'uses HTTPS and documents the default Chrome profile' {
        $example = Get-Content -LiteralPath $exampleConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $example.PortalUrl | Should -Be 'https://net.zju.edu.cn'
        $example.CooldownSeconds | Should -Be 300
        $example.ChromeExecutable | Should -Be ''
        $example.ChromeProfile | Should -Be 'Default'
    }
}

Describe 'Invoke-ZjuNetworkAuth dry-run paths' {
    It 'imports the adjacent module and contains no credential handling' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw

        $runner | Should -Match 'Join-Path \$PSScriptRoot ''ZjuNetworkAuth\.psm1'''
        $runner | Should -Match 'Get-ZjuAuthConfiguration'
        $runner | Should -Match 'Get-ZjuAuthMetaRefreshTarget'
        $runner | Should -Not -Match 'password|username|credential|document\.cookie|agent-browser|--cdp|Edge'
    }

    It 'would authenticate only for the approved captive portal without probing or launching' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'RunnerProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'RunnerProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'config.json'
            @{ ChromeExecutable = $chromePath } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
            Mock -CommandName Invoke-WebRequest -MockWith {
                throw 'dry-run attempted a network request'
            }

            & $runnerPath -ConfigPath $configPath -CurrentUrl 'https://net.zju.edu.cn/srun_portal_pc?ac_id=80' -DryRun | Should -Be 'WouldAuthenticate'
            Should -Invoke -CommandName Invoke-WebRequest -Times 0 -Exactly
            $logPath = Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin\logs\activity.log'
            Test-Path -LiteralPath $logPath | Should -Be $true
            (Get-Content -LiteralPath $logPath -Raw -Encoding UTF8) | Should -Match '^\d{4}-\d{2}-\d{2}T.*Z\s+WouldAuthenticate'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'returns AlreadyOnline and Cooldown without launching Chrome' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'RunnerProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'RunnerProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'config.json'
            @{ ChromeExecutable = $chromePath } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

            & $runnerPath -ConfigPath $configPath -CurrentUrl 'https://net.zju.edu.cn/srun_portal_success/details' -DryRun | Should -Be 'AlreadyOnline'

            Set-ZjuAuthLastAttempt -StatePath (Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin\state.json') -AttemptedAt (Get-Date)
            & $runnerPath -ConfigPath $configPath -CurrentUrl 'https://net.zju.edu.cn/srun_portal_pc?ac_id=80' -DryRun | Should -Be 'Cooldown'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'uses a 15-second request timeout, propagates the profile, and logs authentication' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'RunnerProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'RunnerProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'NetworkProbeLocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'config.json'
            @{
                ChromeExecutable = $chromePath
                ChromeProfile = 'Profile 4'
            } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
            Mock -CommandName Invoke-WebRequest -MockWith {
                [pscustomobject]@{
                    Content = '<meta http-equiv="refresh" content="0;url=/srun_portal_pc?ac_id=80">'
                    BaseResponse = [pscustomobject]@{
                        ResponseUri = [uri]'https://net.zju.edu.cn/'
                    }
                }
            }
            Mock -CommandName Start-Process -MockWith {}

            & $runnerPath -ConfigPath $configPath | Should -Be 'Authenticate'

            Should -Invoke -CommandName Invoke-WebRequest -Times 1 -ParameterFilter {
                $TimeoutSec -eq 15 -and $MaximumRedirection -eq 0
            }
            Should -Invoke -CommandName Start-Process -Times 1 -ParameterFilter {
                $FilePath -eq $chromePath -and
                @($ArgumentList).Count -eq 3 -and
                $ArgumentList[0] -eq '--profile-directory="Profile 4"' -and
                $ArgumentList[1] -eq '--new-window' -and
                $ArgumentList[2] -eq 'https://net.zju.edu.cn/srun_portal_pc?ac_id=80'
            }
            $logPath = Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin\logs\activity.log'
            (Get-Content -LiteralPath $logPath -Raw -Encoding UTF8) | Should -Match '^\d{4}-\d{2}-\d{2}T.*Z\s+Authenticate'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'logs request errors and never launches Chrome on failure' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'RunnerProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'RunnerProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'config.json'
            @{ ChromeExecutable = $chromePath } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
            Mock -CommandName Invoke-WebRequest -MockWith {
                throw 'simulated request failure'
            }
            Mock -CommandName Start-Process -MockWith {}

            Get-TestExceptionMessage {
                & $runnerPath -ConfigPath $configPath
            } | Should -Match 'simulated request failure'

            Should -Invoke -CommandName Invoke-WebRequest -Times 1 -ParameterFilter {
                $TimeoutSec -eq 15 -and $MaximumRedirection -eq 0
            }
            Should -Invoke -CommandName Start-Process -Times 0 -Exactly -Scope It
            $logPath = Join-Path $env:LOCALAPPDATA 'ZjuNetworkAutoLogin\logs\activity.log'
            Test-Path -LiteralPath $logPath | Should -Be $true
            (Get-Content -LiteralPath $logPath -Raw -Encoding UTF8) | Should -Match 'Error: simulated request failure'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'throws for an unexpected destination even in dry-run mode' {
        $oldProgramFiles = $env:ProgramFiles
        $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'RunnerProgramFiles'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'RunnerProgramFilesX86'
            $env:LOCALAPPDATA = Join-Path $TestDrive 'LocalAppData'
            $chromePath = New-TestChromeExecutable -Root $env:LOCALAPPDATA
            $configPath = Join-Path $TestDrive 'config.json'
            @{ ChromeExecutable = $chromePath } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

            Get-TestExceptionMessage {
                & $runnerPath -ConfigPath $configPath -CurrentUrl 'https://example.com/' -DryRun
            } | Should -Match 'Refusing to automate'
        }
        finally {
            $env:ProgramFiles = $oldProgramFiles
            ${env:ProgramFiles(x86)} = $oldProgramFilesX86
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }
}
