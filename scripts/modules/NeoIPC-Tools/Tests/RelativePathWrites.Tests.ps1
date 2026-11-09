#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for file writes given a path relative to PowerShell's current location or outside the file
    system, and for the failures a localization writer must not report as success.

.DESCRIPTION
    The file APIs of .NET resolve a relative path against the process's working directory, which a
    Set-Location does not change, while every PowerShell cmdlet resolves it against the current location.
    A script that reads a file with Get-Content and writes it back with [System.IO.File]::WriteAllText
    therefore reads one file and writes another, or fails to write, whenever the two differ, which is the
    case in any session that changed directory after it started. Each test here sets the process's working
    directory away from the current location, so each test that runs its writer in the Pester process goes
    red for a writer that resolves the path through .NET. A path on a drive of a provider other than the file
    system, such as Variable:, has a provider path that .NET would take for one relative to the process's
    working directory, so the module's write point refuses it, under the caller's SilentlyContinue too, and
    refuses a path on a drive that does not exist with the reason.

    A failed write, a malformed YAML master, and a master that cannot be found each have to stop
    Update-Po4aYamlKeys.ps1 with a non-zero exit code and no success line, leaving the config as it was.
    Those tests run the script in a child process: in the same process, a statement-terminating error
    reaches Pester's own try/catch whether or not the script stops on it, so only the exit code tells
    the two apart. A child started with -File runs the script at its global scope, where the script's
    own $ErrorActionPreference reaches the modules it calls. The malformed master is therefore run a
    second way, with & in a child started with -Command, as a prompt or Invoke-Localization.ps1 runs the
    script: there a module sees only the global preference, and only the script's -ErrorAction on the
    YAML parser stops it.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/RelativePathWrites.Tests.ps1
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..') -Force
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:keysScript = Join-Path $script:repoRoot 'scripts' 'Update-Po4aYamlKeys.ps1'

    # Runs Update-Po4aYamlKeys.ps1 in a child process in the current location and returns its exit code
    # and output lines. The child runs the script as its -File, or with -InProcess calls it with & from
    # -Command, below the global scope.
    function Invoke-KeysScript {
        param([switch]$InProcess)
        $output = if ($InProcess) {
            $command = "& '$($script:keysScript.Replace("'", "''"))' -ConfigFile 'test.po4a.cfg'"
            & pwsh -NoProfile -NonInteractive -Command $command 2>&1
        }
        else {
            & pwsh -NoProfile -NonInteractive -File $script:keysScript -ConfigFile 'test.po4a.cfg' 2>&1
        }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
    }
}

Describe 'Writes given a path relative to the current location or outside the file system' {

    BeforeEach {
        $script:processDirectory = [System.Environment]::CurrentDirectory
        # TestDrive is shared by every test of this block, so each test gets directories of its own.
        $script:testRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        $script:elsewhere = Join-Path $script:testRoot 'elsewhere'
        $script:here = Join-Path $script:testRoot 'here'
        New-Item -ItemType Directory -Path $script:elsewhere, $script:here | Out-Null
        [System.Environment]::CurrentDirectory = $script:elsewhere
        Push-Location -LiteralPath $script:here
        $script:config = Join-Path $script:here 'test.po4a.cfg'
    }

    AfterEach {
        Pop-Location
        [System.Environment]::CurrentDirectory = $script:processDirectory
    }

    It 'Write-NeoIPCTextFile writes to the current location' {
        InModuleScope 'NeoIPC-Tools' { Write-NeoIPCTextFile -Path 'out.txt' -Text "a`r`nb" }

        Join-Path $script:here 'out.txt' | Should -Exist
        Join-Path $script:elsewhere 'out.txt' | Should -Not -Exist
        [System.IO.File]::ReadAllText((Join-Path $script:here 'out.txt')) | Should -BeExactly "a`nb"
    }

    It 'Write-NeoIPCTextFile refuses a path on a drive of a provider other than the file system, writing nothing' {
        # The provider path of a variable is no file-system path, which .NET would write relative to the process's
        # working directory.
        { InModuleScope 'NeoIPC-Tools' { Write-NeoIPCTextFile -Path 'Variable:\NeoIPCTestTarget' -Text 'a' } } |
            Should -Throw -ExpectedMessage "The path 'Variable:\NeoIPCTestTarget' is on a drive of the Variable provider, not in the file system*"

        Join-Path $script:elsewhere 'NeoIPCTestTarget' | Should -Not -Exist
        Join-Path $script:here 'NeoIPCTestTarget' | Should -Not -Exist
    }

    It 'Write-NeoIPCTextFile writes nothing for a path on a drive of another provider under the caller''s SilentlyContinue' {
        # In a process of its own, whose global preference the module's functions see: inside Pester's own try, the
        # refusal ends the call whatever the function does. The child starts in the current location, where a dropped
        # refusal would have written the variable's name; its last line shows that it reached the call.
        $caller = Join-Path $script:testRoot 'silently.ps1'
        $callerText = "param(`$Module)`n`$global:ErrorActionPreference = 'SilentlyContinue'`nImport-Module `$Module`n& (Get-Module NeoIPC-Tools) { Write-NeoIPCTextFile -Path 'Variable:\NeoIPCTestTarget' -Text 'a' }`n'reached'`n"
        [System.IO.File]::WriteAllText($caller, $callerText, [System.Text.UTF8Encoding]::new($false))
        $module = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
        $said = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $caller -Module $module 2>&1 | ForEach-Object { "$_" })

        $said | Should -Contain 'reached'
        Join-Path $script:here 'NeoIPCTestTarget' | Should -Not -Exist
        Join-Path $script:elsewhere 'NeoIPCTestTarget' | Should -Not -Exist
    }

    It 'Write-NeoIPCTextFile refuses a path on a drive that does not exist, without the wrapper PowerShell puts around the reason' {
        $thrown = { InModuleScope 'NeoIPC-Tools' { Write-NeoIPCTextFile -Path 'NeoIPCNoSuchDrive:\out.txt' -Text 'a' } } |
            Should -Throw -ExpectedMessage "The path 'NeoIPCNoSuchDrive:\out.txt' cannot be resolved: *" -PassThru
        $thrown.Exception.Message | Should -Not -BeLike '*GetUnresolvedProviderPathFromPSPath*'
    }

    It 'Update-Po4aYamlKeys.ps1 rewrites the config it read' {
        [System.IO.File]::WriteAllText((Join-Path $script:here 'strings.yaml'), "outer:`n  inner: Text`n")
        [System.IO.File]::WriteAllText($script:config, "[type: yaml] strings.yaml`n")

        & $script:keysScript -ConfigFile 'test.po4a.cfg' 6>$null

        [System.IO.File]::ReadAllText($script:config) |
            Should -BeExactly "[type: yaml] strings.yaml opt:`"-o keys='inner outer'`"`n"
        Join-Path $script:elsewhere 'test.po4a.cfg' | Should -Not -Exist
    }

    It 'Build-LocaleReportSources.ps1 reads the reports under a relative toolkit root' {
        Push-Location -LiteralPath (Join-Path $script:repoRoot 'reports')
        try {
            $output = & (Join-Path $script:repoRoot 'scripts' 'Build-LocaleReportSources.ps1') -Check -ToolkitRoot '..' 6>&1
        }
        finally {
            Pop-Location
        }
        ($output | ForEach-Object { "$_" }) | Should -Contain 'All locale wrappers are up to date.'
    }

    It 'Update-Po4aYamlKeys.ps1 fails when it cannot write the config' {
        if ($IsLinux -and [System.Environment]::UserName -eq 'root') {
            Set-ItResult -Skipped -Because 'root writes to a read-only file'
            return
        }
        [System.IO.File]::WriteAllText((Join-Path $script:here 'strings.yaml'), "key: Text`n")
        [System.IO.File]::WriteAllText($script:config, "[type: yaml] strings.yaml`n")
        Set-ItemProperty -LiteralPath $script:config -Name IsReadOnly -Value $true
        try {
            $result = Invoke-KeysScript
        }
        finally {
            Set-ItemProperty -LiteralPath $script:config -Name IsReadOnly -Value $false
        }

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Not -Contain 'Config updated successfully.'
        [System.IO.File]::ReadAllText($script:config) | Should -BeExactly "[type: yaml] strings.yaml`n"
    }

    It 'Update-Po4aYamlKeys.ps1 fails on a malformed YAML master, run <Case>' -ForEach @(
        @{ Case = 'as a child''s -File'; InProcess = $false }
        @{ Case = 'with & from a child''s -Command'; InProcess = $true }
    ) {
        [System.IO.File]::WriteAllText((Join-Path $script:here 'strings.yaml'), "key: [unclosed`n")
        [System.IO.File]::WriteAllText($script:config, "[type: yaml] strings.yaml`n")

        $result = Invoke-KeysScript -InProcess:$InProcess

        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Not -Contain 'Config updated successfully.'
        [System.IO.File]::ReadAllText($script:config) | Should -BeExactly "[type: yaml] strings.yaml`n"
    }

    It 'Update-Po4aYamlKeys.ps1 fails on a YAML master it cannot find, <Case>' -ForEach @(
        @{ Case = 'whose keys it collects'; Line = '[type: yaml] missing.yaml' }
        @{ Case = 'whose keys are curated'; Line = "[type: yaml] missing.yaml opt:`"-o keys='a b'`" # manual-keys" }
    ) {
        [System.IO.File]::WriteAllText($script:config, "$Line`n")

        $result = Invoke-KeysScript

        $result.ExitCode | Should -Not -Be 0
        ($result.Output -join "`n") | Should -Match "YAML master 'missing\.yaml' not found"
        $result.Output | Should -Not -Contain 'Config updated successfully.'
        [System.IO.File]::ReadAllText($script:config) | Should -BeExactly "$Line`n"
    }
}
