#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for the Reference Report builder's edition surface: the preset parameter, the
    department floor, and the always-generated dataset of an online build.

.DESCRIPTION
    Runs the real scripts/Build-ReferenceReport.ps1 in a child pwsh whose PATH leads with stub
    quarto and Rscript scripts that record their arguments and answer success, so every assertion
    reads what the builder handed its children and what it decided between the steps. No DHIS2
    instance is reached: the online builds carry a syntactically valid synthetic token the stubs
    never send anywhere.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReferenceReportBuilder.Tests.ps1
#>

BeforeAll {
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' '..' '..'
    $script:BuilderPath = (Resolve-Path (Join-Path $ScriptsDir 'Build-ReferenceReport.ps1')).Path
    $script:PwshPath = (Get-Command pwsh).Source
    # Shape-valid version-2 personal access token, per Test-DHIS2PersonalAccessToken; the checksum
    # is DHIS2's to verify and nothing is ever sent, so this synthetic value names no credential.
    $script:SyntheticToken = 'd2p_' + ('a' * 44) + 'ABC123'
    # The floor gate decodes the dataset in R, so the stub Rscript must forward those calls
    # to the real one; the path is resolved here, before any run leads PATH with the stubs.
    $script:RealRscript = (Get-Command -Name Rscript -ErrorAction SilentlyContinue).Source

    # A child pwsh whose PATH leads with the stubs, run with -File; returns the child's exit code,
    # stdout, and stderr. The fake-* environment variables tell the stubs where to log and what to
    # answer with. The caller's PATH is restored in finally, as in-process environment assignments
    # persist.
    $script:InvokeBuilder = {
        param($StubsDir, $QuartoLog, $RscriptLog, $DatasetForRscript, $Arguments)
        $savedPath = $env:PATH
        $savedQuartoLog = ${env:NEOIPC_FAKE_QUARTO_LOG}
        $savedRscriptLog = ${env:NEOIPC_FAKE_RSCRIPT_LOG}
        $savedDataset = ${env:NEOIPC_FAKE_RSCRIPT_DATASET}
        $savedRealRscript = ${env:NEOIPC_FAKE_RSCRIPT_REAL}
        try {
            $env:PATH = "$StubsDir$([System.IO.Path]::PathSeparator)$savedPath"
            ${env:NEOIPC_FAKE_QUARTO_LOG} = $QuartoLog
            ${env:NEOIPC_FAKE_RSCRIPT_LOG} = $RscriptLog
            ${env:NEOIPC_FAKE_RSCRIPT_REAL} = $RealRscript
            if ($DatasetForRscript) { ${env:NEOIPC_FAKE_RSCRIPT_DATASET} = $DatasetForRscript }
            else { [Environment]::SetEnvironmentVariable('NEOIPC_FAKE_RSCRIPT_DATASET', [NullString]::Value, 'Process') }
            $stdout = & $PwshPath -NoProfile -NonInteractive -File $BuilderPath @Arguments 2>&1
            [pscustomobject]@{
                Exit  = $LASTEXITCODE
                Lines = @($stdout | ForEach-Object { "$_" })
            }
        }
        finally {
            $env:PATH = $savedPath
            $restore = @{ NEOIPC_FAKE_QUARTO_LOG = $savedQuartoLog; NEOIPC_FAKE_RSCRIPT_LOG = $savedRscriptLog; NEOIPC_FAKE_RSCRIPT_DATASET = $savedDataset; NEOIPC_FAKE_RSCRIPT_REAL = $savedRealRscript }
            foreach ($name in $restore.Keys) {
                if ($null -eq $restore[$name]) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process') }
                else { [Environment]::SetEnvironmentVariable($name, $restore[$name], 'Process') }
            }
        }
    }

    $script:ReadBuildReport = {
        param($OutputDir)
        $file = Get-ChildItem -LiteralPath $OutputDir -Filter '*_NeoIPC-Surveillance-Reference-Report-Build.json' |
            Select-Object -First 1
        if (-not $file) { return $null }
        (Get-Content -LiteralPath $file.FullName -Raw) | ConvertFrom-Json
    }

    # The -P argument pairs a stubbed quarto recorded, as 'key:value' strings.
    $script:QuartoParams = {
        param($QuartoLog)
        if (-not (Test-Path -LiteralPath $QuartoLog)) { return @() }
        $lines = Get-Content -LiteralPath $QuartoLog
        for ($i = 0; $i -lt $lines.Count - 1; $i++) {
            if ($lines[$i] -eq '-P') { $lines[$i + 1] }
        }
    }
}

# Decided during discovery, so that it can gate -Skip: every build below runs the floor
# gate, which decodes its dataset in R.
$script:RscriptAvailable = [bool](Get-Command -Name Rscript -ErrorAction SilentlyContinue)

Describe 'The builder edition surface: parameter surface' {
    It 'has a Preset parameter whose tab-completion lists the presets.json names' {
        $command = Get-Command -Name $BuilderPath
        $command.Parameters.Keys | Should -Contain 'Preset'
        $completer = @($command.Parameters['Preset'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] })
        $completer.Count | Should -Be 1
        # Completers arrive as an AutocompleteInfo wrapping the script block; call the block as
        # tab-completion would and read the preset names it offers.
        $scriptBlock = $completer[0].ScriptBlock
        $names = @(& $scriptBlock 'Build-ReferenceReport.ps1' 'Preset' '' $null @{})
        $names | Should -Contain 'class-range-edition'
    }
}

Describe 'The builder edition surface: render decisions' -Skip:(-not $script:RscriptAvailable) {
    BeforeAll {
        $script:StubsDir = Join-Path $TestDrive 'stubs'
        New-Item -ItemType Directory -Path $StubsDir | Out-Null
        @'
#!/usr/bin/env pwsh
#Requires -Version 7.6
Add-Content -LiteralPath ${env:NEOIPC_FAKE_QUARTO_LOG} -Value $args
exit 0
'@ | Set-Content -LiteralPath (Join-Path $StubsDir 'quarto.ps1') -Encoding utf8NoBOM
        @'
#!/usr/bin/env pwsh
#Requires -Version 7.6
Add-Content -LiteralPath ${env:NEOIPC_FAKE_RSCRIPT_LOG} -Value $args
# Only the generation call is stubbed: an expression call is the floor gate decoding a
# dataset in R, which only the real Rscript can answer.
if ($args -ccontains '-e') {
    & $env:NEOIPC_FAKE_RSCRIPT_REAL @args
    exit $LASTEXITCODE
}
$fileIndex = [Array]::IndexOf($args, '--file')
if ($fileIndex -ge 0 -and $fileIndex + 1 -lt $args.Count) {
    Copy-Item -LiteralPath ${env:NEOIPC_FAKE_RSCRIPT_DATASET} -Destination $args[$fileIndex + 1] -Force
}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $StubsDir 'Rscript.ps1') -Encoding utf8NoBOM

        $script:QuartoLog = Join-Path $TestDrive 'quarto-args.txt'
        $script:RscriptLog = Join-Path $TestDrive 'rscript-args.txt'

        # The datasets are what Generate-ReferenceData.R's writer really produces, made here
        # by the same R that reads them: the serialized shape belongs to the installed
        # jsonlite and has shifted across package versions, so a hand-written fixture can
        # pin a shape no writer writes.
        $gen = Join-Path $TestDrive 'make-datasets.R'
        @'
args <- commandArgs(trailingOnly = TRUE)
writeLines(jsonlite::serializeJSON(structure(list(n_departments = 5L),
             class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))), args[[1]])
writeLines(jsonlite::serializeJSON(structure(list(n_departments = 4L),
             class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))), args[[2]])
'@ | Set-Content -LiteralPath $gen -Encoding utf8NoBOM
        $script:Dataset5 = Join-Path $TestDrive 'dataset-5.json'
        $script:Dataset4 = Join-Path $TestDrive 'dataset-4.json'
        & Rscript --vanilla $gen $Dataset5 $Dataset4
        if ($LASTEXITCODE -ne 0) {
            throw "The R fixture writer failed with exit code $LASTEXITCODE."
        }
    }

    Context 'DataFile mode renders with the preset applied' {
        BeforeAll {
            $script:Out = Join-Path $TestDrive 'out-preset'
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $null @(
                '-DataFile', $Dataset5, '-OutputDir', $Out, '-Preset', 'minimal'
            )
        }

        It 'hands the preset parameters to the render' {
            $params = & $QuartoParams $QuartoLog
            $params | Should -Contain 'includeMethodsTexts:False'
            $params | Should -Contain 'includeConfidenceIntervals:none'
        }

        It 'still renders' {
            $Result.Exit | Should -Be 0
        }
    }

    Context 'DataFile mode keeps an explicit parameter over the preset' {
        BeforeAll {
            Remove-Item -LiteralPath $QuartoLog -ErrorAction SilentlyContinue
            $script:Out = Join-Path $TestDrive 'out-explicit'
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $null @(
                '-DataFile', $Dataset5, '-OutputDir', $Out, '-Preset', 'minimal', '-ConfidenceIntervals', 'pooled'
            )
        }

        It 'lets the command line win and does not pass the preset value as well' {
            $params = & $QuartoParams $QuartoLog
            @($params | Where-Object { $_ -like 'includeConfidenceIntervals:*' }) | Should -BeExactly 'includeConfidenceIntervals:pooled'
        }

        It 'still applies the preset parameters nobody overrode' {
            $params = & $QuartoParams $QuartoLog
            $params | Should -Contain 'includeMethodsTexts:False'
        }
    }

    Context 'DataFile mode lifts a preset false with the switch given false outright' {
        BeforeAll {
            Remove-Item -LiteralPath $QuartoLog -ErrorAction SilentlyContinue
            $script:Out = Join-Path $TestDrive 'out-explicitfalse'
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $null @(
                '-DataFile', $Dataset5, '-OutputDir', $Out, '-Preset', 'minimal', '-HideIntroductionTexts:$false'
            )
        }

        It 'renders the introduction texts the preset turned off' {
            $Result.Exit | Should -Be 0
            $params = & $QuartoParams $QuartoLog
            @($params | Where-Object { $_ -like 'includeIntroductionTexts:*' }) | Should -BeExactly 'includeIntroductionTexts:true'
        }
    }

    It 'refuses a name the presets file lacks, without rendering' {
        Remove-Item -LiteralPath $QuartoLog -ErrorAction SilentlyContinue
        $Out = Join-Path $TestDrive 'out-badname'
        $result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $null @(
            '-DataFile', $Dataset5, '-OutputDir', $Out, '-Preset', 'no-such-preset'
        )
        $result.Exit | Should -Not -Be 0
        # Match the reader's own message: on a builder without -Preset the child fails the
        # same way on parameter binding, so only the refusal text ties this to the feature.
        @($result.Lines | Where-Object { $_ -match 'No preset named' }) | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $QuartoLog | Should -BeFalse -Because 'a preset the file does not know must stop the build before any render'
    }

    Context 'The floor of five contributing departments stops an edition' {
        BeforeAll {
            Remove-Item -LiteralPath $QuartoLog -ErrorAction SilentlyContinue
            $script:Out = Join-Path $TestDrive 'out-floor'
            # A dataset one department below the floor, and one of exactly five below: the
            # pair pins the floor at five, where 2 and 5 would also pass a floor of four.
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $null @(
                '-DataFile', $Dataset4, '-OutputDir', $Out, '-JsonReport'
            )
        }

        It 'ends the build with the builder''s cancellation exit code' {
            $Result.Exit | Should -Be 1
        }

        It 'warns about the department count' {
            # Match the message body, not the prefix: Write-Warning localizes the word
            # 'WARNING' to the host's language.
            @($Result.Lines | Where-Object { $_ -match 'departments contribute' }) | Should -Not -BeNullOrEmpty
        }

        It 'renders nothing' {
            Test-Path -LiteralPath $QuartoLog | Should -BeFalse
        }

        It 'reports the build as cancelled, with no outputs' {
            $report = & $ReadBuildReport $Out
            $report | Should -Not -BeNullOrEmpty
            $report.status | Should -BeExactly 'cancelled'
            @($report.outputFilePaths).Count | Should -Be 0
        }
    }

    Context 'A dataset of five departments passes the floor' {
        BeforeAll {
            Remove-Item -LiteralPath $QuartoLog -ErrorAction SilentlyContinue
            $script:Out = Join-Path $TestDrive 'out-floor-pass'
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $null @(
                '-DataFile', $Dataset5, '-OutputDir', $Out, '-JsonReport'
            )
        }

        It 'renders and succeeds' {
            $Result.Exit | Should -Be 0
            Test-Path -LiteralPath $QuartoLog | Should -BeTrue
            (& $ReadBuildReport $Out).status | Should -BeExactly 'success'
        }
    }

    Context 'An online build generates its dataset first and gates on it' {
        BeforeAll {
            Remove-Item -LiteralPath $QuartoLog, $RscriptLog -ErrorAction SilentlyContinue
            $script:Out = Join-Path $TestDrive 'out-online'
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $Dataset5 @(
                '-Token', $SyntheticToken, '-OutputDir', $Out, '-JsonReport',
                '-ReportingPeriodFrom', '2024-01-01', '-ReportingPeriodTo', '2026-10-31'
            )
        }

        It 'acquires the dataset through R before rendering' {
            Test-Path -LiteralPath $RscriptLog | Should -BeTrue
        }

        It 'renders from the generated dataset' {
            $params = & $QuartoParams $QuartoLog
            @($params | Where-Object { $_ -like 'referenceDataFile:*' }).Count | Should -Be 1 -Because 'an online build gates the floor on its dataset, so the render reads the dataset the build generated'
        }

        It 'marks the generated dataset as intermediate when the caller asked for no json output' {
            $report = & $ReadBuildReport $Out
            $report.status | Should -BeExactly 'success'
            $report.generatedDataFile.intermediate | Should -BeTrue
        }

        It 'removes the intermediate dataset once the build completed' {
            $report = & $ReadBuildReport $Out
            Test-Path -LiteralPath $report.generatedDataFile.filePath | Should -BeFalse
        }
    }

    Context 'An online build of fewer than five departments stops before rendering' {
        BeforeAll {
            Remove-Item -LiteralPath $QuartoLog, $RscriptLog -ErrorAction SilentlyContinue
            $script:Out = Join-Path $TestDrive 'out-online-floor'
            $script:Result = & $InvokeBuilder $StubsDir $QuartoLog $RscriptLog $Dataset4 @(
                '-Token', $SyntheticToken, '-OutputDir', $Out, '-JsonReport',
                '-ReportingPeriodFrom', '2024-01-01', '-ReportingPeriodTo', '2026-10-31'
            )
        }

        It 'never reaches the render' {
            Test-Path -LiteralPath $QuartoLog | Should -BeFalse
            $Result.Exit | Should -Be 1
        }

        It 'reports the build as cancelled' {
            (& $ReadBuildReport $Out).status | Should -BeExactly 'cancelled'
        }

        It 'keeps the acquired dataset the cancelled build report names' {
            $report = & $ReadBuildReport $Out
            $report.generatedDataFile.filePath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $report.generatedDataFile.filePath | Should -BeTrue -Because 'the report names this path as what the build acquired, and the operator needs the dataset behind a below-floor count'
        }
    }
}
