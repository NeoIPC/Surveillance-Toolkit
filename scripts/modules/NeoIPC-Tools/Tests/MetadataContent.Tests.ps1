#Requires -Version 7.6

<#
.SYNOPSIS
    Content lints over the authored metadata directory, as opposed to module logic.

.DESCRIPTION
    These read the real committed files under the authored metadata directory, its CSVs and the infectious-agent
    list, and catch content drift that a synthetic fixture cannot. That is the distinction from Metadata.Tests.ps1
    and InfectiousAgentValidation.Tests.ps1, which exercise module logic against fixtures they construct themselves.

    The motivating defect is worth keeping in view: six SSI organism rules were attached to the BSI program
    stage rather than the SSI one. They were dead — they could never fire — yet every offline gate and the
    end-to-end suite passed, because "attached to a stage whose fields do not exist, so never fires" is
    indistinguishable from "correctly does nothing" unless something cross-references the rule's name
    against its stage. A green suite proves a failure absent, not a safeguard unnecessary; this is the
    cross-reference that would have caught it.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/MetadataContent.Tests.ps1
#>

# The infectious-agent checks are private module functions, reached through InModuleScope, which needs the module
# imported during Pester's discovery phase, so at file top.
Import-Module (Join-Path $PSScriptRoot '..') -Force

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
    # config/indicator code, or a hand-vs-generated collision. This lint does, so a future edit introducing a
    # 51-char, malformed, or duplicate code fails here instead of as an import-blocking E4001 at deploy. The 50-char
    # cap and per-type uniqueness are universal DHIS2 rules; the ^[A-Z][A-Z0-9_]*$ shape is the NeoIPC scheme for the
    # first-class types whose NEOIPC_ codes NeoIPC authors (options / antibiotic-domain codes have their own schemes
    # and are only length/uniqueness-checked).
    BeforeAll {
        $common = (Resolve-Path (Join-Path $PSScriptRoot '../../../../metadata/common')).Path
        $script:CodesByType = [ordered]@{}
        foreach ($csv in Get-ChildItem -LiteralPath $common -Filter '*.csv') {
            $rows = @(Import-Csv -LiteralPath $csv.FullName)
            if ($rows.Count -eq 0 -or -not ($rows[0].PSObject.Properties.Name -contains 'code')) { continue }
            $codes = @($rows | ForEach-Object { [string]$_.code } | Where-Object { $_ -ne '' })
            if ($codes.Count) { $script:CodesByType[$csv.BaseName] = $codes }
        }
        # The first-class types whose NEOIPC_ codes NeoIPC authors; they must match the code scheme.
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

InModuleScope 'NeoIPC-Tools' {
    Describe 'Infectious-agent list (metadata/common/infectious-agents)' {
        # The checks of Private/InfectiousAgentValidation.ps1, applied to the committed list. The release check reads
        # the infectious-agents-v* tags, so it needs a clone with its tags, as a full history has them; it fails rather
        # than passes in a clone without them, but for the tag of the release the VERSION file names while [Unreleased]
        # lists no change, a tag pushed once that release's preparation has merged.
        BeforeAll {
            Import-Module powershell-yaml -ErrorAction Stop
            $script:RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
            $script:ListDirectory = Join-Path $script:RepositoryRoot 'metadata/common/infectious-agents'
            $script:ListText = [System.IO.File]::ReadAllText((Join-Path $script:ListDirectory 'NeoIPC-Infectious-Agents.yaml'))
            $script:ListTree = $script:ListText | ConvertFrom-Yaml
            $script:UidRows = @(Import-Csv -LiteralPath (Join-Path $script:ListDirectory 'NeoIPC-Infectious-Agents.uids.csv') -Encoding utf8NoBOM)

            function Format-Finding {
                # The first findings, one per line of the failure message.
                param([AllowEmptyCollection()][object[]]$Finding)
                (@($Finding | Select-Object -First 20 | ForEach-Object { "$($_.Rule) at $($_.Location): $($_.Message)" })) -join "`n"
            }
        }

        # Repeated keys, anchors, and aliases are YamlPortability.Tests.ps1's, which holds every committed YAML file,
        # this one included, to the portable subset.
        It 'spells every key as its place in the list has it, keeps every structure in its place, and writes each Id, record number, and flag in its form' {
            $findings = @(Get-NeoIPCInfectiousAgentKeyFinding -Text $script:ListText)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        It 'gives every node an integer Id of its own, a Name, a rank, a known source with its record number, and Boolean flags' {
            $findings = @(Get-NeoIPCInfectiousAgentNodeFinding -Tree $script:ListTree)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        It 'tells every node from every other: a synonym by an Id of its own, a record by one node, an ICTV taxon by one concept, and a NeoIPC concept by an integer ConceptId' {
            $findings = @(Get-NeoIPCInfectiousAgentIdentityFinding -Tree $script:ListTree)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        # A warning fails the test too: it is settled by a flag, or by Comments.CommonCommensal on the node it names.
        It 'sets each common-commensal flag on a concept, only where it changes the inherited status, with its reason, and says why wherever one flag would hold for all beneath a node' {
            $findings = @(Get-NeoIPCInfectiousAgentFlagFinding -Tree $script:ListTree)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        It 'generates option labels that are distinct and fit DHIS2' {
            $findings = @(Get-NeoIPCInfectiousAgentLabelFinding -Tree $script:ListTree)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        It 'gives every Id of the list, and nothing else, a well-formed UID of its own in the UID sidecar' {
            $findings = @(Get-NeoIPCInfectiousAgentUidFinding -Tree $script:ListTree -UidRow $script:UidRows)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        It 'keeps every released Id, name and UID, and adds new Ids above the released ones' {
            $concepts = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
            foreach ($c in @(Get-NeoIPCInfectiousAgentConcept -Node $script:ListTree)) { $concepts[[string]$c.Id] = $c.Name }
            $uids = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
            foreach ($row in $script:UidRows) { $uids[[string]$row.id] = [string]$row.uid }
            $changelog = Join-Path $script:ListDirectory 'CHANGELOG.md'
            $findings = @(Get-NeoIPCInfectiousAgentReleaseFinding -Current ([pscustomobject]@{ Concepts = $concepts; Uids = $uids }) `
                    -Release @(Read-NeoIPCInfectiousAgentRelease -RepositoryRoot $script:RepositoryRoot) `
                    -ChangelogRelease @(Get-NeoIPCChangelogRelease -Path $changelog) `
                    -PreparedVersion ([System.IO.File]::ReadAllText((Join-Path $script:ListDirectory 'VERSION')).Trim()) `
                    -HasUnreleasedEntry (Test-NeoIPCChangelogUnreleasedEntry -Path $changelog))
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }

        # NEOIPC-COMPAT(legacy-infectious-agent-csv): see Private/InfectiousAgentValidation.ps1.
        It 'keeps the two CSVs that readers outside this repository download byte for byte' {
            $findings = @(Get-NeoIPCFrozenInfectiousAgentCsvFinding -Directory $script:ListDirectory)
            $findings | Should -BeNullOrEmpty -Because (Format-Finding $findings)
        }
    }
}
