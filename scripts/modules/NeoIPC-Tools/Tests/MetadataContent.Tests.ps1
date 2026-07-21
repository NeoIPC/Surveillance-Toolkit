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
