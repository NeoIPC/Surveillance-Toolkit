# Pester 5 tests for the NeoIPC metadata pipeline (Private/Metadata.ps1 + Private/MetadataTypeMaps.ps1).
# Self-contained: every fixture is synthetic, so the suite runs against a standalone Surveillance-Toolkit
# checkout with no DHIS2 metadata.json present. The full-metadata.json round-trip is a workspace-level
# gate (Test-NeoIPCMetadataRoundTrip against repos/neoipc-dhis2), intentionally not reproduced here.
#
# Run:  Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests
#
# Internals are exercised via InModuleScope so the private (non-exported) helpers are in scope. The
# Import-Module at file top runs during Pester's discovery phase, which InModuleScope requires.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        # Round-trip one object through row<->object and report semantic equality the way the comparator
        # sees it (normalized + canonical). Returns the row and rebuilt object too, for cell-level asserts.
        function Get-RowRoundTrip {
            param([string]$Type, $Object)
            $row  = ConvertTo-NeoIPCMetadataRow -Type $Type -Object $Object
            $back = ConvertFrom-NeoIPCMetadataRow -Type $Type -Row $row
            $o1 = ConvertFrom-NeoIPCMetadataJsonText -Json ($Object | ConvertTo-Json -Depth 40)
            $o2 = ConvertFrom-NeoIPCMetadataJsonText -Json ($back | ConvertTo-Json -Depth 40)
            $a = (ConvertTo-NeoIPCMetadataCanonical (Remove-NeoIPCMetadataNoise -Object $o1 -WarningAction SilentlyContinue)) | ConvertTo-Json -Compress -Depth 40
            $b = (ConvertTo-NeoIPCMetadataCanonical (Remove-NeoIPCMetadataNoise -Object $o2 -WarningAction SilentlyContinue)) | ConvertTo-Json -Compress -Depth 40
            @{ Equal = ($a -eq $b); Row = $row; Back = $back; A = $a; B = $b }
        }
    }

    Describe 'Cell coercion' {
        It 'serializes bool $false as "False" and parses it back without flipping' {
            (ConvertTo-NeoIPCMetadataCell -Class bool -Value $false) | Should -BeExactly 'False'
            (ConvertFrom-NeoIPCMetadataCell -Class bool -Cell 'False') | Should -BeFalse
        }
        It 'parses the string "false" to $false on emit (no [bool]-cast truthiness flip)' {
            # Regression: the emit fallback must use [bool]::Parse, not [bool]'false' (which is $true).
            (ConvertTo-NeoIPCMetadataCell -Class bool -Value 'false') | Should -BeExactly 'False'
        }
        It 'round-trips an int larger than Int32.MaxValue (Int64 path, no overflow)' {
            $big = 2147483648            # Int32.MaxValue + 1
            $cell = ConvertTo-NeoIPCMetadataCell -Class int -Value $big
            $cell | Should -BeExactly '2147483648'
            (ConvertFrom-NeoIPCMetadataCell -Class int -Cell $cell) | Should -Be $big
        }
        It 'rejects a fractional value for an int-class property instead of silently rounding' {
            { ConvertTo-NeoIPCMetadataCell -Class int -Value 1.5 } | Should -Throw '*Non-integer value*'
        }
        It 'parses ints with invariant culture (no thousands separators)' {
            (ConvertFrom-NeoIPCMetadataCell -Class int -Cell '1000') | Should -Be 1000
        }
        It 'ordinal-sorts an idArray cell (set semantics, deterministic)' {
            $v = @([ordered]@{ id = 'zzz' }, [ordered]@{ id = 'aaa' }, [ordered]@{ id = 'mmm' })
            (ConvertTo-NeoIPCMetadataCell -Class idArray -Value $v) | Should -BeExactly 'aaa mmm zzz'
        }
        It 'preserves array order for an idArrayOrdered cell (list semantics, order is data)' {
            $v = @([ordered]@{ id = 'zzz' }, [ordered]@{ id = 'aaa' }, [ordered]@{ id = 'mmm' })
            (ConvertTo-NeoIPCMetadataCell -Class idArrayOrdered -Value $v) | Should -BeExactly 'zzz aaa mmm'
        }
        It 'round-trips idArrayOrdered cell back to ref objects in the same order' {
            $back = ConvertFrom-NeoIPCMetadataCell -Class idArrayOrdered -Cell 'zzz aaa mmm'
            @($back | ForEach-Object { $_.id }) | Should -Be @('zzz', 'aaa', 'mmm')
        }
        It 'tokenizes whitespace-collapsed lists without spurious empties' {
            (Split-NeoIPCMetadataList "  a   b`tc  ") | Should -Be @('a', 'b', 'c')
            (Split-NeoIPCMetadataList '') | Should -Be @()
        }
    }

    Describe 'Row round-trip (representative types)' {
        It 'round-trips a dataElement, dropping noise and empty collections' {
            $de = [ordered]@{ id = 'dataElmnt01'; code = 'NEOIPC_X'; name = 'X'; shortName = 'x'; valueType = 'TEXT'; domainType = 'TRACKER'
                aggregationType = 'NONE'; zeroIsSignificant = $false; categoryCombo = [ordered]@{ id = 'catComboAAA' }
                legendSets = @(); aggregationLevels = @()
                created = '2020-01-01'; lastUpdated = '2021-01-01'; createdBy = [ordered]@{ id = 'userAAA1234' }; displayName = 'X disp'
                sharing = [ordered]@{ public = 'rw------'; owner = 'userAAA1234'; external = $false; users = [ordered]@{}; userGroups = [ordered]@{} }
                translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'X (de)' }) }
            $r = Get-RowRoundTrip 'dataElements' $de
            $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            $r.Back.Contains('legendSets') | Should -BeFalse        # empty array dropped
            $r.Back.Contains('created') | Should -BeFalse           # audit noise not carried
            $r.Back['sharing']['public'] | Should -BeExactly 'rw------'
            $r.Back['sharing'].Contains('owner') | Should -BeFalse  # owner/external/empty grants dropped
        }
        It 'round-trips an optionSet and ordinal-sorts its option refs (recoverable via Option.sortOrder)' {
            $os = [ordered]@{ id = 'optSetBBB12'; code = 'NEOIPC_OS'; name = 'OS'; valueType = 'TEXT'; version = 3
                options = @([ordered]@{ id = 'optZZZ99999' }, [ordered]@{ id = 'optAAA11111' }, [ordered]@{ id = 'optMMM55555' })
                created = '2020'; sharing = [ordered]@{ public = 'rw------' } }
            $r = Get-RowRoundTrip 'optionSets' $os
            $r.Equal | Should -BeTrue
            $r.Row['version'] | Should -BeExactly '3'
            $r.Row['options'] | Should -BeExactly 'optAAA11111 optMMM55555 optZZZ99999'
        }
        It 'uses the optionSet|code composite natural key for options' {
            $opt = [ordered]@{ id = 'optZZZ99999'; code = '1'; name = 'Yes'; sortOrder = 2; optionSet = [ordered]@{ id = 'optSetBBB12' } }
            (Get-NeoIPCMetadataNaturalKey -Type 'options' -Object $opt) | Should -BeExactly 'optSetBBB12|1'
        }
        It 'drops an empty pattern string on a trackedEntityAttribute' {
            $tea = [ordered]@{ id = 'teaAAA12345'; code = 'NEOIPC_TEA'; name = 'T'; valueType = 'TEXT'; aggregationType = 'NONE'
                confidential = $false; unique = $true; generated = $false; pattern = ''
                created = 'x'; sharing = [ordered]@{ public = 'rw------' } }
            $r = Get-RowRoundTrip 'trackedEntityAttributes' $tea
            $r.Equal | Should -BeTrue
            $r.Back.Contains('pattern') | Should -BeFalse
        }
        It 'round-trips a programStageSection: renderType flattened, dataElements order preserved' {
            $pss = [ordered]@{ id = 'psSecAAA123'; name = 'Sec1'; sortOrder = 1; programStage = [ordered]@{ id = 'psStageAA01' }
                dataElements = @([ordered]@{ id = 'deBBB22222' }, [ordered]@{ id = 'deAAA11111' }); programIndicators = @()
                renderType = [ordered]@{ DESKTOP = [ordered]@{ type = 'LISTING' }; MOBILE = [ordered]@{ type = 'SEQUENTIAL' } }
                created = 'x'; sharing = [ordered]@{ public = 'rw------' } }
            $r = Get-RowRoundTrip 'programStageSections' $pss
            $r.Equal | Should -BeTrue
            $r.Row['dataElements'] | Should -BeExactly 'deBBB22222 deAAA11111'   # NOT sorted
            $r.Row['renderType_DESKTOP'] | Should -BeExactly 'LISTING'
            $r.Back['renderType']['MOBILE']['type'] | Should -BeExactly 'SEQUENTIAL'
        }
        It 'round-trips a validationRule (leftSide/rightSide; nested translations dropped; nested bool no-flip)' {
            $vr = [ordered]@{ id = 'valRuleA001'; name = 'VR'; operator = 'greater_than'; periodType = 'Monthly'; importance = 'MEDIUM'; skipFormValidation = $false
                organisationUnitLevels = @(3, 1, 2)
                leftSide  = [ordered]@{ expression = '#{a.b}'; missingValueStrategy = 'NEVER_SKIP'; slidingWindow = $false; translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'x' }) }
                rightSide = [ordered]@{ expression = 'V{zero}'; missingValueStrategy = 'NEVER_SKIP'; slidingWindow = $false }
                created = 'x'; sharing = [ordered]@{ public = 'rw------' } }
            $r = Get-RowRoundTrip 'validationRules' $vr
            $r.Equal | Should -BeTrue
            $r.Row['leftSide_slidingWindow'] | Should -BeExactly 'False'
            $r.Back['leftSide']['slidingWindow'] | Should -BeFalse
            $r.Row['leftSide_expression'] | Should -BeExactly '#{a.b}'
        }
        It 'round-trips a trackedEntityType (style.icon nested, unwrapped)' {
            $tet = [ordered]@{ id = 'tetAAA12345'; name = 'Patient'; description = 'P'; featureType = 'NONE'; allowAuditLog = $false
                maxTeiCountToReturn = 0; minAttributesRequiredToSearch = 1
                style = [ordered]@{ icon = 'patient-icon' }; created = 'x'; sharing = [ordered]@{ public = 'rw------' } }
            $r = Get-RowRoundTrip 'trackedEntityTypes' $tet
            $r.Equal | Should -BeTrue
            $r.Back['style']['icon'] | Should -BeExactly 'patient-icon'
        }
        It 'carries program-rule expressions verbatim (multi-line / operators preserved)' {
            $pr = [ordered]@{ id = 'prAAAA12345'; name = 'NeoIPC rule'; condition = 'd2:hasValue(#{x}) && #{x} != 0'; priority = 5
                program = [ordered]@{ id = 'progAAA0001' }; programStage = [ordered]@{ id = 'psStageAA01' }
                programRuleActions = @([ordered]@{ id = 'praAAA11111' }, [ordered]@{ id = 'praAAA22222' }); created = 'x' }
            (Get-RowRoundTrip 'programRules' $pr).Equal | Should -BeTrue
            $pra = [ordered]@{ id = 'praAAA11111'; programRuleActionType = 'ASSIGN'; data = '#{x} + 1'; content = ''
                programRule = [ordered]@{ id = 'prAAAA12345' }; dataElement = [ordered]@{ id = 'deAAA11111' }; created = 'x' }
            (Get-RowRoundTrip 'programRuleActions' $pra).Equal | Should -BeTrue
        }
        It 'strips the displaySubjectTemplate/displayMessageTemplate i18n projections on a programNotificationTemplate' {
            $t = [ordered]@{ id = 'pntTmpl0001'; name = 'T'; subjectTemplate = 'Subj'; messageTemplate = 'Msg'
                notificationTrigger = 'COMPLETION'; notificationRecipient = 'USER_GROUP'
                displaySubjectTemplate = 'Subj (de)'; displayMessageTemplate = 'Msg (de)'   # server-derived mirrors, must not round-trip
                created = 'x'; sharing = [ordered]@{ public = 'rw------' } }
            $r = Get-RowRoundTrip 'programNotificationTemplates' $t
            $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            $r.Back.Contains('displaySubjectTemplate') | Should -BeFalse
            $r.Back.Contains('displayMessageTemplate') | Should -BeFalse
            $r.Back['subjectTemplate'] | Should -BeExactly 'Subj'
        }
    }

    Describe 'List-order preservation (regression for form-layout scramble)' {
        It 'derives the ordered-ref-prop set from the idArrayOrdered class' {
            $expected = @('categories', 'categoryOptions', 'optionGroups', 'dataElements', 'programIndicators', 'trackedEntityAttributes')
            foreach ($p in $expected) { $script:NeoIPCMetadataOrderedRefProps.Contains($p) | Should -BeTrue -Because "'$p' must be order-preserving" }
        }
        It 'the comparator treats categoryCombos.categories as order-SENSITIVE' {
            $mk = { param($order) [ordered]@{ categoryCombos = @([ordered]@{ id = 'ccTestAAA01'; code = 'CC'; name = 'CC'
                            categories = @($order | ForEach-Object { [ordered]@{ id = $_ } }) }) } }
            $a = & $mk @('catBBBBBBB1', 'catAAAAAAA1')
            $b = & $mk @('catAAAAAAA1', 'catBBBBBBB1')
            $diffs = Compare-NeoIPCMetadataCore -Reference $a -Difference $b
            @($diffs).Count | Should -Be 1
            $diffs[0].Kind | Should -BeExactly 'Changed'
        }
        It 'the comparator treats a set-mapped idArray (programs.notificationTemplates) as order-INSENSITIVE' {
            $mk = { param($order) [ordered]@{ programs = @([ordered]@{ id = 'progTESTA01'; code = 'P'; name = 'P'; programType = 'WITH_REGISTRATION'
                            notificationTemplates = @($order | ForEach-Object { [ordered]@{ id = $_ } }) }) } }
            $a = & $mk @('pntBBBBBBB1', 'pntAAAAAAA1')
            $b = & $mk @('pntAAAAAAA1', 'pntBBBBBBB1')
            @(Compare-NeoIPCMetadataCore -Reference $a -Difference $b).Count | Should -Be 0
        }
    }

    Describe 'UID minting and collision' {
        It 'mints a structurally valid DHIS2 UID' {
            $uid = New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_X'
            Test-NeoIPCMetadataUid -Id $uid | Should -BeTrue
            $uid.Length | Should -Be 11
        }
        It 'mints deterministically (same type+key => same uid)' {
            (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_X') |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_X')
        }
        It 'separates the type and key namespaces (NUL join)' {
            (New-NeoIPCMetadataUid -Type 'ab' -NaturalKey 'c') |
                Should -Not -Be (New-NeoIPCMetadataUid -Type 'a' -NaturalKey 'bc')
        }
        It 'preserves a present valid id, mints for an id-less object, and throws on collision' {
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            $de = [ordered]@{ id = 'dataElmnt01'; code = 'NEOIPC_X' }
            (Resolve-NeoIPCMetadataUid -Type 'dataElements' -Object $de -SeenSet $seen) | Should -BeExactly 'dataElmnt01'
            $minted = Resolve-NeoIPCMetadataUid -Type 'dataElements' -Object ([ordered]@{ code = 'NEOIPC_NEW' }) -SeenSet $seen
            Test-NeoIPCMetadataUid -Id $minted | Should -BeTrue
            { Resolve-NeoIPCMetadataUid -Type 'dataElements' -Object ([ordered]@{ id = 'dataElmnt01' }) -SeenSet $seen } |
                Should -Throw '*UID collision*'
        }
    }

    Describe 'Package orchestration (nested-only extract / re-nest / comparator)' {
        BeforeAll {
            $script:pkg0 = [ordered]@{
                programs = @([ordered]@{ id = 'progAAAA001'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'; version = 1
                        onlyEnrollOnce = $true; categoryCombo = [ordered]@{ id = 'catCmbo0001' }; trackedEntityType = [ordered]@{ id = 'tetAAAA0001' }
                        organisationUnits = @(); programStages = @([ordered]@{ id = 'psAAAA00001' }); programSections = @()
                        created = '2020'; sharing = [ordered]@{ public = 'rw------' }
                        programTrackedEntityAttributes = @([ordered]@{ id = 'pteaAAA0001'; program = [ordered]@{ id = 'progAAAA001' }; trackedEntityAttribute = [ordered]@{ id = 'teaAAAA0001' }
                                mandatory = $true; searchable = $false; sortOrder = 1; valueType = 'TEXT'; created = '2020'; displayName = 'proj' }) })
                programStages = @([ordered]@{ id = 'psAAAA00001'; name = 'Adm'; program = [ordered]@{ id = 'progAAAA001' }; sortOrder = 1; repeatable = $false
                        programStageSections = @(); created = '2020'; sharing = [ordered]@{ public = 'rw------' }
                        programStageDataElements = @([ordered]@{ id = 'psdeAAA0001'; programStage = [ordered]@{ id = 'psAAAA00001' }; dataElement = [ordered]@{ id = 'deAAAA00001' }
                                compulsory = $false; sortOrder = 1; displayInReports = $false; created = '2020'; renderType = [ordered]@{ MOBILE = [ordered]@{ type = 'DEFAULT' } } }) })
                trackedEntityTypes = @([ordered]@{ id = 'tetAAAA0001'; name = 'Patient'; created = '2020'; sharing = [ordered]@{ public = 'rw------' }
                        trackedEntityTypeAttributes = @([ordered]@{ id = 'tetaAAA0001'; trackedEntityType = [ordered]@{ id = 'tetAAAA0001' }; trackedEntityAttribute = [ordered]@{ id = 'teaAAAA0001' }
                                mandatory = $true; searchable = $true }) })
                programIndicators = @([ordered]@{ id = 'piAAAAA0001'; name = 'PI'; expression = '#{psAAAA00001.deAAAA00001}'; analyticsType = 'EVENT'; program = [ordered]@{ id = 'progAAAA001' }
                        created = '2020'; sharing = [ordered]@{ public = 'rw------' }
                        analyticsPeriodBoundaries = @([ordered]@{ id = 'apbAAAA0001'; analyticsPeriodBoundaryType = 'BEFORE_END_OF_REPORTING_PERIOD'; boundaryTarget = 'EVENT_DATE'; created = '2020'; access = [ordered]@{ read = $true } }) })
                users = @([ordered]@{ id = 'userAAAA001'; name = 'Anon'; userCredentials = [ordered]@{ username = 'x' } })
            }
        }
        It 'extracts nested-only children to their own row sets and excludes PII types' {
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:pkg0 | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            $rows.Contains('programStageDataElements') | Should -BeTrue
            $rows.Contains('programTrackedEntityAttributes') | Should -BeTrue
            $rows.Contains('analyticsPeriodBoundaries') | Should -BeTrue
            $rows.Contains('users') | Should -BeFalse
            [string]$rows['programStageDataElements'][0]['__fk'] | Should -BeExactly 'psAAAA00001'
        }
        It 're-nests children into parents and never leaks __fk / synthetic fk into output' {
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:pkg0 | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            $pkg  = ConvertTo-NeoIPCMetadataPackage -Rows $rows
            $pkg.Contains('programStageDataElements') | Should -BeFalse
            @($pkg['programStages'][0]['programStageDataElements']).Count | Should -Be 1
            @($pkg['programs'][0]['programTrackedEntityAttributes']).Count | Should -Be 1
            @($pkg['programIndicators'][0]['analyticsPeriodBoundaries']).Count | Should -Be 1
            $pkg['programIndicators'][0]['analyticsPeriodBoundaries'][0].Contains('programIndicator') | Should -BeFalse
            $pkg['programStages'][0]['programStageDataElements'][0].Contains('__fk') | Should -BeFalse
        }
        It 'round-trips the whole package with zero semantic diffs' {
            $work     = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:pkg0 | ConvertTo-Json -Depth 40)
            $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:pkg0 | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            $pkg  = ConvertTo-NeoIPCMetadataPackage -Rows $rows
            @(Compare-NeoIPCMetadataCore -Reference $baseline -Difference $pkg).Count | Should -Be 0
        }
    }

    Describe 'CSV file I/O (RFC 4180 + UTF-8/no-BOM/LF)' {
        It 'round-trips cells with comma, quote, embedded newline, and leading whitespace' {
            $cols = @('id', 'name', 'description')
            $rows = @(
                [ordered]@{ id = 'a1'; name = 'plain'; description = 'has, comma' }
                [ordered]@{ id = 'a2'; name = 'has "quote"'; description = "line1`nline2" }
                [ordered]@{ id = 'a3'; name = ' leading space'; description = '' }
            )
            $csv = Join-Path $TestDrive 'io.csv'
            Write-NeoIPCMetadataCsv -Path $csv -Columns $cols -Rows $rows
            $back = Read-NeoIPCMetadataCsv -Path $csv
            @($back).Count | Should -Be 3
            $back[0]['description'] | Should -BeExactly 'has, comma'
            $back[1]['name'] | Should -BeExactly 'has "quote"'
            $back[1]['description'] | Should -BeExactly "line1`nline2"
            $back[2]['name'] | Should -BeExactly ' leading space'
            $back[2]['description'] | Should -BeExactly ''
        }
        It 'writes UTF-8 with no BOM and LF line endings' {
            $csv = Join-Path $TestDrive 'enc.csv'
            Write-NeoIPCMetadataCsv -Path $csv -Columns @('id', 'name') -Rows @([ordered]@{ id = 'x'; name = 'y' })
            $bytes = [System.IO.File]::ReadAllBytes($csv)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            ($bytes -contains 0x0D) | Should -BeFalse   # no CR
            ($bytes -contains 0x0A) | Should -BeTrue    # has LF
        }
    }

    Describe 'Expression UID extraction (grammar-complete safety-net scanner)' {
        It 'extracts both UIDs from a 2-part data-element ref #{ps.de}' {
            $r = Get-NeoIPCMetadataExpressionRef -Text '#{stageADM001.deUsed00001}'
            @($r | ForEach-Object { $_.Uid }) | Should -Be @('stageADM001', 'deUsed00001')
            $r[0].Form | Should -BeExactly '#'
        }
        It 'extracts all three UIDs from a #{de.coc.aoc} ref' {
            $r = Get-NeoIPCMetadataExpressionRef -Text '#{deUsed00001.catOptCmb01.catOptCmb02}'
            @($r | ForEach-Object { $_.Uid }) | Should -Be @('deUsed00001', 'catOptCmb01', 'catOptCmb02')
        }
        It 'takes only the dataSet UID from R{dataSet.REPORTING_RATE} (2nd part is not a UID)' {
            $r = Get-NeoIPCMetadataExpressionRef -Text 'R{dataSetAAA1.REPORTING_RATE}'
            @($r).Count | Should -Be 1
            $r[0].Uid | Should -BeExactly 'dataSetAAA1'
            $r[0].Form | Should -BeExactly 'R'
        }
        It 'extracts an org-unit-group UID from the OUG{} form' {
            $r = Get-NeoIPCMetadataExpressionRef -Text 'OUG{ougUnres001} == 1'
            @($r).Count | Should -Be 1
            $r[0].Uid | Should -BeExactly 'ougUnres001'
            $r[0].Form | Should -BeExactly 'OUG'
        }
        It 'yields nothing for V{} program variables' {
            @(Get-NeoIPCMetadataExpressionRef -Text 'V{event_date}').Count | Should -Be 0
        }
        It 'does not mis-read the R in VAR{...} as an R{...} data item (lookbehind)' {
            @(Get-NeoIPCMetadataExpressionRef -Text 'VAR{somevariable}').Count | Should -Be 0
        }
        It 'yields nothing for a program-rule NAME ref (#{name with spaces})' {
            @(Get-NeoIPCMetadataExpressionRef -Text '#{NeoIPC BSI Pathogen 1 value}').Count | Should -Be 0
        }
        It 'reads the bare PS_EVENTDATE:<uid> QUIRKS tag' {
            $r = Get-NeoIPCMetadataExpressionRef -Text 'd2:daysBetween(PS_EVENTDATE:stageADM001, V{event_date})'
            @($r).Count | Should -Be 1
            $r[0].Uid | Should -BeExactly 'stageADM001'
            $r[0].Form | Should -BeExactly 'PS_EVENTDATE'
        }
        It 'reads the quoted UID argument of d2:relationshipCount' {
            $r = Get-NeoIPCMetadataExpressionRef -Text "d2:relationshipCount('relTypeAAA1')"
            @($r).Count | Should -Be 1
            $r[0].Uid | Should -BeExactly 'relTypeAAA1'
            $r[0].Form | Should -BeExactly 'relationshipCount'
        }
        It 'returns empty for empty and null input' {
            @(Get-NeoIPCMetadataExpressionRef -Text '').Count | Should -Be 0
            @(Get-NeoIPCMetadataExpressionRef -Text $null).Count | Should -Be 0
        }
        It 'strips a tag: prefix and extracts the tagged category-option UID from #{ps.co:uid}' {
            $r = Get-NeoIPCMetadataExpressionRef -Text '#{stageADM001.co:catOptn0001}'
            @($r | ForEach-Object { $_.Uid }) | Should -Be @('stageADM001', 'catOptn0001')
        }
        It 'extracts a deGroup: data-element-group UID' {
            $r = Get-NeoIPCMetadataExpressionRef -Text '#{deGroup:dataElGrp01}'
            @($r).Count | Should -Be 1
            $r[0].Uid | Should -BeExactly 'dataElGrp01'
        }
        It 'splits an &-joined tagged UID group (#{ps.coGroup:uidA&uidB})' {
            $r = Get-NeoIPCMetadataExpressionRef -Text '#{stageADM001.coGroup:catOGrp0001&catOGrp0002}'
            @($r | ForEach-Object { $_.Uid }) | Should -Be @('stageADM001', 'catOGrp0001', 'catOGrp0002')
        }
        It 'extracts the bare UID arg of orgUnit.program(uid)' {
            $r = Get-NeoIPCMetadataExpressionRef -Text 'orgUnit.program(progOther01) > 0'
            @($r).Count | Should -Be 1
            $r[0].Uid | Should -BeExactly 'progOther01'
            $r[0].Form | Should -BeExactly 'orgUnit.program'
        }
        It 'extracts multiple bare UID args of orgUnit.group(uid, uid)' {
            $r = Get-NeoIPCMetadataExpressionRef -Text 'd2:count(orgUnit.group(ougAAAA0001, ougBBBB0001))'
            @($r | ForEach-Object { $_.Uid }) | Should -Be @('ougAAAA0001', 'ougBBBB0001')
        }
    }

    Describe 'Dependency closure (the prune)' {
        BeforeAll {
            function New-ClosureFixture {
                # A synthetic NEOIPC_CORE program package exercising every closure edge: forward {id} walk,
                # reverse-by-program / -stage, idString (templateUid) following, the expression-UID safety net
                # (in-package miss + non-indexed unresolved), membership recovery (option / data-element groups),
                # ownership (attributes), refs to a non-closure org unit + an excluded user, and an orphan to drop.
                [ordered]@{
                    programs = @([ordered]@{ id = 'progNEOIPC1'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                            trackedEntityType = [ordered]@{ id = 'tetPatient1' }
                            programStages = @([ordered]@{ id = 'stageADM001' })
                            organisationUnits = @([ordered]@{ id = 'ouOverlay01' })   # non-closure org-unit assignment ref
                            programTrackedEntityAttributes = @([ordered]@{ id = 'pteaCore001'; program = [ordered]@{ id = 'progNEOIPC1' }
                                    trackedEntityAttribute = [ordered]@{ id = 'teaPatID001' } }) })
                    programStages = @([ordered]@{ id = 'stageADM001'; name = 'Admission'; program = [ordered]@{ id = 'progNEOIPC1' }
                            programStageDataElements = @([ordered]@{ id = 'psdeAdm0001'; programStage = [ordered]@{ id = 'stageADM001' }
                                    dataElement = [ordered]@{ id = 'deUsed00001' } }) })
                    programRuleVariables = @([ordered]@{ id = 'prvVar00001'; name = 'NeoIPC var'; program = [ordered]@{ id = 'progNEOIPC1' }
                            dataElement = [ordered]@{ id = 'deVarOnly01' } })   # reverse-by-program -> pulls deVarOnly01 (sole path)
                    programStageSections = @([ordered]@{ id = 'pssSec00001'; name = 'Section 1'; programStage = [ordered]@{ id = 'stageADM001' }
                            dataElements = @([ordered]@{ id = 'deSecOnly01' }) })   # reverse-by-stage -> pulls deSecOnly01 (sole path)
                    trackedEntityTypes = @([ordered]@{ id = 'tetPatient1'; name = 'Patient'
                            trackedEntityTypeAttributes = @([ordered]@{ id = 'tetaPat0001'; trackedEntityType = [ordered]@{ id = 'tetPatient1' }
                                    trackedEntityAttribute = [ordered]@{ id = 'teaPatID001' } }) })
                    trackedEntityAttributes = @([ordered]@{ id = 'teaPatID001'; code = 'NEOIPC_PATIENT_ID'; name = 'Patient ID'; valueType = 'TEXT' })
                    dataElements = @(
                        [ordered]@{ id = 'deUsed00001'; code = 'NEOIPC_ADM_X'; name = 'Used'; valueType = 'TEXT'; optionSet = [ordered]@{ id = 'osYesNo0001' } }
                        [ordered]@{ id = 'deExprOnly1'; code = 'NEOIPC_ADM_E'; name = 'ExprOnly'; valueType = 'NUMBER' }   # referenced ONLY in the PI expression
                        [ordered]@{ id = 'deVarOnly01'; code = 'NEOIPC_ADM_V'; name = 'VarOnly'; valueType = 'TEXT' }       # reachable ONLY via the programRuleVariable
                        [ordered]@{ id = 'deSecOnly01'; code = 'NEOIPC_ADM_S'; name = 'SecOnly'; valueType = 'TEXT' }       # reachable ONLY via the programStageSection
                        [ordered]@{ id = 'deOrphan001'; code = 'NEOIPC_ORPHAN'; name = 'Orphan'; valueType = 'TEXT' })      # unreachable -> dropped
                    optionSets = @([ordered]@{ id = 'osYesNo0001'; code = 'NEOIPC_OS'; name = 'OS'; valueType = 'TEXT'; options = @([ordered]@{ id = 'optYes00001' }) })
                    options = @(
                        [ordered]@{ id = 'optYes00001'; code = '1'; name = 'Yes'; optionSet = [ordered]@{ id = 'osYesNo0001' } }
                        [ordered]@{ id = 'optOther001'; code = '1'; name = 'Other'; optionSet = [ordered]@{ id = 'osOther0001' } })   # not in closure
                    optionGroups = @(
                        [ordered]@{ id = 'ogAtc000001'; code = 'NEOIPC_ATC'; name = 'ATC grp'; options = @([ordered]@{ id = 'optYes00001' }) }   # intersects -> recovered
                        [ordered]@{ id = 'ogOther0001'; code = 'OTHER'; name = 'Other grp'; options = @([ordered]@{ id = 'optOther001' }) })       # no intersection -> dropped
                    optionGroupSets = @([ordered]@{ id = 'ogsAware001'; code = 'NEOIPC_AWARE'; name = 'AWaRe'; optionGroups = @([ordered]@{ id = 'ogAtc000001' }) })   # fixpoint after its group
                    dataElementGroups = @([ordered]@{ id = 'degGroup001'; code = 'NEOIPC_DEG'; name = 'DE grp'; dataElements = @([ordered]@{ id = 'deUsed00001' }) })  # intersects -> recovered
                    programRules = @([ordered]@{ id = 'prRule00001'; name = 'NeoIPC rule'; condition = 'OUG{ougUnres001} == 1'; priority = 1
                            program = [ordered]@{ id = 'progNEOIPC1' }                                  # reached via reverse-by-program
                            programRuleActions = @([ordered]@{ id = 'praAction01' }, [ordered]@{ id = 'praSend0001' }, [ordered]@{ id = 'praSendBad1' }) })
                    programRuleActions = @(
                        [ordered]@{ id = 'praAction01'; programRuleActionType = 'ASSIGN'; data = '#{stageADM001.deUsed00001}'
                            programRule = [ordered]@{ id = 'prRule00001' }; dataElement = [ordered]@{ id = 'deUsed00001' } }
                        [ordered]@{ id = 'praSend0001'; programRuleActionType = 'SENDMESSAGE'; templateUid = 'pntTmpl0001'        # idString -> in package
                            programRule = [ordered]@{ id = 'prRule00001' } }
                        [ordered]@{ id = 'praSendBad1'; programRuleActionType = 'SENDMESSAGE'; templateUid = 'pntMissing1'        # idString -> absent (dangling)
                            programRule = [ordered]@{ id = 'prRule00001' } })
                    programNotificationTemplates = @([ordered]@{ id = 'pntTmpl0001'; name = 'Tmpl'; notificationTrigger = 'COMPLETION'; notificationRecipient = 'USER_GROUP' })
                    programIndicators = @([ordered]@{ id = 'piExpr00001'; name = 'PI'; analyticsType = 'EVENT'
                            program = [ordered]@{ id = 'progNEOIPC1' }                                  # reverse-by-program
                            expression = '#{stageADM001.deExprOnly1}' })                                # deExprOnly1 reachable ONLY here
                    validationRules = @(
                        [ordered]@{ id = 'valRuleIn01'; name = 'Refs closure'; operator = 'not_equal_to'; periodType = 'Monthly'
                            leftSide = [ordered]@{ expression = 'I{piExpr00001}'; missingValueStrategy = 'NEVER_SKIP' }       # references the included PI -> recovered
                            rightSide = [ordered]@{ expression = 'V{zero}'; missingValueStrategy = 'NEVER_SKIP' } }
                        [ordered]@{ id = 'valRuleOut1'; name = 'Refs nothing'; operator = 'not_equal_to'; periodType = 'Monthly'
                            leftSide = [ordered]@{ expression = '#{otherStage1.otherDe0001}'; missingValueStrategy = 'NEVER_SKIP' }   # references nothing in closure -> dropped
                            rightSide = [ordered]@{ expression = 'V{zero}'; missingValueStrategy = 'NEVER_SKIP' } })
                    attributes = @([ordered]@{ id = 'attrCustom1'; code = 'IsTestunit'; name = 'IsTestunit'; valueType = 'BOOLEAN' })   # ownership -> kept wholesale
                    organisationUnits = @([ordered]@{ id = 'ouOverlay01'; name = 'Overlay OU' })   # non-closure type -> never indexed, assignment ref resolves to nothing
                    users = @([ordered]@{ id = 'userPII0001'; name = 'Anon' })   # excluded type
                }
            }
            function Get-Closure { Get-NeoIPCMetadataClosure -Package (New-ClosureFixture) }
        }

        It 'keeps the seed and everything structurally reachable; drops the orphan' {
            $r = Get-Closure
            $r.SeedId | Should -BeExactly 'progNEOIPC1'
            foreach ($id in @('progNEOIPC1', 'stageADM001', 'tetPatient1', 'teaPatID001', 'deUsed00001')) {
                $r.IncludedIds.Contains($id) | Should -BeTrue -Because "$id is reachable"
            }
            $r.IncludedIds.Contains('deOrphan001') | Should -BeFalse
            @($r.Package['dataElements'] | ForEach-Object { $_['id'] }) | Should -Not -Contain 'deOrphan001'
            @($r.Package['dataElements'] | ForEach-Object { $_['id'] }) | Should -Contain 'deUsed00001'
        }
        It 'reaches program rules / indicators by the reverse-by-program edge' {
            $r = Get-Closure
            $r.IncludedIds.Contains('prRule00001') | Should -BeTrue
            $r.IncludedIds.Contains('piExpr00001') | Should -BeTrue
            $r.IncludedIds.Contains('praAction01') | Should -BeTrue   # via the rule's forward {id} walk
        }
        It 'follows a SENDMESSAGE templateUid (idString edge) into the closure' {
            $r = Get-Closure
            $r.IncludedIds.Contains('pntTmpl0001') | Should -BeTrue
            @($r.Package['programNotificationTemplates'] | ForEach-Object { $_['id'] }) | Should -Contain 'pntTmpl0001'
        }
        It 'reports a dangling templateUid (idString target absent) without dropping it silently' {
            $dangling = @((Get-Closure).DanglingStringRefs)
            $dangling.Count | Should -Be 1
            $dangling[0].Uid | Should -BeExactly 'pntMissing1'
            $dangling[0].Field | Should -BeExactly 'templateUid'
        }
        It 'rescues a data element referenced ONLY in an expression (the DHIS2-export bug) and reports it' {
            $r = Get-Closure
            $r.IncludedIds.Contains('deExprOnly1') | Should -BeTrue -Because 'the safety net must pull it in'
            @($r.Package['dataElements'] | ForEach-Object { $_['id'] }) | Should -Contain 'deExprOnly1'
            $misses = @($r.ExpressionMisses)
            $misses.Count | Should -Be 1
            $misses[0].Uid | Should -BeExactly 'deExprOnly1'
            $misses[0].TargetType | Should -BeExactly 'dataElements'
        }
        It 'reports an expression ref to a non-indexed target as unresolved (overlay / unmapped)' {
            $r = Get-Closure
            $unres = @($r.ExpressionUnresolved)
            $unres.Count | Should -Be 1
            $unres[0].Uid | Should -BeExactly 'ougUnres001'
            $r.IncludedIds.Contains('ougUnres001') | Should -BeFalse
        }
        It 'recovers grouping objects whose members intersect the closure (membership, with fixpoint)' {
            $r = Get-Closure
            $r.IncludedIds.Contains('ogAtc000001') | Should -BeTrue -Because 'its option is in the closure'
            $r.IncludedIds.Contains('ogsAware001') | Should -BeTrue -Because 'fixpoint: picks up after its option group'
            $r.IncludedIds.Contains('degGroup001') | Should -BeTrue -Because 'its data element is in the closure'
            $r.IncludedIds.Contains('ogOther0001') | Should -BeFalse -Because 'no member intersects the closure'
        }
        It 'recovers a grouping object reachable only via another recovered group drained member (combined fixpoint)' {
            # optionGroup A intersects the closure (optYesInClo) AND carries optCrossLnk, which is NOT otherwise
            # in the closure (the optionSet lists only optYesInClo). optionGroup B's only member is optCrossLnk.
            # B is reachable only after A is recovered AND drained -> needs the membership+drain combined fixpoint.
            $pkg = [ordered]@{
                programs = @([ordered]@{ id = 'progNEOIPC1'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                        programStages = @([ordered]@{ id = 'stageADM001' }) })
                programStages = @([ordered]@{ id = 'stageADM001'; name = 'Adm'; program = [ordered]@{ id = 'progNEOIPC1' }
                        programStageDataElements = @([ordered]@{ id = 'psdeAdm0001'; programStage = [ordered]@{ id = 'stageADM001' }
                                dataElement = [ordered]@{ id = 'deUsed00001' } }) })
                dataElements = @([ordered]@{ id = 'deUsed00001'; code = 'NEOIPC_X'; name = 'X'; valueType = 'TEXT'; optionSet = [ordered]@{ id = 'osYesNo0001' } })
                optionSets = @([ordered]@{ id = 'osYesNo0001'; code = 'OS'; name = 'OS'; valueType = 'TEXT'; options = @([ordered]@{ id = 'optYesInClo' }) })
                options = @(
                    [ordered]@{ id = 'optYesInClo'; code = '1'; name = 'In'; optionSet = [ordered]@{ id = 'osYesNo0001' } }
                    [ordered]@{ id = 'optCrossLnk'; code = '2'; name = 'Cross'; optionSet = [ordered]@{ id = 'osYesNo0001' } })
                optionGroups = @(
                    [ordered]@{ id = 'ogAlpha0001'; code = 'A'; name = 'A'; options = @([ordered]@{ id = 'optYesInClo' }, [ordered]@{ id = 'optCrossLnk' }) }
                    [ordered]@{ id = 'ogBeta00001'; code = 'B'; name = 'B'; options = @([ordered]@{ id = 'optCrossLnk' }) }) }
            $r = Get-NeoIPCMetadataClosure -Package $pkg
            $r.IncludedIds.Contains('ogAlpha0001') | Should -BeTrue
            $r.IncludedIds.Contains('ogBeta00001') | Should -BeTrue -Because 'recovered only after A is drained (combined fixpoint)'
        }
        It 'keeps custom attributes wholesale (ownership) even when unreferenced' {
            $r = Get-Closure
            $r.IncludedIds.Contains('attrCustom1') | Should -BeTrue
            @($r.Package['attributes'] | ForEach-Object { $_['id'] }) | Should -Contain 'attrCustom1'
        }
        It 'recovers a validation rule whose expression references the closure (expression-source recovery)' {
            $r = Get-Closure
            $r.IncludedIds.Contains('valRuleIn01') | Should -BeTrue -Because 'its leftSide references the included program indicator'
            @($r.Package['validationRules'] | ForEach-Object { $_['id'] }) | Should -Contain 'valRuleIn01'
        }
        It 'drops a validation rule that references nothing in the closure' {
            $r = Get-Closure
            $r.IncludedIds.Contains('valRuleOut1') | Should -BeFalse
            @($r.Package['validationRules'] | ForEach-Object { $_['id'] }) | Should -Not -Contain 'valRuleOut1'
        }
        It 'never indexes or includes excluded or non-closure types, and omits them from the pruned package' {
            $r = Get-Closure
            $r.IncludedIds.Contains('ouOverlay01') | Should -BeFalse
            $r.IncludedIds.Contains('userPII0001') | Should -BeFalse
            $r.Package.Contains('users') | Should -BeFalse
            $r.Package.Contains('organisationUnits') | Should -BeFalse
            @($r.StructuredUnresolved | ForEach-Object { $_.Uid }) | Should -Not -Contain 'ouOverlay01'   # non-closure type, not a dropped dependency
        }
        It 'reports a ref to a present-but-unmapped top-level object instead of dropping it silently' {
            # A data element references a top-level legendSet; legendSets is present in the package but is not a
            # mapped/excluded/deferred type, so the closure drops it -> must be flagged, not dropped silently.
            $pkg = [ordered]@{
                programs = @([ordered]@{ id = 'progNEOIPC1'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                        programStages = @([ordered]@{ id = 'stageADM001' }) })
                programStages = @([ordered]@{ id = 'stageADM001'; name = 'Adm'; program = [ordered]@{ id = 'progNEOIPC1' }
                        programStageDataElements = @([ordered]@{ id = 'psdeAdm0001'; programStage = [ordered]@{ id = 'stageADM001' }
                                dataElement = [ordered]@{ id = 'deUsed00001' } }) })
                dataElements = @([ordered]@{ id = 'deUsed00001'; code = 'NEOIPC_X'; name = 'X'; valueType = 'TEXT'
                        legendSets = @([ordered]@{ id = 'lgndSet0001' }) })
                legendSets = @([ordered]@{ id = 'lgndSet0001'; name = 'Legend' }) }   # present top-level, unmapped -> dropped, flagged
            $r = Get-NeoIPCMetadataClosure -Package $pkg
            @($r.StructuredUnresolved | ForEach-Object { $_.Uid }) | Should -Contain 'lgndSet0001'
            $r.IncludedIds.Contains('lgndSet0001') | Should -BeFalse
        }
        It 'reaches a programRuleVariable (reverse-by-program) and its data element (sole path)' {
            $r = Get-Closure
            $r.IncludedIds.Contains('prvVar00001') | Should -BeTrue
            $r.IncludedIds.Contains('deVarOnly01') | Should -BeTrue -Because 'reachable only through the variable'
        }
        It 'reaches a programStageSection (reverse-by-stage) and its data element (sole path)' {
            $r = Get-Closure
            $r.IncludedIds.Contains('pssSec00001') | Should -BeTrue
            $r.IncludedIds.Contains('deSecOnly01') | Should -BeTrue -Because 'reachable only through the section'
        }
        It 'rescues a SECOND-ORDER expression-only reference to a fixpoint (safety net is not single-pass)' {
            # piExpr00001.expression -> deFirstOne1 (1st-order miss); deFirstOne1.description -> deSecond001
            # (2nd-order, reachable ONLY via the rescued object's own field). A single-pass safety net drops it.
            $pkg = [ordered]@{
                programs = @([ordered]@{ id = 'progNEOIPC1'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                        programStages = @([ordered]@{ id = 'stageADM001' }) })
                programStages = @([ordered]@{ id = 'stageADM001'; name = 'Adm'; program = [ordered]@{ id = 'progNEOIPC1' } })
                programIndicators = @([ordered]@{ id = 'piExpr00001'; name = 'PI'; analyticsType = 'EVENT'
                        program = [ordered]@{ id = 'progNEOIPC1' }; expression = '#{stageADM001.deFirstOne1}' })
                dataElements = @(
                    [ordered]@{ id = 'deFirstOne1'; code = 'NEOIPC_F'; name = 'First'; valueType = 'NUMBER'; description = '#{stageADM001.deSecond001}' }
                    [ordered]@{ id = 'deSecond001'; code = 'NEOIPC_S'; name = 'Second'; valueType = 'TEXT' }) }
            $r = Get-NeoIPCMetadataClosure -Package $pkg
            $r.IncludedIds.Contains('deFirstOne1') | Should -BeTrue -Because 'first-order rescue'
            $r.IncludedIds.Contains('deSecond001') | Should -BeTrue -Because 'second-order rescue requires the safety-net fixpoint'
            @($r.ExpressionMisses | ForEach-Object { $_.Uid }) | Should -Contain 'deSecond001'
        }
        It 'throws a clear error when the seed code is not present' {
            { Get-NeoIPCMetadataClosure -Package (New-ClosureFixture) -SeedCode 'NOT_A_PROGRAM' } |
                Should -Throw '*Closure seed not found*'
        }
        It 'is deterministic: the pruned package serializes identically across runs' {
            # -WarningAction SilentlyContinue: the fixture deliberately carries a dangling templateUid and an
            # expression-only data element, so the cmdlet's (expected) diagnostic warnings are suppressed here.
            $a = Select-NeoIPCMetadataClosure -Package (New-ClosureFixture) -Compress -WarningAction SilentlyContinue
            $b = Select-NeoIPCMetadataClosure -Package (New-ClosureFixture) -Compress -WarningAction SilentlyContinue
            $a | Should -BeExactly $b
        }
    }

    Describe 'Targeted package merge (full base + supplement templates)' {
        BeforeAll {
            function New-MergeBase {
                [ordered]@{
                    dataElements = @([ordered]@{ id = 'deBase00001'; code = 'BASE_DE'; name = 'Base DE' })
                    programStages = @([ordered]@{ id = 'stageBase01'; name = 'Stage'
                            programStageDataElements = @([ordered]@{ id = 'psdeBase001'; dataElement = [ordered]@{ id = 'deBase00001' }
                                    compulsory = $false; allowFutureDate = $false }) })   # rich nested PSDE
                }
            }
            function New-MergeSupplement {
                [ordered]@{
                    dataElements = @([ordered]@{ id = 'deSuppl0001'; code = 'SUPPL_DE'; name = 'Suppl DE' })   # MUST NOT replace base
                    programStageDataElements = @([ordered]@{ id = 'psdeBase001'; dataElement = [ordered]@{ id = 'deBase00001' } })   # flattened, lower detail -> NOT taken
                    programNotificationTemplates = @(
                        [ordered]@{ id = 'pntTmpl0001'; name = 'T1'; notificationTrigger = 'COMPLETION' }
                        [ordered]@{ id = 'pntTmpl0002'; name = 'T2'; notificationTrigger = 'ENROLLMENT' })
                }
            }
        }
        It 'splices the named type from the supplement and leaves every base type intact' {
            $m = Merge-NeoIPCMetadataPackage -Base (New-MergeBase) -Supplement (New-MergeSupplement)
            @($m['programNotificationTemplates']).Count | Should -Be 2
            @($m['dataElements'] | ForEach-Object { $_['id'] }) | Should -Be @('deBase00001')   # base, not supplement
        }
        It 'does not take the supplement flattened nested-only types' {
            $m = Merge-NeoIPCMetadataPackage -Base (New-MergeBase) -Supplement (New-MergeSupplement)
            $m.Contains('programStageDataElements') | Should -BeFalse
            @($m['programStages'][0]['programStageDataElements']).Count | Should -Be 1
        }
        It 'warns and changes nothing when the supplement lacks the requested type' {
            $m = Merge-NeoIPCMetadataPackage -Base (New-MergeBase) -Supplement ([ordered]@{ dataElements = @() }) -WarningVariable wv -WarningAction SilentlyContinue
            $wv | Should -Not -BeNullOrEmpty
            $m.Contains('programNotificationTemplates') | Should -BeFalse
        }
        It 'does not mutate the input base package' {
            $base = New-MergeBase
            $null = Merge-NeoIPCMetadataPackage -Base $base -Supplement (New-MergeSupplement)
            $base.Contains('programNotificationTemplates') | Should -BeFalse
        }
    }

    Describe 'Expression canonicalization (name-arg d2-functions -> quoted name)' {
        It 'rewrites a #{name} program-rule-variable arg to the quoted form' {
            ConvertTo-NeoIPCCanonicalExpression -Expression 'd2:hasValue(#{NeoIPC BSI Pathogen 1 value})' |
                Should -BeExactly "d2:hasValue('NeoIPC BSI Pathogen 1 value')"
        }
        It 'rewrites the A{}, C{} and V{} prefixes too (all of [A#CV])' {
            ConvertTo-NeoIPCCanonicalExpression -Expression 'd2:hasValue(A{Gestational age})' | Should -BeExactly "d2:hasValue('Gestational age')"
            ConvertTo-NeoIPCCanonicalExpression -Expression 'd2:count(C{some const})' | Should -BeExactly "d2:count('some const')"
            ConvertTo-NeoIPCCanonicalExpression -Expression 'd2:countIfZeroPos(V{event_count})' | Should -BeExactly "d2:countIfZeroPos('event_count')"
        }
        It 'preserves trailing arguments of multi-arg functions (matches only the first arg)' {
            ConvertTo-NeoIPCCanonicalExpression -Expression "d2:countIfValue(#{my var}, 'POS')" |
                Should -BeExactly "d2:countIfValue('my var', 'POS')"
        }
        It 'consumes leading spaces after the paren but leaves the trailing space (engine-faithful)' {
            ConvertTo-NeoIPCCanonicalExpression -Expression 'd2:hasValue( #{x name} )' | Should -BeExactly "d2:hasValue('x name' )"
        }
        It 'rewrites every occurrence in a multi-call expression' {
            ConvertTo-NeoIPCCanonicalExpression -Expression 'd2:hasValue(#{a}) || d2:hasValue(#{b})' |
                Should -BeExactly "d2:hasValue('a') || d2:hasValue('b')"
        }
        It 'does NOT touch a function outside the avoid-replacement set' {
            $e = 'd2:daysBetween(#{x}, V{event_date})'
            ConvertTo-NeoIPCCanonicalExpression -Expression $e | Should -BeExactly $e
        }
        It 'does NOT touch a #{var} reference outside a d2-function call' {
            $e = '#{x} > 0 && #{y} == 1'
            ConvertTo-NeoIPCCanonicalExpression -Expression $e | Should -BeExactly $e
        }
        It 'is idempotent on an already-canonical expression' {
            $e = "d2:hasValue('NeoIPC var') && #{NeoIPC var} != 1"
            ConvertTo-NeoIPCCanonicalExpression -Expression $e | Should -BeExactly $e
        }
    }

    Describe 'Precedence-ambiguity detector (group-scoped)' {
        It 'flags && and || mixed directly in one group' {
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression 'a && b || c' | Should -BeTrue
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression '#{x} != 0 && (#{x} < 161) || (#{x} >= 310)' | Should -BeTrue
        }
        It 'does NOT flag sibling groups at the same depth ((a&&b) || (c&&d))' {
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression '( a && b ) || ( c && d )' | Should -BeFalse
        }
        It 'does NOT flag a fully grouped sub-expression (a && (b || c))' {
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression 'a && (b || c)' | Should -BeFalse
        }
        It 'does NOT flag a single-operator expression' {
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression 'a && b && c' | Should -BeFalse
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression 'a || b || c' | Should -BeFalse
        }
        It 'ignores operators inside quoted strings and {curly} names' {
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression "d2:hasValue('a || b') && x && y" | Should -BeFalse
            Test-NeoIPCMetadataPrecedenceAmbiguity -Expression '#{name || other} && x && z' | Should -BeFalse
        }
    }

    Describe 'Expression linting (the three NeoIPC issue classes)' {
        It 'flags MixedBooleanPrecedence (Warning)' {
            $f = @(Get-NeoIPCMetadataExpressionFinding -Expression 'a && b || c' -ObjectType 'programRules' -ObjectId 'prX' -Field 'condition')
            ($f | Where-Object Rule -eq 'MixedBooleanPrecedence').Severity | Should -BeExactly 'Warning'
        }
        It 'flags NegativeSentinelComparison for == -1 and != -1 only' {
            @(Get-NeoIPCMetadataExpressionFinding -Expression '#{x} == -1' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 1
            @(Get-NeoIPCMetadataExpressionFinding -Expression '#{x} != -1' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 1
        }
        It 'does NOT flag a comparison against -10, -1.5, or -1e5 (sentinel is exactly -1)' {
            @(Get-NeoIPCMetadataExpressionFinding -Expression '#{x} == -10' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 0
            @(Get-NeoIPCMetadataExpressionFinding -Expression '#{x} == -1.5' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 0
            @(Get-NeoIPCMetadataExpressionFinding -Expression '#{x} == -1e5' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 0
        }
        It 'does NOT flag a non-equality comparison against -1 (>= -1 is a legitimate range check)' {
            @(Get-NeoIPCMetadataExpressionFinding -Expression '#{x} >= -1' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 0
        }
        It 'flags LegacyD2FunctionArgForm (Info) and clears once canonicalized' {
            @(Get-NeoIPCMetadataExpressionFinding -Expression 'd2:hasValue(#{x})' -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'LegacyD2FunctionArgForm').Count | Should -Be 1
            @(Get-NeoIPCMetadataExpressionFinding -Expression "d2:hasValue('x')" -ObjectType 'programRules' -ObjectId 'a' -Field 'condition' | Where-Object Rule -eq 'LegacyD2FunctionArgForm').Count | Should -Be 0
        }
        It 'does NOT flag the legacy d2-arg form in a server-side program-indicator / validation-rule field' {
            # In a server-side expression d2:count(#{ps.de}) is a valid data-item reference, not a legacy form;
            # the rule (and the canonicalizer) apply ONLY to the Tracker-Capture-evaluated fields.
            @(Get-NeoIPCMetadataExpressionFinding -Expression 'd2:count(#{stageADM001.deUsed00001})' -ObjectType 'programIndicators' -Field 'expression' | Where-Object Rule -eq 'LegacyD2FunctionArgForm').Count | Should -Be 0
            @(Get-NeoIPCMetadataExpressionFinding -Expression 'd2:count(#{stageADM001.deUsed00001})' -ObjectType 'validationRules' -Field 'leftSide.expression' | Where-Object Rule -eq 'LegacyD2FunctionArgForm').Count | Should -Be 0
        }

        Context 'Test-NeoIPCMetadataExpression over a package' {
            BeforeAll {
                $script:lintPkg = [ordered]@{
                    programRules = @(
                        [ordered]@{ id = 'prPrec00001'; name = 'Prec'; condition = 'a && b || c' }
                        [ordered]@{ id = 'prLegacy001'; name = 'Legacy'; condition = 'd2:hasValue(#{x}) && #{x} != 1' }
                        [ordered]@{ id = 'prClean0001'; name = 'Clean'; condition = "d2:hasValue('x') && #{x} != 1" })
                    programRuleActions = @([ordered]@{ id = 'praSent0001'; programRuleActionType = 'SHOWERROR'; data = '#{y} == -1' })
                    validationRules = @([ordered]@{ id = 'vrSent00001'; name = 'VR'; operator = 'not_equal_to'
                            leftSide = [ordered]@{ expression = '#{a.b} != -1' }; rightSide = [ordered]@{ expression = 'V{zero}' } })
                }
            }
            It 'returns only Warning-level findings by default' {
                $f = @(Test-NeoIPCMetadataExpression -Package $script:lintPkg)
                $f.Count | Should -Be 3
                ($f | ForEach-Object Rule | Sort-Object -Unique) | Should -Be @('MixedBooleanPrecedence', 'NegativeSentinelComparison')
                ($f | Where-Object Rule -eq 'NegativeSentinelComparison').Count | Should -Be 2
            }
            It 'includes the Info style findings at -MinimumSeverity Info' {
                $f = @(Test-NeoIPCMetadataExpression -Package $script:lintPkg -MinimumSeverity Info)
                ($f | Where-Object Rule -eq 'LegacyD2FunctionArgForm').Count | Should -Be 1
            }
            It 'scans the validation-rule leftSide expression and tags Field/ObjectId' {
                $vr = @(Test-NeoIPCMetadataExpression -Package $script:lintPkg | Where-Object ObjectId -eq 'vrSent00001')
                $vr.Count | Should -Be 1
                $vr[0].Field | Should -BeExactly 'leftSide.expression'
            }
            It 'throws on a non-dictionary package instead of silently reporting clean' {
                # A PSCustomObject (ConvertFrom-Json without -AsHashtable) would index to $null per type and
                # scan empty — a lint tool must fail loudly, not pass dirty input.
                $pso = [pscustomobject]@{ programRules = @([pscustomobject]@{ id = 'r1'; name = 'R'; condition = 'a && b || c' }) }
                { Test-NeoIPCMetadataExpression -Package $pso } | Should -Throw '*dictionary/hashtable*'
            }
        }
    }

    Describe 'Update-NeoIPCMetadata (source transforms)' {
        BeforeAll {
            function New-TransformFixture {
                [ordered]@{
                    programs = @([ordered]@{ id = 'progAAAA001'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                            organisationUnits = @([ordered]@{ id = 'ouOverlay01' })   # absent overlay ref -> must keep its UID
                            programStages = @([ordered]@{ id = 'psAAAA00001' }) })
                    programStages = @([ordered]@{ id = 'psAAAA00001'; name = 'Adm'; program = [ordered]@{ id = 'progAAAA001' }
                            programStageDataElements = @([ordered]@{ id = 'psdeAAA0001'; programStage = [ordered]@{ id = 'psAAAA00001' }
                                    dataElement = [ordered]@{ id = 'deAAAA00001' } }) })
                    dataElements = @([ordered]@{ id = 'deAAAA00001'; code = 'NEOIPC_X'; name = 'X'; valueType = 'TEXT' })
                    programRules = @([ordered]@{ id = 'prAAAA00001'; name = 'R'; condition = 'd2:hasValue(#{NeoIPC var}) && #{NeoIPC var} != 1'
                            program = [ordered]@{ id = 'progAAAA001' } })
                    programIndicators = @([ordered]@{ id = 'piAAAAA0001'; name = 'PI'; analyticsType = 'EVENT'; program = [ordered]@{ id = 'progAAAA001' }
                            expression = '#{psAAAA00001.deAAAA00001} > 0' })
                }
            }
        }
        It 'throws when no transform is requested' {
            { Update-NeoIPCMetadata -Package (New-TransformFixture) } | Should -Throw '*at least one transform*'
        }
        It 'canonicalizes program-rule conditions and counts the changed slots' {
            $r = Update-NeoIPCMetadata -Package (New-TransformFixture) -Canonicalize -PassThru
            $r.CanonicalizedSlots | Should -Be 1
            $r.Package['programRules'][0]['condition'] | Should -BeExactly "d2:hasValue('NeoIPC var') && #{NeoIPC var} != 1"
        }
        It 'does NOT canonicalize a server-side program-indicator expression (only Tracker-Capture fields)' {
            $pkg = [ordered]@{
                programRules = @([ordered]@{ id = 'prAAAA00001'; name = 'R'; condition = 'd2:hasValue(#{NeoIPC var})' })
                programIndicators = @([ordered]@{ id = 'piAAAAA0001'; name = 'PI'; analyticsType = 'EVENT'
                        expression = 'd2:count(#{stageADM001.deUsed00001}) > 0' }) }
            $r = Update-NeoIPCMetadata -Package $pkg -Canonicalize -PassThru
            $r.CanonicalizedSlots | Should -Be 1   # only the program-rule condition
            $r.Package['programRules'][0]['condition'] | Should -BeExactly "d2:hasValue('NeoIPC var')"
            $r.Package['programIndicators'][0]['expression'] | Should -BeExactly 'd2:count(#{stageADM001.deUsed00001}) > 0'   # the data-item ref is untouched
        }
        It 'does not mutate the input package (transforms a clone)' {
            $pkg = New-TransformFixture
            $null = Update-NeoIPCMetadata -Package $pkg -Canonicalize -RegenerateUids
            $pkg['programRules'][0]['condition'] | Should -BeExactly 'd2:hasValue(#{NeoIPC var}) && #{NeoIPC var} != 1'
            $pkg['programs'][0]['id'] | Should -BeExactly 'progAAAA001'
        }

        Context 'UID regeneration' {
            It 'builds a bijective map over OWNED ids only (top-level + nested children, not overlay refs)' {
                $map = New-NeoIPCMetadataUidMap -Package (New-TransformFixture)
                $map.Count | Should -Be 6      # program, stage, PSDE child, dataElement, programRule, programIndicator
                $map.ContainsKey('psdeAAA0001') | Should -BeTrue -Because 'a declared nested-only child is owned'
                $map.ContainsKey('ouOverlay01') | Should -BeFalse -Because 'an absent overlay ref is not owned'
                ($map.Values | Sort-Object -Unique).Count | Should -Be 6
                foreach ($v in $map.Values) { Test-NeoIPCMetadataUid -Id $v | Should -BeTrue }
            }
            It 'rewrites every owned id and updates structured AND expression-embedded references' {
                $r = Update-NeoIPCMetadata -Package (New-TransformFixture) -RegenerateUids -PassThru
                $p = $r.Package
                $r.RegeneratedUids | Should -Be 6
                # owned ids changed
                $p['programs'][0]['id'] | Should -Not -BeExactly 'progAAAA001'
                # structured ref updated to the new program id
                $p['programStages'][0]['program']['id'] | Should -BeExactly $r.UidMap['progAAAA001']
                $p['programStages'][0]['programStageDataElements'][0]['dataElement']['id'] | Should -BeExactly $r.UidMap['deAAAA00001']
                # expression-embedded UIDs rewritten to the new stage/dataElement ids
                $p['programIndicators'][0]['expression'] | Should -BeExactly ("#{{{0}.{1}}} > 0" -f $r.UidMap['psAAAA00001'], $r.UidMap['deAAAA00001'])
            }
            It 'leaves an absent overlay reference (org unit) untouched' {
                $r = Update-NeoIPCMetadata -Package (New-TransformFixture) -RegenerateUids -PassThru
                $r.Package['programs'][0]['organisationUnits'][0]['id'] | Should -BeExactly 'ouOverlay01'
            }
            It 'does not rewrite a UID-shaped substring embedded in a snake_case code' {
                # The code carries a token that IS an owned UID but glued into a snake_case string; the
                # '_' boundary must prevent the token replace from corrupting it.
                $owned = New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'boundary-probe'
                $pkg = [ordered]@{
                    programs = @([ordered]@{ id = 'progAAAA001'; code = 'NEOIPC_CORE'; name = 'C'; programType = 'WITH_REGISTRATION' })
                    dataElements = @([ordered]@{ id = $owned; code = ("PREFIX_{0}_SUFFIX" -f $owned); name = 'X'; valueType = 'TEXT' }) }
                $r = Update-NeoIPCMetadata -Package $pkg -RegenerateUids -PassThru
                $r.Package['dataElements'][0]['id'] | Should -BeExactly $r.UidMap[$owned]   # bare id field IS rewritten
                $r.Package['dataElements'][0]['code'] | Should -BeExactly ("PREFIX_{0}_SUFFIX" -f $owned)   # embedded-in-snake_case is NOT
            }
            It 'is deterministic across runs (pure mint salted by old id)' {
                $a = New-NeoIPCMetadataUidMap -Package (New-TransformFixture)
                $b = New-NeoIPCMetadataUidMap -Package (New-TransformFixture)
                foreach ($k in $a.Keys) { $a[$k] | Should -BeExactly $b[$k] }
            }
            It 'never re-mints excluded / non-closure / unmapped ids or the system default UIDs' {
                # When a full export carries the non-closure (org-unit) / PII / server-generated collections
                # top-level plus the system default categoryCombo (referenced by every dataElement), those must
                # keep their UIDs so the package still binds on import. bjDvmb4bfuf is a default-UID member.
                $pkg = [ordered]@{
                    programs = @([ordered]@{ id = 'progAAAA001'; code = 'NEOIPC_CORE'; name = 'C'; programType = 'WITH_REGISTRATION' })
                    dataElements = @([ordered]@{ id = 'deAAAA00001'; code = 'NEOIPC_X'; name = 'X'; valueType = 'TEXT'; categoryCombo = [ordered]@{ id = 'bjDvmb4bfuf' } })
                    categoryCombos = @([ordered]@{ id = 'bjDvmb4bfuf'; code = 'default'; name = 'default'; dataDimensionType = 'DISAGGREGATION' })
                    organisationUnits = @([ordered]@{ id = 'ouRealOrg01'; name = 'Real OU' })          # non-closure (org-unit family)
                    users = @([ordered]@{ id = 'userReal001'; name = 'Acct' })                          # excluded PII
                    categoryOptionCombos = @([ordered]@{ id = 'cocReal0001'; name = 'COC' })            # excluded server-generated
                    legendSets = @([ordered]@{ id = 'lgndSet0001'; name = 'L' }) }                      # unmapped top-level
                $r = Update-NeoIPCMetadata -Package $pkg -RegenerateUids -PassThru
                foreach ($keep in 'bjDvmb4bfuf', 'ouRealOrg01', 'userReal001', 'cocReal0001', 'lgndSet0001') {
                    $r.UidMap.ContainsKey($keep) | Should -BeFalse -Because "$keep must keep its UID for import binding"
                }
                $r.UidMap.ContainsKey('deAAAA00001') | Should -BeTrue -Because 'a mapped, non-default object IS owned'
                $r.UidMap.ContainsKey('progAAAA001') | Should -BeTrue
                $r.Package['dataElements'][0]['categoryCombo']['id'] | Should -BeExactly 'bjDvmb4bfuf'   # default ref preserved
                $r.Package['categoryCombos'][0]['id'] | Should -BeExactly 'bjDvmb4bfuf'
                $r.Package['organisationUnits'][0]['id'] | Should -BeExactly 'ouRealOrg01'
            }
        }
    }

    Describe 'Org-unit family (non-closure coverage)' {
        It 'round-trips an organisationUnit: ISO open/closed dates, parent/image id refs, derived path stripped, null PII dropped' {
            $ou = [ordered]@{ id = 'ouDept00001'; name = 'Department'; shortName = 'Dept'
                openingDate = '2020-01-01T00:00:00'; closedDate = '2025-06-15T00:00:00'; level = 4   # closedDate: a closed dept
                parent = [ordered]@{ id = 'ouHosp00001' }; image = [ordered]@{ id = 'fileRes0001' }
                path = '/ouRoot00001/ouHosp00001/ouDept00001'                               # server-derived, stripped
                address = $null; code = $null; comment = $null; geometry = $null            # anonymiser nulls, dropped
                created = '2020-01-01'; lastUpdated = '2021-01-01'; translations = @() }
            $r = Get-RowRoundTrip 'organisationUnits' $ou
            $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            $r.Row['openingDate'] | Should -BeExactly '2020-01-01T00:00:00'   # ISO preserved, NOT culture-formatted
            $r.Row['closedDate'] | Should -BeExactly '2025-06-15T00:00:00'    # the closing date round-trips like openingDate
            $r.Back['parent']['id'] | Should -BeExactly 'ouHosp00001'
            $r.Back['image']['id'] | Should -BeExactly 'fileRes0001'
            $r.Back.Contains('path') | Should -BeFalse
            $r.Back.Contains('address') | Should -BeFalse
        }
        It 'drops an empty {} image dict (== absent)' {
            $ou = [ordered]@{ id = 'ouRoot00001'; name = 'Root'; shortName = 'Root'; openingDate = '2020-01-01T00:00:00'; level = 1
                image = [ordered]@{}; created = '2020' }
            $r = Get-RowRoundTrip 'organisationUnits' $ou
            $r.Equal | Should -BeTrue
            $r.Back.Contains('image') | Should -BeFalse
        }
        It 'round-trips an organisationUnitGroup (symbol/color kept), dropping the per-deployment membership' {
            $g = [ordered]@{ id = 'ougDept0001'; code = 'NEO_DEPARTMENT'; name = 'Departments'; shortName = 'Depts'; description = 'd'
                symbol = '12'; color = '#FF0000'
                organisationUnits = @([ordered]@{ id = 'ouZ99999999' }, [ordered]@{ id = 'ouA11111111' }, [ordered]@{ id = 'ouM55555555' })   # anonymised instance membership -> dropped
                sharing = [ordered]@{ public = 'r-------' }; created = '2020' }
            $r = Get-RowRoundTrip 'organisationUnitGroups' $g
            $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            $r.Back.Contains('organisationUnits') | Should -BeFalse   # membership stripped -> common groups carry no members (play populates it as an overlay)
            $r.Row['color'] | Should -BeExactly '#FF0000'
        }
        It 'round-trips an organisationUnitGroupSet (bools + group refs)' {
            $gs = [ordered]@{ id = 'ougsCat0001'; code = 'NEOIPC_CATEGORY'; name = 'Category'; shortName = 'Cat'; description = 'd'
                compulsory = $true; dataDimension = $false; includeSubhierarchyInAnalytics = $true
                organisationUnitGroups = @([ordered]@{ id = 'ougDept0001' }); sharing = [ordered]@{ public = 'r-------' }; created = '2020' }
            $r = Get-RowRoundTrip 'organisationUnitGroupSets' $gs
            $r.Equal | Should -BeTrue
            $r.Row['compulsory'] | Should -BeExactly 'True'
            $r.Row['includeSubhierarchyInAnalytics'] | Should -BeExactly 'True'
        }
        It 'round-trips an organisationUnitLevel' {
            $lvl = [ordered]@{ id = 'oulLevel004'; name = 'Department'; level = 4; offlineLevels = 1; created = '2020' }
            $r = Get-RowRoundTrip 'organisationUnitLevels' $lvl
            $r.Equal | Should -BeTrue
            $r.Row['level'] | Should -BeExactly '4'
        }

        Context 'the closure does not reach the org-unit family (code-referenced, not structured)' {
            BeforeAll {
                $script:ouPkg = [ordered]@{
                    programs = @([ordered]@{ id = 'progNEOIPC1'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                            organisationUnits = @([ordered]@{ id = 'ouDept00001' })   # org-unit assignment ref (non-closure target)
                            programStages = @([ordered]@{ id = 'stageADM001' }) })
                    programStages = @([ordered]@{ id = 'stageADM001'; name = 'Adm'; program = [ordered]@{ id = 'progNEOIPC1' } })
                    programRules = @([ordered]@{ id = 'prRule00001'; name = 'R'; condition = "d2:inOrgUnitGroup('NEO_DEPARTMENT')"; priority = 1
                            program = [ordered]@{ id = 'progNEOIPC1' } })   # references the group by CODE, not {id}
                    organisationUnits = @([ordered]@{ id = 'ouDept00001'; name = 'Dept'; shortName = 'D'; openingDate = '2020-01-01T00:00:00'; level = 1 })
                    organisationUnitGroups = @([ordered]@{ id = 'ougDept0001'; code = 'NEO_DEPARTMENT'; name = 'Depts'; organisationUnits = @([ordered]@{ id = 'ouDept00001' }) })
                    organisationUnitGroupSets = @([ordered]@{ id = 'ougsCat0001'; code = 'NEOIPC_CATEGORY'; name = 'Cat'; organisationUnitGroups = @([ordered]@{ id = 'ougDept0001' }) })
                    organisationUnitLevels = @([ordered]@{ id = 'oulLevel001'; name = 'L1'; level = 1 })
                }
            }
            It 'excludes every org-unit-family object from the closure and the pruned package' {
                $r = Get-NeoIPCMetadataClosure -Package $script:ouPkg
                foreach ($id in 'ouDept00001', 'ougDept0001', 'ougsCat0001', 'oulLevel001') {
                    $r.IncludedIds.Contains($id) | Should -BeFalse -Because "$id is non-closure (code-referenced)"
                }
                foreach ($t in 'organisationUnits', 'organisationUnitGroups', 'organisationUnitGroupSets', 'organisationUnitLevels') {
                    $r.Package.Contains($t) | Should -BeFalse
                }
            }
            It 'does not flag the org-unit assignment ref as a dropped dependency' {
                $r = Get-NeoIPCMetadataClosure -Package $script:ouPkg
                @($r.StructuredUnresolved | ForEach-Object { $_.Uid }) | Should -Not -Contain 'ouDept00001'
            }
            It 'leaves the org-unit family out of the UID-regeneration owned set' {
                $map = New-NeoIPCMetadataUidMap -Package $script:ouPkg
                foreach ($id in 'ouDept00001', 'ougDept0001', 'ougsCat0001', 'oulLevel001') {
                    $map.ContainsKey($id) | Should -BeFalse
                }
                $map.ContainsKey('progNEOIPC1') | Should -BeTrue   # the program itself is owned
            }
        }
    }

    Describe 'Access-control config (userRoles / userGroups non-closure coverage)' {
        It 'round-trips a userRole: code, description, sorted authorities (set semantics)' {
            $role = [ordered]@{ id = 'urAdmin0001'; code = 'NEOIPC_ADMIN'; name = 'NeoIPC Admin'
                description = 'NeoIPC reporting administration.'
                authorities = @('F_NEOIPC_ADMIN', 'F_EXPORT_DATA'); restrictions = @()
                sharing = [ordered]@{ public = 'rw------' }; created = '2020'; lastUpdated = '2021'; translations = @() }
            $r = Get-RowRoundTrip 'userRoles' $role
            $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            $r.Row['authorities'] | Should -BeExactly 'F_EXPORT_DATA F_NEOIPC_ADMIN'   # stringArray ordinal-sorted
            $r.Row['code'] | Should -BeExactly 'NEOIPC_ADMIN'
        }
        It 'round-trips a userRole with no code and no authorities (both absent)' {
            $role = [ordered]@{ id = 'urNothing01'; name = 'Nothing'; description = 'no rights'
                authorities = @(); restrictions = @(); created = '2020' }
            $r = Get-RowRoundTrip 'userRoles' $role
            $r.Equal | Should -BeTrue
            $r.Back.Contains('code') | Should -BeFalse           # absent code -> empty cell -> absent
            $r.Back.Contains('authorities') | Should -BeFalse    # empty array -> absent
        }
        It 'round-trips a userGroup definition, dropping the per-deployment membership' {
            $g = [ordered]@{ id = 'ugAdmins001'; code = 'NEOIPC_PATHOGEN_LIST_ADMINS'; name = 'NeoIPC Pathogen-List admins'
                users = @([ordered]@{ id = 'U2632294693' }, [ordered]@{ id = 'U1641935444' })   # anonymised membership -> dropped
                managedGroups = @([ordered]@{ id = 'ugTesters01' }, [ordered]@{ id = 'ugEditors01' })
                sharing = [ordered]@{ public = 'rw------' }; attributeValues = @(); created = '2020'; translations = @() }
            $r = Get-RowRoundTrip 'userGroups' $g
            $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            $r.Back.Contains('users') | Should -BeFalse                              # membership stripped -> common groups carry no members
            $r.Row['managedGroups'] | Should -BeExactly 'ugEditors01 ugTesters01'    # idArray ordinal-sorted
        }

        Context 'the closure does not reach the access-control types (referenced only by users / stripped sharing / non-closure)' {
            BeforeAll {
                $script:acPkg = [ordered]@{
                    programs = @([ordered]@{ id = 'progNEOIPC1'; code = 'NEOIPC_CORE'; name = 'Core'; programType = 'WITH_REGISTRATION'
                            notificationTemplates = @([ordered]@{ id = 'pntTmpl0001' }) })
                    programNotificationTemplates = @([ordered]@{ id = 'pntTmpl0001'; name = 'T'
                            recipientUserGroup = [ordered]@{ id = 'ugAdmins001' } })   # closure object -> userGroup by {id}
                    userGroups = @([ordered]@{ id = 'ugAdmins001'; code = 'NEOIPC_PATHOGEN_LIST_ADMINS'; name = 'Admins' })
                    userRoles = @([ordered]@{ id = 'urAdmin0001'; code = 'NEOIPC_ADMIN'; name = 'NeoIPC Admin'; authorities = @('F_NEOIPC_ADMIN') })
                }
            }
            It 'excludes userRoles and userGroups from the closure and the pruned package' {
                $r = Get-NeoIPCMetadataClosure -Package $script:acPkg
                $r.IncludedIds.Contains('ugAdmins001') | Should -BeFalse
                $r.IncludedIds.Contains('urAdmin0001') | Should -BeFalse
                $r.Package.Contains('userGroups') | Should -BeFalse
                $r.Package.Contains('userRoles') | Should -BeFalse
            }
            It 'does not flag a notification template recipientUserGroup ref as a dropped dependency' {
                $r = Get-NeoIPCMetadataClosure -Package $script:acPkg
                @($r.StructuredUnresolved | ForEach-Object { $_.Uid }) | Should -Not -Contain 'ugAdmins001'
            }
            It 'leaves the access-control types out of the UID-regeneration owned set' {
                $map = New-NeoIPCMetadataUidMap -Package $script:acPkg
                $map.ContainsKey('ugAdmins001') | Should -BeFalse
                $map.ContainsKey('urAdmin0001') | Should -BeFalse
                $map.ContainsKey('progNEOIPC1') | Should -BeTrue   # the program itself is owned
            }
        }
    }

    Describe 'Authored org-unit compilation (code-keyed -> UID-keyed)' {
        BeforeAll {
            $script:ouCommon = Join-Path $TestDrive 'ou-common.csv'
            $script:ouPlay = Join-Path $TestDrive 'ou-play.csv'
            @('code,name,shortName,openingDate,parent_code',
              'ROOT,Root,Root,2023-01-01,',
              'CtryA,Country A,CtryA,2023-01-01,ROOT') | Set-Content -LiteralPath $script:ouCommon -Encoding utf8
            @('code,name,shortName,openingDate,parent_code',
              'CtryA_H,Hospital A,Hosp A,2023-01-01,CtryA',
              'CtryA_H_D,Dept A,Dept A,2023-01-01,CtryA_H') | Set-Content -LiteralPath $script:ouPlay -Encoding utf8
        }
        It 'mints deterministic UIDs from code, resolves parent_code across files, and computes tree depth as level' {
            $ous = ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $script:ouCommon, $script:ouPlay
            $ous.Count | Should -Be 4
            $byCode = @{}; $ous | ForEach-Object { $byCode[$_.code] = $_ }
            $byCode['ROOT'].level | Should -Be 1
            $byCode['ROOT'].Contains('parent') | Should -BeFalse           # a root has no parent ref
            $byCode['CtryA'].level | Should -Be 2
            $byCode['CtryA_H'].level | Should -Be 3                          # parent defined in the OTHER file
            $byCode['CtryA_H_D'].level | Should -Be 4
            Test-NeoIPCMetadataUid -Id $byCode['ROOT'].id | Should -BeTrue
            $byCode['CtryA_H_D']['parent']['id'] | Should -BeExactly $byCode['CtryA_H'].id
            $byCode['CtryA'].id | Should -BeExactly (New-NeoIPCMetadataUid -Type 'organisationUnits' -NaturalKey 'CtryA')
        }
        It 'produces valid UID-keyed content (each unit round-trips through the converter)' {
            $ous = ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $script:ouCommon, $script:ouPlay
            foreach ($o in $ous) {
                $r = Get-RowRoundTrip 'organisationUnits' $o
                $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            }
        }
        It 'throws on an unknown parent_code' {
            $bad = Join-Path $TestDrive 'ou-bad.csv'
            @('code,name,shortName,openingDate,parent_code', 'X,X,X,2023-01-01,NOPE') | Set-Content -LiteralPath $bad -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $bad } | Should -Throw '*unknown parent_code*'
        }
        It 'throws on a duplicate code' {
            $dup = Join-Path $TestDrive 'ou-dup.csv'
            @('code,name,shortName,openingDate,parent_code', 'D,D,D,2023-01-01,', 'D,D2,D2,2023-01-01,') | Set-Content -LiteralPath $dup -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $dup } | Should -Throw '*Duplicate*'
        }
        It 'throws on an empty code' {
            $empty = Join-Path $TestDrive 'ou-empty.csv'
            @('code,name,shortName,openingDate,parent_code', ',Nameless,N,2023-01-01,') | Set-Content -LiteralPath $empty -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $empty } | Should -Throw '*empty code*'
        }
        It 'throws on a blank shortName or openingDate (DHIS2 not-null fields the round-trip test cannot catch)' {
            $noShort = Join-Path $TestDrive 'ou-noshort.csv'
            @('code,name,shortName,openingDate,parent_code', 'R,Root,,2023-01-01,') | Set-Content -LiteralPath $noShort -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $noShort } | Should -Throw '*non-empty shortName*'
            $noDate = Join-Path $TestDrive 'ou-nodate.csv'
            @('code,name,shortName,openingDate,parent_code', 'R,Root,Root,,') | Set-Content -LiteralPath $noDate -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $noDate } | Should -Throw '*non-empty openingDate*'
        }
    }

    Describe 'Authored play users (normalized code-keyed tables -> UID-keyed)' {
        BeforeAll {
            $script:uUsers = Join-Path $TestDrive 'users.csv'
            $script:uRoles = Join-Path $TestDrive 'userRoleAssignments.csv'
            $script:uOus   = Join-Path $TestDrive 'userOrgUnitAssignments.csv'
            @('username,firstName,surname',
              'play.a.1,Play,A One',
              'play.admin,Play,Admin') | Set-Content -LiteralPath $script:uUsers -Encoding utf8
            @('username,role',
              'play.a.1,Base',
              'play.a.1,Data entry',
              'play.admin,Superuser') | Set-Content -LiteralPath $script:uRoles -Encoding utf8
            @('username,organisationUnit',
              'play.a.1,DeptA',
              'play.admin,ROOT') | Set-Content -LiteralPath $script:uOus -Encoding utf8
            $script:roleUid = @{ 'Base' = 'roleBase001'; 'Data entry' = 'roleData001'; 'Superuser' = 'roleSuper01' }
            $script:ouUid = @{ 'DeptA' = 'ouDeptA0001'; 'ROOT' = 'ouRoot00001' }
        }
        It 'mints a UID per username, sets the password, and joins multi-role + org-unit assignments to all three scopes' {
            $u = ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $script:uUsers -RoleAssignmentPath $script:uRoles -OrgUnitAssignmentPath $script:uOus -RoleUid $script:roleUid -OrgUnitUid $script:ouUid -Password 'district'
            $u.Count | Should -Be 2
            $byName = @{}; $u | ForEach-Object { $byName[$_.username] = $_ }
            $d = $byName['play.a.1']
            Test-NeoIPCMetadataUid -Id $d.id | Should -BeTrue
            $d.id | Should -BeExactly (New-NeoIPCMetadataUid -Type 'users' -NaturalKey 'play.a.1')
            $d.password | Should -BeExactly 'district'
            $d.firstName | Should -BeExactly 'Play'
            @($d.userRoles).Count | Should -Be 2                       # Base + Data entry (two junction rows, not an in-cell array)
            ($d.userRoles | ForEach-Object { $_.id }) -join ',' | Should -BeExactly 'roleBase001,roleData001'
            $d.organisationUnits[0].id | Should -BeExactly 'ouDeptA0001'
            $d.dataViewOrganisationUnits[0].id | Should -BeExactly 'ouDeptA0001'
            $d.teiSearchOrganisationUnits[0].id | Should -BeExactly 'ouDeptA0001'
            $d.Contains('userGroups') | Should -BeFalse                # membership is group-side (group.users[]), not on the user
        }
        It 'throws on an unknown role' {
            $bad = Join-Path $TestDrive 'ur-badrole.csv'
            @('username,role', 'play.a.1,Nope', 'play.admin,Superuser') | Set-Content -LiteralPath $bad -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $script:uUsers -RoleAssignmentPath $bad -OrgUnitAssignmentPath $script:uOus -RoleUid $script:roleUid -OrgUnitUid $script:ouUid } | Should -Throw '*unknown role*'
        }
        It 'throws on an unknown org unit' {
            $bad = Join-Path $TestDrive 'uo-badou.csv'
            @('username,organisationUnit', 'play.a.1,Nowhere', 'play.admin,ROOT') | Set-Content -LiteralPath $bad -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $script:uUsers -RoleAssignmentPath $script:uRoles -OrgUnitAssignmentPath $bad -RoleUid $script:roleUid -OrgUnitUid $script:ouUid } | Should -Throw '*unknown org unit*'
        }
        It 'throws on a user with no role assignment (DHIS2 requires at least one)' {
            $noRole = Join-Path $TestDrive 'ur-norole.csv'
            @('username,role', 'play.admin,Superuser') | Set-Content -LiteralPath $noRole -Encoding utf8   # play.a.1 has no role row
            { ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $script:uUsers -RoleAssignmentPath $noRole -OrgUnitAssignmentPath $script:uOus -RoleUid $script:roleUid -OrgUnitUid $script:ouUid } | Should -Throw '*no userRoles*'
        }
        It 'throws on an assignment targeting a user absent from users.csv' {
            $dangling = Join-Path $TestDrive 'ur-dangling.csv'
            @('username,role', 'play.a.1,Base', 'play.admin,Superuser', 'play.ghost,Base') | Set-Content -LiteralPath $dangling -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $script:uUsers -RoleAssignmentPath $dangling -OrgUnitAssignmentPath $script:uOus -RoleUid $script:roleUid -OrgUnitUid $script:ouUid } | Should -Throw '*unknown user*'
        }
        It 'throws on a duplicate username in users.csv' {
            $dup = Join-Path $TestDrive 'users-dup.csv'
            @('username,firstName,surname', 'd,Xx,Xx', 'd,Yy,Yy') | Set-Content -LiteralPath $dup -Encoding utf8
            $dr = Join-Path $TestDrive 'ur-for-dup.csv'
            @('username,role', 'd,Base') | Set-Content -LiteralPath $dr -Encoding utf8
            $do = Join-Path $TestDrive 'uo-for-dup.csv'
            @('username,organisationUnit', 'd,DeptA') | Set-Content -LiteralPath $do -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $dup -RoleAssignmentPath $dr -OrgUnitAssignmentPath $do -RoleUid $script:roleUid -OrgUnitUid $script:ouUid } | Should -Throw '*Duplicate*'
        }
        It 'throws on a firstName/surname shorter than 2 characters (DHIS2 @PropertyRange min)' {
            $shortName = Join-Path $TestDrive 'users-short.csv'
            @('username,firstName,surname', 'play.x,P,One') | Set-Content -LiteralPath $shortName -Encoding utf8   # firstName 'P' is 1 char
            $ur = Join-Path $TestDrive 'ur-short.csv'
            @('username,role', 'play.x,Base') | Set-Content -LiteralPath $ur -Encoding utf8
            $uo = Join-Path $TestDrive 'uo-short.csv'
            @('username,organisationUnit', 'play.x,DeptA') | Set-Content -LiteralPath $uo -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $shortName -RoleAssignmentPath $ur -OrgUnitAssignmentPath $uo -RoleUid $script:roleUid -OrgUnitUid $script:ouUid } | Should -Throw '*at least 2 characters*'
        }
    }

    Describe 'Authored group memberships (overlays applied group-side)' {
        BeforeAll {
            # A minimal hierarchy exercising all three structural identity groups + the _TEST/_TEST_TEST split.
            $script:gmOu = Join-Path $TestDrive 'gm-ou.csv'
            @('code,name,shortName,openingDate,parent_code',
              'NEOIPC,Root,Root,2023-01-01,',
              'CtryA,Country A,CtryA,2023-01-01,NEOIPC',
              'CtryB,Country B,CtryB,2023-01-01,NEOIPC',
              'CtryA_TEST,Hospital A,Hosp A,2023-01-01,CtryA',
              'CtryA_TEST_TEST,Dept A,Dept A,2023-01-01,CtryA_TEST') | Set-Content -LiteralPath $script:gmOu -Encoding utf8
            $script:gmOrgUnits = ConvertFrom-NeoIPCAuthoredOrgUnitCsv -Path $script:gmOu
            $script:gmIdByCode = @{}; $script:gmOrgUnits | ForEach-Object { $script:gmIdByCode[$_.code] = $_.id }

            # Synthetic users (via the user compiler) for the user-group membership map.
            $uUsers = Join-Path $TestDrive 'gm-users.csv'
            @('username,firstName,surname', 'play.a.1,Play,A One', 'play.admin,Play,Admin') | Set-Content -LiteralPath $uUsers -Encoding utf8
            $uRoles = Join-Path $TestDrive 'gm-roles.csv'
            @('username,role', 'play.a.1,Base', 'play.admin,Superuser') | Set-Content -LiteralPath $uRoles -Encoding utf8
            $uOus = Join-Path $TestDrive 'gm-userous.csv'
            @('username,organisationUnit', 'play.a.1,CtryA_TEST_TEST', 'play.admin,NEOIPC') | Set-Content -LiteralPath $uOus -Encoding utf8
            $script:gmUsers = ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $uUsers -RoleAssignmentPath $uRoles -OrgUnitAssignmentPath $uOus -RoleUid @{ 'Base' = 'roleBase001'; 'Superuser' = 'roleSuper01' } -OrgUnitUid @{ 'CtryA_TEST_TEST' = 'ouDeptA0001'; 'NEOIPC' = 'ouRoot00001' }
            $script:gmIdByUser = @{}; $script:gmUsers | ForEach-Object { $script:gmIdByUser[$_.username] = $_.id }
        }
        It 'derives the three structural identity groups from the hierarchy (suffix + level), no _TEST/_TEST_TEST overlap' {
            $m = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:gmOrgUnits
            @($m['COUNTRY']) | Should -Be @($script:gmIdByCode['CtryA'], $script:gmIdByCode['CtryB'])
            @($m['HOSPITAL']) | Should -Be @($script:gmIdByCode['CtryA_TEST'])
            @($m['NEO_DEPARTMENT']) | Should -Be @($script:gmIdByCode['CtryA_TEST_TEST'])
            @($m['HOSPITAL']) | Should -Not -Contain $script:gmIdByCode['CtryA_TEST_TEST']   # the department is NOT also a hospital
        }
        It 'merges authored domain memberships, resolving org-unit code to its minted UID' {
            $dom = Join-Path $TestDrive 'gm-domain.csv'
            @('organisationUnitGroup,organisationUnit',
              'WORLD_BANK_CLASS_H_FY_2026,CtryA',
              'REFERENCE_CENTRE,CtryA_TEST_TEST') | Set-Content -LiteralPath $dom -Encoding utf8
            $m = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:gmOrgUnits -MembershipPath $dom
            @($m['WORLD_BANK_CLASS_H_FY_2026']) | Should -Be @($script:gmIdByCode['CtryA'])
            @($m['REFERENCE_CENTRE']) | Should -Be @($script:gmIdByCode['CtryA_TEST_TEST'])
            @($m['COUNTRY']).Count | Should -Be 2                                              # structural still present
        }
        It 'merges domain memberships from multiple junction files (common World-Bank + play designations)' {
            $common = Join-Path $TestDrive 'gm-common-mem.csv'
            @('organisationUnitGroup,organisationUnit', 'WORLD_BANK_CLASS_H_FY_2025,CtryA') | Set-Content -LiteralPath $common -Encoding utf8
            $play = Join-Path $TestDrive 'gm-play-mem.csv'
            @('organisationUnitGroup,organisationUnit', 'TEST_UNITS,CtryA_TEST_TEST') | Set-Content -LiteralPath $play -Encoding utf8
            $m = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:gmOrgUnits -MembershipPath $common, $play
            @($m['WORLD_BANK_CLASS_H_FY_2025']) | Should -Be @($script:gmIdByCode['CtryA'])
            @($m['TEST_UNITS']) | Should -Be @($script:gmIdByCode['CtryA_TEST_TEST'])
        }
        It 'de-duplicates a member listed by both the structural rule and a domain row' {
            $dom = Join-Path $TestDrive 'gm-dup.csv'
            @('organisationUnitGroup,organisationUnit', 'COUNTRY,CtryA') | Set-Content -LiteralPath $dom -Encoding utf8
            $m = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:gmOrgUnits -MembershipPath $dom
            @($m['COUNTRY']).Count | Should -Be 2                                              # CtryA not listed twice
        }
        It 'throws on a domain membership row naming an org unit not in the hierarchy' {
            $dom = Join-Path $TestDrive 'gm-badou.csv'
            @('organisationUnitGroup,organisationUnit', 'TEST_UNITS,NOPE') | Set-Content -LiteralPath $dom -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:gmOrgUnits -MembershipPath $dom } | Should -Throw '*unknown org unit*'
        }
        It 'compiles user-group memberships, resolving username to the authored user UID' {
            $ug = Join-Path $TestDrive 'gm-usergroups.csv'
            @('userGroup,username',
              'NEOIPC,play.a.1',
              'NEOIPC,play.admin',
              'NEOIPC_USER_MANAGERS,play.admin') | Set-Content -LiteralPath $ug -Encoding utf8
            $m = ConvertFrom-NeoIPCAuthoredUserGroupMembership -MembershipPath $ug -User $script:gmUsers
            @($m['NEOIPC']) | Should -Be @($script:gmIdByUser['play.a.1'], $script:gmIdByUser['play.admin'])
            @($m['NEOIPC_USER_MANAGERS']) | Should -Be @($script:gmIdByUser['play.admin'])
        }
        It 'throws on a user-group membership row naming an unknown user' {
            $ug = Join-Path $TestDrive 'gm-baduser.csv'
            @('userGroup,username', 'NEOIPC,play.ghost') | Set-Content -LiteralPath $ug -Encoding utf8
            { ConvertFrom-NeoIPCAuthoredUserGroupMembership -MembershipPath $ug -User $script:gmUsers } | Should -Throw '*unknown user*'
        }
        It 'applies org-unit-group membership group-side as {id} refs, leaving member-less groups untouched' {
            $groups = @(
                [ordered]@{ id = 'gOUG000001'; code = 'COUNTRY'; name = 'Country' },
                [ordered]@{ id = 'gOUG000002'; code = 'HOSPITAL'; name = 'Hospital' },
                [ordered]@{ id = 'gOUG000003'; code = 'NEO_DEPARTMENT'; name = 'Neonatology Department' },
                [ordered]@{ id = 'gOUG000004'; code = 'NEOIPC_SPAIN'; name = 'NeoIPC Spain' }   # no membership entry
            )
            $m = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:gmOrgUnits
            Set-NeoIPCGroupMembership -Group $groups -Membership $m -MemberProperty 'organisationUnits' | Should -Be 3
            $dept = $groups | Where-Object { $_.code -eq 'NEO_DEPARTMENT' }
            @($dept.organisationUnits).Count | Should -Be 1
            $dept.organisationUnits[0].id | Should -BeExactly $script:gmIdByCode['CtryA_TEST_TEST']
            ($groups | Where-Object { $_.code -eq 'NEOIPC_SPAIN' }).Contains('organisationUnits') | Should -BeFalse
        }
        It 'applies user-group membership group-side onto userGroup objects' {
            $ug = Join-Path $TestDrive 'gm-ug-apply.csv'
            @('userGroup,username', 'NEOIPC,play.a.1', 'NEOIPC,play.admin') | Set-Content -LiteralPath $ug -Encoding utf8
            $m = ConvertFrom-NeoIPCAuthoredUserGroupMembership -MembershipPath $ug -User $script:gmUsers
            $groups = @([ordered]@{ id = 'ug00000001'; code = 'NEOIPC'; name = 'NeoIPC' }, [ordered]@{ id = 'ug00000002'; code = 'NEOIPC_SPAIN'; name = 'NeoIPC Spain' })
            Set-NeoIPCGroupMembership -Group $groups -Membership $m -MemberProperty 'users' | Should -Be 1
            @(($groups | Where-Object { $_.code -eq 'NEOIPC' }).users).Count | Should -Be 2
            ($groups | Where-Object { $_.code -eq 'NEOIPC_SPAIN' }).Contains('users') | Should -BeFalse
        }
        It 'throws when a membership names a group absent from the package' {
            $m = [ordered]@{ 'NOPE_GROUP' = @('x') }
            { Set-NeoIPCGroupMembership -Group @([ordered]@{ id = 'g000000001'; code = 'HOSPITAL' }) -Membership $m -MemberProperty 'organisationUnits' } | Should -Throw '*not present*'
        }
    }
}
