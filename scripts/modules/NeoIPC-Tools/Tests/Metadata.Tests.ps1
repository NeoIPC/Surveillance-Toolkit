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
            $o1 = $Object | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
            $o2 = $back   | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
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
        It 'the comparator treats a set-mapped idArray (program.organisationUnits) as order-INSENSITIVE' {
            $mk = { param($order) [ordered]@{ programs = @([ordered]@{ id = 'progTESTA01'; code = 'P'; name = 'P'; programType = 'WITH_REGISTRATION'
                            organisationUnits = @($order | ForEach-Object { [ordered]@{ id = $_ } }) }) } }
            $a = & $mk @('ouBBBBBBBB1', 'ouAAAAAAAA1')
            $b = & $mk @('ouAAAAAAAA1', 'ouBBBBBBBB1')
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
            $work = $script:pkg0 | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            $rows.Contains('programStageDataElements') | Should -BeTrue
            $rows.Contains('programTrackedEntityAttributes') | Should -BeTrue
            $rows.Contains('analyticsPeriodBoundaries') | Should -BeTrue
            $rows.Contains('users') | Should -BeFalse
            [string]$rows['programStageDataElements'][0]['__fk'] | Should -BeExactly 'psAAAA00001'
        }
        It 're-nests children into parents and never leaks __fk / synthetic fk into output' {
            $work = $script:pkg0 | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
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
            $work     = $script:pkg0 | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
            $baseline = $script:pkg0 | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
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
}
