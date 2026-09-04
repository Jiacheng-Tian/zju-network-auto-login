BeforeAll {
    $installScriptPath = Join-Path $PSScriptRoot '..\scripts\Install.ps1'
    $uninstallScriptPath = Join-Path $PSScriptRoot '..\scripts\Uninstall.ps1'
}
Describe 'Installation scripts' {
    It 'registers the current-user task from the repository and reports the extension directory' {
        Test-Path -LiteralPath $installScriptPath | Should -Be $true
        $script = Get-Content -LiteralPath $installScriptPath -Raw -Encoding UTF8

        $script | Should -Match 'Get-ZjuAuthTaskXml'
        $script | Should -Match 'WindowsIdentity]::GetCurrent\(\)\.User\.Value'
        $script | Should -Match 'chrome-extension'
        $script | Should -Match 'schtasks\.exe'
        $script | Should -Not -Match 'Copy-Item'
    }

    It 'only removes the scheduled task and retains local user data by default' {
        Test-Path -LiteralPath $uninstallScriptPath | Should -Be $true
        $script = Get-Content -LiteralPath $uninstallScriptPath -Raw -Encoding UTF8

        $script | Should -Match 'schtasks\.exe'
        $script | Should -Match '/Delete'
        $script | Should -Not -Match 'Remove-Item'
        $script | Should -Not -Match 'PurgeData'
    }

    It 'defines an explicit release file allowlist' {
        $packageScriptPath = Join-Path $PSScriptRoot '..\tools\New-ReleasePackage.ps1'
        $script = Get-Content -LiteralPath $packageScriptPath -Raw -Encoding UTF8

        $script | Should -Match "'scripts\\Install\.ps1'"
        $script | Should -Match "'scripts\\Invoke-ZjuNetworkAuth\.ps1'"
        $script | Should -Match "'scripts\\Uninstall\.ps1'"
        $script | Should -Match "'scripts\\ZjuNetworkAuth\.psm1'"
        $script | Should -Match "'chrome-extension\\content\.js'"
        $script | Should -Match "'chrome-extension\\manifest\.json'"
        $script | Should -Match 'actualEntries[\s\S]*expectedEntries'
    }
}
