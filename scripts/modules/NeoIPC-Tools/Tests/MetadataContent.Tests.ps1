# Content lints over the AUTHORED metadata directory (metadata/common). Distinct from Metadata.Tests.ps1, which
# tests module logic against synthetic fixtures: these read the real committed CSVs and catch content drift a
# synthetic test cannot. The motivating defect: six "NeoIPC SSI Organism ..." rules whose programStage was the BSI
# stage (not SSI) - dead rules that fired never, yet every offline gate and the e2e suite passed, because
# "attached to a stage where its fields do not exist, so never fires" is indistinguishable from "correctly does
# nothing" unless a check cross-references the name against the stage. A green suite proves a failure absent, not a
# safeguard unnecessary; this is the cross-reference that would have caught it.
# Run:  Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/MetadataContent.Tests.ps1

Describe 'Program-rule name vs programStage consistency (metadata/common)' {
    BeforeAll {
        $common = (Resolve-Path (Join-Path $PSScriptRoot '../../../../metadata/common')).Path
        $rules = Import-Csv (Join-Path $common 'programRules.csv')

        # NEOIPC_CORE program-stage display name -> the stage TOKEN embedded in that stage's
        # NEOIPC_<TOKEN>_<field> data-element codes (and, by the same convention, in every rule NAME on that stage).
        $stageNameToToken = @{
            'Admission'                 = 'ADMISSION'
            'Surgical Procedure'        = 'SURGERY'
            'Primary Sepsis/BSI'        = 'BSI'
            'Necrotizing enterocolitis' = 'NEC'
            'Surgical Site Infection'   = 'SSI'
            'Pneumonia'                 = 'HAP'
            'Surveillance-End'          = 'SURVEILLANCE_END'
        }
        $stageIdToToken = @{}
        foreach ($s in Import-Csv (Join-Path $common 'programStages.csv')) {
            $tok = $stageNameToToken[$s.name]
            if (-not $tok) { throw "Unmapped program-stage name '$($s.name)' - add it to stageNameToToken." }
            $stageIdToToken[$s.id] = $tok
        }

        # Rule NAME prefix -> the stage token it declares. 'Patient' == enrollment level (no programStage).
        $namePrefixes = @(
            @('SSI ', 'SSI'), @('BSI ', 'BSI'), @('HAP ', 'HAP'), @('NEC ', 'NEC'),
            @('Admission ', 'ADMISSION'), @('Surgical Procedure ', 'SURGERY'), @('SURGERY ', 'SURGERY'),
            @('Surveillance end ', 'SURVEILLANCE_END'), @('Patient ', 'PATIENT'))

        $unmapped = [System.Collections.Generic.List[string]]::new()
        $mismatches = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $rules) {
            $name = [string]$r.name
            $nameTok = $null
            if ($name.StartsWith('NeoIPC ')) {
                $rest = $name.Substring(7)
                foreach ($p in $namePrefixes) { if ($rest.StartsWith($p[0])) { $nameTok = $p[1]; break } }
            }
            if (-not $nameTok) { $unmapped.Add($name); continue }
            $expected = if ($nameTok -eq 'PATIENT') { 'ENROL' } else { $nameTok }
            $actual = if ([string]::IsNullOrEmpty($r.programStage)) { 'ENROL' } else { $stageIdToToken[$r.programStage] }
            if ($expected -ne $actual) { $mismatches.Add("$name : name says $expected, runs on $actual") }
        }
        $script:Unmapped = $unmapped
        $script:Mismatches = $mismatches
    }

    It 'every program-rule name declares a recognised NeoIPC <stage> prefix' {
        $script:Unmapped.Count | Should -Be 0 -Because ('unmapped rule names: ' + ($script:Unmapped -join ' | '))
    }

    It "each rule's name-declared stage equals its programStage (no mis-assignment; no allow-listed exceptions)" {
        $script:Mismatches.Count | Should -Be 0 -Because ('name/stage mismatches: ' + ($script:Mismatches -join ' | '))
    }
}

Describe 'First-class code constraints (metadata/common)' {
    # Guards the DHIS2 hard code constraints against the REAL committed directory - hand-authored AND generated codes
    # together, per type. The generator-only whole-surface check in Metadata.Tests.ps1 cannot see a hand code, a
    # config/indicator code, or a hand-vs-generated collision; and that file is not run in CI. This lint is, so a
    # future edit introducing a 51-char, malformed, or duplicate code fails here instead of as an import-blocking
    # E4001 at deploy. The 50-char cap and per-type uniqueness are universal DHIS2 rules; the ^[A-Z][A-Z0-9_]*$ shape
    # is the NeoIPC scheme for the first-class types this arc authored (options / antibiotic-domain codes have their
    # own schemes and are only length/uniqueness-checked).
    BeforeAll {
        $common = (Resolve-Path (Join-Path $PSScriptRoot '../../../../metadata/common')).Path
        $script:CodesByType = [ordered]@{}
        foreach ($csv in Get-ChildItem -LiteralPath $common -Filter '*.csv') {
            $rows = @(Import-Csv -LiteralPath $csv.FullName)
            if ($rows.Count -eq 0 -or -not ($rows[0].PSObject.Properties.Name -contains 'code')) { continue }
            $codes = @($rows | ForEach-Object { [string]$_.code } | Where-Object { $_ -ne '' })
            if ($codes.Count) { $script:CodesByType[$csv.BaseName] = $codes }
        }
        # The first-class types this arc authored NEOIPC_ codes on; they must match the code scheme.
        $script:NeoIPCSchemeTypes = @('programRules', 'programRuleVariables', 'programStages', 'programStageSections',
            'programSections', 'organisationUnitLevels', 'trackedEntityTypes', 'programIndicators')
    }

    It 'no code exceeds the DHIS2 50-character cap (E4001) in any type' {
        $over = foreach ($t in $script:CodesByType.Keys) {
            foreach ($c in $script:CodesByType[$t]) { if ($c.Length -gt 50) { "$t/$c ($($c.Length))" } }
        }
        @($over) | Should -BeNullOrEmpty -Because ('over-length codes: ' + (@($over) -join ' | '))
    }

    It 'codes are unique within each type (DHIS2 per-type unique constraint)' {
        $dups = foreach ($t in $script:CodesByType.Keys) {
            if ($t -eq 'options') { continue }   # an option's code is unique per optionSet, not per type
            foreach ($x in @($script:CodesByType[$t] | Group-Object | Where-Object Count -gt 1)) { "$t/$($x.Name) x$($x.Count)" }
        }
        @($dups) | Should -BeNullOrEmpty -Because ('duplicate codes: ' + (@($dups) -join ' | '))
    }

    It 'first-class NeoIPC codes match ^[A-Z][A-Z0-9_]*$' {
        $bad = foreach ($t in $script:NeoIPCSchemeTypes) {
            if (-not $script:CodesByType.Contains($t)) { continue }
            foreach ($c in $script:CodesByType[$t]) { if ($c -notmatch '^[A-Z][A-Z0-9_]*$') { "$t/$c" } }
        }
        @($bad) | Should -BeNullOrEmpty -Because ('malformed codes: ' + (@($bad) -join ' | '))
    }
}
