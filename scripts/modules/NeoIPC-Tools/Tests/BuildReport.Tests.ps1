#requires -Module Pester

# Tests for the centralized build-report machinery (Public/BuildReport.ps1):
# Write-NeoIPCBuildReport, New-NeoIPCBuildStep, Complete-NeoIPCBuildStep, Get-NeoIPCParameterSnapshot.

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
    It 'maps a NoData result to a distinct nodata status (not planned)' {
        $step = New-NeoIPCBuildStep | Complete-NeoIPCBuildStep -Result ([pscustomobject]@{ Status = 'NoData'; ExitCode = 0; Messages = @('No problem detected') })
        $step.status | Should -BeExactly 'nodata'
        $step.exitCode | Should -Be 0
        $step.messages | Should -Be @('No problem detected')
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
