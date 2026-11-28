#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for the report edition helpers: the preset reader, the reference dataset's
    department count, and the preset data the birth-weight-class and gestational-age-range
    editions render from.

.DESCRIPTION
    Covers Get-NeoIPCReportPreset and Get-NeoIPCReferenceDatasetDepartmentCount of
    Public/ReportEdition.ps1, and the class-range-edition entry of
    reports/Reference-Report/presets.json. The floor of 5 contributing departments a
    Reference Report edition may publish under is decided by the edition's design; this
    file pins what the helpers read, the builder decides whether to stop on it.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportEdition.Tests.ps1
#>

BeforeAll {
    Import-Module -Name (Join-Path $PSScriptRoot '..') -Force
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:ReferencePresetsPath = Join-Path $RepoRoot 'reports/Reference-Report/presets.json'
}

Describe 'Get-NeoIPCReportPreset' {
    BeforeAll {
        $script:PresetsFile = Join-Path $TestDrive 'presets.json'
        @'
{
  "presets": {
    "default": {},
    "minimal": { "includeMethodsTexts": false },
    "with-comment": {
      "_comment": "not a parameter",
      "includeIntroductionTexts": false
    }
  }
}
'@ | Set-Content -LiteralPath $PresetsFile -Encoding utf8NoBOM
    }

    It 'reads the parameters of a named preset' {
        $preset = Get-NeoIPCReportPreset -PresetsFilePath $PresetsFile -Name 'minimal'
        $preset | Should -BeOfType [hashtable]
        $preset['includeMethodsTexts'] | Should -BeFalse
    }

    It 'returns a fresh hashtable every call, so a caller may edit it' {
        $first = Get-NeoIPCReportPreset -PresetsFilePath $PresetsFile -Name 'minimal'
        $first['added'] = 1
        $second = Get-NeoIPCReportPreset -PresetsFilePath $PresetsFile -Name 'minimal'
        $second.ContainsKey('added') | Should -BeFalse
    }

    It 'leaves out a comment key and keeps every parameter of the preset' {
        $preset = Get-NeoIPCReportPreset -PresetsFilePath $PresetsFile -Name 'with-comment'
        $preset.ContainsKey('_comment') | Should -BeFalse -Because 'the _comment key documents the file, it is no render parameter'
        $preset['includeIntroductionTexts'] | Should -BeFalse
    }

    It 'returns an empty hashtable for a preset that overrides nothing' {
        $preset = Get-NeoIPCReportPreset -PresetsFilePath $PresetsFile -Name 'default'
        @($preset.Keys).Count | Should -Be 0
    }

    It 'names the available presets when it is given a name the file lacks' {
        $errorRecords = @()
        { Get-NeoIPCReportPreset -PresetsFilePath $PresetsFile -Name 'no-such' -ErrorAction SilentlyContinue -ErrorVariable errorRecords } |
            Should -Throw
        ($errorRecords | Out-String) + $Error[0].ToString() | Should -Match 'default'
    }

    It 'refuses a presets file without a presets object' {
        $broken = Join-Path $TestDrive 'broken.json'
        '{"unexpected": {}}' | Set-Content -LiteralPath $broken -Encoding utf8NoBOM
        { Get-NeoIPCReportPreset -PresetsFilePath $broken -Name 'minimal' } | Should -Throw
    }
}

Describe 'Get-NeoIPCReferenceDatasetDepartmentCount' {
    # R decodes the serialized dataset, so these cases run only where Rscript is present.
    # Decided during discovery, so that it can gate -Skip.
    $script:RscriptAvailable = [bool](Get-Command -Name Rscript -ErrorAction SilentlyContinue)

    BeforeAll {
        function New-NeoIPCFailingRscriptStub {
            # Writes an executable that prints the given lines and exits with the given code,
            # shadowing Rscript on PATH. A PATH lookup on Windows takes Rscript.cmd through
            # PATHEXT; on Unix it takes only the bare name with the executable bit, and its
            # shebang needs LF endings.
            param(
                [string]$Directory,
                [string[]]$StdoutLines = @(),
                [string[]]$StderrLines = @(),
                [Parameter(Mandatory)][int]$ExitCode
            )
        New-Item -ItemType Directory -Path $Directory | Out-Null
        if ($IsWindows) {
            $lines = @('@echo off') + @($StderrLines | ForEach-Object { "echo $_ 1>&2" }) +
                @($StdoutLines | ForEach-Object { "echo $_" }) + @("exit /b $ExitCode")
            ($lines -join "`r`n") | Set-Content -LiteralPath (Join-Path $Directory 'Rscript.cmd') -Encoding ascii
        } else {
            $lines = @('#!/bin/sh')
            foreach ($line in $StderrLines) {
                $lines += "echo '$($line.Replace("'", "'\''"))' >&2"
            }
            foreach ($line in $StdoutLines) {
                $lines += "echo '$($line.Replace("'", "'\''"))'"
            }
            $lines += "exit $ExitCode"
            ($lines -join "`n") | Set-Content -LiteralPath (Join-Path $Directory 'Rscript') -Encoding ascii
            chmod +x (Join-Path $Directory 'Rscript')
        }
            return $Directory
        }
    }

    BeforeAll {
        # The fixtures come from serializeJSON's own writer, run in R now. The serialized
        # shape belongs to the installed jsonlite and has shifted across package versions,
        # so a hand-written fixture can pin a shape no writer writes.
        $gen = Join-Path $TestDrive 'make-datasets.R'
        @'
args <- commandArgs(trailingOnly = TRUE)
ds <- structure(list(n_departments = 26L, metadata = list(period = "2024-2025")),
                class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))
writeLines(jsonlite::serializeJSON(ds), args[[1]])
nodata <- structure(list(metadata = list(period = "2024-2025")),
                    class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))
writeLines(jsonlite::serializeJSON(nodata), args[[2]])
wrong <- structure(list(n_departments = "5"),
                   class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))
writeLines(jsonlite::serializeJSON(wrong), args[[3]])
huge <- structure(list(n_departments = 9999999999),
                  class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))
writeLines(jsonlite::serializeJSON(huge), args[[4]])
partial <- structure(list(n_departments_contributing = 7L),
                     class = c("neoipcr_ref_ds", "neoipcr_rep_ds", "list"))
writeLines(jsonlite::serializeJSON(partial), args[[5]])
writeLines(jsonlite::serializeJSON(5L), args[[6]])
'@ | Set-Content -LiteralPath $gen -Encoding utf8NoBOM
        $script:WithCount = Join-Path $TestDrive 'with-count.json'
        $script:WithoutCount = Join-Path $TestDrive 'without-count.json'
        $script:WrongType = Join-Path $TestDrive 'wrong-type.json'
        $script:HugeCount = Join-Path $TestDrive 'huge-count.json'
        $script:PartialName = Join-Path $TestDrive 'partial-name.json'
        $script:ScalarContent = Join-Path $TestDrive 'scalar-content.json'
        $script:PlainJson = Join-Path $TestDrive 'plain.json'
        '{"n_departments": 26}' | Set-Content -LiteralPath $PlainJson -Encoding utf8NoBOM
        if (Get-Command -Name Rscript -ErrorAction SilentlyContinue) {
            & Rscript --vanilla $gen $WithCount $WithoutCount $WrongType $HugeCount $PartialName $ScalarContent
            if ($LASTEXITCODE -ne 0) {
                throw "The R fixture writer failed with exit code $LASTEXITCODE."
            }
        }
    }

    It 'reads the department count out of a dataset as its own writer serializes it' -Skip:(-not $script:RscriptAvailable) {
        Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WithCount | Should -Be 26
    }

    It 'stops with an error that names the file on a serialized dataset that carries no count' -Skip:(-not $script:RscriptAvailable) {
        $message = ''
        try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WithoutCount } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Match ([regex]::Escape([System.IO.Path]::GetFileName($WithoutCount))) -Because 'the operator must see which file lacks the count'
    }

    It 'refuses a plain JSON document that is no serialized dataset' -Skip:(-not $script:RscriptAvailable) {
        $message = ''
        try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $PlainJson } catch { $message = $_.Exception.Message }
        $message | Should -Match ([regex]::Escape([System.IO.Path]::GetFileName($PlainJson))) -Because 'a gate may not count a document R cannot unserialize'
    }

    It 'refuses a dataset whose count is no number' -Skip:(-not $script:RscriptAvailable) {
        $message = ''
        try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WrongType } catch { $message = $_.Exception.Message }
        $message | Should -Match ([regex]::Escape([System.IO.Path]::GetFileName($WrongType))) -Because 'a string that looks like a number is not a count'
    }

    It 'refuses a count no whole department count can be' -Skip:(-not $script:RscriptAvailable) {
        $message = ''
        try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $HugeCount } catch { $message = $_.Exception.Message }
        $message | Should -Match ([regex]::Escape([System.IO.Path]::GetFileName($HugeCount))) -Because 'a value beyond the range of department counts must refuse by naming the file, not by a cast error'
    }

    It 'refuses a field whose name only starts like n_departments' -Skip:(-not $script:RscriptAvailable) {
        # R's $ matches list names partially; the reader must not.
        $message = ''
        try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $PartialName } catch { $message = $_.Exception.Message }
        $message | Should -Match ([regex]::Escape([System.IO.Path]::GetFileName($PartialName))) -Because 'n_departments_contributing is no n_departments'
        $message | Should -Match 'n_departments' -Because 'the refusal says which field is missing'
    }

    It 'quotes R''s own message for serialized content that is no list' -Skip:(-not $script:RscriptAvailable) {
        # A serialized scalar unserializes successfully and fails only in the extraction;
        # the decoder must isolate that too. The failing call's stderr dump repeats the
        # extraction expression in every locale; R's condition message does not.
        $message = ''
        try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $ScalarContent } catch { $message = $_.Exception.Message }
        $message | Should -Match ([regex]::Escape([System.IO.Path]::GetFileName($ScalarContent))) -Because 'the operator must see which file is no dataset'
        $message | Should -Match 'not a serialized reference dataset' -Because 'content that is no list is no dataset'
        $message | Should -Not -Match 'dataset\[\[' -Because "the refusal quotes the message R isolates, not the stderr dump of the failing call: $message"
    }

    It 'reports the missing field itself when native failures throw' -Skip:(-not $script:RscriptAvailable) {
        # The exit codes are the diagnosis, so the reader turns the native-command error
        # preference off around its Rscript call; a machine-wide Stop preference may not
        # throw over them. The module function resolves both preferences from global
        # scope, not the caller's, so the test sets globals and restores them.
        $savedNative = $PSNativeCommandUseErrorActionPreference
        $savedEap = $ErrorActionPreference
        $message = ''
        try {
            $Global:PSNativeCommandUseErrorActionPreference = $true
            $Global:ErrorActionPreference = 'Stop'
            Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WithoutCount
        } catch { $message = $_.Exception.Message } finally {
            $Global:PSNativeCommandUseErrorActionPreference = $savedNative
            $Global:ErrorActionPreference = $savedEap
        }
        $message | Should -Match 'carries no n_departments field' -Because 'the diagnosis survives a Stop preference, which a bare exit code would not'
    }

    It 'quotes the error R isolates, not the startup warning it puts on stderr' -Skip:(-not $script:RscriptAvailable) {
        # R prints startup warnings on stderr before anything the decoder says; the decoder
        # prints its own failure on stdout under status 6, so that and not the warning is
        # what the refusal quotes. The stub plays that R: warning on stderr first, error
        # on stdout, status 6.
        $stubDir = New-NeoIPCFailingRscriptStub -Directory (Join-Path $TestDrive 'stub-status6') `
            -StderrLines @('During startup - Warning messages:') -StdoutLines @('cannot open the connection at line 3') -ExitCode 6
        $savedPath = $env:PATH
        try {
            $env:PATH = "$stubDir$([System.IO.Path]::PathSeparator)$savedPath"
            $message = ''
            try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WithCount } catch { $message = $_.Exception.Message }
            $message | Should -Match 'cannot open the connection' -Because "the refusal quotes the message R isolates on stdout: $message"
            $message | Should -Not -Match 'During startup' -Because 'the startup warning on stderr is no diagnosis'
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'names jsonlite when R lacks it' -Skip:(-not $script:RscriptAvailable) {
        $stubDir = New-NeoIPCFailingRscriptStub -Directory (Join-Path $TestDrive 'stub-status5') `
            -ExitCode 5
        $savedPath = $env:PATH
        try {
            $env:PATH = "$stubDir$([System.IO.Path]::PathSeparator)$savedPath"
            $message = ''
            try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WithCount } catch { $message = $_.Exception.Message }
            $message | Should -Match 'jsonlite' -Because "an R without the package is the lacking environment, not a bad dataset: $message"
            $message | Should -Not -Match 'not a serialized' -Because 'the file is no dataset in this failure'
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'quotes the error on stderr when the Rscript call itself fails' -Skip:(-not $script:RscriptAvailable) {
        $stubDir = New-NeoIPCFailingRscriptStub -Directory (Join-Path $TestDrive 'stub-crash') `
            -StderrLines @('Fatal error: R cannot start') -ExitCode 1
        $savedPath = $env:PATH
        try {
            $env:PATH = "$stubDir$([System.IO.Path]::PathSeparator)$savedPath"
            $message = ''
            try { Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath $WithCount } catch { $message = $_.Exception.Message }
            $message | Should -Match 'R cannot start' -Because "the last resort quotes what the failing call reported: $message"
        } finally {
            $env:PATH = $savedPath
        }
    }
}

Describe 'The Reference Report edition preset' {
    It 'carries a class-range-edition preset' {
        $presets = ((Get-Content -LiteralPath $ReferencePresetsPath -Raw) | ConvertFrom-Json).presets
        $presets.PSObject.Properties.Name | Should -Contain 'class-range-edition'
    }

    It 'withholds every part the edition of a class or range does not print' {
        $edition = ((Get-Content -LiteralPath $ReferencePresetsPath -Raw) | ConvertFrom-Json).presets.'class-range-edition'
        # The editions print the overview, the case-mix figures, the incidence densities,
        # the device-associated rates, and the risk densities, and leave out the validation
        # summary, the agent-per-infection and infectious-agent-detection rates, and the
        # surgery table. The antibiotic utilisation, resistance, and secondary-BSI tables
        # are off in the document defaults, so the preset sets only the four parts it
        # withholds.
        $edition.includeValidationSummaryTable | Should -BeFalse
        $edition.includeAgentPerInfectionRateTable | Should -BeFalse
        $edition.includeInfectiousAgentDetectionRateTable | Should -BeFalse
        $edition.includeSurgicalProcedureRateTable | Should -BeFalse
    }

    It 'lists no parameter that the Reference Report document does not declare' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
        # The document's parameter block is YAML, so it is read with the YAML parser the
        # module tests use elsewhere, not with a regex over its text.
        Import-Module powershell-yaml
        $lines = Get-Content -LiteralPath (Join-Path $RepoRoot 'reports/Reference-Report/Reference-Report.qmd')
        $open = [Array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match '^---\s*$' })
        if ($open -lt 0) { throw 'the Reference Report document carries no YAML frontmatter to read its parameters from' }
        $close = -1
        for ($i = $open + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^---\s*$') { $close = $i; break }
        }
        if ($close -lt 0) { throw 'the Reference Report document has no closing YAML frontmatter marker' }
        $document = ConvertFrom-Yaml (($lines[($open + 1)..($close - 1)] -join [Environment]::NewLine))
        $declared = @($document.params.Keys)
        $edition = ((Get-Content -LiteralPath $ReferencePresetsPath -Raw) | ConvertFrom-Json).presets.'class-range-edition'
        foreach ($key in @($edition.PSObject.Properties.Name)) {
            $declared | Should -Contain $key -Because 'the preset may only set a parameter the document declares'
        }
    }

    It 'keeps the preset a pure diff of the document defaults' {
        $edition = ((Get-Content -LiteralPath $ReferencePresetsPath -Raw) | ConvertFrom-Json).presets.'class-range-edition'
        @($edition.PSObject.Properties.Name) | Should -Not -Contain 'includeSecondaryBsiRateTable' -Because 'the document default already keeps it off'
        @($edition.PSObject.Properties.Name) | Should -Not -Contain 'includeAntibioticUtilisationTable' -Because 'the edition stays off where the document default is off; only the overall report enables it, by parameter'
    }
}
