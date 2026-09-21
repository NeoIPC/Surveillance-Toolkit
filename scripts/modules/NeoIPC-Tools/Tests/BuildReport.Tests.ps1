#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for the centralized build-report machinery.

.DESCRIPTION
    Covers Public/BuildReport.ps1: Write-NeoIPCBuildReport, New-NeoIPCBuildStep,
    Complete-NeoIPCBuildStep and Get-NeoIPCParameterSnapshot — the shared step/timing/parameter record
    every Build-*.ps1 wrapper emits alongside its rendered artifact.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/BuildReport.Tests.ps1
#>

BeforeAll {
    Import-Module -Name (Join-Path $PSScriptRoot '..') -Force
    $script:StartedAt = '2026-07-01T00:00:00.0000000Z'
}

Describe 'Write-NeoIPCBuildReport' {
    It 'computes status: success when completed with no errors' {
        Write-NeoIPCBuildReport -Name 'X' -StartedAt $StartedAt -BuildCompleted $true 6>$null | Should -BeExactly 'success'
    }
    It 'computes status: failed when there are errors' {
        Write-NeoIPCBuildReport -Name 'X' -StartedAt $StartedAt -BuildCompleted $true -Errors @('boom') 6>$null | Should -BeExactly 'failed'
    }
    It 'computes status: cancelled when not completed and no errors' {
        Write-NeoIPCBuildReport -Name 'X' -StartedAt $StartedAt -BuildCompleted $false 6>$null | Should -BeExactly 'cancelled'
    }

    Context 'JSON shape' {
        BeforeAll {
            $reportFilePath = Join-Path $TestDrive 'report.json'
            Write-NeoIPCBuildReport -Name 'Partner Report Build' -StartedAt $StartedAt `
                -OutputFilePaths @('b.pdf', 'a.pdf', 'a.pdf') -BuildCompleted $true -BuildReportFilePath $reportFilePath `
                -ScriptTimestamp '2026-07-01_000000Z' -OutputDirPath 'out' `
                -SiteCodes @('NEO_AT_X') -OutputLocales @('de') -OutputFormats @('pdf') `
                -ParameterHash 'abc' -Parameters ([ordered]@{ k = 1 }) `
                -BuildSteps @((New-NeoIPCBuildStep -SiteCode 'NEO_AT_X')) `
                -ExtraFields ([ordered]@{ patientId = 'P1' }) 6>$null | Out-Null
            $script:report = (Get-Content -LiteralPath $reportFilePath -Raw) | ConvertFrom-Json
            $script:keys = @($report.PSObject.Properties.Name)
        }
        It 'writes the JSON file' { Test-Path -LiteralPath (Join-Path $TestDrive 'report.json') | Should -BeTrue }
        It 'emits keys in the fixed order: envelope, common fields, extras, errors last' {
            $keys | Should -Be @('name', 'status', 'startedAt', 'completedAt', 'outputFilePaths',
                'scriptTimestamp', 'outputDirPath',
                'siteCodes', 'outputLocales', 'outputFormats', 'parameterHash', 'parameters',
                'buildSteps', 'patientId', 'errors')
        }
        It 'renames outputs -> outputFilePaths and dedups + sorts them' {
            $report.outputFilePaths | Should -Be @('a.pdf', 'b.pdf')
        }
        It 'carries the ExtraFields one-off through' { $report.patientId | Should -BeExactly 'P1' }
    }

    It 'omits common first-class fields that were not supplied' {
        $reportFilePath = Join-Path $TestDrive 'minimal.json'
        Write-NeoIPCBuildReport -Name 'Cert' -StartedAt $StartedAt -BuildCompleted $true -BuildReportFilePath $reportFilePath 6>$null | Out-Null
        $names = @(((Get-Content -LiteralPath $reportFilePath -Raw) | ConvertFrom-Json).PSObject.Properties.Name)
        $names | Should -Not -Contain 'siteCodes'
        $names | Should -Not -Contain 'buildSteps'
        $names | Should -Be @('name', 'status', 'startedAt', 'completedAt', 'outputFilePaths', 'errors')
    }

    It 'always serialises outputLocales/outputFormats as arrays even for a single value' {
        $reportFilePath = Join-Path $TestDrive 'single.json'
        Write-NeoIPCBuildReport -Name 'Val' -StartedAt $StartedAt -BuildCompleted $true -BuildReportFilePath $reportFilePath `
            -OutputLocales @('de') -OutputFormats @('pdf') 6>$null | Out-Null
        $json = Get-Content -LiteralPath $reportFilePath -Raw
        $json | Should -Match '"outputLocales":\s*\['
        $json | Should -Match '"outputFormats":\s*\['
    }
}

Describe 'New-NeoIPCBuildStep' {
    It 'produces the canonical camelCase step schema' {
        $step = New-NeoIPCBuildStep -SiteCode 'S' -OutputLocale 'de' -OutputFormat 'pdf' -OutputFileName 'f.pdf' -QmdFilePath 'r.qmd' -QmdParams @{ a = 1 }
        @($step.Keys) | Should -Be @('siteCode', 'outputLocale', 'outputFormat', 'stepStartedAt', 'outputFileName', 'qmdFilePath', 'qmdParams', 'messages', 'status', 'exitCode')
        $step.status | Should -BeExactly 'planned'
        $step.exitCode | Should -BeNullOrEmpty
        $step.messages | Should -BeNullOrEmpty
    }
    It 'leaves omitted fields as $null (not empty string)' {
        $step = New-NeoIPCBuildStep -OutputFormat 'json'
        $step.outputLocale | Should -BeExactly $null
        $step.siteCode | Should -BeExactly $null
        $step.qmdParams | Should -BeOfType [hashtable]
    }
}

Describe 'Complete-NeoIPCBuildStep' {
    It 'maps a Success result onto the step' {
        $step = New-NeoIPCBuildStep -SiteCode 'S' | Complete-NeoIPCBuildStep -Result ([pscustomobject]@{ Status = 'Success'; ExitCode = 0; Messages = @('ok') })
        $step.status | Should -BeExactly 'success'
        $step.exitCode | Should -Be 0
        $step.messages | Should -Be @('ok')
    }
    It 'maps an Error result onto the step' {
        $step = New-NeoIPCBuildStep | Complete-NeoIPCBuildStep -Result ([pscustomobject]@{ Status = 'Error'; ExitCode = 1; Messages = @('boom') })
        $step.status | Should -BeExactly 'error'
        $step.exitCode | Should -Be 1
    }
    It 'accepts explicit -Status / -Messages (for -WhatIf planned steps)' {
        $step = New-NeoIPCBuildStep | Complete-NeoIPCBuildStep -Status 'planned' -Messages @('WhatIf: would render')
        $step.status | Should -BeExactly 'planned'
        $step.messages | Should -Be @('WhatIf: would render')
    }
}

Describe 'Get-NeoIPCParameterSnapshot' {
    It 'excludes sensitive keys, sorts, and returns a 64-char sha256 hex hash' {
        $snap = Get-NeoIPCParameterSnapshot -BoundParameters ([ordered]@{ Token = 'secret'; Password = 'p'; SiteCodeFilter = 'NEO_.*'; IncludeTestData = $true })
        $snap.source.Contains('Token') | Should -BeFalse
        $snap.source.Contains('Password') | Should -BeFalse
        @($snap.source.Keys) | Should -Be @('IncludeTestData', 'SiteCodeFilter')
        $snap.hash | Should -Match '^[0-9a-f]{64}$'
    }
    It 'is deterministic for the same inputs' {
        $a = Get-NeoIPCParameterSnapshot -BoundParameters ([ordered]@{ SiteCodeFilter = 'NEO_.*' })
        $b = Get-NeoIPCParameterSnapshot -BoundParameters ([ordered]@{ SiteCodeFilter = 'NEO_.*' })
        $a.hash | Should -BeExactly $b.hash
    }
}

Describe 'Get-NeoIPCRenderLogLevel' {
    BeforeAll {
        $script:esc = [char]27
    }

    It 'classifies <Expected> for <Description>' -ForEach @(
        # The reports' own logger layout is "{level} [{namespace}] {msg}".
        @{ Description = 'a logger WARN record'; Line = 'WARN [partner-report] sparse'; Expected = 'Warning' }
        @{ Description = 'a logger ERROR record'; Line = 'ERROR [neoipcr] boom'; Expected = 'Error' }
        # Quarto's own diagnostics.
        @{ Description = 'a Quarto WARNING'; Line = 'WARNING: unresolved link'; Expected = 'Warning' }
        # Pandoc brackets its verbosity; Quarto forwards that stderr verbatim.
        @{ Description = 'a bracketed Pandoc warning'; Line = '[WARNING] Could not fetch resource'; Expected = 'Warning' }
        @{ Description = 'a bracketed Pandoc error'; Line = '[ERROR] Could not convert'; Expected = 'Error' }
        # LaTeX announces an error with a leading bang.
        @{ Description = 'a LaTeX error'; Line = '! Undefined control sequence'; Expected = 'Error' }
        @{ Description = 'a German R error'; Line = 'Fehler in eval(x): nicht gefunden'; Expected = 'Error' }
        # Not levels at all.
        @{ Description = 'an INFO record'; Line = 'INFO [neoipcr] 42 rows'; Expected = $null }
        @{ Description = 'a word merely starting with WARN'; Line = 'WARNINGS_ENABLED=1'; Expected = $null }
        @{ Description = 'an indented continuation line'; Line = '  [WARNING] continued'; Expected = $null }
        # ^ must bind to every alternative: a sticky error flag means one mid-line
        # "Fehler" would otherwise stamp the whole render as failed.
        @{ Description = 'Fehler in the middle of a line'; Line = 'Es trat kein Fehler auf'; Expected = $null }
    ) {
        Get-NeoIPCRenderLogLevel -Line $Line | Should -BeExactly $Expected
    }

    # Quarto wraps the WHOLE of knitr's stderr in red — colors.red(output) in
    # refs/quarto-cli/src/execute/rmd.ts — optionally after a reset, so every
    # warning and error the R engine raises during a render arrives coloured.
    # A classifier admitting only some colours drops all of them silently.
    It 'sees through any run of ANSI colour sequences' {
        Get-NeoIPCRenderLogLevel -Line "$esc[31mWARN [partner-report] sparse" | Should -BeExactly 'Warning'
        Get-NeoIPCRenderLogLevel -Line "$esc[39m$esc[31mWARN [partner-report] sparse" | Should -BeExactly 'Warning'
        Get-NeoIPCRenderLogLevel -Line "$esc[39m$esc[31mFehler in eval(x)" | Should -BeExactly 'Error'
        Get-NeoIPCRenderLogLevel -Line "$esc[39m[WARNING] Could not fetch" | Should -BeExactly 'Warning'
        Get-NeoIPCRenderLogLevel -Line "$esc[33mWARNING: yellow still works" | Should -BeExactly 'Warning'
    }

    It 'returns nothing for an empty line' {
        Get-NeoIPCRenderLogLevel -Line '' | Should -BeExactly $null
    }
}

Describe 'Test-NeoIPCRenderWarningHead' {
    BeforeAll {
        $script:esc = [char]27
    }

    # A Quarto filter warning names its source file and line in parentheses;
    # its message may follow on the same line or, when it begins with a
    # newline as the stray-fence diagnostic does, on lines of its own.
    It 'is true for a filter warning head, with or without text on it' {
        Test-NeoIPCRenderWarningHead -Line 'WARNING (C:/Program Files/Quarto/share/filters/main.lua:10090) ' | Should -BeTrue
        Test-NeoIPCRenderWarningHead -Line "$esc[33mWARNING (main.lua:10090) " | Should -BeTrue
        Test-NeoIPCRenderWarningHead -Line 'WARNING (main.lua:10090)' | Should -BeTrue
        Test-NeoIPCRenderWarningHead -Line 'WARNING (main.lua:14840) Unable to resolve crossref @sec-solution-6' | Should -BeTrue
    }

    It 'is false for a warning that is not a filter warning' {
        Test-NeoIPCRenderWarningHead -Line 'WARNING: unresolved link' | Should -BeFalse
        Test-NeoIPCRenderWarningHead -Line '[WARNING] Could not fetch resource' | Should -BeFalse
        Test-NeoIPCRenderWarningHead -Line 'WARN [partner-report] sparse' | Should -BeFalse
        # Parentheses that do not hold a Lua source location.
        Test-NeoIPCRenderWarningHead -Line 'WARNING (HTTP status:404) resource not found' | Should -BeFalse
        Test-NeoIPCRenderWarningHead -Line 'WARNING (see below) ' | Should -BeFalse
        Test-NeoIPCRenderWarningHead -Line '' | Should -BeFalse
    }
}

Describe 'Invoke-QuartoRender' {
    BeforeAll {
        # The helper runs the `quarto` executable. A global stub stands in for it
        # so the command resolves wherever the tests run; each case then mocks its
        # behaviour in the module's scope.
        function global:quarto { param([Parameter(ValueFromRemainingArguments)] $Arguments) }
    }
    AfterAll {
        Remove-Item -Path 'Function:\quarto' -ErrorAction SilentlyContinue
    }

    # A render that finds nothing to report is an ordinary successful render:
    # nothing in the output may turn it into anything else, or the per-site
    # wrappers would drop the clean sites' files.
    It 'reports Success for a render that exits 0 without an error line' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            'processing file: Validation-Report.qmd'
            'No problem detected'
            'Output created: report.pdf'
        }
        $result = Invoke-QuartoRender -Arguments @('render', 'r.qmd') 6>$null
        $result.Status | Should -BeExactly 'Success'
        $result.ExitCode | Should -Be 0
        $result.Messages | Should -Contain 'Output created: report.pdf'
    }
    It 'reports Error for a non-zero exit code' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 1
            'Quitting from lines 3-9'
        }
        $result = Invoke-QuartoRender -Arguments @('render', 'r.qmd') 6>$null
        $result.Status | Should -BeExactly 'Error'
        $result.ExitCode | Should -Be 1
    }
    It 'reports Error for an error line even when the exit code is 0' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            'ERROR [validation-report] the import failed'
        }
        $result = Invoke-QuartoRender -Arguments @('render', 'r.qmd') 6>$null
        $result.Status | Should -BeExactly 'Error'
    }

    # Quarto's normalize filter puts its stray-fence message on the lines after
    # the WARNING head. The whole message must reach the warning stream, the
    # blank line that ends it must end the forwarding, and the ordinary output
    # after it must not be reported as a warning.
    It 'forwards the body of a warning whose head carries no message, up to the blank line' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            'processing file: Validation-Report.qmd'
            'WARNING (C:/Program Files/Quarto/share/filters/main.lua:10090) '
            'The following string was found in the document: :::'
            'This usually indicates a problem with a fenced div in the document.'
            ''
            'Output created: report.pdf'
        }
        $result = Invoke-QuartoRender -Arguments @('render', 'r.qmd') -WarningVariable warnings 6>$null 3>$null
        $result.Status | Should -BeExactly 'Success'
        $texts = @($warnings | ForEach-Object { $_.Message })
        $texts | Should -Contain 'WARNING (C:/Program Files/Quarto/share/filters/main.lua:10090) '
        $texts | Should -Contain 'The following string was found in the document: :::'
        $texts | Should -Contain 'This usually indicates a problem with a fenced div in the document.'
        $texts | Should -Not -Contain 'Output created: report.pdf'
        $texts | Should -Not -Contain 'processing file: Validation-Report.qmd'
        $texts.Count | Should -Be 3
    }

    It 'keeps a body line that itself reads as a warning inside the body' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            'WARNING (main.lua:10090) '
            'WARNING: the document holds a stray fence'
            'Please check the document for errors.'
            ''
            'Output created: report.pdf'
        }
        $null = Invoke-QuartoRender -Arguments @('render', 'r.qmd') -WarningVariable warnings 6>$null 3>$null
        @($warnings | ForEach-Object { $_.Message }) | Should -Be @(
            'WARNING (main.lua:10090) ',
            'WARNING: the document holds a stray fence',
            'Please check the document for errors.')
    }

    It 'keeps a body line that itself reads as an error inside the body, and the render successful' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            'WARNING (main.lua:10090) '
            'ERROR: this sentence belongs to the warning'
            ''
            'ERROR [validation-report] a real error after the body'
        }
        $result = Invoke-QuartoRender -Arguments @('render', 'r.qmd') -WarningVariable warnings 6>$null 3>$null
        @($warnings | ForEach-Object { $_.Message }) | Should -Be @(
            'WARNING (main.lua:10090) ',
            'ERROR: this sentence belongs to the warning')
        # The blank line ends the body, so an error after it is still one.
        $result.Status | Should -BeExactly 'Error'
    }

    # Quarto colours a filter warning as a whole, so the reset lands on a line
    # of its own after the message and is the blank line that ends it.
    It 'ends a one-line filter warning at the colour reset that follows it' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            "$([char]27)[33mWARNING (main.lua:14840) Unable to resolve crossref @sec-solution-6"
            "$([char]27)[39m"
            'Output created: report.pdf'
        }
        $null = Invoke-QuartoRender -Arguments @('render', 'r.qmd') -WarningVariable warnings 6>$null 3>$null
        @($warnings | ForEach-Object { $_.Message }) | Should -Be @("$([char]27)[33mWARNING (main.lua:14840) Unable to resolve crossref @sec-solution-6")
    }

    It 'forwards the continuation of a filter warning whose head carries text' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            'WARNING (main.lua:20000) The first line of the message'
            'and its second line.'
            ''
            'Output created: report.pdf'
        }
        $null = Invoke-QuartoRender -Arguments @('render', 'r.qmd') -WarningVariable warnings 6>$null 3>$null
        @($warnings | ForEach-Object { $_.Message }) | Should -Be @(
            'WARNING (main.lua:20000) The first line of the message',
            'and its second line.')
    }

    # Pandoc's own warnings and the reports' logger records are single lines
    # with nothing after them to absorb.
    It 'forwards a non-filter warning alone' {
        Mock -ModuleName NeoIPC-Tools -CommandName quarto -MockWith {
            $global:LASTEXITCODE = 0
            '[WARNING] Could not fetch resource'
            'Output created: report.pdf'
        }
        $null = Invoke-QuartoRender -Arguments @('render', 'r.qmd') -WarningVariable warnings 6>$null 3>$null
        @($warnings | ForEach-Object { $_.Message }) | Should -Be @('[WARNING] Could not fetch resource')
    }
}
