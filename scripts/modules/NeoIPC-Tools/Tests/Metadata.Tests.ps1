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

        # Seed the module-scoped sharing-profile registry the row converter consults, built the same way
        # Import-NeoIPCSharingProfile builds it (spec -> sharing object -> canonical-value index) but without
        # a YAML file, so the suite stays self-contained. Grants are keyed by group CODE (UG_TEST), resolved
        # to a UID through this fixture key map, exactly as the real userGroups roster does.
        $script:TestUgKeyMap = @{
            KeyToId = @{ UG_TEST = 'ugTestAAA01'; UG_TEST2 = 'ugTestBBB02' }
            IdToKey = @{ ugTestAAA01 = 'UG_TEST'; ugTestBBB02 = 'UG_TEST2' }
        }
        $script:NeoIPCSharingProfiles = @{ ByKey = [ordered]@{}; ByValue = @{} }
        foreach ($p in @(
                @{ Key = 'PUBLIC_RW'; Spec = @{ public = 'rw------' } },
                @{ Key = 'PUBLIC_R'; Spec = @{ public = 'r-------' } },
                @{ Key = 'PRIVATE'; Spec = @{ public = '--------' } },
                @{ Key = 'NEOIPC_READ'; Spec = @{ public = '--------'; userGroups = @{ UG_TEST = 'r-------' } } },
                @{ Key = 'DATA_EDIT'; Spec = @{ public = '--------'; userGroups = @{ UG_TEST = 'r-r-----'; UG_TEST2 = 'r-rw----' } } }
            )) {
            $sharing = ConvertTo-NeoIPCSharingFromProfileSpec -Spec $p.Spec -KeyToId $script:TestUgKeyMap.KeyToId
            $script:NeoIPCSharingProfiles.ByKey[$p.Key] = $sharing
            $script:NeoIPCSharingProfiles.ByValue[(Get-NeoIPCSharingCanonicalKey -Sharing $sharing)] = $p.Key
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
        It 'parses a single-element array cell to a 1-element array, not a scalar (else import rejects the object)' {
            foreach ($cls in 'idArray', 'idArrayOrdered', 'stringArray', 'intArray') {
                $cell = if ($cls -eq 'intArray') { '7' } else { 'onlyOneVal1' }
                $parsed = ConvertFrom-NeoIPCMetadataCell -Class $cls -Cell $cell
                $parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string] -and $parsed -isnot [System.Collections.IDictionary] | Should -BeTrue -Because "$cls must stay an array"
                @($parsed).Count | Should -Be 1
            }
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

    Describe 'Sharing profiles' {
        It 'resolves a normalized sharing object to its profile key (the CSV cell value)' {
            $sharing = Convert-NeoIPCSharing ([ordered]@{ public = 'rw------'; owner = 'u'; external = $false })
            (Resolve-NeoIPCSharingProfileKey -Sharing $sharing) | Should -BeExactly 'PUBLIC_RW'
        }
        It 'drops the per-grant displayName when normalizing (keeps id + access only)' {
            $sharing = Convert-NeoIPCSharing ([ordered]@{ public = '--------'
                    userGroups = [ordered]@{ ugTestAAA01 = [ordered]@{ id = 'ugTestAAA01'; access = 'r-------'; displayName = 'Some Group ' } } })
            $sharing['userGroups']['ugTestAAA01'].Contains('displayName') | Should -BeFalse
            $sharing['userGroups']['ugTestAAA01']['access'] | Should -BeExactly 'r-------'
            (Resolve-NeoIPCSharingProfileKey -Sharing $sharing) | Should -BeExactly 'NEOIPC_READ'
        }
        It 'expands a profile key back into a DHIS2 sharing object' {
            $sharing = Expand-NeoIPCSharingProfile -Key 'NEOIPC_READ'
            $sharing['public'] | Should -BeExactly '--------'
            $sharing['userGroups']['ugTestAAA01']['access'] | Should -BeExactly 'r-------'
            $sharing['userGroups']['ugTestAAA01']['id'] | Should -BeExactly 'ugTestAAA01'
        }
        It 'builds a userGroup key map (code and name both resolve; code preferred for writing)' {
            $map = Get-NeoIPCUserGroupKeyMap -UserGroups @(
                [ordered]@{ id = 'ug11111aaaa'; code = 'GRP_A'; name = 'Group A' },
                [ordered]@{ id = 'ug22222bbbb'; name = 'Codeless Group' }
            )
            $map.KeyToId['GRP_A'] | Should -BeExactly 'ug11111aaaa'
            $map.KeyToId['Group A'] | Should -BeExactly 'ug11111aaaa'
            $map.IdToKey['ug11111aaaa'] | Should -BeExactly 'GRP_A'           # code preferred
            $map.KeyToId['Codeless Group'] | Should -BeExactly 'ug22222bbbb'
            $map.IdToKey['ug22222bbbb'] | Should -BeExactly 'Codeless Group'  # name fallback
        }
        It 'resolves a userGroup code to its UID when expanding a profile spec' {
            $sharing = ConvertTo-NeoIPCSharingFromProfileSpec -Spec @{ public = '--------'; userGroups = @{ GRP_A = 'rw------' } } -KeyToId @{ GRP_A = 'ug11111aaaa' }
            $sharing['userGroups']['ug11111aaaa']['access'] | Should -BeExactly 'rw------'
            $sharing['userGroups']['ug11111aaaa']['id'] | Should -BeExactly 'ug11111aaaa'
        }
        It 'fails loud on an unknown userGroup code/name in a profile spec' {
            { ConvertTo-NeoIPCSharingFromProfileSpec -Spec @{ userGroups = @{ NOPE = 'r-------' } } -KeyToId @{} } | Should -Throw '*unknown user group*'
        }
        It 'fails loud when a userGroup name collides with another group''s code' {
            { Get-NeoIPCUserGroupKeyMap -UserGroups @(
                    [ordered]@{ id = 'ugAAAAAAAA1'; code = 'SHARED'; name = 'Group A' },
                    [ordered]@{ id = 'ugBBBBBBBB2'; name = 'SHARED' }
                ) } | Should -Throw "*Ambiguous user-group handle 'SHARED'*"
        }
        It 'fails loud when two codeless groups share a name' {
            { Get-NeoIPCUserGroupKeyMap -UserGroups @(
                    [ordered]@{ id = 'ugAAAAAAAA1'; name = 'Dup Name' },
                    [ordered]@{ id = 'ugBBBBBBBB2'; name = 'Dup Name' }
                ) } | Should -Throw '*Ambiguous user-group handle*'
        }
        It 'resolves and expands a profile with two distinct userGroup grants (canonical order-independent)' {
            # Grants supplied in the OPPOSITE order to the profile spec — canonicalization must still match.
            $key = Resolve-NeoIPCSharingProfileKey -Sharing (Convert-NeoIPCSharing ([ordered]@{ public = '--------'
                        userGroups = [ordered]@{
                            ugTestBBB02 = [ordered]@{ id = 'ugTestBBB02'; access = 'r-rw----' }
                            ugTestAAA01 = [ordered]@{ id = 'ugTestAAA01'; access = 'r-r-----' }
                        }
                    }))
            $key | Should -BeExactly 'DATA_EDIT'
            $back = Expand-NeoIPCSharingProfile -Key 'DATA_EDIT'
            $back['userGroups']['ugTestAAA01']['access'] | Should -BeExactly 'r-r-----'
            $back['userGroups']['ugTestBBB02']['access'] | Should -BeExactly 'r-rw----'
        }
        It 'fails loud when two profiles resolve to the same sharing object' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-shc-' + [System.IO.Path]::GetRandomFileName() + '.yaml')
            $saved = $script:NeoIPCSharingProfiles
            try {
                @('PUBLIC_RW:', '  public: "rw------"', 'ALSO_RW:', '  public: "rw------"') | Set-Content -LiteralPath $tmp -Encoding utf8
                { Import-NeoIPCSharingProfile -Path $tmp } | Should -Throw '*resolve to the same sharing object*'
            }
            finally { $script:NeoIPCSharingProfiles = $saved; Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        }
        It 'auto-generates a self-contained sharing.yaml from a package (Initialize -> Export -> Import, ordinal SHARING_NNN)' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
            $saved = $script:NeoIPCSharingProfiles
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-shg-' + [System.IO.Path]::GetRandomFileName() + '.yaml')
            try {
                $pkg = [ordered]@{ dataElements = @(
                        [ordered]@{ id = 'deAAAAAAAA1'; sharing = [ordered]@{ public = 'rw------' } },
                        [ordered]@{ id = 'deBBBBBBBB2'; sharing = [ordered]@{ public = '--------'
                                userGroups = [ordered]@{ ugTestAAA01 = [ordered]@{ id = 'ugTestAAA01'; access = 'r-------' } } } }
                    ) }
                Initialize-NeoIPCSharingProfileFromPackage -Package $pkg
                @($script:NeoIPCSharingProfiles.ByKey.Keys) | Should -Be @('SHARING_001', 'SHARING_002')
                # Ordinal sort of the canonical JSON puts "--------" (the grant shape) before "rw------".
                (Resolve-NeoIPCSharingProfileKey -Sharing (Convert-NeoIPCSharing ([ordered]@{ public = 'rw------' }))) | Should -BeExactly 'SHARING_002'
                Export-NeoIPCSharingProfile -Path $tmp -IdToKey $script:TestUgKeyMap.IdToKey
                (Get-Content -LiteralPath $tmp -Raw) | Should -Match 'UG_TEST'   # grant written by code, not UID
                Import-NeoIPCSharingProfile -Path $tmp -KeyToId $script:TestUgKeyMap.KeyToId
                (Expand-NeoIPCSharingProfile -Key 'SHARING_001')['userGroups']['ugTestAAA01']['access'] | Should -BeExactly 'r-------'
            }
            finally { $script:NeoIPCSharingProfiles = $saved; Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        }
        It 'writes the profile KEY (not a JSON blob) into the CSV sharing cell, and round-trips it' {
            $de = [ordered]@{ id = 'dataElmnt09'; code = 'NEOIPC_S'; name = 'S'; shortName = 's'; valueType = 'TEXT'; domainType = 'TRACKER'
                aggregationType = 'NONE'; zeroIsSignificant = $false
                sharing = [ordered]@{ public = '--------'; userGroups = [ordered]@{ ugTestAAA01 = [ordered]@{ id = 'ugTestAAA01'; access = 'r-------'; displayName = 'X' } } } }
            $row = ConvertTo-NeoIPCMetadataRow -Type 'dataElements' -Object $de
            $row['sharing'] | Should -BeExactly 'NEOIPC_READ'
            $back = ConvertFrom-NeoIPCMetadataRow -Type 'dataElements' -Row $row
            $back['sharing']['public'] | Should -BeExactly '--------'
            $back['sharing']['userGroups']['ugTestAAA01']['access'] | Should -BeExactly 'r-------'
            $back['sharing']['userGroups']['ugTestAAA01'].Contains('displayName') | Should -BeFalse
        }
        It 'fails loud on an unrecognized sharing pattern (so a new shape is named in sharing.yaml)' {
            $sharing = Convert-NeoIPCSharing ([ordered]@{ public = 'rwrw----' })
            { Resolve-NeoIPCSharingProfileKey -Sharing $sharing } | Should -Throw '*Unrecognized sharing pattern*'
        }
        It 'fails loud on an unknown profile key' {
            { Expand-NeoIPCSharingProfile -Key 'NO_SUCH_PROFILE' } | Should -Throw "*Unknown sharing profile key 'NO_SUCH_PROFILE'*"
        }
        It 'round-trips the registry through Export -> Import keyed by group code (YAML file form)' -Skip:(-not (Get-Module -ListAvailable powershell-yaml)) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-sh-' + [System.IO.Path]::GetRandomFileName() + '.yaml')
            $saved = $script:NeoIPCSharingProfiles
            try {
                Export-NeoIPCSharingProfile -Path $tmp -IdToKey $script:TestUgKeyMap.IdToKey
                $text = Get-Content -LiteralPath $tmp -Raw
                $text | Should -Match 'UG_TEST'             # grants written by group code...
                $text | Should -Not -Match 'ugTestAAA01'    # ...never the opaque UID
                Import-NeoIPCSharingProfile -Path $tmp -KeyToId $script:TestUgKeyMap.KeyToId
                (Expand-NeoIPCSharingProfile -Key 'NEOIPC_READ')['userGroups']['ugTestAAA01']['access'] | Should -BeExactly 'r-------'
            }
            finally {
                $script:NeoIPCSharingProfiles = $saved
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            }
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
        It 'keeps a single-element collection an array (serializes to [...], not an object — import would reject a HashSet from an object)' {
            $obj = ConvertFrom-NeoIPCMetadataJsonText -Json '{"id":"og000000001","code":"G","options":[{"id":"opt1111aaaa"}]}'
            $cleaned = Remove-NeoIPCMetadataNoise -Object $obj -WarningAction SilentlyContinue
            $cleaned['options'] -is [System.Collections.IEnumerable] -and $cleaned['options'] -isnot [System.Collections.IDictionary] | Should -BeTrue
            ($cleaned | ConvertTo-Json -Depth 6 -Compress) | Should -Match '"options":\['
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
        It 'emits rows ordinally sorted by natural key (deterministic, review-stable order)' {
            # Unsorted input -> code-ordered output. (Guards the converter sort: the 3-arg [Array]::Sort
            # overload is a silent no-op in PowerShell, so the sort must use the List<object>.Sort path.)
            $pkg = [ordered]@{ optionSets = @(
                    [ordered]@{ id = 'osZZZ00001'; code = 'ZEBRA'; name = 'Z'; valueType = 'TEXT' }
                    [ordered]@{ id = 'osAAA00001'; code = 'ALPHA'; name = 'A'; valueType = 'TEXT' }
                    [ordered]@{ id = 'osMMM00001'; code = 'MIKE';  name = 'M'; valueType = 'TEXT' }) }
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($pkg | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            @($rows['optionSets'] | ForEach-Object { [string]$_['code'] }) | Should -Be @('ALPHA', 'MIKE', 'ZEBRA')
        }
        It 'orders options by their optionSet then sortOrder (not row-insertion order)' {
            $pkg = [ordered]@{ options = @(
                    [ordered]@{ id = 'optBBB0002'; code = 'b2'; name = 'B2'; sortOrder = 2; optionSet = [ordered]@{ id = 'osBBB00001' } }
                    [ordered]@{ id = 'optAAA0001'; code = 'a1'; name = 'A1'; sortOrder = 1; optionSet = [ordered]@{ id = 'osAAA00001' } }
                    [ordered]@{ id = 'optBBB0001'; code = 'b1'; name = 'B1'; sortOrder = 1; optionSet = [ordered]@{ id = 'osBBB00001' } }) }
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($pkg | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            @($rows['options'] | ForEach-Object { [string]$_['id'] }) | Should -Be @('optAAA0001', 'optBBB0001', 'optBBB0002')
        }
    }

    Describe 'Domain option-set exclusion (pathogens / substances sourced from YAML, not the directory)' {
        BeforeAll {
            $script:domPkg = [ordered]@{
                optionSets = @(
                    [ordered]@{ id = 'osPathogen1'; code = 'NEOIPC_PATHOGENS'; name = 'Pathogens'; valueType = 'INTEGER_ZERO_OR_POSITIVE'; options = @([ordered]@{ id = 'optPath0001' }, [ordered]@{ id = 'optPath0002' }) }
                    [ordered]@{ id = 'osSubstanc1'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; name = 'Substances'; valueType = 'TEXT'; options = @([ordered]@{ id = 'optSubs0001' }) }
                    [ordered]@{ id = 'osAsaScore1'; code = 'NEOIPC_ASA_SCORE'; name = 'ASA'; valueType = 'INTEGER_POSITIVE'; options = @([ordered]@{ id = 'optAsa00001' }, [ordered]@{ id = 'optAsa00002' }) }
                )
                options = @(
                    [ordered]@{ id = 'optPath0001'; code = 'P1'; name = 'Path1'; sortOrder = 1; optionSet = [ordered]@{ id = 'osPathogen1' } }
                    [ordered]@{ id = 'optPath0002'; code = 'P2'; name = 'Path2'; sortOrder = 2; optionSet = [ordered]@{ id = 'osPathogen1' } }
                    [ordered]@{ id = 'optSubs0001'; code = 'S1'; name = 'Subs1'; sortOrder = 1; optionSet = [ordered]@{ id = 'osSubstanc1' } }
                    [ordered]@{ id = 'optAsa00001'; code = 'A1'; name = 'Asa1'; sortOrder = 1; optionSet = [ordered]@{ id = 'osAsaScore1' } }
                    [ordered]@{ id = 'optAsa00002'; code = 'A2'; name = 'Asa2'; sortOrder = 2; optionSet = [ordered]@{ id = 'osAsaScore1' } }
                )
            }
        }
        It 'drops the domain option SETS from the directory but keeps the others' {
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            @($rows['optionSets']).Count | Should -Be 1
            [string]$rows['optionSets'][0]['code'] | Should -BeExactly 'NEOIPC_ASA_SCORE'
        }
        It 'drops options belonging to the domain sets but keeps the others' {
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            @($rows['options']).Count | Should -Be 2
            @($rows['options'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('optAsa00001', 'optAsa00002')
        }
        It 'the comparator treats the domain content as a known non-difference (round-trip stays green)' {
            # Baseline carries the domain sets + their options; the directory-derived (rebuilt) side does not.
            $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $work     = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $rebuilt  = ConvertTo-NeoIPCMetadataPackage -Rows (ConvertFrom-NeoIPCMetadataPackage -Package $work)
            @(Compare-NeoIPCMetadataCore -Reference $baseline -Difference $rebuilt).Count | Should -Be 0
        }
        It 'covers the domain sets when they exist ONLY on the Difference side (the union pulls UIDs from both sides)' {
            # Mirror of the round-trip case: Reference = the rebuilt (domain-dropped) package, Difference = the
            # baseline (domain present). If the comparator unioned domain UIDs from the Reference side only, the
            # Difference-side sets/options would surface as spurious Added diffs — this guards the .UnionWith line.
            $work     = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $rebuilt  = ConvertTo-NeoIPCMetadataPackage -Rows (ConvertFrom-NeoIPCMetadataPackage -Package $work)   # no domain
            $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)        # domain present
            @(Compare-NeoIPCMetadataCore -Reference $rebuilt -Difference $baseline).Count | Should -Be 0
        }
        It 'still flags a real change in a NON-domain option set' {
            $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $mutated  = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40)
            $mutated['options'][3]['name'] = 'Asa1-CHANGED'   # optAsa00001 — a non-domain option
            @(Compare-NeoIPCMetadataCore -Reference $baseline -Difference $mutated | Where-Object { $_.Kind -eq 'Changed' }).Count | Should -Be 1
        }
        It 'Test-NeoIPCMetadataDomainExcluded keys sets by code and options by parent set, sparing others' {
            $ids = Get-NeoIPCMetadataDomainOptionSetIds -Package (ConvertFrom-NeoIPCMetadataJsonText -Json ($script:domPkg | ConvertTo-Json -Depth 40))
            @($ids).Count | Should -Be 2
            Test-NeoIPCMetadataDomainExcluded -Type 'optionSets' -Object ([ordered]@{ code = 'NEOIPC_PATHOGENS' }) -DomainSetIds $ids | Should -BeTrue
            Test-NeoIPCMetadataDomainExcluded -Type 'optionSets' -Object ([ordered]@{ code = 'NEOIPC_ASA_SCORE' }) -DomainSetIds $ids | Should -BeFalse
            Test-NeoIPCMetadataDomainExcluded -Type 'options' -Object ([ordered]@{ optionSet = [ordered]@{ id = 'osSubstanc1' } }) -DomainSetIds $ids | Should -BeTrue
            Test-NeoIPCMetadataDomainExcluded -Type 'options' -Object ([ordered]@{ optionSet = [ordered]@{ id = 'osAsaScore1' } }) -DomainSetIds $ids | Should -BeFalse
            Test-NeoIPCMetadataDomainExcluded -Type 'dataElements' -Object ([ordered]@{ code = 'X' }) -DomainSetIds $ids | Should -BeFalse
        }
    }

    Describe 'Directory materialisation + retired/option-domain exclusion' {
        BeforeAll {
            # A package mixing the matrix-generated families (now MATERIALISED into the directory) with hand-authored
            # business metadata (kept) and a RETIRED aggregate rule (omitted — superseded, not in the to-be). The
            # substance PRV / rule names are the DEPLOYED *unpadded* form ("substance 1"), exercising the
            # slot-normalisation that matches them to the padded plan ("substance 01").
            $script:genPkg = [ordered]@{
                dataElements = @(
                    [ordered]@{ id = 'deBsiPat001'; code = 'NEOIPC_BSI_PATHOGEN_1'; name = 'NeoIPC BSI Organism 1'; valueType = 'INTEGER_ZERO_OR_POSITIVE' }                          # generated
                    [ordered]@{ id = 'deBsiPat3gc'; code = 'NEOIPC_BSI_PATHOGEN_1_3GCR'; name = 'NeoIPC BSI Organism 1 3GCR'; valueType = 'INTEGER' }                                    # generated
                    [ordered]@{ id = 'deSubst0001'; code = 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01'; name = 'NeoIPC Surveillance end Antibiotic substance 01'; valueType = 'TEXT' }          # generated
                    [ordered]@{ id = 'deNoPosCul1'; code = 'NEOIPC_BSI_NO_POS_CULTURE'; name = 'NeoIPC BSI no positive culture'; valueType = 'TRUE_ONLY' }                                # business, kept
                    [ordered]@{ id = 'deAdmDate01'; code = 'NEOIPC_ADM_DATE'; name = 'NeoIPC Admission date'; valueType = 'DATE' }                                                        # business, kept
                )
                programRuleVariables = @(
                    [ordered]@{ id = 'prvBsiVal01'; name = 'NeoIPC BSI Pathogen 1 value'; programRuleVariableSourceType = 'DATAELEMENT_CURRENT_EVENT' }                                  # generated
                    [ordered]@{ id = 'prvBsiMb3gc'; name = 'NeoIPC BSI Pathogen 1 may be 3GCR'; programRuleVariableSourceType = 'CALCULATED_VALUE' }                                      # generated
                    [ordered]@{ id = 'prvSubVal01'; name = 'NeoIPC Surveillance end Antibiotic substance 1 - current event value'; programRuleVariableSourceType = 'DATAELEMENT_CURRENT_EVENT' }  # generated (unpadded)
                    [ordered]@{ id = 'prvBizAbtv1'; name = 'NeoIPC BSI antibiotic treatment value'; programRuleVariableSourceType = 'DATAELEMENT_CURRENT_EVENT' }                         # business, kept
                )
                programRules = @(
                    [ordered]@{ id = 'rlSet3gcr01'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR'; condition = 'true'; programRuleActions = @([ordered]@{ id = 'acSet3gcr01' }) }            # generated
                    [ordered]@{ id = 'rlWhenEmp01'; name = 'NeoIPC BSI Pathogen 1 - when empty'; condition = '!d2:hasValue(#{x})'; programRuleActions = @([ordered]@{ id = 'acWhenEmp01' }) }  # generated
                    [ordered]@{ id = 'rlSubHide01'; name = 'NeoIPC Surveillance end Antibiotic substance 1 - hide'; condition = 'x'; programRuleActions = @([ordered]@{ id = 'acSubHide01' }) }  # generated (unpadded)
                    [ordered]@{ id = 'rlHapAggr01'; name = 'NeoIPC HAP - set pathogen attribute variables'; condition = 'true'; programRuleActions = @([ordered]@{ id = 'acHapAggr01' }) }  # retired aggregate
                    [ordered]@{ id = 'rlBizInf001'; name = 'NeoIPC BSI infection present'; condition = 'x'; programRuleActions = @([ordered]@{ id = 'acBizInf001' }) }                    # business, kept
                )
                programRuleActions = @(
                    [ordered]@{ id = 'acSet3gcr01'; programRuleActionType = 'ASSIGN'; programRule = [ordered]@{ id = 'rlSet3gcr01' } }
                    [ordered]@{ id = 'acWhenEmp01'; programRuleActionType = 'HIDEFIELD'; programRule = [ordered]@{ id = 'rlWhenEmp01' } }
                    [ordered]@{ id = 'acSubHide01'; programRuleActionType = 'HIDEFIELD'; programRule = [ordered]@{ id = 'rlSubHide01' } }
                    [ordered]@{ id = 'acHapAggr01'; programRuleActionType = 'ASSIGN'; programRule = [ordered]@{ id = 'rlHapAggr01' } }
                    [ordered]@{ id = 'acBizInf001'; programRuleActionType = 'SHOWWARNING'; programRule = [ordered]@{ id = 'rlBizInf001' } }
                )
            }
        }
        It 'Get-NeoIPCMetadataGeneratedKeys resolves the matrix refresh-identity + the retired rule ids' {
            $gk = Get-NeoIPCMetadataGeneratedKeys -Package (ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40))
            # Refresh identity (which materialised rows are generated): matrix DE codes + variable + rule names.
            $gk.DataElementCodes.Contains('NEOIPC_BSI_PATHOGEN_1') | Should -BeTrue
            $gk.DataElementCodes.Contains('NEOIPC_SURVEILLANCE_END_AB_SUBST_01') | Should -BeTrue
            $gk.DataElementCodes.Contains('NEOIPC_BSI_NO_POS_CULTURE') | Should -BeFalse
            $gk.VariableNames.Contains('NeoIPC BSI Pathogen 1 value') | Should -BeTrue
            # The deployed unpadded substance name is normalised into the (padded) matrix set.
            $gk.VariableNames.Contains('NeoIPC Surveillance end Antibiotic substance 1 - current event value') | Should -BeTrue
            $gk.RuleNames.Contains('NeoIPC BSI Pathogen 1 - set 3GCR') | Should -BeTrue
            $gk.RuleNames.Contains('NeoIPC BSI infection present') | Should -BeFalse
            # The retired aggregate is NOT a materialised matrix rule — it is tracked separately for exclusion.
            $gk.RuleNames.Contains('NeoIPC HAP - set pathogen attribute variables') | Should -BeFalse
            $gk.RetiredRuleNames.Contains('NeoIPC HAP - set pathogen attribute variables') | Should -BeTrue
            # RetiredRuleIds = in-package ids of RETIRED rules (their name-less actions drop by owning id);
            # GeneratedRuleIds = ALL generated rule ids (matrix + retired) for the classified-diff gate's selection.
            @($gk.RetiredRuleIds | Sort-Object) | Should -Be @('rlHapAggr01')
            @($gk.GeneratedRuleIds | Sort-Object) | Should -Be @('rlHapAggr01', 'rlSet3gcr01', 'rlSubHide01', 'rlWhenEmp01')
        }
        It 'Test-NeoIPCMetadataGeneratedExcluded excludes only retired rules + the antibiotic option-domain; matrix families are materialised' {
            $gk = Get-NeoIPCMetadataGeneratedKeys -Package (ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40))
            # Matrix DEs / PRVs / rules / actions are MATERIALISED -> NOT excluded.
            Test-NeoIPCMetadataGeneratedExcluded -Type 'dataElements' -Object ([ordered]@{ code = 'NEOIPC_BSI_PATHOGEN_1' }) -GeneratedKeys $gk | Should -BeFalse
            Test-NeoIPCMetadataGeneratedExcluded -Type 'programRuleVariables' -Object ([ordered]@{ name = 'NeoIPC Surveillance end Antibiotic substance 1 - current event value' }) -GeneratedKeys $gk | Should -BeFalse
            Test-NeoIPCMetadataGeneratedExcluded -Type 'programRules' -Object ([ordered]@{ name = 'NeoIPC BSI Pathogen 1 - when empty' }) -GeneratedKeys $gk | Should -BeFalse
            Test-NeoIPCMetadataGeneratedExcluded -Type 'programRuleActions' -Object ([ordered]@{ programRule = [ordered]@{ id = 'rlSet3gcr01' } }) -GeneratedKeys $gk | Should -BeFalse
            # The retired aggregate rule + its actions ARE excluded (superseded; not in the to-be directory).
            Test-NeoIPCMetadataGeneratedExcluded -Type 'programRules' -Object ([ordered]@{ name = 'NeoIPC HAP - set pathogen attribute variables' }) -GeneratedKeys $gk | Should -BeTrue
            Test-NeoIPCMetadataGeneratedExcluded -Type 'programRuleActions' -Object ([ordered]@{ programRule = [ordered]@{ id = 'rlHapAggr01' } }) -GeneratedKeys $gk | Should -BeTrue
            Test-NeoIPCMetadataGeneratedExcluded -Type 'programRuleActions' -Object ([ordered]@{ programRule = [ordered]@{ id = 'rlBizInf001' } }) -GeneratedKeys $gk | Should -BeFalse
            # The antibiotic option-domain stays generated from the curation CSVs -> excluded by code shape.
            Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroups' -Object ([ordered]@{ code = 'J01AA' }) -GeneratedKeys $gk | Should -BeTrue
            Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroups' -Object ([ordered]@{ code = 'WHO_AWARE_WATCH' }) -GeneratedKeys $gk | Should -BeTrue
            Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroups' -Object ([ordered]@{ code = 'NEOIPC_OTHER_GROUP' }) -GeneratedKeys $gk | Should -BeFalse
            Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroupSets' -Object ([ordered]@{ code = 'ATC5' }) -GeneratedKeys $gk | Should -BeTrue
            Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroupSets' -Object ([ordered]@{ code = 'WHO_AWARE' }) -GeneratedKeys $gk | Should -BeTrue
        }
        It 'the emit materialises the matrix families + business and drops only the retired aggregate' {
            $work = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40)
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package $work
            # All five DEs are kept (3 matrix + 2 business) — the matrix families are materialised, not dropped.
            # (Compare-Object asserts set equality, order-independent — Sort-Object is culture-aware.)
            (Compare-Object @($rows['dataElements'] | ForEach-Object { [string]$_['code'] }) @('NEOIPC_ADM_DATE', 'NEOIPC_BSI_NO_POS_CULTURE', 'NEOIPC_BSI_PATHOGEN_1', 'NEOIPC_BSI_PATHOGEN_1_3GCR', 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01')) | Should -BeNullOrEmpty
            (Compare-Object @($rows['programRuleVariables'] | ForEach-Object { [string]$_['name'] }) @('NeoIPC BSI Pathogen 1 value', 'NeoIPC BSI Pathogen 1 may be 3GCR', 'NeoIPC Surveillance end Antibiotic substance 1 - current event value', 'NeoIPC BSI antibiotic treatment value')) | Should -BeNullOrEmpty
            # The retired aggregate is the only rule dropped (superseded); the three matrix rules + business stay.
            (Compare-Object @($rows['programRules'] | ForEach-Object { [string]$_['name'] }) @('NeoIPC BSI Pathogen 1 - set 3GCR', 'NeoIPC BSI Pathogen 1 - when empty', 'NeoIPC Surveillance end Antibiotic substance 1 - hide', 'NeoIPC BSI infection present')) | Should -BeNullOrEmpty
            # Its action drops with it; the four kept rules' actions remain.
            @($rows['programRuleActions'] | ForEach-Object { [string]$_['id'] }) | Should -Not -Contain 'acHapAggr01'
            (Compare-Object @($rows['programRuleActions'] | ForEach-Object { [string]$_['id'] }) @('acSet3gcr01', 'acWhenEmp01', 'acSubHide01', 'acBizInf001')) | Should -BeNullOrEmpty
        }
        It 'materialises a now-directory rule together with its hand-authored action' {
            # The BSI 'when set' rule bundles a hand-authored HIDEFIELD on NEOIPC_BSI_NO_POS_CULTURE alongside the
            # generated SETMANDATORYFIELD on _SOURCE. The rule is now a MATERIALISED directory row, so BOTH actions
            # (and both DEs) are emitted with it — including the hand-authored one. (The export-independence / BSI
            # step later promotes that hand-authored action to its own stand-alone directory rule.)
            $pkg = [ordered]@{
                dataElements = @(
                    [ordered]@{ id = 'deBsiSrc001'; code = 'NEOIPC_BSI_PATHOGEN_1_SOURCE'; name = 'src'; valueType = 'INTEGER_POSITIVE' }          # matrix
                    [ordered]@{ id = 'deNoPosCul1'; code = 'NEOIPC_BSI_NO_POS_CULTURE'; name = 'no positive culture'; valueType = 'TRUE_ONLY' }       # business
                )
                programRules = @(
                    [ordered]@{ id = 'rlWhenSet01'; name = 'NeoIPC BSI Pathogen 1 - when set'; condition = 'd2:hasValue(#{x})'; programRuleActions = @([ordered]@{ id = 'acSrcMand01' }, [ordered]@{ id = 'acNoPosHid1' }) }
                )
                programRuleActions = @(
                    [ordered]@{ id = 'acSrcMand01'; programRuleActionType = 'SETMANDATORYFIELD'; programRule = [ordered]@{ id = 'rlWhenSet01' }; dataElement = [ordered]@{ id = 'deBsiSrc001' } }
                    [ordered]@{ id = 'acNoPosHid1'; programRuleActionType = 'HIDEFIELD'; programRule = [ordered]@{ id = 'rlWhenSet01' }; dataElement = [ordered]@{ id = 'deNoPosCul1' } }
                )
            }
            $rows = ConvertFrom-NeoIPCMetadataPackage -Package (ConvertFrom-NeoIPCMetadataJsonText -Json ($pkg | ConvertTo-Json -Depth 40))
            @($rows['programRules'] | ForEach-Object { [string]$_['name'] }) | Should -Be @('NeoIPC BSI Pathogen 1 - when set')
            @($rows['programRuleActions'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('acNoPosHid1', 'acSrcMand01')
            @($rows['dataElements'] | ForEach-Object { [string]$_['code'] } | Sort-Object) | Should -Be @('NEOIPC_BSI_NO_POS_CULTURE', 'NEOIPC_BSI_PATHOGEN_1_SOURCE')
        }
        It 'the comparator round-trips the materialised matrix families and skips the retired aggregate (both directions)' {
            $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40)
            $work     = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40)
            $rebuilt  = ConvertTo-NeoIPCMetadataPackage -Rows (ConvertFrom-NeoIPCMetadataPackage -Package $work)
            # The matrix families are materialised, so they survive emit->rebuild and compare equal; the retired
            # aggregate is dropped from $rebuilt, and the comparator skips it via ExcludedRuleIds on BOTH sides.
            @(Compare-NeoIPCMetadataCore -Reference $baseline -Difference $rebuilt).Count | Should -Be 0
            # Reversed sides: the retired rule + its action live only on the Reference here, guarding the
            # ExcludedRuleIds .UnionWith (without it they would surface as spurious Removed).
            @(Compare-NeoIPCMetadataCore -Reference $rebuilt -Difference $baseline).Count | Should -Be 0
        }
        It 'still flags a real change in a business rule' {
            $baseline = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40)
            $mutated  = ConvertFrom-NeoIPCMetadataJsonText -Json ($script:genPkg | ConvertTo-Json -Depth 40)
            $mutated['programRules'][4]['condition'] = 'CHANGED'   # rlBizInf001 — a kept business rule
            @(Compare-NeoIPCMetadataCore -Reference $baseline -Difference $mutated | Where-Object { $_.Kind -eq 'Changed' }).Count | Should -Be 1
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

    Describe 'Per-expression text-file externalisation (directory layout)' {
        BeforeAll {
            function New-ExprRows {
                [ordered]@{
                    programRules       = @(
                        [ordered]@{ id = 'Rule1111111'; name = 'NeoIPC BSI - set 3GCR'; condition = 'd2:hasValue(#{x})' },
                        [ordered]@{ id = 'Rule2222222'; name = 'A/B rule'; condition = "#{a}`n&& #{b}" }   # multi-line + slash in name
                    )
                    programRuleActions = @(
                        [ordered]@{ id = 'Act11111111'; programRuleActionType = 'ASSIGN'; programRule = 'Rule1111111'; data = "d2:concatenate(#{x},`n'y')" },
                        [ordered]@{ id = 'Act22222222'; programRuleActionType = 'HIDEFIELD'; programRule = 'Rule1111111'; data = '' },
                        [ordered]@{ id = 'Act33333333'; programRuleActionType = 'SHOWERROR'; programRule = 'Rule2222222'; data = '1 > 0'; content = 'msg' }
                    )
                    programIndicators  = @([ordered]@{ id = 'PI111111111'; expression = '#{a.b}'; filter = '#{c} > 0' })
                    validationRules    = @([ordered]@{ id = 'VR111111111'; leftSide_expression = 'I{x}'; rightSide_expression = '' })
                }
            }
        }
        BeforeEach {
            $script:exprDir = Join-Path $TestDrive ('expr-' + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $script:exprDir -Force | Out-Null
        }

        It 'eligibility: condition always; data only for the expression-bearing action types' {
            (Test-NeoIPCMetadataExpressionColumn -Type 'programRules' -Column 'condition' -ActionType $null) | Should -BeTrue
            (Test-NeoIPCMetadataExpressionColumn -Type 'programRuleActions' -Column 'data' -ActionType 'ASSIGN') | Should -BeTrue
            (Test-NeoIPCMetadataExpressionColumn -Type 'programRuleActions' -Column 'data' -ActionType 'SHOWERROR') | Should -BeTrue
            (Test-NeoIPCMetadataExpressionColumn -Type 'programRuleActions' -Column 'data' -ActionType 'HIDEFIELD') | Should -BeFalse
            (Test-NeoIPCMetadataExpressionColumn -Type 'programRuleActions' -Column 'data' -ActionType 'SENDMESSAGE') | Should -BeFalse
            (Test-NeoIPCMetadataExpressionColumn -Type 'programRules' -Column 'name' -ActionType $null) | Should -BeFalse
        }
        It 'segment sanitiser: reserved chars -> _, trailing dot/space trimmed, empty -> _' {
            (ConvertTo-NeoIPCExpressionPathSegment -Name 'A/B:c*?') | Should -BeExactly 'A_B_c__'
            (ConvertTo-NeoIPCExpressionPathSegment -Name 'trailing. ') | Should -BeExactly 'trailing'
            (ConvertTo-NeoIPCExpressionPathSegment -Name '') | Should -BeExactly '_'
        }
        It 'rule-segment map fails loud on a post-sanitisation name collision' {
            $rows = @([ordered]@{ id = 'R1'; name = 'A/B' }, [ordered]@{ id = 'R2'; name = 'A:B' })   # both -> 'A_B'
            { Get-NeoIPCMetadataExpressionRuleSegmentMap -RuleRows $rows } | Should -Throw '*collision*'
        }
        It 'writes per-rule co-located files (condition + the rule''s action data) and references in the cells' {
            $rows = New-ExprRows
            Write-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir
            @($rows['programRules'])[0]['condition'] | Should -BeExactly 'expressions/programRules/NeoIPC BSI - set 3GCR/condition.dhis2'
            (Test-Path -LiteralPath (Join-Path $script:exprDir 'expressions/programRules/NeoIPC BSI - set 3GCR/condition.dhis2')) | Should -BeTrue
            # the rule's ASSIGN action data co-locates under the SAME rule folder
            @($rows['programRuleActions'])[0]['data'] | Should -BeExactly 'expressions/programRules/NeoIPC BSI - set 3GCR/Act11111111.data.dhis2'
            # the slash in rule 2's name is sanitised to the folder segment
            @($rows['programRules'])[1]['condition'] | Should -BeExactly 'expressions/programRules/A_B rule/condition.dhis2'
            # program indicators / validation rules stay flat per-type
            @($rows['programIndicators'])[0]['expression'] | Should -BeExactly 'expressions/programIndicators/PI111111111.expression.dhis2'
            @($rows['programIndicators'])[0]['filter'] | Should -BeExactly 'expressions/programIndicators/PI111111111.filter.dhis2'
            @($rows['validationRules'])[0]['leftSide_expression'] | Should -BeExactly 'expressions/validationRules/VR111111111.leftSide_expression.dhis2'
        }
        It 'leaves a non-eligible action''s data inline (HIDEFIELD), and an empty value untouched' {
            $rows = New-ExprRows
            @($rows['programRuleActions'])[1]['data'] = '#{cond}'   # a (hypothetical) inline condition on a HIDEFIELD
            Write-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir
            @($rows['programRuleActions'])[1]['data'] | Should -BeExactly '#{cond}'                   # NOT externalised
            @($rows['validationRules'])[0]['rightSide_expression'] | Should -BeExactly ''             # empty -> no file
        }
        It 'round-trips verbatim through write+read (multi-line preserved)' {
            $rows = New-ExprRows
            $origCond = @($rows['programRules'])[1]['condition']
            $origData = @($rows['programRuleActions'])[0]['data']
            Write-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir
            Read-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir
            @($rows['programRules'])[1]['condition'] | Should -BeExactly $origCond
            @($rows['programRuleActions'])[0]['data'] | Should -BeExactly $origData
        }
        It 'read fails loud on a referenced-but-missing expression file' {
            $rows = [ordered]@{ programRules = @([ordered]@{ id = 'Rx'; condition = 'expressions/programRules/ghost/condition.dhis2' }) }
            { Read-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir } | Should -Throw '*not found*'
        }
        It 'read leaves an inline (non-reference) expression untouched' {
            $rows = [ordered]@{ programRules = @([ordered]@{ id = 'Rx'; condition = 'd2:hasValue(#{x})' }) }
            Read-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir
            @($rows['programRules'])[0]['condition'] | Should -BeExactly 'd2:hasValue(#{x})'
        }
        It 'rule-segment map skips a null/absent programRules collection (no crash) and returns an empty map' {
            (Get-NeoIPCMetadataExpressionRuleSegmentMap -RuleRows $null).Count | Should -Be 0
            # the production trigger: a $rows that omits programRules but carries another externalised type must not crash
            $rows = [ordered]@{ programIndicators = @([ordered]@{ id = 'PIonly00001'; expression = '#{a.b}' }) }
            { Write-NeoIPCMetadataExpressionFiles -Rows $rows -Directory $script:exprDir } | Should -Not -Throw
            @($rows['programIndicators'])[0]['expression'] | Should -BeExactly 'expressions/programIndicators/PIonly00001.expression.dhis2'
        }
        It 'wiring: ConvertFrom-/ConvertTo-NeoIPCMetadataJson externalise on emit and re-inline on read (end-to-end)' {
            $pkg = [ordered]@{
                userGroups         = @()
                programRules       = @(
                    [ordered]@{ id = 'IntgRule001'; name = 'Intg rule one'; program = [ordered]@{ id = 'ProgIntg001' }; condition = "d2:hasValue(#{v})`n&& true" }
                )
                programRuleActions = @(
                    [ordered]@{ id = 'IntgActA001'; programRuleActionType = 'ASSIGN'; programRule = [ordered]@{ id = 'IntgRule001' }; data = "d2:concatenate('a',`n'b')" }
                )
            }
            $jsonPath = Join-Path $script:exprDir 'intg.metadata.json'
            [System.IO.File]::WriteAllText($jsonPath, ($pkg | ConvertTo-Json -Depth 40), [System.Text.UTF8Encoding]::new($false))
            $outDir = Join-Path $script:exprDir 'intg-dir'
            # ConvertFrom-/ConvertTo-NeoIPCMetadataJson (re)initialise the module-global sharing-profile registry;
            # save + restore it so this integration test does not pollute the sharing state other Describes rely on.
            $savedSharing = $script:NeoIPCSharingProfiles
            try {
                ConvertFrom-NeoIPCMetadataJson -Path $jsonPath -OutputDirectory $outDir
                # emit hook: per-rule co-located files written; the CSV cell holds the reference, not the value
                (Test-Path -LiteralPath (Join-Path $outDir 'expressions/programRules/Intg rule one/condition.dhis2')) | Should -BeTrue
                (Test-Path -LiteralPath (Join-Path $outDir 'expressions/programRules/Intg rule one/IntgActA001.data.dhis2')) | Should -BeTrue
                @(Import-Csv -LiteralPath (Join-Path $outDir 'programRules.csv'))[0].condition | Should -Match '^expressions/programRules/'
                # read hook: the multi-line expression is re-inlined verbatim
                $back = (ConvertTo-NeoIPCMetadataJson -Path $outDir) | ConvertFrom-Json -AsHashtable
                (@($back['programRules'] | Where-Object { $_['id'] -eq 'IntgRule001' })[0]['condition']) | Should -BeExactly "d2:hasValue(#{v})`n&& true"
                (@($back['programRuleActions'] | Where-Object { $_['id'] -eq 'IntgActA001' })[0]['data']) | Should -BeExactly "d2:concatenate('a',`n'b')"
            }
            finally { $script:NeoIPCSharingProfiles = $savedSharing }
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
                # When a full export carries the excluded (org-unit instances / PII / server-generated) and the
                # non-closure (org-unit groups / user roles) collections top-level plus the system default
                # categoryCombo (referenced by every dataElement), those must keep their UIDs so the package still
                # binds on import. bjDvmb4bfuf is a default-UID member.
                $pkg = [ordered]@{
                    programs = @([ordered]@{ id = 'progAAAA001'; code = 'NEOIPC_CORE'; name = 'C'; programType = 'WITH_REGISTRATION' })
                    dataElements = @([ordered]@{ id = 'deAAAA00001'; code = 'NEOIPC_X'; name = 'X'; valueType = 'TEXT'; categoryCombo = [ordered]@{ id = 'bjDvmb4bfuf' } })
                    categoryCombos = @([ordered]@{ id = 'bjDvmb4bfuf'; code = 'default'; name = 'default'; dataDimensionType = 'DISAGGREGATION' })
                    organisationUnits = @([ordered]@{ id = 'ouRealOrg01'; name = 'Real OU' })          # excluded (authored org-unit instances) -> keeps its UID
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

    Describe 'Authored org-unit reading (UID-keyed directory -> objects)' {
        BeforeAll {
            $script:ouCommon = Join-Path $TestDrive 'common-ou.csv'
            $script:ouPlay = Join-Path $TestDrive 'play-ou.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing',
              'ouROOT00001,ROOT,Root,Root,2023-01-01,,1,,,',
              'ouCtryA0001,CtryA,Country A,CtryA,2023-01-01,,2,ouROOT00001,,') | Set-Content -LiteralPath $script:ouCommon -Encoding utf8
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing',
              'ouCtryAH001,CtryA_TEST,Hospital A,Hosp A,2023-01-01,,3,ouCtryA0001,,',
              'ouCtryAHD01,CtryA_TEST_TEST,Dept A,Dept A,2023-01-01,,4,ouCtryAH001,,') | Set-Content -LiteralPath $script:ouPlay -Encoding utf8
        }
        It 'reads UID-keyed CSVs across files, preserving committed ids, level, and parent refs' {
            $ous = Read-NeoIPCAuthoredOrgUnit -Path $script:ouCommon, $script:ouPlay
            $ous.Count | Should -Be 4
            $byCode = @{}; $ous | ForEach-Object { $byCode[$_.code] = $_ }
            $byCode['ROOT'].id | Should -BeExactly 'ouROOT00001'              # committed UID preserved, not minted
            $byCode['ROOT'].level | Should -Be 1                              # coerced from the cell string...
            $byCode['ROOT'].level | Should -BeOfType [long]                   # ...to Int64 (int-class cells parse via [long]::Parse), not a left-over string
            $byCode['ROOT'].Contains('parent') | Should -BeFalse             # root: empty parent cell -> absent
            $byCode['CtryA'].level | Should -Be 2
            $byCode['CtryA_TEST'].level | Should -Be 3                         # parent defined in the OTHER file
            $byCode['CtryA_TEST_TEST'].level | Should -Be 4
            $byCode['CtryA_TEST_TEST']['parent']['id'] | Should -BeExactly 'ouCtryAH001'   # parent UID preserved
        }
        It 'produces valid UID-keyed content (each unit round-trips through the converter)' {
            $ous = Read-NeoIPCAuthoredOrgUnit -Path $script:ouCommon, $script:ouPlay
            foreach ($o in $ous) {
                $r = Get-RowRoundTrip 'organisationUnits' $o
                $r.Equal | Should -BeTrue -Because ($r.A + ' vs ' + $r.B)
            }
        }
        It 'throws on a missing file' {
            { Read-NeoIPCAuthoredOrgUnit -Path (Join-Path $TestDrive 'nope.csv') } | Should -Throw '*Org-unit CSV not found*'
        }
        It 'throws on a duplicate org-unit code across files (would clobber membership / assignment resolution)' {
            $a = Join-Path $TestDrive 'dupcode-a.csv'
            $b = Join-Path $TestDrive 'dupcode-b.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouDupAAAAA1,DUP,Dup A,Dup A,2023-01-01,,2,,,') | Set-Content -LiteralPath $a -Encoding utf8
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouDupBBBBB2,DUP,Dup B,Dup B,2023-01-01,,2,,,') | Set-Content -LiteralPath $b -Encoding utf8
            { Read-NeoIPCAuthoredOrgUnit -Path $a, $b } | Should -Throw "*Duplicate authored org-unit code 'DUP'*"
        }
        It 'throws on a duplicate org-unit UID across files (would collide at idScheme=UID import)' {
            $a = Join-Path $TestDrive 'dupid-a.csv'
            $b = Join-Path $TestDrive 'dupid-b.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouSameIDAA1,CODEA,A,A,2023-01-01,,2,,,') | Set-Content -LiteralPath $a -Encoding utf8
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouSameIDAA1,CODEB,B,B,2023-01-01,,2,,,') | Set-Content -LiteralPath $b -Encoding utf8
            { Read-NeoIPCAuthoredOrgUnit -Path $a, $b } | Should -Throw '*Duplicate authored org-unit UID*'
        }
        It 'throws on a malformed org-unit UID (a blank/invalid id would otherwise slip past the assembly collision guard)' {
            $bad = Join-Path $TestDrive 'badid-ou.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'not-a-uid,CODEX,X,X,2023-01-01,,2,,,') | Set-Content -LiteralPath $bad -Encoding utf8
            { Read-NeoIPCAuthoredOrgUnit -Path $bad } | Should -Throw '*invalid UID*'
        }
        It 'throws on a malformed parent UID' {
            $bad = Join-Path $TestDrive 'badparent-ou.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouChildAAA1,CHILD,C,C,2023-01-01,,2,badparentX,,') | Set-Content -LiteralPath $bad -Encoding utf8
            { Read-NeoIPCAuthoredOrgUnit -Path $bad } | Should -Throw '*invalid parent UID*'
        }
        It 'throws on a parent UID that is well-formed but resolves to no org unit in the set (dangling parent)' {
            $bad = Join-Path $TestDrive 'danglingparent-ou.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouChildAAA1,CHILD,Child,Child,2023-01-01,,2,ouNoSuchAA9,,') | Set-Content -LiteralPath $bad -Encoding utf8
            { Read-NeoIPCAuthoredOrgUnit -Path $bad } | Should -Throw '*unknown parent UID*'
        }
        It 'throws on a blank DHIS2 not-null field (name / shortName / openingDate)' {
            $bad = Join-Path $TestDrive 'noname-ou.csv'
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing', 'ouNoNameAA1,NONAME,,Short,2023-01-01,,2,,,') | Set-Content -LiteralPath $bad -Encoding utf8
            { Read-NeoIPCAuthoredOrgUnit -Path $bad } | Should -Throw '*non-empty name*'
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
        It 'preserves a committed UID from a UID-keyed users.csv (instead of minting)' {
            $uidUsers = Join-Path $TestDrive 'users-uid.csv'
            @('id,username,firstName,surname', 'uPreserved1,play.a.1,Play,A One') | Set-Content -LiteralPath $uidUsers -Encoding utf8
            $ur = Join-Path $TestDrive 'ur-uid.csv'
            @('username,role', 'play.a.1,Base') | Set-Content -LiteralPath $ur -Encoding utf8
            $uo = Join-Path $TestDrive 'uo-uid.csv'
            @('username,organisationUnit', 'play.a.1,DeptA') | Set-Content -LiteralPath $uo -Encoding utf8
            $u = ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $uidUsers -RoleAssignmentPath $ur -OrgUnitAssignmentPath $uo -RoleUid $script:roleUid -OrgUnitUid $script:ouUid
            $u[0].id | Should -BeExactly 'uPreserved1'
        }
        It 'falls back to a deterministic mint when the row id is present but not a valid UID' {
            $badId = Join-Path $TestDrive 'users-badid.csv'
            @('id,username,firstName,surname', 'not-a-uid,play.a.1,Play,A One') | Set-Content -LiteralPath $badId -Encoding utf8
            $ur = Join-Path $TestDrive 'ur-badid.csv'; @('username,role', 'play.a.1,Base') | Set-Content -LiteralPath $ur -Encoding utf8
            $uo = Join-Path $TestDrive 'uo-badid.csv'; @('username,organisationUnit', 'play.a.1,DeptA') | Set-Content -LiteralPath $uo -Encoding utf8
            $u = ConvertFrom-NeoIPCAuthoredUserCsv -UserPath $badId -RoleAssignmentPath $ur -OrgUnitAssignmentPath $uo -RoleUid $script:roleUid -OrgUnitUid $script:ouUid
            Test-NeoIPCMetadataUid -Id $u[0].id | Should -BeTrue                                       # not the malformed 'not-a-uid'
            $u[0].id | Should -BeExactly (New-NeoIPCMetadataUid -Type 'users' -NaturalKey 'play.a.1')   # minted from the username
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
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing',
              'ouNEOIPC001,NEOIPC,Root,Root,2023-01-01,,1,,,',
              'ouCtryA0001,CtryA,Country A,CtryA,2023-01-01,,2,ouNEOIPC001,,',
              'ouCtryB0001,CtryB,Country B,CtryB,2023-01-01,,2,ouNEOIPC001,,',
              'ouCtryAH001,CtryA_TEST,Hospital A,Hosp A,2023-01-01,,3,ouCtryA0001,,',
              'ouCtryAHD01,CtryA_TEST_TEST,Dept A,Dept A,2023-01-01,,4,ouCtryAH001,,') | Set-Content -LiteralPath $script:gmOu -Encoding utf8
            $script:gmOrgUnits = Read-NeoIPCAuthoredOrgUnit -Path $script:gmOu
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

    Describe 'Play-package assembly (Join + collision + group-side membership)' {
        BeforeEach {
            # A minimal captured config: a closure type, the non-closure group/role definitions, and a
            # server-generated combo. Rebuilt per test because Join mutates it in place.
            $script:asmConfig = [ordered]@{
                programs               = @([ordered]@{ id = 'prog0000001'; code = 'NEOIPC_CORE'; name = 'Core' })
                organisationUnitGroups = @(
                    [ordered]@{ id = 'oug0000001'; code = 'HOSPITAL'; name = 'Hospital' },
                    [ordered]@{ id = 'oug0000002'; code = 'COUNTRY'; name = 'Country' },
                    [ordered]@{ id = 'oug0000003'; code = 'NEO_DEPARTMENT'; name = 'Neonatology Department' })
                userGroups             = @([ordered]@{ id = 'ug00000001'; code = 'NEOIPC'; name = 'NeoIPC' })
                categoryOptionCombos   = @([ordered]@{ id = 'coc0000001'; name = 'default' })
            }
            $script:asmOus = @(
                [ordered]@{ id = 'ou00000001'; code = 'AT'; level = 2 },
                [ordered]@{ id = 'ou00000002'; code = 'AT_TEST'; level = 3 },
                [ordered]@{ id = 'ou00000003'; code = 'AT_TEST_TEST'; level = 4 })
            $script:asmUsers = @([ordered]@{ id = 'usr0000001'; username = 'play.a' })
        }
        It 'recursively collects object and reference ids' {
            $node = [ordered]@{ id = 'aaaaaaaaaa1'; child = [ordered]@{ id = 'bbbbbbbbbb2' }; list = @([ordered]@{ id = 'cccccccccc3'; ref = [ordered]@{ id = 'dddddddddd4' } }) }
            $acc = [System.Collections.Generic.HashSet[string]]::new()
            Add-NeoIPCMetadataId -Node $node -Accumulator $acc
            $acc.Count | Should -Be 4
            $acc.Contains('dddddddddd4') | Should -BeTrue
        }
        It 'stitches authored org units / users in, drops server-generated combos, applies memberships group-side' {
            $oug = ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership -OrgUnit $script:asmOus   # structural: COUNTRY/HOSPITAL/NEO_DEPARTMENT
            $ug = [ordered]@{ NEOIPC = @('usr0000001') }
            $pkg = Join-NeoIPCMetadataPackage -Config $script:asmConfig -OrgUnit $script:asmOus -User $script:asmUsers -OrgUnitGroupMembership $oug -UserGroupMembership $ug
            $pkg.Contains('categoryOptionCombos') | Should -BeFalse
            @($pkg['organisationUnits']).Count | Should -Be 3
            @($pkg['users']).Count | Should -Be 1
            ($pkg['organisationUnitGroups'] | Where-Object { $_.code -eq 'HOSPITAL' }).organisationUnits[0].id | Should -BeExactly 'ou00000002'
            ($pkg['organisationUnitGroups'] | Where-Object { $_.code -eq 'COUNTRY' }).organisationUnits[0].id | Should -BeExactly 'ou00000001'
            ($pkg['userGroups'] | Where-Object { $_.code -eq 'NEOIPC' }).users[0].id | Should -BeExactly 'usr0000001'
        }
        It 'throws when an authored org-unit UID collides with a captured object id' {
            $collide = @([ordered]@{ id = 'prog0000001'; code = 'X_TEST'; level = 3 })   # same id as the program
            { Join-NeoIPCMetadataPackage -Config $script:asmConfig -OrgUnit $collide -User @() -OrgUnitGroupMembership ([ordered]@{}) -UserGroupMembership ([ordered]@{}) } | Should -Throw '*collides*'
        }
        It 'throws when an authored user UID collides with an authored org-unit UID (cross-check)' {
            $u = @([ordered]@{ id = 'ou00000001'; username = 'clash' })   # same id as the AT org unit
            { Join-NeoIPCMetadataPackage -Config $script:asmConfig -OrgUnit $script:asmOus -User $u -OrgUnitGroupMembership ([ordered]@{}) -UserGroupMembership ([ordered]@{}) } | Should -Throw '*collides*'
        }
        It 'fails loud (does not silently drop) when a membership names a group type wholly absent from the config' {
            $config = [ordered]@{ programs = @([ordered]@{ id = 'prog0000001'; code = 'NEOIPC_CORE'; name = 'Core' }) }   # no organisationUnitGroups type at all
            $mem = [ordered]@{ NEO_DEPARTMENT = @('ou00000003') }
            { Join-NeoIPCMetadataPackage -Config $config -OrgUnit $script:asmOus -User $script:asmUsers -OrgUnitGroupMembership $mem -UserGroupMembership ([ordered]@{}) } | Should -Throw '*not present*'
        }
    }

    Describe 'New-NeoIPCMetadataPackage (public assembler: export-free directory read; production / -Play)' {
        BeforeAll {
            # A minimal canonical directory — the build reads it ALONE (no export). common/ carries the config the
            # assembler needs: the org-unit scaffold (root + AT country), the userRoles (role-name -> UID map), and
            # the three structural org-unit groups the derived membership lands on. play/ carries the synthetic test
            # hierarchy (AT_TEST hospital + AT_TEST_TEST dept, one user). No membership files -> exercises the
            # optional-file guards; the only memberships are the structural COUNTRY/HOSPITAL/NEO_DEPARTMENT
            # derivation off the codes.
            $script:asmDir = Join-Path $TestDrive 'asm-mdir'
            $commonDir = Join-Path $script:asmDir 'common'
            $playDir = Join-Path $script:asmDir 'play'
            New-Item -ItemType Directory -Path $commonDir -Force | Out-Null
            New-Item -ItemType Directory -Path $playDir -Force | Out-Null
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing',
              'ouNEOIPC001,NEOIPC,NeoIPC,NeoIPC,2023-01-01,,1,,,',
              'ouAT0000001,AT,Austria,Austria,2023-01-01,,2,ouNEOIPC001,,') | Set-Content -LiteralPath (Join-Path $commonDir 'organisationUnits.csv') -Encoding utf8
            @('id,name,sharing',
              'roleBase001,Base,',
              'roleData001,Data entry,',
              'roleSuper01,Superuser,') | Set-Content -LiteralPath (Join-Path $commonDir 'userRoles.csv') -Encoding utf8
            @('id,code,name,sharing',
              'oug0000001,HOSPITAL,Hospital,',
              'oug0000002,COUNTRY,Country,',
              'oug0000003,NEO_DEPARTMENT,Neonatology Department,') | Set-Content -LiteralPath (Join-Path $commonDir 'organisationUnitGroups.csv') -Encoding utf8
            @('id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing',
              'ouATTEST001,AT_TEST,Hospital,Hospital,2023-01-01,,3,ouAT0000001,,',
              'ouATTESTT01,AT_TEST_TEST,Dept,Dept,2023-01-01,,4,ouATTEST001,,') | Set-Content -LiteralPath (Join-Path $playDir 'organisationUnits.csv') -Encoding utf8
            @('id,username,firstName,surname', 'usrPlayAT01,play.at.user1,Play,AT User 1') | Set-Content -LiteralPath (Join-Path $playDir 'users.csv') -Encoding utf8
            @('username,role', 'play.at.user1,Base', 'play.at.user1,Data entry') | Set-Content -LiteralPath (Join-Path $playDir 'userRoleAssignments.csv') -Encoding utf8
            @('username,organisationUnit', 'play.at.user1,AT_TEST_TEST') | Set-Content -LiteralPath (Join-Path $playDir 'userOrgUnitAssignments.csv') -Encoding utf8
        }
        It 'assembles the play variant from common + play, preserving committed UIDs and resolving role names' {
            $res = New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -Play -SkipGeneration -PassThru -WarningAction SilentlyContinue
            $res.OrgUnitCount | Should -Be 4          # 2 common + 2 play
            $res.UserCount | Should -Be 1
            $pkg = $res.Package
            @($pkg['organisationUnits']).Count | Should -Be 4
            @($pkg['users']).Count | Should -Be 1
            $pkg['users'][0]['id'] | Should -BeExactly 'usrPlayAT01'                                       # committed UID preserved
            @($pkg['users'][0]['userRoles'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('roleBase001', 'roleData001')   # role NAME -> directory UID
            ($pkg['organisationUnitGroups'] | Where-Object { $_.code -eq 'COUNTRY' }).organisationUnits[0].id | Should -BeExactly 'ouAT0000001'
            ($pkg['organisationUnitGroups'] | Where-Object { $_.code -eq 'HOSPITAL' }).organisationUnits[0].id | Should -BeExactly 'ouATTEST001'
            ($pkg['organisationUnitGroups'] | Where-Object { $_.code -eq 'NEO_DEPARTMENT' }).organisationUnits[0].id | Should -BeExactly 'ouATTESTT01'
        }
        It 'emits JSON (no -PassThru) carrying the assembled org units' {
            $json = New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -Play -SkipGeneration -WarningAction SilentlyContinue
            $json | Should -Match '"organisationUnits"'
        }
        It 'without -SkipGeneration, splices the generated option-domain into the package (exercises the generation branch)' {
            # The four option-domain generators are mocked so the branch runs without the YAML / antibiotics sources.
            Mock New-NeoIPCPathogenOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osPbuild'; code = 'NEOIPC_PATHOGENS' }); options = @([ordered]@{ id = 'optP0build'; code = '0'; optionSet = [ordered]@{ id = 'osPbuild' } }) } }
            Mock New-NeoIPCAntimicrobialOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osAbxbuild'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES' }); options = @() } }
            Mock New-NeoIPCAntibioticOptionGroup { [ordered]@{ optionGroups = @([ordered]@{ id = 'ogAtcbuild'; code = 'J01AA' }) } }
            Mock New-NeoIPCAntibioticOptionGroupSet { [ordered]@{ optionGroupSets = @([ordered]@{ id = 'ogsAtcbuild'; code = 'ATC5' }) } }
            $res = New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -Play -PassThru -WarningAction SilentlyContinue
            @($res.Package['optionSets'] | Where-Object { [string]$_['code'] -eq 'NEOIPC_PATHOGENS' }).Count | Should -Be 1
            @($res.Package['optionGroups'] | Where-Object { [string]$_['id'] -eq 'ogAtcbuild' }).Count | Should -Be 1
            Should -Invoke New-NeoIPCAntibioticOptionGroupSet -Times 1
        }
        It 'production (no overlay) is the install base — config + groups/roles, no org units or users' {
            $res = New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -SkipGeneration -PassThru -WarningAction SilentlyContinue
            $res.OrgUnitCount | Should -Be 0
            $res.UserCount | Should -Be 0
            @($res.Package['organisationUnitGroups']).Count | Should -Be 3      # the group DEFINITIONS are still carried
            @($res.Package['userRoles']).Count | Should -Be 3
        }
        It 'production throws when the -OverlayPath does not exist' {
            { New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -OverlayPath (Join-Path $TestDrive 'no-such-overlay') -WarningAction SilentlyContinue } | Should -Throw '*Overlay directory not found*'
        }
        It 'production reads the supplied -OverlayPath instead of play/' {
            # An overlay with a DIFFERENT user set proves the overlay (not play/) is the variant source.
            $overlay = Join-Path $TestDrive 'asm-prod-overlay'
            New-Item -ItemType Directory -Path $overlay -Force | Out-Null
            Copy-Item (Join-Path $playDir 'organisationUnits.csv') (Join-Path $overlay 'organisationUnits.csv')
            @('id,username,firstName,surname', 'usrProdX0001,prod.x.1,Prod,X One', 'usrProdX0002,prod.x.2,Prod,X Two') | Set-Content -LiteralPath (Join-Path $overlay 'users.csv') -Encoding utf8
            @('username,role', 'prod.x.1,Base', 'prod.x.2,Base') | Set-Content -LiteralPath (Join-Path $overlay 'userRoleAssignments.csv') -Encoding utf8
            @('username,organisationUnit', 'prod.x.1,AT_TEST_TEST', 'prod.x.2,AT_TEST_TEST') | Set-Content -LiteralPath (Join-Path $overlay 'userOrgUnitAssignments.csv') -Encoding utf8
            $res = New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -OverlayPath $overlay -SkipGeneration -PassThru -WarningAction SilentlyContinue
            $res.UserCount | Should -Be 2                                                                  # the overlay's users
            @($res.Package['users'] | ForEach-Object { [string]$_['username'] } | Sort-Object) | Should -Be @('prod.x.1', 'prod.x.2')
        }
        It '-Play and -OverlayPath are mutually exclusive (parameter sets)' {
            { New-NeoIPCMetadataPackage -MetadataDirectory $script:asmDir -Play -OverlayPath $TestDrive -SkipGeneration -WarningAction SilentlyContinue } | Should -Throw
        }
        It 'throws when the metadata directory is missing' {
            { New-NeoIPCMetadataPackage -MetadataDirectory (Join-Path $TestDrive 'no-such-dir') -WarningAction SilentlyContinue } | Should -Throw '*Metadata directory not found*'
        }
        It 'throws when the common/ subdirectory is missing' {
            $bare = Join-Path $TestDrive 'asm-bare'
            New-Item -ItemType Directory -Path (Join-Path $bare 'play') -Force | Out-Null
            { New-NeoIPCMetadataPackage -MetadataDirectory $bare -Play -WarningAction SilentlyContinue } | Should -Throw '*Common metadata directory not found*'
        }
    }

    Describe 'Translation property/token model (intersection with the type maps)' {
        It 'derives translatable fields as type-map Properties intersect the translatable-property table' {
            $f = Get-NeoIPCMetadataTranslatableField -Type 'organisationUnitGroups'
            @($f | ForEach-Object { $_.Property }) | Should -Be @('name', 'shortName', 'description')
            @($f | ForEach-Object { $_.Token }) | Should -Be @('NAME', 'SHORT_NAME', 'DESCRIPTION')
        }
        It 'maps a property to its literal DHIS2 token, not a generic uppercase' {
            $f = Get-NeoIPCMetadataTranslatableField -Type 'programs'
            ($f | Where-Object { $_.Property -eq 'enrollmentDateLabel' }).Token | Should -BeExactly 'ENROLLMENT_DATE_LABEL'
            $nt = Get-NeoIPCMetadataTranslatableField -Type 'programNotificationTemplates'
            ($nt | Where-Object { $_.Property -eq 'subjectTemplate' }).Token | Should -BeExactly 'SUBJECT_TEMPLATE'
        }
        It 'omits a translatable base property the type map does not carry (options has no shortName)' {
            @(Get-NeoIPCMetadataTranslatableField -Type 'options' | ForEach-Object { $_.Property }) | Should -Be @('name')
        }
        It 'returns no fields for a non-translatable type' {
            (Get-NeoIPCMetadataTranslatableField -Type 'analyticsPeriodBoundaries').Count | Should -Be 0
        }
    }

    Describe 'Translation msgctxt key (stable, code-based)' {
        It 'keys an option by <optionSetCode>/<optionCode>' {
            $opt = [ordered]@{ id = 'OPaaaaaaaa1'; code = '1'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' } }
            Get-NeoIPCMetadataTranslationKey -Type 'options' -Object $opt -OptionSetCodeById @{ 'OSaaaaaaaa1' = 'NEOIPC_ASA_SCORE' } | Should -BeExactly 'NEOIPC_ASA_SCORE/1'
        }
        It 'keys a coded object by its code' {
            Get-NeoIPCMetadataTranslationKey -Type 'organisationUnitGroups' -Object ([ordered]@{ code = 'NEO_DEPARTMENT'; name = 'Departments' }) | Should -BeExactly 'NEO_DEPARTMENT'
        }
        It 'keys a code-less object by its UID, not the name (DHIS2 names are not unique)' {
            Get-NeoIPCMetadataTranslationKey -Type 'programRules' -Object ([ordered]@{ id = 'PRabc123XYZ'; name = 'Rule X' }) | Should -BeExactly 'PRabc123XYZ'
        }
        It 'returns null when an option cannot resolve its set code (no stable identity)' {
            Get-NeoIPCMetadataTranslationKey -Type 'options' -Object ([ordered]@{ code = '1'; optionSet = [ordered]@{ id = 'OSunknown01' } }) | Should -BeNullOrEmpty
        }
    }

    Describe 'Generated-family translation keys (stable semantic msgctxt — change-locality)' {
        It 'derives stable DE-code-scheme keys for every generated PRV / rule family (name- and UID-independent)' {
            $idx = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package ([ordered]@{})
            # Resistance PRVs (primary + secondary), field-gating PRV, substance PRV (slot-padding-normalised lookup).
            $idx.VariableKeyByName['NeoIPC BSI Pathogen 1 value'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_VALUE'
            $idx.VariableKeyByName['NeoIPC BSI Pathogen 1 may be 3GCR'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_MAYBE_3GCR'
            $idx.VariableKeyByName['NeoIPC BSI Pathogen 1 may be carbapenem-resistant'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_MAYBE_CAR'
            $idx.VariableKeyByName['NeoIPC HAP Secondary BSI pathogen 1 value'] | Should -BeExactly 'NEOIPC_HAP_SEC_BSI_PATHOGEN_1_VALUE'
            $idx.VariableKeyByName['NeoIPC BSI Pathogen 1 is recognized pathogen'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_IS_RECOGNIZED'
            $idx.VariableKeyByName['NeoIPC Surveillance end Antibiotic substance 1 - current event value'] | Should -BeExactly 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_VALUE'
            $idx.VariableKeyByName['NeoIPC Surveillance end Antibiotic substance 1 days - current event value'] | Should -BeExactly 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS_VALUE'
            # Rules: the resistance triple, the field-gating kinds, the substance cluster.
            $idx.RuleKeyByName['NeoIPC BSI Pathogen 1 - set 3GCR'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_SET_3GCR'
            $idx.RuleKeyByName['NeoIPC BSI Pathogen 1 - not VRE'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_NOT_VRE'
            $idx.RuleKeyByName['NeoIPC BSI Pathogen 1 - when empty'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_WHEN_EMPTY'
            $idx.RuleKeyByName['NeoIPC BSI Pathogen 1 - set recognized pathogen'] | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_SET_RECOGNIZED'
            $idx.RuleKeyByName['NeoIPC Surveillance end Antibiotic substance 1 - hide'] | Should -BeExactly 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_HIDE'
            $idx.RuleKeyByName['NeoIPC Surveillance end Antibiotic substance days - validate'] | Should -BeExactly 'NEOIPC_SURVEILLANCE_END_AB_SUBST_DAYS_VALIDATE'
        }
        It 'resolves a generated rule / variable to its semantic key and a hand-authored code-less object to null' {
            $idx = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package ([ordered]@{})
            Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRules' -Object ([ordered]@{ id = 'rl1'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR' }) -Index $idx | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_SET_3GCR'
            Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRuleVariables' -Object ([ordered]@{ id = 'pv1'; name = 'NeoIPC BSI Pathogen 1 value' }) -Index $idx | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_VALUE'
            Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRules' -Object ([ordered]@{ id = 'rlx'; name = 'NeoIPC BSI infection present' }) -Index $idx | Should -BeNullOrEmpty
        }
        It 'keys a generated action by owning-rule key + action type (+ target DE code), unique across a multi-action rule' {
            $pkg = [ordered]@{
                dataElements = @(
                    [ordered]@{ id = 'deNam2'; code = 'NEOIPC_BSI_PATHOGEN_2_NAME' }
                )
                programRules = @(
                    [ordered]@{ id = 'rlWE1'; name = 'NeoIPC BSI Pathogen 1 - when empty' }
                    [ordered]@{ id = 'rlSet1'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR' }
                )
            }
            $idx = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package (ConvertFrom-NeoIPCMetadataJsonText -Json ($pkg | ConvertTo-Json -Depth 40))
            # ASSIGN with no DE target -> <ruleKey>/ASSIGN
            Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRuleActions' -Object ([ordered]@{ programRuleActionType = 'ASSIGN'; programRule = [ordered]@{ id = 'rlSet1' } }) -Index $idx | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_SET_3GCR/ASSIGN'
            # HIDEFIELD with a DE target -> <ruleKey>/HIDEFIELD/<deCode>
            Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRuleActions' -Object ([ordered]@{ programRuleActionType = 'HIDEFIELD'; programRule = [ordered]@{ id = 'rlWE1' }; dataElement = [ordered]@{ id = 'deNam2' } }) -Index $idx | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_WHEN_EMPTY/HIDEFIELD/NEOIPC_BSI_PATHOGEN_2_NAME'
            # an action on a non-generated rule -> null (it keeps its UID key)
            Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRuleActions' -Object ([ordered]@{ programRuleActionType = 'HIDEFIELD'; programRule = [ordered]@{ id = 'rlUnknown' } }) -Index $idx | Should -BeNullOrEmpty
        }
        It 'extract: a generated code-less object keys by the semantic key; a hand-authored one keeps its UID' {
            $pkg = [ordered]@{
                programRuleVariables = @(
                    [ordered]@{ id = 'pvGen00001'; name = 'NeoIPC BSI Pathogen 1 may be MRSA' }    # generated
                    [ordered]@{ id = 'pvHand0001'; name = 'NeoIPC custom hand-authored variable' }  # hand-authored
                )
            }
            $msgctxts = @(Get-NeoIPCMetadataTranslationUnit -Package $pkg | ForEach-Object { $_.Msgctxt })
            $msgctxts | Should -Contain 'programRuleVariables/NEOIPC_BSI_PATHOGEN_1_MAYBE_MRSA/NAME'
            $msgctxts | Should -Contain 'programRuleVariables/pvHand0001/NAME'
        }
        It 'the generated key is independent of the object UID (no churn when a deployed UID is reused vs minted)' {
            $idx = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package ([ordered]@{})
            $a = Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRules' -Object ([ordered]@{ id = 'realUID0001'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR' }) -Index $idx
            $b = Get-NeoIPCMetadataGeneratedTranslationKey -Type 'programRules' -Object ([ordered]@{ id = 'mintedXYZ99'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR' }) -Index $idx
            $a | Should -BeExactly $b
            $a | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1_SET_3GCR'
        }
        It 'adding a slot is additive: every key from a smaller slot count survives unchanged (bounded diff)' {
            $idx3 = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package ([ordered]@{}) -PathogenCount 3 -SubstanceCount 9
            $idx4 = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package ([ordered]@{}) -PathogenCount 4 -SubstanceCount 9
            foreach ($n in $idx3.VariableKeyByName.Keys) { $idx4.VariableKeyByName[$n] | Should -BeExactly $idx3.VariableKeyByName[$n] }
            foreach ($n in $idx3.RuleKeyByName.Keys) { $idx4.RuleKeyByName[$n] | Should -BeExactly $idx3.RuleKeyByName[$n] }
            $idx4.RuleKeyByName.Count | Should -BeGreaterThan $idx3.RuleKeyByName.Count   # slot 4 only ADDS entries
        }
    }

    Describe 'PO string escaping' {
        It 'escapes and unescapes quote / backslash / newline / tab losslessly' {
            $raw = "a `"quoted`" b\c`nline2`ttab"
            $esc = ConvertTo-NeoIPCPoString $raw
            $esc | Should -Not -Match "`n"
            (ConvertFrom-NeoIPCPoString $esc) | Should -BeExactly $raw
        }
        It 'handles empty / null' {
            (ConvertTo-NeoIPCPoString '') | Should -BeExactly ''
            (ConvertFrom-NeoIPCPoString '') | Should -BeExactly ''
        }
    }

    Describe 'Metadata translation extract / emit / parse / inject (PO round-trip)' {
        BeforeAll {
            function New-TranslationFixture {
                [ordered]@{
                    optionSets        = @( [ordered]@{ id = 'OSaaaaaaaa1'; code = 'NEOIPC_ASA_SCORE'; name = 'ASA score' } )
                    options           = @(
                        [ordered]@{ id = 'OPaaaaaaaa1'; code = '1'; name = 'ASA I'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' }
                            translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'ASA I (de)' }, [ordered]@{ property = 'NAME'; locale = 'es'; value = 'ASA I (es)' } )
                        }
                        [ordered]@{ id = 'OPaaaaaaaa2'; code = '2'; name = 'ASA II'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' } }
                    )
                    organisationUnitGroups = @(
                        [ordered]@{ id = 'OGaaaaaaaa1'; code = 'NEO_DEPARTMENT'; name = 'Departments'; shortName = 'Depts'
                            translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'Abteilungen' } )
                        }
                    )
                }
            }
            function Get-InjectedFixture {
                # Extract -> per-locale PO -> parse -> inject into a translations-stripped copy. Returns the package.
                $src = New-TranslationFixture
                $units = Get-NeoIPCMetadataTranslationUnit -Package $src
                $po = @{}
                foreach ($loc in 'de', 'es') {
                    $po[$loc] = Read-NeoIPCMetadataPoText -Text (Write-NeoIPCMetadataPoText -Entry (ConvertTo-NeoIPCMetadataPoEntry -Unit $units -Locale $loc) -Locale $loc)
                }
                $clean = ConvertFrom-NeoIPCMetadataJsonText -Json (New-TranslationFixture | ConvertTo-Json -Depth 40)
                foreach ($t in 'options', 'organisationUnitGroups') { foreach ($o in @($clean[$t])) { $o.Remove('translations') | Out-Null } }
                Add-NeoIPCMetadataTranslationToPackage -Package $clean -PoByLocale $po
            }
        }
        It 'extracts one unit per (object, translatable field) with a non-empty base value' {
            $units = Get-NeoIPCMetadataTranslationUnit -Package (New-TranslationFixture)
            @($units | ForEach-Object { $_.Msgctxt }) | Should -Be @(
                'options/NEOIPC_ASA_SCORE/1/NAME', 'options/NEOIPC_ASA_SCORE/2/NAME',
                'optionSets/NEOIPC_ASA_SCORE/NAME', 'organisationUnitGroups/NEO_DEPARTMENT/NAME', 'organisationUnitGroups/NEO_DEPARTMENT/SHORT_NAME')
        }
        It 'orders units by key intrinsically (ordinal) — independent of the order the package carries its objects' {
            # The two options are listed in REVERSE key order in the package; the .pot must still come out key-sorted
            # (an export/assembled build orders objects by closure, not by key — the .pot order must not follow that).
            $pkg = [ordered]@{
                optionSets = @( [ordered]@{ id = 'OSaaaaaaaa1'; code = 'NEOIPC_ASA_SCORE'; name = 'ASA score' } )
                options    = @(
                    [ordered]@{ id = 'OPaaaaaaaa2'; code = '2'; name = 'ASA II'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' } }
                    [ordered]@{ id = 'OPaaaaaaaa1'; code = '1'; name = 'ASA I'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' } }
                )
            }
            @(Get-NeoIPCMetadataTranslationUnit -Package $pkg | ForEach-Object { $_.Msgctxt }) | Should -Be @(
                'options/NEOIPC_ASA_SCORE/1/NAME', 'options/NEOIPC_ASA_SCORE/2/NAME', 'optionSets/NEOIPC_ASA_SCORE/NAME')
        }
        It 'recognises ATC level-4 (5-char) and level-5 (7-char) codes, not other codes' {
            (Test-NeoIPCAtcCode -Code 'J01CG') | Should -BeTrue       # ATC level 4 (drug-class group)
            (Test-NeoIPCAtcCode -Code 'J01AA01') | Should -BeTrue     # ATC level 5 (substance)
            (Test-NeoIPCAtcCode -Code 'WHO_AWARE_ACCESS') | Should -BeFalse
            (Test-NeoIPCAtcCode -Code 'NEOIPC_ASA_SCORE') | Should -BeFalse
        }
        It 'excludes the whole antibiotic domain (ATC + AWaRe groups, ATC5/WHO_AWARE group-sets) from the metadata PO, keeping non-antibiotic groups' {
            $pkg = [ordered]@{
                optionGroups    = @(
                    [ordered]@{ id = 'OGaaaaaaaa1'; code = 'J01CG'; name = 'Beta-lactamase inhibitors' }
                    [ordered]@{ id = 'OGaaaaaaaa2'; code = 'WHO_AWARE_ACCESS'; name = 'AWaRe Access' }
                    [ordered]@{ id = 'OGaaaaaaaa3'; code = 'NEOIPC_PATHOGEN_LIST'; name = 'Pathogen list' }
                )
                optionGroupSets = @(
                    [ordered]@{ id = 'OGSaaaaaaa1'; code = 'ATC5'; name = 'ATC-5 Groups' }
                    [ordered]@{ id = 'OGSaaaaaaa2'; code = 'WHO_AWARE'; name = 'AWaRe Groups' }
                    [ordered]@{ id = 'OGSaaaaaaa3'; code = 'NEO_ORG_GROUP_SET'; name = 'Organism group set' }
                )
            }
            $units = Get-NeoIPCMetadataTranslationUnit -Package $pkg
            $keys = @($units | ForEach-Object { $_.Key })
            $keys | Should -Not -Contain 'J01CG'            # ATC group -> the dedicated antibiotic component
            $keys | Should -Not -Contain 'WHO_AWARE_ACCESS' # AWaRe group -> the dedicated antibiotic component
            $keys | Should -Not -Contain 'ATC5'             # ATC5 group-set -> the dedicated antibiotic component
            $keys | Should -Not -Contain 'WHO_AWARE'        # WHO_AWARE group-set -> the dedicated antibiotic component
            $keys | Should -Contain 'NEOIPC_PATHOGEN_LIST'  # non-antibiotic group stays in the metadata PO
            $keys | Should -Contain 'NEO_ORG_GROUP_SET'     # non-antibiotic group-set stays in the metadata PO
        }
        It 'excludes organisationUnit INSTANCES from extraction (authored content) but keeps the group classification labels' {
            # Org-unit instances are authored content (real UIDs / ISO codes / country names) the export anonymises,
            # so they are an excluded type — never extracted to the metadata PO. The org-unit GROUPS / GROUP-SETS,
            # however, are translatable classification config and stay (e.g. NEO_DEPARTMENT, World-Bank classes).
            $pkg = [ordered]@{
                organisationUnits      = @( [ordered]@{ id = 'OUaaaaaaaa1'; code = 'AT'; name = 'Austria'; shortName = 'Austria'
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'Oesterreich' } ) } )
                organisationUnitGroups = @( [ordered]@{ id = 'OGaaaaaaaa1'; code = 'NEO_DEPARTMENT'; name = 'Departments' } )
            }
            $keys = @(Get-NeoIPCMetadataTranslationUnit -Package $pkg | ForEach-Object { $_.Msgctxt })
            $keys | Should -Not -Contain 'organisationUnits/AT/NAME'                  # instance excluded (authored)
            $keys | Should -Not -Contain 'organisationUnits/AT/SHORT_NAME'
            $keys | Should -Contain 'organisationUnitGroups/NEO_DEPARTMENT/NAME'      # group label kept
        }
        It 'sources msgid from the English base value and gathers existing translations by locale' {
            $units = Get-NeoIPCMetadataTranslationUnit -Package (New-TranslationFixture)
            $u = $units | Where-Object { $_.Msgctxt -eq 'options/NEOIPC_ASA_SCORE/1/NAME' }
            $u.Msgid | Should -BeExactly 'ASA I'
            $u.Translations['de'] | Should -BeExactly 'ASA I (de)'
            $u.Translations['es'] | Should -BeExactly 'ASA I (es)'
        }
        It 'emits a .pot with empty msgstr and a .<lang>.po with the language msgstr' {
            $units = Get-NeoIPCMetadataTranslationUnit -Package (New-TranslationFixture)
            $pot = Write-NeoIPCMetadataPoText -Entry (ConvertTo-NeoIPCMetadataPoEntry -Unit $units)
            $pot | Should -Match '(?m)^msgctxt "organisationUnitGroups/NEO_DEPARTMENT/NAME"'
            $pot | Should -Match '(?m)^"Language: en\\n"'
            $poDe = Write-NeoIPCMetadataPoText -Entry (ConvertTo-NeoIPCMetadataPoEntry -Unit $units -Locale 'de') -Locale 'de'
            $poDe | Should -Match '(?m)^"Language: de\\n"'
            $poDe | Should -Match 'Abteilungen'
        }
        It 'parses a .po back, skipping the header entry' {
            $units = Get-NeoIPCMetadataTranslationUnit -Package (New-TranslationFixture)
            $entries = Read-NeoIPCMetadataPoText -Text (Write-NeoIPCMetadataPoText -Entry (ConvertTo-NeoIPCMetadataPoEntry -Unit $units -Locale 'de') -Locale 'de')
            @($entries | Where-Object { -not $_.Msgctxt }).Count | Should -Be 0          # no empty-context header entry
            ($entries | Where-Object { $_.Msgctxt -eq 'organisationUnitGroups/NEO_DEPARTMENT/NAME' }).Msgstr | Should -BeExactly 'Abteilungen'
        }
        It 'parses gettext multi-line continuation (msgmerge-style wrapped value)' {
            $wrapped = "msgctxt `"x/y/NAME`"`nmsgid `"`"`n`"part one `"`n`"part two`"`nmsgstr `"`"`n`"trans one `"`n`"trans two`"`n"
            $e = Read-NeoIPCMetadataPoText -Text $wrapped
            $e.Count | Should -Be 1
            $e[0].Msgid | Should -BeExactly 'part one part two'
            $e[0].Msgstr | Should -BeExactly 'trans one trans two'
        }
        It 'reconstructs translations[] losslessly through PO (de + es)' {
            $inj = Get-InjectedFixture
            $opt1 = @($inj['options']) | Where-Object { $_['code'] -eq '1' }
            @($opt1['translations'] | ForEach-Object { '{0}:{1}={2}' -f $_['property'], $_['locale'], $_['value'] }) |
                Should -Be @('NAME:de=ASA I (de)', 'NAME:es=ASA I (es)')
            $grp = @($inj['organisationUnitGroups']) | Where-Object { $_['code'] -eq 'NEO_DEPARTMENT' }
            @($grp['translations'] | ForEach-Object { '{0}:{1}={2}' -f $_['property'], $_['locale'], $_['value'] }) | Should -Be @('NAME:de=Abteilungen')
        }
        It 'keeps a single-element translations[] an array (serializes as JSON [...] for import)' {
            $inj = Get-InjectedFixture
            $grp = @($inj['organisationUnitGroups']) | Where-Object { $_['code'] -eq 'NEO_DEPARTMENT' }
            $grp['translations'] -is [System.Collections.IEnumerable] -and $grp['translations'] -isnot [System.Collections.IDictionary] | Should -BeTrue
            ($inj | ConvertTo-Json -Depth 100) | Should -Match '"translations": \['
        }
        It 'leaves an untranslated object without a translations property' {
            $inj = Get-InjectedFixture
            $opt2 = @($inj['options']) | Where-Object { $_['code'] -eq '2' }
            $opt2.Contains('translations') | Should -BeFalse
        }
        It 'warns about a translations[] entry on a token the type map does not carry' {
            $pkg = [ordered]@{ options = @( [ordered]@{ id = 'OPaaaaaaaa1'; code = '1'; name = 'ASA I'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' }
                        translations = @( [ordered]@{ property = 'DESCRIPTION'; locale = 'de'; value = 'x' } ) } )
                optionSets = @( [ordered]@{ id = 'OSaaaaaaaa1'; code = 'NEOIPC_ASA_SCORE'; name = 'ASA' } ) }
            $warnings = $null
            Get-NeoIPCMetadataTranslationUnit -Package $pkg -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            @($warnings | Where-Object { $_ -match 'token DESCRIPTION' }).Count | Should -BeGreaterThan 0
        }
    }

    Describe 'PO merge + fuzzy handling (msgmerge-equivalent, in code)' {
        BeforeAll {
            function New-Entry { param($Ctx, $Id, $Str = '', $Fuzzy = $false) [ordered]@{ Msgctxt = $Ctx; Msgid = $Id; Msgstr = $Str; Fuzzy = $Fuzzy } }
            function New-EntryList { $l = [System.Collections.Generic.List[object]]::new(); foreach ($e in $args) { $l.Add($e) }; return , $l }
        }
        It 'projects units to .pot entries with empty msgstr, and to language entries with the value' {
            $units = Get-NeoIPCMetadataTranslationUnit -Package ([ordered]@{
                    optionSets = @( [ordered]@{ id = 'OSaaaaaaaa1'; code = 'S'; name = 'Set' } )
                    options    = @( [ordered]@{ id = 'OPaaaaaaaa1'; code = '1'; name = 'One'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' }
                            translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'Eins' } ) } ) })
            $optName = $units | Where-Object { $_.Msgctxt -eq 'options/S/1/NAME' }
            (ConvertTo-NeoIPCMetadataPoEntry -Unit (New-EntryList $optName) | ForEach-Object { $_.Msgstr }) | Should -Be @('')
            (ConvertTo-NeoIPCMetadataPoEntry -Unit (New-EntryList $optName) -Locale 'de' | ForEach-Object { $_.Msgstr }) | Should -Be @('Eins')
        }
        It 'preserves a translation when the source msgid is unchanged' {
            $new = New-EntryList (New-Entry 'a/b/NAME' 'Hello')
            $old = New-EntryList (New-Entry 'a/b/NAME' 'Hello' 'Hallo')
            $m = Merge-NeoIPCMetadataPoEntry -New $new -Existing $old
            $m[0].Msgstr | Should -BeExactly 'Hallo'
            $m[0].Fuzzy | Should -BeFalse
        }
        It 'keeps but fuzzies a translation when the source msgid changed' {
            $new = New-EntryList (New-Entry 'a/b/NAME' 'Hello there')
            $old = New-EntryList (New-Entry 'a/b/NAME' 'Hello' 'Hallo')
            $m = Merge-NeoIPCMetadataPoEntry -New $new -Existing $old
            $m[0].Msgstr | Should -BeExactly 'Hallo'
            $m[0].Fuzzy | Should -BeTrue
        }
        It 'drops obsolete entries and leaves brand-new ones untranslated' {
            $new = New-EntryList (New-Entry 'a/b/NAME' 'Hello') (New-Entry 'a/c/NAME' 'New')
            $old = New-EntryList (New-Entry 'a/b/NAME' 'Hello' 'Hallo') (New-Entry 'gone/x/NAME' 'Gone' 'Weg')
            $m = Merge-NeoIPCMetadataPoEntry -New $new -Existing $old
            @($m | ForEach-Object { $_.Msgctxt }) | Should -Be @('a/b/NAME', 'a/c/NAME')
            ($m | Where-Object { $_.Msgctxt -eq 'a/c/NAME' }).Msgstr | Should -BeExactly ''
        }
        It 'round-trips the fuzzy flag through write/read' {
            $entries = New-EntryList (New-Entry 'a/b/NAME' 'Hello' 'Hallo' $true)
            $back = Read-NeoIPCMetadataPoText -Text (Write-NeoIPCMetadataPoText -Entry $entries -Locale 'de')
            $back[0].Fuzzy | Should -BeTrue
        }
        It 'injection skips a fuzzy entry (unreviewed translation is not applied)' {
            $pkg = [ordered]@{ organisationUnitGroups = @( [ordered]@{ id = 'OGaaaaaaaa1'; code = 'NEO_DEPARTMENT'; name = 'Departments' } ) }
            $po = @{ de = (New-EntryList (New-Entry 'organisationUnitGroups/NEO_DEPARTMENT/NAME' 'Departments' 'Abteilungen' $true)) }
            $inj = Add-NeoIPCMetadataTranslationToPackage -Package $pkg -PoByLocale $po
            @($inj['organisationUnitGroups'])[0].Contains('translations') | Should -BeFalse
        }
    }

    Describe 'Export / Import-NeoIPCMetadataTranslation (public PO cmdlets)' {
        BeforeAll {
            $script:trExport = Join-Path $TestDrive 'tr-export.json'
            $script:trPoDir = Join-Path $TestDrive 'tr-po'
            $pkg = [ordered]@{
                optionSets        = @( [ordered]@{ id = 'OSaaaaaaaa1'; code = 'NEOIPC_ASA_SCORE'; name = 'ASA score' } )
                options           = @( [ordered]@{ id = 'OPaaaaaaaa1'; code = '1'; name = 'ASA I'; optionSet = [ordered]@{ id = 'OSaaaaaaaa1' }
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'ASA I (de)' } ) } )
                organisationUnitGroups = @( [ordered]@{ id = 'OGaaaaaaaa1'; code = 'NEO_DEPARTMENT'; name = 'Departments'; shortName = 'Depts' } )
            }
            [System.IO.File]::WriteAllText($script:trExport, ($pkg | ConvertTo-Json -Depth 40), [System.Text.UTF8Encoding]::new($false))
        }
        It 'writes metadata.pot + one metadata.<lang>.po per requested locale' {
            Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale de, es
            Test-Path (Join-Path $script:trPoDir 'metadata.pot') | Should -BeTrue
            Test-Path (Join-Path $script:trPoDir 'metadata.de.po') | Should -BeTrue
            Test-Path (Join-Path $script:trPoDir 'metadata.es.po') | Should -BeTrue
        }
        It 'seeds a new .po from the package existing translations[]' {
            Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale de, es
            (Get-Content (Join-Path $script:trPoDir 'metadata.de.po') -Raw) | Should -Match 'ASA I \(de\)'
            (Get-Content (Join-Path $script:trPoDir 'metadata.es.po') -Raw) | Should -Not -Match 'ASA I \(de\)'
        }
        It 'emits an empty msgstr in the .pot template' {
            Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale de
            $pot = Get-Content (Join-Path $script:trPoDir 'metadata.pot') -Raw
            $pot | Should -Match 'msgctxt "options/NEOIPC_ASA_SCORE/1/NAME"'
            $pot | Should -Not -Match 'ASA I \(de\)'
        }
        It 'round-trips: Export then Import reconstructs translations[] from the .po files' {
            Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale de, es
            $inj = Import-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale de, es -PassThru
            $opt = @($inj['options'])[0]
            @($opt['translations'] | ForEach-Object { '{0}:{1}={2}' -f $_['property'], $_['locale'], $_['value'] }) | Should -Be @('NAME:de=ASA I (de)')
        }
        It 'preserves a translator-supplied msgstr across re-export (msgmerge-equivalent)' {
            Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale es
            $esPath = Join-Path $script:trPoDir 'metadata.es.po'
            $entries = Read-NeoIPCMetadataPoText -Text (Get-Content $esPath -Raw)
            ($entries | Where-Object { $_.Msgctxt -eq 'organisationUnitGroups/NEO_DEPARTMENT/NAME' }).Msgstr = 'Departments (es)'
            [System.IO.File]::WriteAllText($esPath, (Write-NeoIPCMetadataPoText -Entry $entries -Locale 'es'), [System.Text.UTF8Encoding]::new($false))
            Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory $script:trPoDir -Locale es
            (Get-Content $esPath -Raw) | Should -Match 'Departments \(es\)'
        }
        It 'throws on a missing export file / PO directory' {
            { Export-NeoIPCMetadataTranslation -Path (Join-Path $TestDrive 'no.json') -PoDirectory $script:trPoDir } | Should -Throw '*not found*'
            { Import-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory (Join-Path $TestDrive 'no-po-dir') } | Should -Throw '*not found*'
        }
        It '-Validate throws when msgfmt reports the generated PO invalid' {
            Mock Test-NeoIPCMetadataPoSyntax { $false }
            { Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory (Join-Path $TestDrive 'tr-val-bad') -Locale de -Validate } | Should -Throw '*failed msgfmt validation*'
        }
        It '-Validate does not throw when the generated PO is valid' {
            Mock Test-NeoIPCMetadataPoSyntax { $true }
            { Export-NeoIPCMetadataTranslation -Path $script:trExport -PoDirectory (Join-Path $TestDrive 'tr-val-ok') -Locale de -Validate } | Should -Not -Throw
        }
    }

    Describe 'Translation priority (full surface, internal strings deprioritised)' {
        It 'elevates a user-facing token and deprioritises an unlisted one on the same object' {
            $pkg = [ordered]@{ dataElements = @( [ordered]@{ id = 'DEaaaaaaaa1'; code = 'DE1'; name = 'Internal element name'; formName = 'Field label' } ) }
            $units = Get-NeoIPCMetadataTranslationUnit -Package $pkg
            ($units | Where-Object { $_.Token -eq 'FORM_NAME' }).Priority | Should -Be 200   # data-entry label (elevated)
            ($units | Where-Object { $_.Token -eq 'NAME' }).Priority | Should -Be 10          # internal name (deprioritised)
        }
        It 'deprioritises an entirely unlisted type to the low priority' {
            $pkg = [ordered]@{ programRuleVariables = @( [ordered]@{ id = 'PRVaaaaaaa1'; name = 'myVariable' } ) }
            (Get-NeoIPCMetadataTranslationUnit -Package $pkg)[0].Priority | Should -Be 10
        }
        It 'emits a priority flag only for non-default values and round-trips it through read' {
            $e = [System.Collections.Generic.List[object]]::new()
            $e.Add([ordered]@{ Msgctxt = 'a/b/FORM_NAME'; Msgid = 'X'; Msgstr = ''; Fuzzy = $false; Priority = 200 })
            $e.Add([ordered]@{ Msgctxt = 'a/c/NAME'; Msgid = 'Y'; Msgstr = ''; Fuzzy = $false; Priority = 100 })
            $e.Add([ordered]@{ Msgctxt = 'a/d/NAME'; Msgid = 'Z'; Msgstr = ''; Fuzzy = $true; Priority = 10 })
            $txt = Write-NeoIPCMetadataPoText -Entry $e
            $txt | Should -Match '#, priority:200'
            $txt | Should -Match '#, fuzzy, priority:10'                          # fuzzy + priority combine
            ($txt -split "`n" | Where-Object { $_ -eq '#, priority:100' }).Count | Should -Be 0   # default omitted
            $back = Read-NeoIPCMetadataPoText -Text $txt
            ($back | Where-Object { $_.Msgctxt -eq 'a/b/FORM_NAME' }).Priority | Should -Be 200
            ($back | Where-Object { $_.Msgctxt -eq 'a/c/NAME' }).Priority | Should -Be 100   # no flag -> default
            ($back | Where-Object { $_.Msgctxt -eq 'a/d/NAME' }).Fuzzy | Should -BeTrue
        }
    }

    Describe 'Translation regressions (adversarial-review hardening)' {
        BeforeAll {
            function New-Entry { param($Ctx, $Id, $Str = '', $Fuzzy = $false) [ordered]@{ Msgctxt = $Ctx; Msgid = $Id; Msgstr = $Str; Fuzzy = $Fuzzy } }
            function New-EntryList { $l = [System.Collections.Generic.List[object]]::new(); foreach ($e in $args) { $l.Add($e) }; return , $l }
        }
        It 'gives two same-named code-less objects DISTINCT (unique) msgctxt via their UIDs' {
            $pkg = [ordered]@{ programStageSections = @(
                    [ordered]@{ id = 'PSSaaaaaaa1'; name = 'BSI/Sepsis' }
                    [ordered]@{ id = 'PSSaaaaaaa2'; name = 'BSI/Sepsis' } ) }
            $units = Get-NeoIPCMetadataTranslationUnit -Package $pkg
            @($units | ForEach-Object { $_.Msgctxt }) | Should -Be @('programStageSections/PSSaaaaaaa1/NAME', 'programStageSections/PSSaaaaaaa2/NAME')
        }
        It 'THROWS on a genuine duplicate msgctxt (two objects mapping to the same key)' {
            $pkg = [ordered]@{ organisationUnitGroups = @(
                    [ordered]@{ id = 'OGaaaaaaaa1'; code = 'DUP'; name = 'A' }
                    [ordered]@{ id = 'OGaaaaaaaa2'; code = 'DUP'; name = 'B' } ) }
            { Get-NeoIPCMetadataTranslationUnit -Package $pkg } | Should -Throw '*Duplicate translation msgctxt*'
        }
        It 'excludes the domain option sets (pathogens / substances) from extraction' {
            $pkg = [ordered]@{
                optionSets = @( [ordered]@{ id = 'OSdomain001'; code = 'NEOIPC_PATHOGENS'; name = 'Pathogens' } )
                options    = @( [ordered]@{ id = 'OPdomain001'; code = 'P1'; name = 'E. coli'; optionSet = [ordered]@{ id = 'OSdomain001' } } )
            }
            (Get-NeoIPCMetadataTranslationUnit -Package $pkg).Count | Should -Be 0
        }
        It 'drops the redundant FORM_NAME on nameable config types (empty base) WITHOUT warning, and never re-injects it' {
            # programs / programStages / trackedEntityTypes carry a FORM_NAME translation that duplicates NAME
            # while the base formName is empty; DHIS2 falls back to the NAME translation, so it is intentionally
            # not carried (NeoIPCMetadataTranslationIgnoredTokens) — no drift warning, and import never rebuilds it.
            $pkg = [ordered]@{ programStages = @( [ordered]@{ id = 'psFORM00001'; name = 'Admission'
                        translations = @(
                            [ordered]@{ property = 'NAME'; locale = 'de'; value = 'Aufnahme' }
                            [ordered]@{ property = 'FORM_NAME'; locale = 'de'; value = 'Aufnahme' } ) } ) }
            $units = Get-NeoIPCMetadataTranslationUnit -Package $pkg -WarningVariable warns -WarningAction SilentlyContinue
            @($units | Where-Object { $_.Token -eq 'FORM_NAME' }).Count | Should -Be 0   # not extracted
            @($units | Where-Object { $_.Token -eq 'NAME' }).Count | Should -Be 1         # NAME still carried
            @($warns | Where-Object { "$_" -match 'FORM_NAME' }).Count | Should -Be 0     # no drift warning
            $back = Add-NeoIPCMetadataTranslationToPackage -Package $pkg -PoByLocale @{ de = (New-EntryList) }
            @(@($back['programStages'])[0]['translations'] | Where-Object { $_.property -eq 'FORM_NAME' }).Count | Should -Be 0
        }
        It 'Import preserves translations[] on every excluded antibiotic-domain object (ATC + AWaRe groups, ATC5/WHO_AWARE group-sets, domain option) it does not own' {
            # An EMPTY PO would REBUILD (and so wipe) translations[] on any object the injection does not skip. So if
            # the broadened Test-NeoIPCAntibioticTranslationExcluded failed to exclude the AWaRe groups or the
            # group-sets on the injection side, their translations[] would be dropped — this guards exactly that.
            $pkg = [ordered]@{
                optionSets      = @( [ordered]@{ id = 'OSdomain001'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; name = 'Substances' } )
                options         = @( [ordered]@{ id = 'OPdomain001'; code = 'J01AA01'; name = 'Demeclocycline'; optionSet = [ordered]@{ id = 'OSdomain001' }
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'Demeclocyclin' } ) } )
                optionGroups    = @(
                    [ordered]@{ id = 'OGatc000001'; code = 'J01CG'; name = 'Beta-lactamase inhibitors'
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'Beta-Laktamase-Inhibitoren' } ) }
                    [ordered]@{ id = 'OGaware0001'; code = 'WHO_AWARE_ACCESS'; name = 'AWaRe Access'
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'AWaRe Zugang' } ) } )
                optionGroupSets = @(
                    [ordered]@{ id = 'OGSatc00001'; code = 'ATC5'; name = 'ATC-5 Groups'
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'ATC-5-Gruppen' } ) }
                    [ordered]@{ id = 'OGSaware001'; code = 'WHO_AWARE'; name = 'AWaRe Groups'
                        translations = @( [ordered]@{ property = 'NAME'; locale = 'de'; value = 'AWaRe-Gruppen' } ) } )
            }
            $inj = Add-NeoIPCMetadataTranslationToPackage -Package $pkg -PoByLocale @{ de = (New-EntryList) }
            @($inj['options'])[0]['translations'] | Should -Not -BeNullOrEmpty
            foreach ($g in @($inj['optionGroups'])) { $g['translations'] | Should -Not -BeNullOrEmpty }        # ATC + AWaRe groups kept
            foreach ($s in @($inj['optionGroupSets'])) { $s['translations'] | Should -Not -BeNullOrEmpty }     # ATC5 + WHO_AWARE group-sets kept
        }
        It 'Merge takes the priority from the source (New) side' {
            $new = New-EntryList (New-Entry 'a/b/NAME' 'Hello'); $new[0].Priority = 200
            $old = New-EntryList (New-Entry 'a/b/NAME' 'Hello' 'Hallo'); $old[0].Priority = 10
            $m = Merge-NeoIPCMetadataPoEntry -New $new -Existing $old
            $m[0].Priority | Should -Be 200
            $m[0].Msgstr | Should -BeExactly 'Hallo'
        }
        It 'injects translations[] in deterministic (locale asc, then token) order regardless of PoByLocale key order' {
            $pkg = [ordered]@{ organisationUnitGroups = @( [ordered]@{ id = 'OGaaaaaaaa1'; code = 'NEO_DEPARTMENT'; name = 'Departments'; shortName = 'Depts' } ) }
            $po = [ordered]@{}
            $po['es'] = (New-EntryList (New-Entry 'organisationUnitGroups/NEO_DEPARTMENT/NAME' 'Departments' 'Departments-es') (New-Entry 'organisationUnitGroups/NEO_DEPARTMENT/SHORT_NAME' 'Depts' 'Depts-es'))
            $po['de'] = (New-EntryList (New-Entry 'organisationUnitGroups/NEO_DEPARTMENT/NAME' 'Departments' 'Abteilungen') (New-Entry 'organisationUnitGroups/NEO_DEPARTMENT/SHORT_NAME' 'Depts' 'Abk'))
            $inj = Add-NeoIPCMetadataTranslationToPackage -Package $pkg -PoByLocale $po
            @(@($inj['organisationUnitGroups'])[0]['translations'] | ForEach-Object { '{0}/{1}' -f $_.locale, $_.property }) |
                Should -Be @('de/NAME', 'de/SHORT_NAME', 'es/NAME', 'es/SHORT_NAME')
        }
        It 'Test-NeoIPCAtcCode is case-sensitive (a lowercased code is not treated as ATC)' {
            (Test-NeoIPCAtcCode -Code 'j01cg') | Should -BeFalse
        }
        It 'parses a wrapped (continuation) msgctxt' {
            $txt = "msgctxt `"`"`n`"options/SET/`"`n`"1/NAME`"`nmsgid `"X`"`nmsgstr `"Y`"`n"
            $e = Read-NeoIPCMetadataPoText -Text $txt
            $e.Count | Should -Be 1
            $e[0].Msgctxt | Should -BeExactly 'options/SET/1/NAME'
        }
        It 'writes PO text with LF line endings (no CRLF)' {
            $txt = Write-NeoIPCMetadataPoText -Entry (New-EntryList (New-Entry 'a/b/NAME' 'X' 'Y'))
            $txt.Contains("`r`n") | Should -BeFalse
            $txt.Contains("`n") | Should -BeTrue
        }
    }

    Describe 'Pathogen option-set generation' {
        BeforeAll {
            Import-Module powershell-yaml -ErrorAction Stop
            # Author the fixture as real YAML text (the exact path the cmdlet exercises): higher-rank nodes carry
            # no Id; genus / species / synonym nodes do; a synonym is itself an Id-bearing, selectable option.
            $yaml = @'
Hierarchies:
- Name: Not listed
  ConceptType: Unknown
  Id: 0
- Name: Bacteria
  ConceptType: Domain
  Children:
  - Name: Escherichia
    ConceptType: Genus
    Id: 10
    Children:
    - Name: Escherichia coli
      ConceptType: Species
      Id: 11
      Synonyms:
      - Name: Bacillus coli
        Id: 12
'@
            $script:GenYaml = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-onto-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $script:GenYaml -Value $yaml -Encoding utf8
            $script:GenTree = (Get-Content -LiteralPath $script:GenYaml -Raw | ConvertFrom-Yaml)
        }
        AfterAll {
            if ($script:GenYaml -and (Test-Path -LiteralPath $script:GenYaml)) { Remove-Item -LiteralPath $script:GenYaml -Force }
        }

        It 'walks the tree depth-first (Hierarchies/Synonyms/Children), emitting every Id-bearing node (synonyms included)' {
            $concepts = @(Get-NeoIPCInfectiousAgentConcept -Node $script:GenTree)
            @($concepts | ForEach-Object { $_.Id }) | Should -Be @(0, 10, 11, 12)
            @($concepts | ForEach-Object { $_.Name }) | Should -Be @('Not listed', 'Escherichia', 'Escherichia coli', 'Bacillus coli')
        }
        It 'captures each node''s ConceptType (rank) and flags synonym-list members' {
            $concepts = @(Get-NeoIPCInfectiousAgentConcept -Node $script:GenTree)
            $concepts[0].ConceptType | Should -BeExactly 'Unknown'   # Not listed
            $concepts[1].ConceptType | Should -BeExactly 'Genus'     # Escherichia
            $concepts[2].ConceptType | Should -BeExactly 'Species'   # Escherichia coli
            $concepts[3].ConceptType | Should -BeNullOrEmpty         # Bacillus coli (synonym, no ConceptType)
            @($concepts | ForEach-Object { [bool]$_.IsSynonym }) | Should -Be @($false, $false, $false, $true)
        }
        It 'does not propagate the synonym flag into a synonym''s own children (they are concepts)' {
            $tree = [ordered]@{ Hierarchies = @(
                    [ordered]@{ Name = 'Genus'; ConceptType = 'Genus'; Id = 100; Synonyms = @(
                            [ordered]@{ Name = 'Old genus'; ConceptType = 'Genus'; Id = 101; Children = @(
                                    [ordered]@{ Name = 'Child species'; ConceptType = 'Species'; Id = 102 }) }) }
                ) }
            $byId = @{}
            foreach ($c in @(Get-NeoIPCInfectiousAgentConcept -Node $tree)) { $byId[$c.Id] = $c }
            $byId[101].IsSynonym | Should -BeTrue    # direct Synonyms member
            $byId[102].IsSynonym | Should -BeFalse   # a synonym's child is a concept
        }
        It 'Get-NeoIPCPathogenOptionLabel appends the rank tag, [synonym] for synonyms, and no tag for Unknown/absent/blank' {
            (Get-NeoIPCPathogenOptionLabel -Name 'Escherichia coli' -ConceptType 'Species' -IsSynonym $false) | Should -BeExactly 'Escherichia coli [species]'
            (Get-NeoIPCPathogenOptionLabel -Name 'Mycobacterium avium complex' -ConceptType 'Species complex' -IsSynonym $false) | Should -BeExactly 'Mycobacterium avium complex [species complex]'
            (Get-NeoIPCPathogenOptionLabel -Name 'Bacillus coli' -ConceptType 'Species' -IsSynonym $true) | Should -BeExactly 'Bacillus coli [synonym]'
            (Get-NeoIPCPathogenOptionLabel -Name 'Not listed' -ConceptType 'Unknown' -IsSynonym $false) | Should -BeExactly 'Not listed'
            (Get-NeoIPCPathogenOptionLabel -Name 'Unidentifiable' -ConceptType $null -IsSynonym $false) | Should -BeExactly 'Unidentifiable'
            (Get-NeoIPCPathogenOptionLabel -Name 'Blank rank' -ConceptType '' -IsSynonym $false) | Should -BeExactly 'Blank rank'
        }
        It 'a synonym carrying its own ConceptType is still tagged [synonym] (synonym precedence) end-to-end' {
            $y = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-onto-syn-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $y -Encoding utf8 -Value @'
Hierarchies:
- Name: Escherichia coli
  ConceptType: Species
  Id: 11
  Synonyms:
  - Name: Bacillus coli
    ConceptType: Species
    Id: 12
'@
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $y
                (@($frag['options'] | Where-Object { $_['code'] -eq '12' })[0]['name']) | Should -BeExactly 'Bacillus coli [synonym]'
                (@($frag['options'] | Where-Object { $_['code'] -eq '11' })[0]['name']) | Should -BeExactly 'Escherichia coli [species]'
            }
            finally { Remove-Item -LiteralPath $y -Force }
        }
        It 'emits a node''s synonyms before its children (deterministic visit order, not file order)' {
            # A node carrying BOTH an Id-bearing Synonym and an Id-bearing Child, child listed first in the source.
            $tree = [ordered]@{ Hierarchies = @(
                    [ordered]@{ Name = 'Genus'; Id = 100; Children = @([ordered]@{ Name = 'Child species'; Id = 102 }); Synonyms = @([ordered]@{ Name = 'Old genus'; Id = 101 }) }
                ) }
            @(Get-NeoIPCInfectiousAgentConcept -Node $tree | ForEach-Object { $_.Id }) | Should -Be @(100, 101, 102)
        }
        It 'skips higher-rank nodes that carry no Id' {
            (@(Get-NeoIPCInfectiousAgentConcept -Node $script:GenTree) | Where-Object { $_.Name -eq 'Bacteria' }).Count | Should -Be 0
        }
        It 'fails loud on an Id-bearing node with a blank or non-integer Id' {
            { Get-NeoIPCInfectiousAgentConcept -Node ([ordered]@{ Hierarchies = @([ordered]@{ Name = 'X'; Id = '' }) }) } | Should -Throw '*blank or non-integer Id*'
            { Get-NeoIPCInfectiousAgentConcept -Node ([ordered]@{ Hierarchies = @([ordered]@{ Name = 'X'; Id = 'abc' }) }) } | Should -Throw '*blank or non-integer Id*'
        }
        It 'fails loud on an Id-bearing node with a blank Name' {
            { Get-NeoIPCInfectiousAgentConcept -Node ([ordered]@{ Hierarchies = @([ordered]@{ Name = ''; Id = 7 }) }) } | Should -Throw '*blank Name*'
        }
        It 'emits one option per Id-bearing node (code=Id, name=Name+tag, 1-based sortOrder, document order)' {
            $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml
            @($frag['optionSets']).Count | Should -Be 1
            @($frag['options']).Count | Should -Be 4
            $os = @($frag['optionSets'])[0]
            $os['code'] | Should -BeExactly 'NEOIPC_PATHOGENS'
            $os['valueType'] | Should -BeExactly 'INTEGER_ZERO_OR_POSITIVE'
            @($os['options']).Count | Should -Be 4
            @($frag['options'] | ForEach-Object { $_['code'] }) | Should -Be @('0', '10', '11', '12')
            @($frag['options'] | ForEach-Object { $_['sortOrder'] }) | Should -Be @(1, 2, 3, 4)
            @($frag['options'] | ForEach-Object { $_['name'] }) | Should -Be @('Not listed', 'Escherichia [genus]', 'Escherichia coli [species]', 'Bacillus coli [synonym]')
            (@($frag['options'])[0]['optionSet']['id']) | Should -BeExactly $os['id']
            (Test-NeoIPCMetadataUid -Id $os['id']) | Should -BeTrue
        }
        It 'mints deterministic UIDs — pure across runs, and option uid = f(optionSet uid, code)' {
            $a = New-NeoIPCPathogenOptionSet -Path $script:GenYaml
            $b = New-NeoIPCPathogenOptionSet -Path $script:GenYaml
            (@($a['optionSets'])[0]['id']) | Should -BeExactly (@($b['optionSets'])[0]['id'])
            @($a['options'] | ForEach-Object { $_['id'] }) | Should -Be @($b['options'] | ForEach-Object { $_['id'] })
            $osUid = @($a['optionSets'])[0]['id']
            $expected = New-NeoIPCMetadataUid -Type 'options' -NaturalKey ('{0}|{1}' -f $osUid, '11')
            (@($a['options'] | Where-Object { $_['code'] -eq '11' })[0]['id']) | Should -BeExactly $expected
        }
        It 'takes the option-set + option UIDs from source (-OptionSetUid + the sidecar) and sharing from the export' {
            $sidecar = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-uids-{0}.csv' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $sidecar -Encoding utf8 -Value "id,uid`n11,optExist001"
            $existing = @{
                optionSets = @([ordered]@{ id = 'osPathogn01'; code = 'NEOIPC_PATHOGENS'; name = 'old'; sharing = @{ public = 'rw------' } })
                options    = @([ordered]@{ id = 'optExist001'; code = '11'; name = 'old'; optionSet = [ordered]@{ id = 'osPathogn01' } })
            }
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -OptionSetUid 'osPathogn01' -UidSidecarPath $sidecar -ExistingPackage $existing
                (@($frag['optionSets'])[0]['id']) | Should -BeExactly 'osPathogn01'   # from -OptionSetUid (source)
                (@($frag['optionSets'])[0]['sharing']) | Should -Not -BeNullOrEmpty    # from the export
                (@($frag['options'] | Where-Object { $_['code'] -eq '11' })[0]['id']) | Should -BeExactly 'optExist001'   # from the sidecar
                # A code absent from the sidecar still mints deterministically off the source set UID.
                (@($frag['options'] | Where-Object { $_['code'] -eq '12' })[0]['id']) |
                    Should -BeExactly (New-NeoIPCMetadataUid -Type 'options' -NaturalKey 'osPathogn01|12')
            }
            finally { Remove-Item -LiteralPath $sidecar -Force }
        }
        It 'identity is SOURCE, not the export: when the sidecar/-OptionSetUid disagree with the export, source wins' {
            # The export carries DIFFERENT well-formed UIDs for the same deployed code 11 — they must be ignored for
            # identity (the export is read only for sharing + the no-silent-drop validation). Pins the commit's guarantee
            # against a future export-by-code identity fallback (which would otherwise pass every other test).
            $sidecar = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-uids-{0}.csv' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $sidecar -Encoding utf8 -Value "id,uid`n11,srcUID00011"
            $existing = @{
                optionSets = @([ordered]@{ id = 'osExport001'; code = 'NEOIPC_PATHOGENS'; name = 'old' })
                options    = @([ordered]@{ id = 'expUID00011'; code = '11'; name = 'old'; optionSet = [ordered]@{ id = 'osExport001' } })
            }
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -OptionSetUid 'osSource001' -UidSidecarPath $sidecar -ExistingPackage $existing
                $os = @($frag['optionSets'])[0]
                $os['id'] | Should -BeExactly 'osSource001'      # from -OptionSetUid (source)
                $os['id'] | Should -Not -Be 'osExport001'        # NOT the export's option-set id
                $o11 = @($frag['options'] | Where-Object { $_['code'] -eq '11' })[0]
                $o11['id'] | Should -BeExactly 'srcUID00011'     # from the sidecar (source)
                $o11['id'] | Should -Not -Be 'expUID00011'       # NOT the export's option id, even though code 11 matches
                # A code with no sidecar entry mints off the SOURCE set UID — never the export.
                $o12 = @($frag['options'] | Where-Object { $_['code'] -eq '12' })[0]
                $o12['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'options' -NaturalKey 'osSource001|12')
            }
            finally { Remove-Item -LiteralPath $sidecar -Force }
        }
        It 'fails loud when the export carries a deployed code absent from the ontology (no silent drop)' {
            $existing = @{
                optionSets = @([ordered]@{ id = 'osPathogn01'; code = 'NEOIPC_PATHOGENS'; name = 'old' })
                options    = @([ordered]@{ id = 'optGhost001'; code = '9999'; name = 'ghost'; optionSet = [ordered]@{ id = 'osPathogn01' } })
            }
            { New-NeoIPCPathogenOptionSet -Path $script:GenYaml -ExistingPackage $existing } | Should -Throw '*9999*'
        }
        It 'fails loud on a duplicate Id in the ontology' {
            $dupYaml = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-onto-dup-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $dupYaml -Encoding utf8 -Value @'
Hierarchies:
- Name: A
  Id: 5
- Name: B
  Id: 5
'@
            try { { New-NeoIPCPathogenOptionSet -Path $dupYaml } | Should -Throw '*Duplicate option code 5*' }
            finally { Remove-Item -LiteralPath $dupYaml -Force }
        }
        It 're-mints deterministically when the source option-set / option UID is structurally invalid' {
            $sidecar = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-uids-{0}.csv' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $sidecar -Encoding utf8 -Value "id,uid`n11,short"   # 'short' is not a valid UID -> mint
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -OptionSetUid 'BAD!' -UidSidecarPath $sidecar
                $osUid = @($frag['optionSets'])[0]['id']
                (Test-NeoIPCMetadataUid -Id $osUid) | Should -BeTrue
                $osUid | Should -BeExactly (New-NeoIPCMetadataUid -Type 'optionSets' -NaturalKey 'NEOIPC_PATHOGENS')
                $opt = @($frag['options'] | Where-Object { $_['code'] -eq '11' })[0]['id']
                (Test-NeoIPCMetadataUid -Id $opt) | Should -BeTrue
                $opt | Should -BeExactly (New-NeoIPCMetadataUid -Type 'options' -NaturalKey ('{0}|{1}' -f $osUid, '11'))
            }
            finally { Remove-Item -LiteralPath $sidecar -Force }
        }
        It 'fails loud when two option codes in the sidecar share a UID' {
            $sidecar = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-uids-{0}.csv' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $sidecar -Encoding utf8 -Value "id,uid`n11,dupSharedAA`n12,dupSharedAA"   # valid UID shape, shared
            try { { New-NeoIPCPathogenOptionSet -Path $script:GenYaml -UidSidecarPath $sidecar } | Should -Throw '*UID collision*' }
            finally { Remove-Item -LiteralPath $sidecar -Force }
        }
        It 'fails loud when the ontology has no Id-bearing concepts (would orphan the bindings)' {
            $emptyYaml = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-onto-empty-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $emptyYaml -Encoding utf8 -Value @'
Hierarchies:
- Name: Bacteria
  ConceptType: Domain
  Children:
  - Name: Escherichia
    ConceptType: Genus
'@
            try { { New-NeoIPCPathogenOptionSet -Path $emptyYaml } | Should -Throw '*No Id-bearing concepts*' }
            finally { Remove-Item -LiteralPath $emptyYaml -Force }
        }
        It 'fails loud when -ExistingPackage is supplied but lacks the target option set' {
            $existing = @{ optionSets = @([ordered]@{ id = 'osPathogn01'; code = 'SOME_OTHER_SET' }); options = @() }
            { New-NeoIPCPathogenOptionSet -Path $script:GenYaml -ExistingPackage $existing } | Should -Throw '*not found in the supplied*'
        }
        It 'regenerates the option and set names from the ontology, not a preserved drifted name' {
            $existing = @{
                optionSets = @([ordered]@{ id = 'osPathogn01'; code = 'NEOIPC_PATHOGENS'; name = 'DRIFTED SET NAME' })
                options    = @([ordered]@{ id = 'optExist001'; code = '11'; name = 'DRIFTED OPTION'; optionSet = [ordered]@{ id = 'osPathogn01' } })
            }
            $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -ExistingPackage $existing
            (@($frag['optionSets'])[0]['name']) | Should -BeExactly 'NeoIPC Pathogen options'
            (@($frag['options'] | Where-Object { $_['code'] -eq '11' })[0]['name']) | Should -BeExactly 'Escherichia coli [species]'
        }
        It 'emits optionSet.options in the same order as the options list / sortOrder (the DHIS2 ordering authority)' {
            $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml
            $os = @($frag['optionSets'])[0]
            @($os['options'] | ForEach-Object { $_['id'] }) | Should -Be @($frag['options'] | ForEach-Object { $_['id'] })
        }
        It 'honours the -OptionSetCode / -OptionSetName / -ValueType overrides' {
            $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -OptionSetCode 'MY_SET' -OptionSetName 'Custom name' -ValueType 'TEXT'
            $os = @($frag['optionSets'])[0]
            $os['code'] | Should -BeExactly 'MY_SET'
            $os['name'] | Should -BeExactly 'Custom name'
            $os['valueType'] | Should -BeExactly 'TEXT'
            $os['id'] | Should -BeExactly $script:NeoIPCPathogenOptionSetUid   # the default -OptionSetUid (source), not derived from the code
        }
        It 'Get-NeoIPCPathogenUidMap reads id->uid, is empty when absent, and fails loud on a blank/duplicate id' {
            (Get-NeoIPCPathogenUidMap -Path (Join-Path $TestDrive 'no-such-sidecar.csv')).Count | Should -Be 0
            $ok = Join-Path $TestDrive 'uids-ok.csv'
            Set-Content -LiteralPath $ok -Encoding utf8 -Value "id,uid`n11,optExist001`n12,optExist002"
            $m = Get-NeoIPCPathogenUidMap -Path $ok
            $m['11'] | Should -BeExactly 'optExist001'
            $m.ContainsKey('99') | Should -BeFalse
            $dup = Join-Path $TestDrive 'uids-dup.csv'
            Set-Content -LiteralPath $dup -Encoding utf8 -Value "id,uid`n11,a`n11,b"
            { Get-NeoIPCPathogenUidMap -Path $dup } | Should -Throw '*Duplicate*'
            $blank = Join-Path $TestDrive 'uids-blank.csv'
            Set-Content -LiteralPath $blank -Encoding utf8 -Value "id,uid`n,xUID00abcde"
            { Get-NeoIPCPathogenUidMap -Path $blank } | Should -Throw '*blank id*'
        }
        It 'generates from source alone (no -ExistingPackage): set UID from -OptionSetUid, options from the sidecar else minted' {
            $sidecar = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-uids-{0}.csv' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $sidecar -Encoding utf8 -Value "id,uid`n11,optSrc00011"
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -OptionSetUid 'osSrcOnly01' -UidSidecarPath $sidecar
                @($frag['optionSets'])[0]['id'] | Should -BeExactly 'osSrcOnly01'
                @($frag['optionSets'])[0].Contains('sharing') | Should -BeFalse
                @($frag['options'] | Where-Object { $_['code'] -eq '11' })[0]['id'] | Should -BeExactly 'optSrc00011'
                @($frag['options'] | Where-Object { $_['code'] -eq '12' })[0]['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'options' -NaturalKey 'osSrcOnly01|12')
            }
            finally { Remove-Item -LiteralPath $sidecar -Force }
        }
        It 'Get-NeoIPCPoTranslationMap reads a po4a YAML .po: skips header/untranslated/identical/obsolete, joins wrapped' {
            $po = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-po-{0}.po' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $po -Encoding utf8 -Value @'
msgid ""
msgstr ""
"Language: de\n"

#. type: Hash Value: Hierarchies ConceptType
#: metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml:1
#, no-wrap
msgid "Species"
msgstr "Art"

msgid "Untranslated"
msgstr ""

msgid "Identical"
msgstr "Identical"

#~ msgid "obsolete-key"
#~ msgstr "obsolete-value"

#, fuzzy, no-wrap
#| msgid "synonym for {0}"
msgid "synonym"
msgstr "Synonym für {0}"

msgid "Wrapped"
msgstr ""
"Wra"
"pped-DE"
'@
            try {
                $map = Get-NeoIPCPoTranslationMap -Path $po
                $map['Species'] | Should -BeExactly 'Art'
                $map['Wrapped'] | Should -BeExactly 'Wrapped-DE'
                $map.Contains('Untranslated') | Should -BeFalse
                $map.Contains('Identical') | Should -BeFalse
                $map.Contains('obsolete-key') | Should -BeFalse
                $map.Contains('synonym') | Should -BeFalse    # fuzzy msgmerge guess — skipped, like gettext
                $map.Count | Should -Be 2
            }
            finally { Remove-Item -LiteralPath $po -Force }
        }
        It 'Get-NeoIPCPoTranslationMap returns an empty map for an absent catalogue' {
            $map = Get-NeoIPCPoTranslationMap -Path (Join-Path ([System.IO.Path]::GetTempPath()) ('no-such-{0}.po' -f ([guid]::NewGuid().ToString('N'))))
            $map.Count | Should -Be 0
        }
        It 'composes per-locale option labels from a .po: localized name + rank/synonym word, English fallback, no tag for Unknown' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-podir-{0}' -f ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'infectious_agents.de.po') -Encoding utf8 -Value @'
msgid ""
msgstr ""
"Language: de\n"

msgid "Genus"
msgstr "Gattung"

msgid "Species"
msgstr "Art"

msgid "synonym"
msgstr "Synonym"

msgid "Not listed"
msgstr "Nicht aufgeführt"

msgid "Escherichia coli"
msgstr "Escherichia coli"
'@
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -PoDirectory $dir
                $byCode = @{}; foreach ($o in @($frag['options'])) { $byCode[[string]$o['code']] = $o }
                # English source names are unchanged.
                $byCode['10']['name'] | Should -BeExactly 'Escherichia [genus]'
                $byCode['11']['name'] | Should -BeExactly 'Escherichia coli [species]'
                # Each option carries exactly the composed German label: localized rank (verbatim casing), the
                # synonym word, the localized name where translated, English fallback otherwise, no tag for Unknown.
                (@($byCode['0']['translations']) | Where-Object { $_.locale -eq 'de' }).value  | Should -BeExactly 'Nicht aufgeführt'
                (@($byCode['10']['translations']) | Where-Object { $_.locale -eq 'de' }).value | Should -BeExactly 'Escherichia [Gattung]'
                (@($byCode['11']['translations']) | Where-Object { $_.locale -eq 'de' }).value | Should -BeExactly 'Escherichia coli [Art]'
                (@($byCode['12']['translations']) | Where-Object { $_.locale -eq 'de' }).value | Should -BeExactly 'Bacillus coli [Synonym]'
                @($byCode['11']['translations'])[0].property | Should -BeExactly 'NAME'   # DHIS2 ObjectTranslation token (uppercase, case-sensitive)
            }
            finally { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
        It 'omits a translations[] entry where the locale leaves the label identical to the English source' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-podir-{0}' -f ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $dir | Out-Null
            # Only the genus rank is translated, so only the genus option's label differs; the rest stay English.
            Set-Content -LiteralPath (Join-Path $dir 'infectious_agents.it.po') -Encoding utf8 -Value @'
msgid ""
msgstr ""
"Language: it\n"

msgid "Genus"
msgstr "Genere"
'@
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -PoDirectory $dir
                $byCode = @{}; foreach ($o in @($frag['options'])) { $byCode[[string]$o['code']] = $o }
                (@($byCode['10']['translations']) | Where-Object { $_.locale -eq 'it' }).value | Should -BeExactly 'Escherichia [Genere]'
                $byCode['0']['translations']  | Should -BeNullOrEmpty
                $byCode['11']['translations'] | Should -BeNullOrEmpty
                $byCode['12']['translations'] | Should -BeNullOrEmpty
            }
            finally { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
        It 'emits one translations[] entry per translated locale, in deterministic (filename-sorted) locale order' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-podir-{0}' -f ([guid]::NewGuid().ToString('N')))
            New-Item -ItemType Directory -Path $dir | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'infectious_agents.de.po') -Encoding utf8 -Value @'
msgid ""
msgstr ""
"Language: de\n"

msgid "Genus"
msgstr "Gattung"
'@
            Set-Content -LiteralPath (Join-Path $dir 'infectious_agents.es.po') -Encoding utf8 -Value @'
msgid ""
msgstr ""
"Language: es\n"

msgid "Genus"
msgstr "Género"
'@
            try {
                $frag = New-NeoIPCPathogenOptionSet -Path $script:GenYaml -PoDirectory $dir
                $genus = @($frag['options'] | Where-Object { [string]$_['code'] -eq '10' })[0]
                $t = @($genus['translations'])
                $t.Count | Should -Be 2
                @($t | ForEach-Object { $_.locale }) | Should -Be @('de', 'es')   # filename-sorted, deterministic
                @($t | ForEach-Object { $_.property }) | Should -Be @('NAME', 'NAME')
                ($t | Where-Object { $_.locale -eq 'de' }).value | Should -BeExactly 'Escherichia [Gattung]'
                ($t | Where-Object { $_.locale -eq 'es' }).value | Should -BeExactly 'Escherichia [Género]'
            }
            finally { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
    }

    Describe 'Resistance effective-flag computation (own-or-inherited, false overrides)' {
        BeforeAll {
            Import-Module powershell-yaml -ErrorAction Stop
            # A genus carries Carbapenems; its species inherits it; a synonym under the species inherits it too.
            # A sibling genus carries nothing (all categories false). Verifies inheritance down Children + Synonyms
            # and the YAML-key -> category-key mapping (Carbapenems -> carbapenem-resistant).
            $yaml = @'
Hierarchies:
- Name: Not listed
  Id: 0
  MRSA: true
  VRE: true
  3GCR: true
  Carbapenems: true
  Colistin: true
- Name: Bacteria
  Children:
  - Name: Klebsiella
    Id: 100
    Carbapenems: true
    Children:
    - Name: Klebsiella pneumoniae
      Id: 101
      Synonyms:
      - Name: Old klebsiella
        Id: 102
  - Name: Lactobacillus
    Id: 200
    Children:
    - Name: Lactobacillus acidophilus
      Id: 201
'@
            $script:FlagTree = ($yaml | ConvertFrom-Yaml)
        }

        It 'inherits a flag down Children and Synonyms (genus -> species -> synonym)' {
            $flags = @(Get-NeoIPCResistanceFlag -Node $script:FlagTree)
            ($flags | Where-Object { $_.Id -eq 100 })['carbapenem-resistant'] | Should -BeTrue
            ($flags | Where-Object { $_.Id -eq 101 })['carbapenem-resistant'] | Should -BeTrue
            ($flags | Where-Object { $_.Id -eq 102 })['carbapenem-resistant'] | Should -BeTrue
        }
        It 'defaults to false where no flag is set on the node or any ancestor' {
            $flags = @(Get-NeoIPCResistanceFlag -Node $script:FlagTree)
            ($flags | Where-Object { $_.Id -eq 201 })['carbapenem-resistant'] | Should -BeFalse
            ($flags | Where-Object { $_.Id -eq 101 })['MRSA'] | Should -BeFalse
        }
        It 'maps the YAML flag keys to the DHIS2 category keys' {
            $flags = @(Get-NeoIPCResistanceFlag -Node $script:FlagTree)
            $notListed = $flags | Where-Object { $_.Id -eq 0 }
            @($notListed.Keys) | Should -Be @('Id', '3GCR', 'carbapenem-resistant', 'colistin-resistant', 'MRSA', 'VRE')
            $notListed['colistin-resistant'] | Should -BeTrue
        }
        It 'honours an explicit false that overrides an inherited true (and re-inherits below)' {
            $tree = [ordered]@{ Hierarchies = @(
                    [ordered]@{ Name = 'Genus'; Id = 1; Carbapenems = $true; Children = @(
                            [ordered]@{ Name = 'Exception species'; Id = 2; Carbapenems = $false; Children = @(
                                    [ordered]@{ Name = 'Sub'; Id = 3 }
                                ) }
                            [ordered]@{ Name = 'Normal species'; Id = 4 }
                        ) }
                ) }
            $flags = @(Get-NeoIPCResistanceFlag -Node $tree)
            ($flags | Where-Object { $_.Id -eq 1 })['carbapenem-resistant'] | Should -BeTrue
            ($flags | Where-Object { $_.Id -eq 2 })['carbapenem-resistant'] | Should -BeFalse
            ($flags | Where-Object { $_.Id -eq 3 })['carbapenem-resistant'] | Should -BeFalse
            ($flags | Where-Object { $_.Id -eq 4 })['carbapenem-resistant'] | Should -BeTrue
        }
        It 'fails loud on a non-boolean flag value' {
            $tree = [ordered]@{ Hierarchies = @([ordered]@{ Name = 'X'; Id = 9; Carbapenems = 'maybe' }) }
            { Get-NeoIPCResistanceFlag -Node $tree } | Should -Throw '*non-boolean*'
        }

        It 'aggregates code sets per category, ascending and category-keyed' {
            $sets = Get-NeoIPCResistanceCodeSet -Node $script:FlagTree
            @($sets.Keys) | Should -Be @('3GCR', 'carbapenem-resistant', 'colistin-resistant', 'MRSA', 'VRE')
            # Id 0 (all flags) + the carbapenem-flagged Klebsiella clade (100/101/102); Lactobacillus excluded.
            @($sets['carbapenem-resistant']) | Should -Be @(0, 100, 101, 102)
            # Only Id 0 carries 3GCR/MRSA/VRE/colistin in this fixture.
            @($sets['3GCR']) | Should -Be @(0)
            @($sets['MRSA']) | Should -Be @(0)
            @($sets['colistin-resistant']) | Should -Be @(0)
        }
        It 'sorts numerically, not lexically' {
            $tree = [ordered]@{ Hierarchies = @(
                    [ordered]@{ Name = 'A'; Id = 100; MRSA = $true }
                    [ordered]@{ Name = 'B'; Id = 9; MRSA = $true }
                    [ordered]@{ Name = 'C'; Id = 21; MRSA = $true }
                ) }
            @((Get-NeoIPCResistanceCodeSet -Node $tree)['MRSA']) | Should -Be @(9, 21, 100)
        }
    }

    Describe 'Pathogen data-element generation' {
        BeforeAll {
            $script:DePlan = @(Get-NeoIPCPathogenDataElementPlan)
            # Synthetic export covering every matrix DE (stub: id + description + categoryCombo) plus the option
            # sets the DEs bind, so the generator can reuse content and resolve option-set codes.
            $des = foreach ($d in $script:DePlan) {
                [ordered]@{
                    id            = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $d.Code)
                    code          = $d.Code
                    description   = ('desc for {0}' -f $d.Code)
                    categoryCombo = [ordered]@{ id = 'bjDvmb4bfuf' }
                }
            }
            $script:DePackage = @{
                dataElements = @($des)
                optionSets   = @(
                    [ordered]@{ id = 'osPathogn01'; code = 'NEOIPC_PATHOGENS' },
                    [ordered]@{ id = 'TnE2yuSrqEP'; code = 'NEOIPC_YES_NO_NOT_TESTED' },
                    [ordered]@{ id = 'B3oP3uOI5Ef'; code = 'NEOIPC_BSI_PATHOGEN_RECOVERED_FROM' },
                    [ordered]@{ id = 'Y64Emj9405U'; code = 'NEOIPC_HAP_RESPIRATORY_TRACT_SAMPLE_SOURCES' }
                )
            }
        }

        It 'expands the capability matrix to 135 per-slot data elements' {
            $script:DePlan.Count | Should -Be 135
        }
        It 'gives a BSI primary slot the full suffix set (base + NAME + 5 resistance + SOURCE + MULTIPLE), in order' {
            @($script:DePlan | Where-Object { $_.Code -like 'NEOIPC_BSI_PATHOGEN_1*' } | ForEach-Object { $_.Code }) | Should -Be @(
                'NEOIPC_BSI_PATHOGEN_1', 'NEOIPC_BSI_PATHOGEN_1_NAME', 'NEOIPC_BSI_PATHOGEN_1_3GCR',
                'NEOIPC_BSI_PATHOGEN_1_CAR', 'NEOIPC_BSI_PATHOGEN_1_COR', 'NEOIPC_BSI_PATHOGEN_1_MRSA',
                'NEOIPC_BSI_PATHOGEN_1_VRE', 'NEOIPC_BSI_PATHOGEN_1_SOURCE', 'NEOIPC_BSI_PATHOGEN_1_MULTIPLE')
        }
        It 'gives HAP primary a SOURCE but no MULTIPLE; SSI primary neither' {
            (@($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_HAP_PATHOGEN_1_SOURCE' }).Count) | Should -Be 1
            (@($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_HAP_PATHOGEN_1_MULTIPLE' }).Count) | Should -Be 0
            (@($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_SSI_PATHOGEN_1_SOURCE' }).Count) | Should -Be 0
        }
        It 'gives a secondary-BSI slot only base + NAME + 5 resistance (no SOURCE/MULTIPLE)' {
            $nec1 = @($script:DePlan | Where-Object { $_.Code -like 'NEOIPC_NEC_SEC_BSI_PATHOGEN_1*' })
            $nec1.Count | Should -Be 7
            (@($nec1 | Where-Object { $_.Code -match '_(SOURCE|MULTIPLE)$' }).Count) | Should -Be 0
            (@($nec1)[0].Name) | Should -BeExactly 'NeoIPC NEC Secondary BSI organism 1'
            (@($nec1)[0].OptionSetCode) | Should -BeExactly 'NEOIPC_PATHOGENS'
        }
        It 'binds the correct option sets, value types and names per suffix' {
            $base = @($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_BSI_PATHOGEN_1' })[0]
            $base.ValueType | Should -BeExactly 'INTEGER_ZERO_OR_POSITIVE'
            $base.OptionSetCode | Should -BeExactly 'NEOIPC_PATHOGENS'
            $base.FormName | Should -BeExactly 'Organism 1'
            $gcr = @($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_BSI_PATHOGEN_1_3GCR' })[0]
            $gcr.ValueType | Should -BeExactly 'INTEGER'
            $gcr.OptionSetCode | Should -BeExactly 'NEOIPC_YES_NO_NOT_TESTED'
            $gcr.Name | Should -BeExactly 'NeoIPC BSI Organism 1 3GCR'
            $gcr.FormName | Should -BeExactly '- 3GCR'
            (@($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_BSI_PATHOGEN_1_SOURCE' })[0].OptionSetCode) | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_RECOVERED_FROM'
            (@($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_HAP_PATHOGEN_1_SOURCE' })[0].OptionSetCode) | Should -BeExactly 'NEOIPC_HAP_RESPIRATORY_TRACT_SAMPLE_SOURCES'
            $mult = @($script:DePlan | Where-Object { $_.Code -eq 'NEOIPC_BSI_PATHOGEN_1_MULTIPLE' })[0]
            $mult.ValueType | Should -BeExactly 'TRUE_ONLY'
            $mult.OptionSetCode | Should -BeNullOrEmpty
        }

        It 'generates 135 DEs, reusing id/description/categoryCombo and resolving option-set bindings' {
            $frag = New-NeoIPCPathogenDataElement -ExistingPackage $script:DePackage
            @($frag['dataElements']).Count | Should -Be 135
            $byCode = @{}; foreach ($de in @($frag['dataElements'])) { $byCode[[string]$de['code']] = $de }
            $base = $byCode['NEOIPC_BSI_PATHOGEN_1']
            $base['optionSet']['id'] | Should -BeExactly 'osPathogn01'
            $base['valueType'] | Should -BeExactly 'INTEGER_ZERO_OR_POSITIVE'
            $base['name'] | Should -BeExactly 'NeoIPC BSI Organism 1'
            $base['description'] | Should -BeExactly 'desc for NEOIPC_BSI_PATHOGEN_1'
            $base['categoryCombo']['id'] | Should -BeExactly 'bjDvmb4bfuf'
            $base['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1')
            $base['zeroIsSignificant'] | Should -BeTrue
            $byCode['NEOIPC_BSI_PATHOGEN_1_3GCR']['optionSet']['id'] | Should -BeExactly 'TnE2yuSrqEP'
            $byCode['NEOIPC_HAP_PATHOGEN_1_SOURCE']['optionSet']['id'] | Should -BeExactly 'Y64Emj9405U'
            $byCode['NEOIPC_BSI_PATHOGEN_1_NAME']['valueType'] | Should -BeExactly 'TEXT'
            $byCode['NEOIPC_BSI_PATHOGEN_1_NAME'].Contains('optionSet') | Should -BeFalse
            $byCode['NEOIPC_BSI_PATHOGEN_1_MULTIPLE']['valueType'] | Should -BeExactly 'TRUE_ONLY'
            $byCode['NEOIPC_BSI_PATHOGEN_1_MULTIPLE'].Contains('optionSet') | Should -BeFalse
        }
        It 'fails loud when a matrix data element is missing from the package' {
            $pkg = @{
                dataElements = @($script:DePackage['dataElements'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_SSI_PATHOGEN_3_VRE' })
                optionSets   = $script:DePackage['optionSets']
            }
            { New-NeoIPCPathogenDataElement -ExistingPackage $pkg } | Should -Throw '*NEOIPC_SSI_PATHOGEN_3_VRE*'
        }
        It 'fails loud when a bound option set is absent from the package' {
            $pkg = @{
                dataElements = $script:DePackage['dataElements']
                optionSets   = @($script:DePackage['optionSets'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_YES_NO_NOT_TESTED' })
            }
            { New-NeoIPCPathogenDataElement -ExistingPackage $pkg } | Should -Throw '*NEOIPC_YES_NO_NOT_TESTED*'
        }
        It 'normalises _SOURCE zeroIsSignificant to false for both BSI and HAP (deployed has them inconsistent)' {
            $frag = New-NeoIPCPathogenDataElement -ExistingPackage $script:DePackage
            $byCode = @{}; foreach ($de in @($frag['dataElements'])) { $byCode[[string]$de['code']] = $de }
            $byCode['NEOIPC_BSI_PATHOGEN_1_SOURCE']['zeroIsSignificant'] | Should -BeFalse
            $byCode['NEOIPC_HAP_PATHOGEN_1_SOURCE']['zeroIsSignificant'] | Should -BeFalse
        }
        It 're-mints deterministically when an existing data element carries a structurally invalid id' {
            $des = foreach ($d in $script:DePackage['dataElements']) {
                $c = [ordered]@{}; foreach ($k in $d.Keys) { $c[$k] = $d[$k] }
                if ($c['code'] -eq 'NEOIPC_BSI_PATHOGEN_1') { $c['id'] = 'BAD!' }
                $c
            }
            $frag = New-NeoIPCPathogenDataElement -ExistingPackage @{ dataElements = @($des); optionSets = $script:DePackage['optionSets'] }
            $id = @($frag['dataElements'] | Where-Object { $_['code'] -eq 'NEOIPC_BSI_PATHOGEN_1' })[0]['id']
            (Test-NeoIPCMetadataUid -Id $id) | Should -BeTrue
            $id | Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1')
        }
        It 'regenerates name/shortName/formName from the matrix, not a drifted export value' {
            $des = foreach ($d in $script:DePackage['dataElements']) {
                $c = [ordered]@{}; foreach ($k in $d.Keys) { $c[$k] = $d[$k] }
                if ($c['code'] -eq 'NEOIPC_BSI_PATHOGEN_1') { $c['name'] = 'DRIFT'; $c['shortName'] = 'DRIFT'; $c['formName'] = 'DRIFT' }
                $c
            }
            $frag = New-NeoIPCPathogenDataElement -ExistingPackage @{ dataElements = @($des); optionSets = $script:DePackage['optionSets'] }
            $base = @($frag['dataElements'] | Where-Object { $_['code'] -eq 'NEOIPC_BSI_PATHOGEN_1' })[0]
            $base['name'] | Should -BeExactly 'NeoIPC BSI Organism 1'
            $base['shortName'] | Should -BeExactly 'NeoIPC BSI Org. 1'
            $base['formName'] | Should -BeExactly 'Organism 1'
        }
        It 'fails loud when two matrix DE codes in the export share a UID' {
            $des = foreach ($d in $script:DePackage['dataElements']) {
                $c = [ordered]@{}; foreach ($k in $d.Keys) { $c[$k] = $d[$k] }
                if ($c['code'] -in 'NEOIPC_BSI_PATHOGEN_1', 'NEOIPC_BSI_PATHOGEN_2') { $c['id'] = 'dupSharedAA' }
                $c
            }
            { New-NeoIPCPathogenDataElement -ExistingPackage @{ dataElements = @($des); optionSets = $script:DePackage['optionSets'] } } | Should -Throw '*Duplicate data-element id*'
        }
        It 'fails loud when the package carries two data elements with the same code' {
            $des = @($script:DePackage['dataElements']) + , ([ordered]@{ id = 'extraDupAA01'; code = 'NEOIPC_BSI_PATHOGEN_1'; categoryCombo = [ordered]@{ id = 'bjDvmb4bfuf' } })
            { New-NeoIPCPathogenDataElement -ExistingPackage @{ dataElements = @($des); optionSets = $script:DePackage['optionSets'] } } | Should -Throw '*Duplicate data-element code*'
        }
    }

    Describe 'Pathogen program-rule-variable generation' {
        BeforeAll {
            $script:PrvPlan = @(Get-NeoIPCPathogenVariablePlan)
            $baseCodes = @($script:PrvPlan | Where-Object { $_.Kind -eq 'value' } | ForEach-Object { $_.DataElementCode })
            $des = foreach ($c in $baseCodes) { [ordered]@{ code = $c; id = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $c) } }
            $script:PrvPackage = @{
                programs             = @([ordered]@{ code = 'NEOIPC_CORE'; id = 'progCore001' })
                dataElements         = @($des)
                # one pre-existing PRV, to prove UID preservation by name
                programRuleVariables = @([ordered]@{ name = 'NeoIPC BSI Pathogen 1 value'; id = 'prvBsiP1Val' })
            }
        }

        It 'expands to 108 resistance variables (18 value + 90 may-be)' {
            $script:PrvPlan.Count | Should -Be 108
            (@($script:PrvPlan | Where-Object { $_.Kind -eq 'value' }).Count) | Should -Be 18
            (@($script:PrvPlan | Where-Object { $_.Kind -eq 'mayBe' }).Count) | Should -Be 90
        }
        It 'gives each slot one value + five may-be variables with the right shapes and names' {
            $slot = @($script:PrvPlan | Where-Object { $_.Name -like 'NeoIPC BSI Pathogen 1*' })
            $slot.Count | Should -Be 6
            $val = @($slot | Where-Object { $_.Kind -eq 'value' })[0]
            $val.Name | Should -BeExactly 'NeoIPC BSI Pathogen 1 value'
            $val.SourceType | Should -BeExactly 'DATAELEMENT_CURRENT_EVENT'
            $val.ValueType | Should -BeExactly 'INTEGER_ZERO_OR_POSITIVE'
            $val.UseCodeForOptionSet | Should -BeTrue
            $val.DataElementCode | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_1'
            @($slot | Where-Object { $_.Kind -eq 'mayBe' } | ForEach-Object { $_.Name }) | Should -Be @(
                'NeoIPC BSI Pathogen 1 may be 3GCR', 'NeoIPC BSI Pathogen 1 may be carbapenem-resistant',
                'NeoIPC BSI Pathogen 1 may be colistin-resistant', 'NeoIPC BSI Pathogen 1 may be MRSA',
                'NeoIPC BSI Pathogen 1 may be VRE')
            $mb = @($slot | Where-Object { $_.Kind -eq 'mayBe' })[0]
            $mb.SourceType | Should -BeExactly 'CALCULATED_VALUE'
            $mb.ValueType | Should -BeExactly 'BOOLEAN'
            $mb.DataElementCode | Should -BeNullOrEmpty
        }
        It 'uses the secondary-BSI name template for secondary slots' {
            (@($script:PrvPlan | Where-Object { $_.Kind -eq 'value' -and $_.Stage -eq 'NEC' })[0].Name) |
                Should -BeExactly 'NeoIPC NEC Secondary BSI pathogen 1 value'
        }

        It 'generates 108 PRVs, resolving the base DE + program and preserving the UID by name' {
            $frag = New-NeoIPCPathogenVariable -ExistingPackage $script:PrvPackage
            @($frag['programRuleVariables']).Count | Should -Be 108
            $byName = @{}; foreach ($v in @($frag['programRuleVariables'])) { $byName[[string]$v['name']] = $v }
            $val = $byName['NeoIPC BSI Pathogen 1 value']
            $val['id'] | Should -BeExactly 'prvBsiP1Val'   # preserved from the package
            $val['programRuleVariableSourceType'] | Should -BeExactly 'DATAELEMENT_CURRENT_EVENT'
            $val['useCodeForOptionSet'] | Should -BeTrue
            $val['program']['id'] | Should -BeExactly 'progCore001'
            $val['dataElement']['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1')
            $mb = $byName['NeoIPC BSI Pathogen 1 may be 3GCR']
            $mb['programRuleVariableSourceType'] | Should -BeExactly 'CALCULATED_VALUE'
            $mb['valueType'] | Should -BeExactly 'BOOLEAN'
            $mb.Contains('dataElement') | Should -BeFalse
            # a value PRV not pre-existing is minted deterministically by name
            $byName['NeoIPC HAP Pathogen 1 value']['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey 'NeoIPC HAP Pathogen 1 value')
        }
        It 'fails loud when the program is absent from the package' {
            $pkg = @{ programs = @(); dataElements = $script:PrvPackage['dataElements']; programRuleVariables = @() }
            { New-NeoIPCPathogenVariable -ExistingPackage $pkg } | Should -Throw '*NEOIPC_CORE*'
        }
        It 'fails loud when a base data element is absent from the package' {
            $pkg = @{
                programs             = $script:PrvPackage['programs']
                dataElements         = @($script:PrvPackage['dataElements'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_BSI_PATHOGEN_1' })
                programRuleVariables = @()
            }
            { New-NeoIPCPathogenVariable -ExistingPackage $pkg } | Should -Throw '*NEOIPC_BSI_PATHOGEN_1*'
        }
        It 're-mints deterministically when a pre-existing PRV carries a structurally invalid id' {
            $pkg = @{
                programs             = $script:PrvPackage['programs']
                dataElements         = $script:PrvPackage['dataElements']
                programRuleVariables = @([ordered]@{ name = 'NeoIPC BSI Pathogen 1 value'; id = 'BAD!' })
            }
            $id = @((New-NeoIPCPathogenVariable -ExistingPackage $pkg)['programRuleVariables'] | Where-Object { $_['name'] -eq 'NeoIPC BSI Pathogen 1 value' })[0]['id']
            (Test-NeoIPCMetadataUid -Id $id) | Should -BeTrue
            $id | Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey 'NeoIPC BSI Pathogen 1 value')
        }
        It 'fails loud when two PRV names in the export share a UID' {
            $pkg = @{
                programs             = $script:PrvPackage['programs']
                dataElements         = $script:PrvPackage['dataElements']
                programRuleVariables = @(
                    [ordered]@{ name = 'NeoIPC BSI Pathogen 1 value'; id = 'dupSharedAA' },
                    [ordered]@{ name = 'NeoIPC BSI Pathogen 1 may be 3GCR'; id = 'dupSharedAA' })
            }
            { New-NeoIPCPathogenVariable -ExistingPackage $pkg } | Should -Throw '*UID collision for program-rule variable*'
        }
        It 'fails loud when the package carries two PRVs with the same name' {
            $pkg = @{
                programs             = $script:PrvPackage['programs']
                dataElements         = $script:PrvPackage['dataElements']
                programRuleVariables = @(
                    [ordered]@{ name = 'NeoIPC BSI Pathogen 1 value'; id = 'prvDupAAA01' },
                    [ordered]@{ name = 'NeoIPC BSI Pathogen 1 value'; id = 'prvDupAAA02' })
            }
            { New-NeoIPCPathogenVariable -ExistingPackage $pkg } | Should -Throw '*Duplicate program-rule-variable name*'
        }
        It 'honours the -ProgramCode override (and fails loud without it)' {
            $pkg = @{
                programs             = @([ordered]@{ code = 'MY_PROGRAM'; id = 'MyProgram01' })
                dataElements         = $script:PrvPackage['dataElements']
                programRuleVariables = @()
            }
            (@((New-NeoIPCPathogenVariable -ExistingPackage $pkg -ProgramCode 'MY_PROGRAM')['programRuleVariables'])[0]['program']['id']) | Should -BeExactly 'MyProgram01'
            { New-NeoIPCPathogenVariable -ExistingPackage $pkg } | Should -Throw '*NEOIPC_CORE*'
        }
    }

    Describe 'Pathogen resistance-rule generation' {
        BeforeAll {
            Import-Module powershell-yaml -ErrorAction Stop
            $script:RulePlan = @(Get-NeoIPCPathogenRulePlan)

            # Tiny ontology: Id 0 carries every flag; Klebsiella (100) carbapenem only. So the effective code sets
            # are carbapenem-resistant = {0,100} and every other category = {0} — small enough to assert exactly.
            $script:RuleYaml = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-rule-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $script:RuleYaml -Encoding utf8 -Value @'
Hierarchies:
- Name: Not listed
  Id: 0
  3GCR: true
  Carbapenems: true
  Colistin: true
  MRSA: true
  VRE: true
- Name: Bacteria
  Children:
  - Name: Klebsiella
    Id: 100
    Carbapenems: true
'@
            # A package covering the four program stages (by code), every `_<CAT>` resistance DE (by code) and the
            # program — the minimum the generator resolves against. Built from the DE plan so it stays in lockstep.
            # Stages carry no code; the generator resolves each via a slot-1 _3GCR anchor DE listed in
            # programStageDataElements (the same DE→stage link the real export carries).
            $repDe = @{ BSI = 'NEOIPC_BSI_PATHOGEN_1_3GCR'; HAP = 'NEOIPC_HAP_PATHOGEN_1_3GCR'; SSI = 'NEOIPC_SSI_PATHOGEN_1_3GCR'; NEC = 'NEOIPC_NEC_SEC_BSI_PATHOGEN_1_3GCR' }
            $stages = foreach ($s in 'BSI', 'HAP', 'SSI', 'NEC') {
                [ordered]@{
                    code                     = "NEOIPC_$s"
                    id                       = (New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey "NEOIPC_$s")
                    programStageDataElements = @([ordered]@{ dataElement = [ordered]@{ id = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $repDe[$s]) } })
                }
            }
            $resCats = @('3GCR', 'CAR', 'COR', 'MRSA', 'VRE')
            $resDe = foreach ($d in (Get-NeoIPCPathogenDataElementPlan)) {
                if ($d.Suffix -in $resCats) { [ordered]@{ code = $d.Code; id = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $d.Code) } }
            }
            $script:RulePkg = @{
                programs           = @([ordered]@{ code = 'NEOIPC_CORE'; id = 'progCore001' })
                programStages      = @($stages)
                dataElements       = @($resDe)
                programRules       = @()
                programRuleActions = @()
            }
        }
        AfterAll {
            if ($script:RuleYaml -and (Test-Path -LiteralPath $script:RuleYaml)) { Remove-Item -LiteralPath $script:RuleYaml -Force }
        }

        It 'expands to 270 rules (90 set + 90 may-be + 90 not)' {
            $script:RulePlan.Count | Should -Be 270
            (@($script:RulePlan | Where-Object { $_.Kind -eq 'set' }).Count) | Should -Be 90
            (@($script:RulePlan | Where-Object { $_.Kind -eq 'mayBe' }).Count) | Should -Be 90
            (@($script:RulePlan | Where-Object { $_.Kind -eq 'not' }).Count) | Should -Be 90
        }
        It 'the PathogenCount parameter drives slot expansion (1 -> 90, 3 -> 270)' {
            (@(Get-NeoIPCPathogenRulePlan -PathogenCount 1)).Count | Should -Be 90
            (@(Get-NeoIPCPathogenRulePlan -PathogenCount 3)).Count | Should -Be 270
        }
        It 'produces well-formed single-digit slot codes and names up to the max slot 9' {
            $plan = @(Get-NeoIPCPathogenRulePlan -PathogenCount 9)
            (@($plan | Where-Object { $_.Name -eq 'NeoIPC BSI Pathogen 9 - set carbapenem-resistant' }).Count) | Should -Be 1
            $mb = @($plan | Where-Object { $_.Name -eq 'NeoIPC BSI Pathogen 9 - may be carbapenem-resistant' })[0]
            $mb.CategoryDeCode | Should -BeExactly 'NEOIPC_BSI_PATHOGEN_9_CAR'
            $mb.ValueVariable | Should -BeExactly 'NeoIPC BSI Pathogen 9 value'
        }
        It 'caps the pathogen count at 1..9 (single digit)' {
            { Get-NeoIPCPathogenRulePlan -PathogenCount 0 } | Should -Throw
            { Get-NeoIPCPathogenRulePlan -PathogenCount 10 } | Should -Throw
            # 6 stage-instances (3 primary + 3 secondary) x slots x 5 categories x 3 kinds.
            (@(Get-NeoIPCPathogenRulePlan -PathogenCount 9)).Count | Should -Be (6 * 9 * 5 * 3)
        }
        It 'gives set priority 0 and may-be / not priority 1 (the load-bearing ASSIGN-before-consumer order)' {
            (@($script:RulePlan | Where-Object { $_.Kind -eq 'set' -and $_.Priority -ne 0 }).Count) | Should -Be 0
            (@($script:RulePlan | Where-Object { $_.Kind -in 'mayBe', 'not' -and $_.Priority -ne 1 }).Count) | Should -Be 0
        }
        It 'makes the not condition the exact complement of the may-be condition (mandatory implies shown)' {
            $byKey = @{}
            foreach ($d in $script:RulePlan) { $byKey["$($d.Stage)|$($d.SlotKind)|$($d.Index)|$($d.Category)|$($d.Kind)"] = $d }
            foreach ($d in @($script:RulePlan | Where-Object { $_.Kind -eq 'mayBe' })) {
                $not = $byKey["$($d.Stage)|$($d.SlotKind)|$($d.Index)|$($d.Category)|not"]
                $not.Condition | Should -BeExactly ('!' + $d.Condition)
            }
        }

        It 'generates 270 rules and 270 actions' {
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            @($frag['programRules']).Count | Should -Be 270
            @($frag['programRuleActions']).Count | Should -Be 270
        }
        It 'forwards PathogenCount to expansion (1 -> 90 rules + 90 actions)' {
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg -PathogenCount 1
            @($frag['programRules']).Count | Should -Be 90
            @($frag['programRuleActions']).Count | Should -Be 90
        }
        It 'builds the set rule: condition true, priority 0, ASSIGN content=may-be var, data=hasValue + ascending enumeration' {
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }

            $car = $rules['NeoIPC BSI Pathogen 1 - set carbapenem-resistant']
            $car['condition'] | Should -BeExactly 'true'
            $car['priority'] | Should -Be 0
            $carAct = $acts[[string]@($car['programRuleActions'])[0]['id']]
            $carAct['programRuleActionType'] | Should -BeExactly 'ASSIGN'
            $carAct['content'] | Should -BeExactly '#{NeoIPC BSI Pathogen 1 may be carbapenem-resistant}'
            $carAct['data'] | Should -BeExactly 'd2:hasValue(#{NeoIPC BSI Pathogen 1 value})&&(#{NeoIPC BSI Pathogen 1 value}==0||#{NeoIPC BSI Pathogen 1 value}==100)'
            # A single-code category emits a bare term with no `||`.
            $g = $rules['NeoIPC BSI Pathogen 1 - set 3GCR']
            $acts[[string]@($g['programRuleActions'])[0]['id']]['data'] | Should -BeExactly 'd2:hasValue(#{NeoIPC BSI Pathogen 1 value})&&(#{NeoIPC BSI Pathogen 1 value}==0)'
        }
        It 'builds the may-be rule: priority 1, condition #{var}, SETMANDATORYFIELD on the _<CAT> data element' {
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $mb = $rules['NeoIPC BSI Pathogen 1 - may be carbapenem-resistant']
            $mb['priority'] | Should -Be 1
            $mb['condition'] | Should -BeExactly '#{NeoIPC BSI Pathogen 1 may be carbapenem-resistant}'
            $act = $acts[[string]@($mb['programRuleActions'])[0]['id']]
            $act['programRuleActionType'] | Should -BeExactly 'SETMANDATORYFIELD'
            $act['dataElement']['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1_CAR')
        }
        It 'builds the not rule: priority 1, condition !#{var}, HIDEFIELD on the same _<CAT> data element' {
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $not = $rules['NeoIPC BSI Pathogen 1 - not carbapenem-resistant']
            $not['priority'] | Should -Be 1
            $not['condition'] | Should -BeExactly '!#{NeoIPC BSI Pathogen 1 may be carbapenem-resistant}'
            $act = $acts[[string]@($not['programRuleActions'])[0]['id']]
            $act['programRuleActionType'] | Should -BeExactly 'HIDEFIELD'
            $act['dataElement']['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1_CAR')
        }
        It 'resolves each rule programStage via DE->stage membership (stages carry no code)' {
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $rules['NeoIPC BSI Pathogen 1 - set 3GCR']['programStage']['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey 'NEOIPC_BSI')
            $rules['NeoIPC NEC Secondary BSI pathogen 1 - set 3GCR']['programStage']['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey 'NEOIPC_NEC')
        }
        It 'preserves rule UID + action UID from the export by name; uses the plan description; mints otherwise' {
            $pkg = @{
                programs           = $script:RulePkg['programs']
                programStages      = $script:RulePkg['programStages']
                dataElements       = $script:RulePkg['dataElements']
                programRules       = @([ordered]@{ name = 'NeoIPC BSI Pathogen 1 - set 3GCR'; id = 'RULEseed001'; description = 'Seeded description.' })
                programRuleActions = @([ordered]@{ id = 'ACTseed0001'; programRule = [ordered]@{ id = 'RULEseed001' }; programRuleActionType = 'ASSIGN' })
            }
            $frag = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $pkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $seeded = $rules['NeoIPC BSI Pathogen 1 - set 3GCR']
            $seeded['id'] | Should -BeExactly 'RULEseed001'
            # Description is the canonical plan wording — it OVERWRITES the deployed/seeded text (rule descriptions
            # are not load-bearing; the deployed copy carried drift). UID + action UID are still preserved.
            $expectedDesc = [string](@(Get-NeoIPCPathogenRulePlan | Where-Object { [string]$_['Name'] -eq 'NeoIPC BSI Pathogen 1 - set 3GCR' })[0]['Description'])
            $expectedDesc | Should -Not -BeNullOrEmpty
            $seeded['description'] | Should -BeExactly $expectedDesc
            @($seeded['programRuleActions'])[0]['id'] | Should -BeExactly 'ACTseed0001'
            # A rule not in the export mints rule + action deterministically.
            $minted = $rules['NeoIPC BSI Pathogen 1 - not 3GCR']
            $minted['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRules' -NaturalKey 'NeoIPC BSI Pathogen 1 - not 3GCR')
            @($minted['programRuleActions'])[0]['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleActions' -NaturalKey 'NeoIPC BSI Pathogen 1 - not 3GCR|HIDEFIELD')
        }
        It 'mints deterministically across runs' {
            $a = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            $b = New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $script:RulePkg
            @($a['programRules'] | ForEach-Object { $_['id'] }) | Should -Be @($b['programRules'] | ForEach-Object { $_['id'] })
            @($a['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @($b['programRuleActions'] | ForEach-Object { $_['id'] })
        }
        It 'fails loud when a program stage is missing from the package' {
            $pkg = @{
                programs           = $script:RulePkg['programs']
                programStages      = @($script:RulePkg['programStages'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_NEC' })
                dataElements       = $script:RulePkg['dataElements']
                programRules       = @()
                programRuleActions = @()
            }
            { New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $pkg } | Should -Throw '*NEOIPC_NEC*'
        }
        It 'fails loud when a resistance data element is missing from the package' {
            $pkg = @{
                programs           = $script:RulePkg['programs']
                programStages      = $script:RulePkg['programStages']
                dataElements       = @($script:RulePkg['dataElements'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_BSI_PATHOGEN_1_CAR' })
                programRules       = @()
                programRuleActions = @()
            }
            { New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $pkg } | Should -Throw '*NEOIPC_BSI_PATHOGEN_1_CAR*'
        }
        It 'fails loud when the program is absent' {
            $pkg = @{ programs = @(); programStages = $script:RulePkg['programStages']; dataElements = $script:RulePkg['dataElements']; programRules = @(); programRuleActions = @() }
            { New-NeoIPCPathogenRule -Path $script:RuleYaml -ExistingPackage $pkg } | Should -Throw '*NEOIPC_CORE*'
        }
    }

    Describe 'Substance cluster generation (surveillance-end)' {
        BeforeAll {
            $script:SubDePlan = @(Get-NeoIPCSubstanceDataElementPlan)
            $script:SubPrvPlan = @(Get-NeoIPCSubstanceVariablePlan)
            $script:SubRulePlan = @(Get-NeoIPCSubstanceRulePlan)
            $script:SubCcId = New-NeoIPCMetadataUid -Type 'categoryCombos' -NaturalKey 'default'
            $script:SubDeId = { param($code) New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $code }

            # Package with the deployed substance + days DEs (slots 1-9), the total AB-days DE, the option set, the
            # program and the surveillance-end stage. DEs carry a categoryCombo + description so reuse-by-code is exercised.
            $subDes = foreach ($d in $script:SubDePlan) {
                [ordered]@{ code = $d.Code; id = (& $script:SubDeId $d.Code); description = "deployed $($d.Code) desc"; categoryCombo = [ordered]@{ id = $script:SubCcId } }
            }
            $abDays = [ordered]@{ code = 'NEOIPC_SURVEILLANCE_END_AB_DAYS'; id = (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_DAYS'); categoryCombo = [ordered]@{ id = $script:SubCcId } }
            $script:SubPkg = @{
                programs             = @([ordered]@{ code = 'NEOIPC_CORE'; id = 'progCore001' })
                programStages        = @([ordered]@{ id = 'psSurvEnd01'; programStageDataElements = @([ordered]@{ dataElement = [ordered]@{ id = (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_DAYS') } }) })
                optionSets           = @([ordered]@{ code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; id = 'osSubstan01' })
                dataElements         = @($subDes) + @($abDays)
                programRuleVariables = @()
                programRules         = @()
                programRuleActions   = @()
            }
        }

        It 'normalises the slot number for padding-insensitive matching' {
            ConvertTo-NeoIPCSubstanceUnpaddedName -Name 'NeoIPC Surveillance end Antibiotic substance 02 days - current event value' |
                Should -BeExactly 'NeoIPC Surveillance end Antibiotic substance 2 days - current event value'
            ConvertTo-NeoIPCSubstanceUnpaddedName -Name 'NeoIPC Surveillance end Antibiotic substance days - validate' |
                Should -BeExactly 'NeoIPC Surveillance end Antibiotic substance days - validate'
            ConvertTo-NeoIPCSubstanceUnpaddedName -Name 'NeoIPC Surveillance end Antibiotic substance 10 - hide' |
                Should -BeExactly 'NeoIPC Surveillance end Antibiotic substance 10 - hide'
        }

        It 'DE plan: 2 per slot; code/name/shortName padded, formName unpadded' {
            $script:SubDePlan.Count | Should -Be 18
            $sub = @($script:SubDePlan | Where-Object { $_.Code -eq 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01' })[0]
            $sub.Name | Should -BeExactly 'NeoIPC Surveillance end Antibiotic substance 01'
            $sub.ShortName | Should -BeExactly 'NeoIPC Surv. end AB 01'
            $sub.FormName | Should -BeExactly 'Antibiotic substance 1'
            $sub.ValueType | Should -BeExactly 'TEXT'
            $sub.OptionSetCode | Should -BeExactly 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'
            $sub.CommentOptionSetCode | Should -BeExactly 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'
            $days = @($script:SubDePlan | Where-Object { $_.Code -eq 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS' })[0]
            $days.ValueType | Should -BeExactly 'INTEGER_POSITIVE'
            $days.ZeroIsSignificant | Should -BeTrue
            $days.FormName | Should -BeExactly 'Antibiotic substance 1 days'
        }

        It 'PRV plan: substance value TEXT/useCode true, days value INTEGER_POSITIVE/useCode false (padded names)' {
            $script:SubPrvPlan.Count | Should -Be 18
            $sv = @($script:SubPrvPlan | Where-Object { $_.Name -eq 'NeoIPC Surveillance end Antibiotic substance 01 - current event value' })[0]
            $sv.SourceType | Should -BeExactly 'DATAELEMENT_CURRENT_EVENT'
            $sv.ValueType | Should -BeExactly 'TEXT'
            $sv.UseCodeForOptionSet | Should -BeTrue
            $sv.DataElementCode | Should -BeExactly 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01'
            $dv = @($script:SubPrvPlan | Where-Object { $_.Name -eq 'NeoIPC Surveillance end Antibiotic substance 01 days - current event value' })[0]
            $dv.UseCodeForOptionSet | Should -BeFalse
            $dv.ValueType | Should -BeExactly 'INTEGER_POSITIVE'
        }

        It 'rule plan: 2*N+2 rules with cascading-reveal / require / validate shapes' {
            $script:SubRulePlan.Count | Should -Be (2 * 9 + 2)
            $hide1 = @($script:SubRulePlan | Where-Object { $_.Name -eq 'NeoIPC Surveillance end Antibiotic substance 01 - hide' })[0]
            $hide1.Condition | Should -BeExactly '#{NeoIPC Surveillance end AB days - current event value} <= 0'
            @($hide1.Actions).Count | Should -Be 2
            @($hide1.Actions | ForEach-Object { $_.Type }) | Should -Be @('HIDEFIELD', 'HIDEFIELD')
            @($hide1.Actions | ForEach-Object { $_.DataElementCode }) | Should -Be @('NEOIPC_SURVEILLANCE_END_AB_SUBST_01', 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS')
            $hide2 = @($script:SubRulePlan | Where-Object { $_.Name -eq 'NeoIPC Surveillance end Antibiotic substance 02 - hide' })[0]
            $hide2.Condition | Should -BeExactly '!d2:hasValue(#{NeoIPC Surveillance end Antibiotic substance 01 - current event value})'
            $req = @($script:SubRulePlan | Where-Object { $_.Kind -eq 'substanceRequire' })
            $req.Count | Should -Be 1
            $req[0].Name | Should -BeExactly 'NeoIPC Surveillance end Antibiotic substance 01 - require'
            $req[0].Condition | Should -BeExactly '#{NeoIPC Surveillance end AB days - current event value} >= 1'
            $daysReq = @($script:SubRulePlan | Where-Object { $_.Kind -eq 'daysRequire' })
            $daysReq.Count | Should -Be 9
            $dr1 = @($daysReq | Where-Object { $_.Name -eq 'NeoIPC Surveillance end Antibiotic substance 01 days - require' })[0]
            $dr1.Condition | Should -BeExactly 'd2:hasValue(#{NeoIPC Surveillance end Antibiotic substance 01 - current event value})'
            @($dr1.Actions).Count | Should -Be 1
            @($dr1.Actions)[0].Type | Should -BeExactly 'SETMANDATORYFIELD'
            @($dr1.Actions)[0].DataElementCode | Should -BeExactly 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS'
            $val = @($script:SubRulePlan | Where-Object { $_.Kind -eq 'validate' })[0]
            $val.Priority | Should -Be 1
            $val.Condition | Should -BeLike '(#{NeoIPC Surveillance end Antibiotic substance 01 days - current event value} + *#{NeoIPC Surveillance end Antibiotic substance 09 days - current event value}) < #{NeoIPC Surveillance end AB days - current event value}'
            @($val.Actions)[0].Type | Should -BeExactly 'SHOWERROR'
            @($val.Actions)[0].Content | Should -BeExactly 'The sum of all antibiotic substance days must be greater than or equal to antibiotic days'
            # The default-count assertion above wildcards the middle terms; pin the full enumeration at a small count.
            $val3 = @(Get-NeoIPCSubstanceRulePlan -SubstanceCount 3 | Where-Object { $_.Kind -eq 'validate' })[0]
            $val3.Condition | Should -BeExactly ('(#{NeoIPC Surveillance end Antibiotic substance 01 days - current event value}' +
                ' + #{NeoIPC Surveillance end Antibiotic substance 02 days - current event value}' +
                ' + #{NeoIPC Surveillance end Antibiotic substance 03 days - current event value})' +
                ' < #{NeoIPC Surveillance end AB days - current event value}')
        }

        It 'count parameter aligns the three plans and caps at 1..99' {
            (@(Get-NeoIPCSubstanceDataElementPlan -SubstanceCount 4)).Count | Should -Be 8
            (@(Get-NeoIPCSubstanceVariablePlan -SubstanceCount 4)).Count | Should -Be 8
            (@(Get-NeoIPCSubstanceRulePlan -SubstanceCount 4)).Count | Should -Be (2 * 4 + 2)
            { Get-NeoIPCSubstanceDataElementPlan -SubstanceCount 0 } | Should -Throw
            { Get-NeoIPCSubstanceDataElementPlan -SubstanceCount 100 } | Should -Throw
        }

        It 'DE generator: 18 DEs, reusing UID/categoryCombo/description by code, resolving option + comment option set' {
            $frag = New-NeoIPCSubstanceDataElement -ExistingPackage $script:SubPkg
            @($frag['dataElements']).Count | Should -Be 18
            $byCode = @{}; foreach ($de in @($frag['dataElements'])) { $byCode[[string]$de['code']] = $de }
            $sub = $byCode['NEOIPC_SURVEILLANCE_END_AB_SUBST_01']
            $sub['id'] | Should -BeExactly (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01')
            $sub['name'] | Should -BeExactly 'NeoIPC Surveillance end Antibiotic substance 01'
            $sub['formName'] | Should -BeExactly 'Antibiotic substance 1'
            $sub['description'] | Should -BeExactly 'deployed NEOIPC_SURVEILLANCE_END_AB_SUBST_01 desc'
            $sub['categoryCombo']['id'] | Should -BeExactly $script:SubCcId
            $sub['optionSet']['id'] | Should -BeExactly 'osSubstan01'
            $sub['commentOptionSet']['id'] | Should -BeExactly 'osSubstan01'
            $byCode['NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS'].Contains('optionSet') | Should -BeFalse
        }

        It 'DE generator: grows beyond the deployed slots (mint UID + sibling categoryCombo + templated description)' {
            # Package with only slots 1-3; ask for 5 -> slots 4-5 are minted.
            $smallDes = foreach ($d in (Get-NeoIPCSubstanceDataElementPlan -SubstanceCount 3)) {
                [ordered]@{ code = $d.Code; id = (& $script:SubDeId $d.Code); categoryCombo = [ordered]@{ id = $script:SubCcId } }
            }
            $pkg = @{
                programs     = $script:SubPkg['programs']
                optionSets   = $script:SubPkg['optionSets']
                dataElements = @($smallDes)
            }
            $frag = New-NeoIPCSubstanceDataElement -ExistingPackage $pkg -SubstanceCount 5
            @($frag['dataElements']).Count | Should -Be 10
            $byCode = @{}; foreach ($de in @($frag['dataElements'])) { $byCode[[string]$de['code']] = $de }
            $new = $byCode['NEOIPC_SURVEILLANCE_END_AB_SUBST_04']
            $new['id'] | Should -BeExactly (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_SUBST_04')
            $new['categoryCombo']['id'] | Should -BeExactly $script:SubCcId
            $new['description'] | Should -BeExactly 'Systemic antibiotic substance number 4 the infant received.'
            $byCode['NEOIPC_SURVEILLANCE_END_AB_SUBST_04_DAYS']['description'] | Should -BeExactly 'The cumulative number of days the infant received antibiotic substance number 4.'
        }

        It 'DE generator: fails loud when the option set is absent' {
            $pkg = @{ programs = $script:SubPkg['programs']; optionSets = @(); dataElements = $script:SubPkg['dataElements'] }
            { New-NeoIPCSubstanceDataElement -ExistingPackage $pkg } | Should -Throw '*NEOIPC_ANTIMICROBIAL_SUBSTANCES*'
        }

        It 'PRV generator: 18 PRVs, preserving UID by slot-normalised name, resolving the base DE' {
            $pkg = $script:SubPkg.Clone()
            $pkg['programRuleVariables'] = @([ordered]@{ name = 'NeoIPC Surveillance end Antibiotic substance 2 - current event value'; id = 'SUBprv00002' })
            $frag = New-NeoIPCSubstanceVariable -ExistingPackage $pkg
            @($frag['programRuleVariables']).Count | Should -Be 18
            $byName = @{}; foreach ($v in @($frag['programRuleVariables'])) { $byName[[string]$v['name']] = $v }
            $v2 = $byName['NeoIPC Surveillance end Antibiotic substance 02 - current event value']
            $v2['id'] | Should -BeExactly 'SUBprv00002'   # preserved across the padding rename
            $v2['useCodeForOptionSet'] | Should -BeTrue
            $v2['dataElement']['id'] | Should -BeExactly (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_SUBST_02')
            $byName['NeoIPC Surveillance end Antibiotic substance 03 - current event value']['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey 'NeoIPC Surveillance end Antibiotic substance 03 - current event value')
        }

        It 'rule generator: hide (2 HIDEFIELD), validate (SHOWERROR), stage by DE membership, padding-insensitive UID preserve' {
            $hideSubId = & $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01'
            $hideDaysId = & $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS'
            $pkg = $script:SubPkg.Clone()
            $pkg['programRules'] = @([ordered]@{ name = 'NeoIPC Surveillance end Antibiotic substance 1 - hide'; id = 'SUBrule0001' })
            $pkg['programRuleActions'] = @(
                [ordered]@{ id = 'SUBact00001'; programRule = [ordered]@{ id = 'SUBrule0001' }; programRuleActionType = 'HIDEFIELD'; dataElement = [ordered]@{ id = $hideSubId } },
                [ordered]@{ id = 'SUBact00002'; programRule = [ordered]@{ id = 'SUBrule0001' }; programRuleActionType = 'HIDEFIELD'; dataElement = [ordered]@{ id = $hideDaysId } })
            $frag = New-NeoIPCSubstanceRule -ExistingPackage $pkg
            @($frag['programRules']).Count | Should -Be (2 * 9 + 2)
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }

            $hide = $rules['NeoIPC Surveillance end Antibiotic substance 01 - hide']
            $hide['id'] | Should -BeExactly 'SUBrule0001'                  # preserved across the padding rename
            $hide['programStage']['id'] | Should -BeExactly 'psSurvEnd01'  # resolved via DE->stage membership
            @($hide['programRuleActions']).Count | Should -Be 2
            $hideActIds = @($hide['programRuleActions'] | ForEach-Object { [string]$_['id'] })
            $hideActIds | Should -Contain 'SUBact00001'                    # action UID preserved by (type + target DE)
            $hideActIds | Should -Contain 'SUBact00002'
            ($acts['SUBact00001']['dataElement']['id']) | Should -BeExactly $hideSubId
            $hide.Contains('priority') | Should -BeFalse                   # null priority -> omitted

            $val = $rules['NeoIPC Surveillance end Antibiotic substance days - validate']
            $val['priority'] | Should -Be 1
            $valAct = $acts[[string]@($val['programRuleActions'])[0]['id']]
            $valAct['programRuleActionType'] | Should -BeExactly 'SHOWERROR'
            $valAct['content'] | Should -BeExactly 'The sum of all antibiotic substance days must be greater than or equal to antibiotic days'
            $valAct['dataElement']['id'] | Should -BeExactly (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_DAYS')
        }

        It 'rule generator: fails loud when the surveillance-end stage is absent' {
            $pkg = $script:SubPkg.Clone()
            $pkg['programStages'] = @()
            { New-NeoIPCSubstanceRule -ExistingPackage $pkg } | Should -Throw '*surveillance-end*'
        }
        It 'rule generator: emits the per-slot days-require rule (SETMANDATORYFIELD on the _DAYS DE)' {
            $frag = New-NeoIPCSubstanceRule -ExistingPackage $script:SubPkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $dr = $rules['NeoIPC Surveillance end Antibiotic substance 01 days - require']
            $dr['condition'] | Should -BeExactly 'd2:hasValue(#{NeoIPC Surveillance end Antibiotic substance 01 - current event value})'
            $act = $acts[[string]@($dr['programRuleActions'])[0]['id']]
            $act['programRuleActionType'] | Should -BeExactly 'SETMANDATORYFIELD'
            $act['dataElement']['id'] | Should -BeExactly (& $script:SubDeId 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01_DAYS')
        }
        It 'PRV generator: fail-loud paths (program / base DE absent; invalid id re-mints)' {
            $noProg = @{ programs = @(); dataElements = $script:SubPkg['dataElements']; programRuleVariables = @() }
            { New-NeoIPCSubstanceVariable -ExistingPackage $noProg } | Should -Throw '*NEOIPC_CORE*'
            $noDe = @{
                programs             = $script:SubPkg['programs']
                dataElements         = @($script:SubPkg['dataElements'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01' })
                programRuleVariables = @()
            }
            { New-NeoIPCSubstanceVariable -ExistingPackage $noDe } | Should -Throw '*NEOIPC_SURVEILLANCE_END_AB_SUBST_01*'
            # A deployed PRV with an invalid id, matched across the padding rename, re-mints by the padded name.
            $badId = @{
                programs             = $script:SubPkg['programs']
                dataElements         = $script:SubPkg['dataElements']
                programRuleVariables = @([ordered]@{ name = 'NeoIPC Surveillance end Antibiotic substance 1 - current event value'; id = 'BAD!' })
            }
            $v = @((New-NeoIPCSubstanceVariable -ExistingPackage $badId)['programRuleVariables'] | Where-Object { $_['name'] -eq 'NeoIPC Surveillance end Antibiotic substance 01 - current event value' })[0]
            (Test-NeoIPCMetadataUid -Id $v['id']) | Should -BeTrue
            $v['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey 'NeoIPC Surveillance end Antibiotic substance 01 - current event value')
        }
        It 'DE generator: fails loud when a slot has no categoryCombo and no sibling to copy one from' {
            $noCcDes = foreach ($d in (Get-NeoIPCSubstanceDataElementPlan -SubstanceCount 2)) {
                [ordered]@{ code = $d.Code; id = (& $script:SubDeId $d.Code) }   # deliberately NO categoryCombo
            }
            $pkg = @{ programs = $script:SubPkg['programs']; optionSets = $script:SubPkg['optionSets']; dataElements = @($noCcDes) }
            { New-NeoIPCSubstanceDataElement -ExistingPackage $pkg -SubstanceCount 3 } | Should -Throw '*categoryCombo*'
        }
    }

    Describe 'Common-commensal effective-flag computation (own-or-inherited, false overrides)' {
        BeforeAll {
            Import-Module powershell-yaml -ErrorAction Stop
            # A genus carries CommonCommensal; its species inherits it; a synonym under the species inherits it too.
            # A sibling genus carries nothing (default false). Verifies inheritance down Children + Synonyms and the
            # default-false fallback — the same model as the resistance flag but for the single CommonCommensal flag.
            $yaml = @'
Hierarchies:
- Name: Not listed
  Id: 0
  CommonCommensal: true
- Name: Bacteria
  Children:
  - Name: Staphylococcus
    Id: 100
    CommonCommensal: true
    Children:
    - Name: Staphylococcus epidermidis
      Id: 101
      Synonyms:
      - Name: Old epidermidis name
        Id: 102
  - Name: Escherichia
    Id: 200
    Children:
    - Name: Escherichia coli
      Id: 201
'@
            $script:CcTree = ($yaml | ConvertFrom-Yaml)
        }

        It 'inherits the flag down Children and Synonyms (genus -> species -> synonym)' {
            $flags = @(Get-NeoIPCCommonCommensalFlag -Node $script:CcTree)
            ($flags | Where-Object { $_.Id -eq 100 })['CommonCommensal'] | Should -BeTrue
            ($flags | Where-Object { $_.Id -eq 101 })['CommonCommensal'] | Should -BeTrue
            ($flags | Where-Object { $_.Id -eq 102 })['CommonCommensal'] | Should -BeTrue
        }
        It 'defaults to false where no flag is set on the node or any ancestor' {
            $flags = @(Get-NeoIPCCommonCommensalFlag -Node $script:CcTree)
            ($flags | Where-Object { $_.Id -eq 200 })['CommonCommensal'] | Should -BeFalse
            ($flags | Where-Object { $_.Id -eq 201 })['CommonCommensal'] | Should -BeFalse
        }
        It 'honours an explicit false that overrides an inherited true (and re-inherits below)' {
            $tree = [ordered]@{ Hierarchies = @(
                    [ordered]@{ Name = 'Genus'; Id = 1; CommonCommensal = $true; Children = @(
                            [ordered]@{ Name = 'Exception species'; Id = 2; CommonCommensal = $false; Children = @(
                                    [ordered]@{ Name = 'Sub'; Id = 3 }
                                ) }
                            [ordered]@{ Name = 'Normal species'; Id = 4 }
                        ) }
                ) }
            $flags = @(Get-NeoIPCCommonCommensalFlag -Node $tree)
            ($flags | Where-Object { $_.Id -eq 1 })['CommonCommensal'] | Should -BeTrue
            ($flags | Where-Object { $_.Id -eq 2 })['CommonCommensal'] | Should -BeFalse
            ($flags | Where-Object { $_.Id -eq 3 })['CommonCommensal'] | Should -BeFalse
            ($flags | Where-Object { $_.Id -eq 4 })['CommonCommensal'] | Should -BeTrue
        }
        It 'fails loud on a non-boolean flag value' {
            $tree = [ordered]@{ Hierarchies = @([ordered]@{ Name = 'X'; Id = 9; CommonCommensal = 'maybe' }) }
            { Get-NeoIPCCommonCommensalFlag -Node $tree } | Should -Throw '*non-boolean*'
        }
        It 'fails loud on a non-integer Id' {
            $tree = [ordered]@{ Hierarchies = @([ordered]@{ Name = 'X'; Id = 'not-a-number'; CommonCommensal = $true }) }
            { Get-NeoIPCCommonCommensalFlag -Node $tree } | Should -Throw '*non-integer Id*'
        }

        It 'aggregates the code set ascending, true ids only' {
            @(Get-NeoIPCCommonCommensalCodeSet -Node $script:CcTree) | Should -Be @(0, 100, 101, 102)
        }
        It 'sorts numerically, not lexically' {
            $tree = [ordered]@{ Hierarchies = @(
                    [ordered]@{ Name = 'A'; Id = 100; CommonCommensal = $true }
                    [ordered]@{ Name = 'B'; Id = 9; CommonCommensal = $true }
                    [ordered]@{ Name = 'C'; Id = 21; CommonCommensal = $true }
                ) }
            @(Get-NeoIPCCommonCommensalCodeSet -Node $tree) | Should -Be @(9, 21, 100)
        }
        It 'returns an empty set when nothing is flagged' {
            $tree = [ordered]@{ Hierarchies = @([ordered]@{ Name = 'A'; Id = 1 }, [ordered]@{ Name = 'B'; Id = 2 }) }
            @(Get-NeoIPCCommonCommensalCodeSet -Node $tree).Count | Should -Be 0
        }
    }

    Describe 'Pathogen slot-suffix matrix' {
        It 'gives a BSI primary slot the full suffix set (base + NAME + 5 resistance + SOURCE + MULTIPLE), in order' {
            @(Get-NeoIPCPathogenSlotSuffix -Stage 'BSI' -IsPrimary $true) |
                Should -Be @('', 'NAME', '3GCR', 'CAR', 'COR', 'MRSA', 'VRE', 'SOURCE', 'MULTIPLE')
        }
        It 'gives HAP primary a SOURCE but no MULTIPLE' {
            @(Get-NeoIPCPathogenSlotSuffix -Stage 'HAP' -IsPrimary $true) |
                Should -Be @('', 'NAME', '3GCR', 'CAR', 'COR', 'MRSA', 'VRE', 'SOURCE')
        }
        It 'gives SSI primary neither SOURCE nor MULTIPLE' {
            @(Get-NeoIPCPathogenSlotSuffix -Stage 'SSI' -IsPrimary $true) |
                Should -Be @('', 'NAME', '3GCR', 'CAR', 'COR', 'MRSA', 'VRE')
        }
        It 'gives a secondary slot the core suffixes only, on every stage that carries them' {
            foreach ($s in 'HAP', 'NEC', 'SSI') {
                @(Get-NeoIPCPathogenSlotSuffix -Stage $s -IsPrimary $false) |
                    Should -Be @('', 'NAME', '3GCR', 'CAR', 'COR', 'MRSA', 'VRE')
            }
        }
    }

    Describe 'Pathogen field-gating generation' {
        BeforeAll {
            Import-Module powershell-yaml -ErrorAction Stop
            $script:FgVarPlan = @(Get-NeoIPCPathogenFieldGatingVariablePlan)
            $script:FgRulePlan = @(Get-NeoIPCPathogenFieldGatingRulePlan)

            # Tiny ontology: Id 0 and the Staphylococcus genus (100) are common commensals; S. aureus (101) overrides
            # to false. So the effective CC code set is {0,100} — small enough to pin the negated ASSIGN exactly.
            $script:FgYaml = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-fg-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $script:FgYaml -Encoding utf8 -Value @'
Hierarchies:
- Name: Not listed
  Id: 0
  CommonCommensal: true
- Name: Bacteria
  Children:
  - Name: Staphylococcus
    Id: 100
    CommonCommensal: true
    Children:
    - Name: Staphylococcus aureus
      Id: 101
      CommonCommensal: false
  - Name: Escherichia coli
    Id: 200
'@
            # The four pathogen stages (BSI/HAP/SSI/NEC), each resolved via a slot-1 _3GCR anchor DE in
            # programStageDataElements (stages carry no code), plus every pathogen DE (so every gating target resolves),
            # the program, and empty rule/action collections. Built from the DE plan so it stays in lockstep.
            $repDe = @{ BSI = 'NEOIPC_BSI_PATHOGEN_1_3GCR'; HAP = 'NEOIPC_HAP_PATHOGEN_1_3GCR'; SSI = 'NEOIPC_SSI_PATHOGEN_1_3GCR'; NEC = 'NEOIPC_NEC_SEC_BSI_PATHOGEN_1_3GCR' }
            $stages = foreach ($s in 'BSI', 'HAP', 'SSI', 'NEC') {
                [ordered]@{
                    id                       = (New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey "NEOIPC_$s")
                    programStageDataElements = @([ordered]@{ dataElement = [ordered]@{ id = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $repDe[$s]) } })
                }
            }
            $des = foreach ($d in (Get-NeoIPCPathogenDataElementPlan)) {
                [ordered]@{ code = $d.Code; id = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $d.Code) }
            }
            $script:FgPkg = @{
                programs           = @([ordered]@{ code = 'NEOIPC_CORE'; id = 'progCore001' })
                programStages      = @($stages)
                dataElements       = @($des)
                programRules       = @()
                programRuleActions = @()
            }
        }
        AfterAll {
            if ($script:FgYaml -and (Test-Path -LiteralPath $script:FgYaml)) { Remove-Item -LiteralPath $script:FgYaml -Force }
        }

        # ---- variable plan -------------------------------------------------------------------------------------------
        It 'variable plan: one is-recognized-pathogen boolean per BSI primary slot, BSI only' {
            $script:FgVarPlan.Count | Should -Be 3
            @($script:FgVarPlan | Where-Object { $_.Stage -ne 'BSI' }).Count | Should -Be 0
            $v = @($script:FgVarPlan | Where-Object { $_.Index -eq 1 })[0]
            $v.Name | Should -BeExactly 'NeoIPC BSI Pathogen 1 is recognized pathogen'
            $v.SourceType | Should -BeExactly 'CALCULATED_VALUE'
            $v.ValueType | Should -BeExactly 'BOOLEAN'
            $v.DataElementCode | Should -BeNullOrEmpty
        }
        It 'variable plan: PathogenCount drives slot expansion (1 -> 1, 9 -> 9, named up to the max slot)' {
            @(Get-NeoIPCPathogenFieldGatingVariablePlan -PathogenCount 1).Count | Should -Be 1
            $nine = @(Get-NeoIPCPathogenFieldGatingVariablePlan -PathogenCount 9)
            $nine.Count | Should -Be 9
            @($nine | Where-Object { $_.Name -eq 'NeoIPC BSI Pathogen 9 is recognized pathogen' }).Count | Should -Be 1
        }

        # ---- rule plan -----------------------------------------------------------------------------------------------
        It 'rule plan: 56 rules at count 3, broken down by kind' {
            # recognizedPathogen 3 (BSI primary) + whenSet 3 (BSI primary) + whenEmpty 14 + whenEmptyOrListed 18 +
            # whenNotListed 18. whenEmpty = 14: BSI/HAP primary all 3 slots (own SOURCE/MULTIPLE always hide) = 6;
            # SSI primary + the 3 secondary stages emit it only where a downstream slot exists (slots 1-2) = 4*2 = 8.
            $script:FgRulePlan.Count | Should -Be 56
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'recognizedPathogen' }).Count) | Should -Be 3
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenSet' }).Count) | Should -Be 3
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmpty' }).Count) | Should -Be 14
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmptyOrListed' }).Count) | Should -Be 18
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenNotListed' }).Count) | Should -Be 18
        }
        It 'rule plan: recognizedPathogen and whenSet exist only on BSI primary slots' {
            foreach ($k in 'recognizedPathogen', 'whenSet') {
                @($script:FgRulePlan | Where-Object { $_.Kind -eq $k -and -not ($_.Stage -eq 'BSI' -and $_.SlotKind -eq 'primary') }).Count |
                    Should -Be 0
            }
        }
        It 'rule plan: whenEmpty is omitted only when a slot has no own-extra and no downstream slot' {
            # SSI primary slot 3 (no SOURCE/MULTIPLE, no downstream) -> no whenEmpty; slot 1 (downstream 2,3) -> has one.
            @($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmpty' -and $_.Stage -eq 'SSI' -and $_.SlotKind -eq 'primary' -and $_.Index -eq 3 }).Count | Should -Be 0
            @($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmpty' -and $_.Stage -eq 'SSI' -and $_.SlotKind -eq 'primary' -and $_.Index -eq 1 }).Count | Should -Be 1
            # The last secondary slot likewise drops whenEmpty; BSI primary keeps it on every slot (own SOURCE/MULTIPLE).
            @($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmpty' -and $_.SlotKind -eq 'secondary' -and $_.Index -eq 3 }).Count | Should -Be 0
            @($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmpty' -and $_.Stage -eq 'BSI' -and $_.Index -eq 3 }).Count | Should -Be 1
        }
        It 'rule plan: recognizedPathogen is priority 0, every other kind priority 1' {
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'recognizedPathogen' -and $_.Priority -ne 0 }).Count) | Should -Be 0
            (@($script:FgRulePlan | Where-Object { $_.Kind -ne 'recognizedPathogen' -and $_.Priority -ne 1 }).Count) | Should -Be 0
        }
        It 'rule plan: whenNotListed is the exact De Morgan complement of whenEmptyOrListed (mandatory iff shown)' {
            # !(hasValue && ==0) == (!hasValue || !=0): the name field is required exactly when it is not hidden.
            foreach ($nl in @($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenNotListed' })) {
                $v = $nl.ValueVariable
                $eol = @($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenEmptyOrListed' -and $_.Stage -eq $nl.Stage -and $_.SlotKind -eq $nl.SlotKind -and $_.Index -eq $nl.Index })[0]
                $nl.Condition | Should -BeExactly "d2:hasValue(#{$v}) && #{$v} == 0"
                $eol.Condition | Should -BeExactly "!d2:hasValue(#{$v}) || #{$v} != 0"
            }
        }
        It 'rule plan: uses the secondary-BSI name template for secondary slots' {
            (@($script:FgRulePlan | Where-Object { $_.Kind -eq 'whenNotListed' -and $_.Stage -eq 'NEC' -and $_.Index -eq 1 })[0].Name) |
                Should -BeExactly 'NeoIPC NEC Secondary BSI pathogen 1 - when not listed'
        }

        # ---- variable generator --------------------------------------------------------------------------------------
        It 'variable generator: 3 PRVs, resolving the program and preserving the UID by name; mints otherwise' {
            $pkg = $script:FgPkg.Clone()
            $pkg['programRuleVariables'] = @([ordered]@{ name = 'NeoIPC BSI Pathogen 1 is recognized pathogen'; id = 'fgRecP1AAAA' })
            $frag = New-NeoIPCPathogenFieldGatingVariable -ExistingPackage $pkg
            @($frag['programRuleVariables']).Count | Should -Be 3
            $byName = @{}; foreach ($v in @($frag['programRuleVariables'])) { $byName[[string]$v['name']] = $v }
            $p1 = $byName['NeoIPC BSI Pathogen 1 is recognized pathogen']
            $p1['id'] | Should -BeExactly 'fgRecP1AAAA'   # preserved
            $p1['programRuleVariableSourceType'] | Should -BeExactly 'CALCULATED_VALUE'
            $p1['valueType'] | Should -BeExactly 'BOOLEAN'
            $p1['program']['id'] | Should -BeExactly 'progCore001'
            $p1.Contains('dataElement') | Should -BeFalse
            $byName['NeoIPC BSI Pathogen 2 is recognized pathogen']['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleVariables' -NaturalKey 'NeoIPC BSI Pathogen 2 is recognized pathogen')
        }
        It 'variable generator: fail-loud paths (program absent; invalid id re-mints; duplicate name; UID collision)' {
            { New-NeoIPCPathogenFieldGatingVariable -ExistingPackage @{ programs = @(); programRuleVariables = @() } } | Should -Throw '*NEOIPC_CORE*'
            $badId = $script:FgPkg.Clone()
            $badId['programRuleVariables'] = @([ordered]@{ name = 'NeoIPC BSI Pathogen 1 is recognized pathogen'; id = 'BAD!' })
            $v = @((New-NeoIPCPathogenFieldGatingVariable -ExistingPackage $badId)['programRuleVariables'] | Where-Object { $_['name'] -eq 'NeoIPC BSI Pathogen 1 is recognized pathogen' })[0]
            (Test-NeoIPCMetadataUid -Id $v['id']) | Should -BeTrue
            $dupName = $script:FgPkg.Clone()
            $dupName['programRuleVariables'] = @(
                [ordered]@{ name = 'NeoIPC BSI Pathogen 1 is recognized pathogen'; id = 'fgDupAAAA01' },
                [ordered]@{ name = 'NeoIPC BSI Pathogen 1 is recognized pathogen'; id = 'fgDupAAAA02' })
            { New-NeoIPCPathogenFieldGatingVariable -ExistingPackage $dupName } | Should -Throw '*Duplicate program-rule-variable name*'
        }

        # ---- rule generator ------------------------------------------------------------------------------------------
        It 'rule generator: 56 rules and 177 actions' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            @($frag['programRules']).Count | Should -Be 56
            # 3 ASSIGN + 3 whenSet + 18 whenEmptyOrListed + 18 whenNotListed + 135 whenEmpty HIDEFIELDs.
            @($frag['programRuleActions']).Count | Should -Be 177
        }
        It 'rule generator: forwards PathogenCount (1 -> the single-slot subset)' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg -PathogenCount 1
            # Per slot-1-only group: BSI {recognized, whenSet, whenEmpty, EOL, NL}=5; HAP primary {whenEmpty,EOL,NL}=3;
            # SSI primary {EOL,NL}=2 (no own-extra, no downstream); 3 secondary stages {EOL,NL}=2 each = 6. Total 16.
            @($frag['programRules']).Count | Should -Be 16
        }
        It 'rule generator: recognizedPathogen ASSIGN content = the is-recognized var, data = hasValue && negated CC set (ascending)' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $rp = $rules['NeoIPC BSI Pathogen 1 - set recognized pathogen']
            $rp['condition'] | Should -BeExactly 'true'
            $rp['priority'] | Should -Be 0
            $act = $acts[[string]@($rp['programRuleActions'])[0]['id']]
            $act['programRuleActionType'] | Should -BeExactly 'ASSIGN'
            $act['content'] | Should -BeExactly '#{NeoIPC BSI Pathogen 1 is recognized pathogen}'
            $act['data'] | Should -BeExactly 'd2:hasValue(#{NeoIPC BSI Pathogen 1 value}) && !(#{NeoIPC BSI Pathogen 1 value}==0||#{NeoIPC BSI Pathogen 1 value}==100)'
            $act.Contains('dataElement') | Should -BeFalse
        }
        It 'rule generator: whenSet makes _SOURCE mandatory; condition is d2:hasValue on the slot value' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $ws = $rules['NeoIPC BSI Pathogen 1 - when set']
            $ws['condition'] | Should -BeExactly 'd2:hasValue(#{NeoIPC BSI Pathogen 1 value})'
            $ws['priority'] | Should -Be 1
            $act = $acts[[string]@($ws['programRuleActions'])[0]['id']]
            $act['programRuleActionType'] | Should -BeExactly 'SETMANDATORYFIELD'
            $act['dataElement']['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1_SOURCE')
        }
        It 'rule generator: whenEmpty hides own SOURCE/MULTIPLE + every downstream slot field (progressive reveal)' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $we = $rules['NeoIPC BSI Pathogen 1 - when empty']
            $we['condition'] | Should -BeExactly '!d2:hasValue(#{NeoIPC BSI Pathogen 1 value})'
            $hidden = @($we['programRuleActions'] | ForEach-Object { $acts[[string]$_['id']] })
            ($hidden | ForEach-Object { $_['programRuleActionType'] } | Select-Object -Unique) | Should -Be 'HIDEFIELD'
            # Own SOURCE + MULTIPLE, then slots 2 and 3 x 7 core fields = 2 + 14 = 16.
            $hidden.Count | Should -Be 16
            $targetIds = @($hidden | ForEach-Object { $_['dataElement']['id'] })
            foreach ($c in 'NEOIPC_BSI_PATHOGEN_1_SOURCE', 'NEOIPC_BSI_PATHOGEN_1_MULTIPLE', 'NEOIPC_BSI_PATHOGEN_2', 'NEOIPC_BSI_PATHOGEN_3_VRE') {
                $targetIds | Should -Contain (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey $c)
            }
            # A downstream slot's own SOURCE/MULTIPLE are hidden by THAT slot's own whenEmpty, never repeated here.
            $targetIds | Should -Not -Contain (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_2_SOURCE')
        }
        It 'rule generator: whenEmptyOrListed hides _NAME; whenNotListed requires _NAME (complementary conditions)' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $acts = @{}; foreach ($a in @($frag['programRuleActions'])) { $acts[[string]$a['id']] = $a }
            $nameId = New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1_NAME'
            $eol = $rules['NeoIPC BSI Pathogen 1 - when empty or listed']
            $eol['condition'] | Should -BeExactly '!d2:hasValue(#{NeoIPC BSI Pathogen 1 value}) || #{NeoIPC BSI Pathogen 1 value} != 0'
            $eolAct = $acts[[string]@($eol['programRuleActions'])[0]['id']]
            $eolAct['programRuleActionType'] | Should -BeExactly 'HIDEFIELD'
            $eolAct['dataElement']['id'] | Should -BeExactly $nameId
            $nl = $rules['NeoIPC BSI Pathogen 1 - when not listed']
            $nl['condition'] | Should -BeExactly 'd2:hasValue(#{NeoIPC BSI Pathogen 1 value}) && #{NeoIPC BSI Pathogen 1 value} == 0'
            $nlAct = $acts[[string]@($nl['programRuleActions'])[0]['id']]
            $nlAct['programRuleActionType'] | Should -BeExactly 'SETMANDATORYFIELD'
            $nlAct['dataElement']['id'] | Should -BeExactly $nameId
        }
        It 'rule generator: resolves each rule programStage via DE->stage membership (stages carry no code)' {
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $rules['NeoIPC BSI Pathogen 1 - when not listed']['programStage']['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey 'NEOIPC_BSI')
            $rules['NeoIPC NEC Secondary BSI pathogen 1 - when not listed']['programStage']['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey 'NEOIPC_NEC')
        }
        It 'rule generator: preserves rule UID + action UID from the export by name; uses the plan description; mints otherwise' {
            $pkg = $script:FgPkg.Clone()
            $bsiStageId = New-NeoIPCMetadataUid -Type 'programStages' -NaturalKey 'NEOIPC_BSI'
            $pkg['programRules'] = @([ordered]@{ name = 'NeoIPC BSI Pathogen 1 - when set'; id = 'RULEseed001'; description = 'Seeded description.' })
            $pkg['programRuleActions'] = @([ordered]@{ id = 'ACTseed0001'; programRule = [ordered]@{ id = 'RULEseed001' }; programRuleActionType = 'SETMANDATORYFIELD'; dataElement = [ordered]@{ id = (New-NeoIPCMetadataUid -Type 'dataElements' -NaturalKey 'NEOIPC_BSI_PATHOGEN_1_SOURCE') } })
            $frag = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $pkg
            $rules = @{}; foreach ($r in @($frag['programRules'])) { $rules[[string]$r['name']] = $r }
            $seeded = $rules['NeoIPC BSI Pathogen 1 - when set']
            $seeded['id'] | Should -BeExactly 'RULEseed001'
            # Description is the canonical plan wording — it OVERWRITES the deployed/seeded text; UID + action UID kept.
            $expectedDesc = [string](@(Get-NeoIPCPathogenFieldGatingRulePlan | Where-Object { [string]$_['Name'] -eq 'NeoIPC BSI Pathogen 1 - when set' })[0]['Description'])
            $expectedDesc | Should -Not -BeNullOrEmpty
            $seeded['description'] | Should -BeExactly $expectedDesc
            @($seeded['programRuleActions'])[0]['id'] | Should -BeExactly 'ACTseed0001'
            # A rule absent from the export mints rule + action deterministically.
            $minted = $rules['NeoIPC BSI Pathogen 1 - when not listed']
            $minted['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRules' -NaturalKey 'NeoIPC BSI Pathogen 1 - when not listed')
            @($minted['programRuleActions'])[0]['id'] |
                Should -BeExactly (New-NeoIPCMetadataUid -Type 'programRuleActions' -NaturalKey 'NeoIPC BSI Pathogen 1 - when not listed|SETMANDATORYFIELD|NEOIPC_BSI_PATHOGEN_1_NAME')
        }
        It 'rule generator: mints deterministically across runs' {
            $a = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            $b = New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $script:FgPkg
            @($a['programRules'] | ForEach-Object { $_['id'] }) | Should -Be @($b['programRules'] | ForEach-Object { $_['id'] })
            @($a['programRuleActions'] | ForEach-Object { $_['id'] }) | Should -Be @($b['programRuleActions'] | ForEach-Object { $_['id'] })
        }
        It 'rule generator: fails loud when the program is absent' {
            $pkg = @{ programs = @(); programStages = $script:FgPkg['programStages']; dataElements = $script:FgPkg['dataElements']; programRules = @(); programRuleActions = @() }
            { New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $pkg } | Should -Throw '*NEOIPC_CORE*'
        }
        It 'rule generator: fails loud when a stage anchor data element is absent (stage unresolvable)' {
            $pkg = $script:FgPkg.Clone()
            $pkg['dataElements'] = @($script:FgPkg['dataElements'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_NEC_SEC_BSI_PATHOGEN_1_3GCR' })
            { New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $pkg } | Should -Throw '*program stage*'
        }
        It 'rule generator: fails loud when a gating target data element is absent' {
            $pkg = $script:FgPkg.Clone()
            $pkg['dataElements'] = @($script:FgPkg['dataElements'] | Where-Object { [string]$_['code'] -ne 'NEOIPC_BSI_PATHOGEN_1_NAME' })
            { New-NeoIPCPathogenFieldGatingRule -Path $script:FgYaml -ExistingPackage $pkg } | Should -Throw '*NEOIPC_BSI_PATHOGEN_1_NAME*'
        }
        It 'rule generator: fails loud when the common-commensal set is empty (no recognized-pathogen expression)' {
            $emptyYaml = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-fg-empty-{0}.yaml' -f ([guid]::NewGuid().ToString('N')))
            Set-Content -LiteralPath $emptyYaml -Encoding utf8 -Value "Hierarchies:`n- Name: Bacteria`n  Id: 1`n"
            try {
                { New-NeoIPCPathogenFieldGatingRule -Path $emptyYaml -ExistingPackage $script:FgPkg } | Should -Throw '*common-commensal code set is empty*'
            }
            finally { Remove-Item -LiteralPath $emptyYaml -Force }
        }
    }

    Describe 'Add-NeoIPCGeneratedMetadata (generated-class splice)' {
        # The nine generators are tested in their own Describes; here they are MOCKED to return small controlled
        # fragments so this exercises only the splice — replacement by id/code/name, the stale-aggregate drop, the
        # non-family-action salvage, and the duplicate-id guard — without a full pathogen-machinery fixture.
        # Reproduced objects carry the deployed id (preserve-by-key); optNEW + prvFG1 are mint-only additions.
        BeforeAll {
            function New-SpliceConfig {
                [ordered]@{
                    optionSets           = @([ordered]@{ id = 'osOther'; code = 'OTHER_SET' }, [ordered]@{ id = 'osP'; code = 'NEOIPC_PATHOGENS' }, [ordered]@{ id = 'osAbx'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES' })
                    options              = @([ordered]@{ id = 'optOther'; code = 'x'; optionSet = [ordered]@{ id = 'osOther' } }, [ordered]@{ id = 'optA'; code = '0'; optionSet = [ordered]@{ id = 'osP' } }, [ordered]@{ id = 'optAbxOld'; code = 'J01AA01'; optionSet = [ordered]@{ id = 'osAbx' } })
                    optionGroups         = @([ordered]@{ id = 'ogAtc'; code = 'J01AA' }, [ordered]@{ id = 'ogAw'; code = 'WHO_AWARE_WATCH' })
                    optionGroupSets      = @([ordered]@{ id = 'ogsAtc'; code = 'ATC5' }, [ordered]@{ id = 'ogsAw'; code = 'WHO_AWARE' })
                    dataElements         = @([ordered]@{ id = 'deOther'; code = 'NEOIPC_ADM_X' }, [ordered]@{ id = 'deP1'; code = 'NEOIPC_BSI_PATHOGEN_1' })
                    programRuleVariables = @([ordered]@{ id = 'prvOther'; name = 'Some other var' }, [ordered]@{ id = 'prvR1'; name = 'NeoIPC BSI Pathogen 1 value' })
                    programRules         = @(
                        [ordered]@{ id = 'ruleDef'; name = 'Some definition rule' },
                        [ordered]@{ id = 'ruleAgg'; name = 'NeoIPC HAP - set pathogen attribute variables' },
                        [ordered]@{ id = 'ruleWS'; name = 'NeoIPC BSI Pathogen 1 - when set' },
                        [ordered]@{ id = 'ruleSV'; name = 'NeoIPC Surveillance end Antibiotic substance days - validate' }
                    )
                    programRuleActions   = @(
                        [ordered]@{ id = 'actDef'; programRule = [ordered]@{ id = 'ruleDef' }; programRuleActionType = 'HIDEFIELD'; dataElement = [ordered]@{ id = 'deOther' } },
                        [ordered]@{ id = 'actAgg'; programRule = [ordered]@{ id = 'ruleAgg' }; programRuleActionType = 'ASSIGN' },
                        [ordered]@{ id = 'actWSsrc'; programRule = [ordered]@{ id = 'ruleWS' }; programRuleActionType = 'SETMANDATORYFIELD'; dataElement = [ordered]@{ id = 'deSrc' } },
                        [ordered]@{ id = 'actNoPos'; programRule = [ordered]@{ id = 'ruleWS' }; programRuleActionType = 'HIDEFIELD'; dataElement = [ordered]@{ id = 'deNoPos' } },
                        [ordered]@{ id = 'actSV'; programRule = [ordered]@{ id = 'ruleSV' }; programRuleActionType = 'SHOWERROR'; dataElement = [ordered]@{ id = 'deABdays' } }
                    )
                }
            }
        }
        BeforeEach {
            Mock New-NeoIPCPathogenOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osP'; code = 'NEOIPC_PATHOGENS' }); options = @([ordered]@{ id = 'optA'; code = '0'; optionSet = [ordered]@{ id = 'osP' } }, [ordered]@{ id = 'optNEW'; code = '999'; optionSet = [ordered]@{ id = 'osP' } }) } }
            Mock New-NeoIPCPathogenDataElement { [ordered]@{ dataElements = @([ordered]@{ id = 'deP1'; code = 'NEOIPC_BSI_PATHOGEN_1' }, [ordered]@{ id = 'deSrc'; code = 'NEOIPC_BSI_PATHOGEN_1_SOURCE' }) } }
            Mock New-NeoIPCSubstanceDataElement { [ordered]@{ dataElements = @([ordered]@{ id = 'deS1'; code = 'NEOIPC_SURVEILLANCE_END_AB_SUBST_01' }) } }
            Mock New-NeoIPCPathogenVariable { [ordered]@{ programRuleVariables = @([ordered]@{ id = 'prvR1'; name = 'NeoIPC BSI Pathogen 1 value' }) } }
            Mock New-NeoIPCPathogenFieldGatingVariable { [ordered]@{ programRuleVariables = @([ordered]@{ id = 'prvFG1'; name = 'NeoIPC BSI Pathogen 1 is recognized pathogen' }) } }
            Mock New-NeoIPCSubstanceVariable { [ordered]@{ programRuleVariables = @([ordered]@{ id = 'prvS1'; name = 'NeoIPC Surveillance end Antibiotic substance 01 - current event value' }) } }
            Mock New-NeoIPCPathogenRule { [ordered]@{ programRules = @([ordered]@{ id = 'ruleR1'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR'; programRuleActions = @([ordered]@{ id = 'actR1' }) }); programRuleActions = @([ordered]@{ id = 'actR1'; programRule = [ordered]@{ id = 'ruleR1' }; programRuleActionType = 'ASSIGN' }) } }
            Mock New-NeoIPCPathogenFieldGatingRule { [ordered]@{ programRules = @([ordered]@{ id = 'ruleWS'; name = 'NeoIPC BSI Pathogen 1 - when set'; programRuleActions = @([ordered]@{ id = 'actWSsrc' }) }); programRuleActions = @([ordered]@{ id = 'actWSsrc'; programRule = [ordered]@{ id = 'ruleWS' }; programRuleActionType = 'SETMANDATORYFIELD'; dataElement = [ordered]@{ id = 'deSrc' } }) } }
            Mock New-NeoIPCSubstanceRule { [ordered]@{ programRules = @([ordered]@{ id = 'ruleSV'; name = 'NeoIPC Surveillance end Antibiotic substance days - validate'; programRuleActions = @([ordered]@{ id = 'actSV' }) }); programRuleActions = @([ordered]@{ id = 'actSV'; programRule = [ordered]@{ id = 'ruleSV' }; programRuleActionType = 'SHOWERROR'; dataElement = [ordered]@{ id = 'deABdays' }; content = 'x' }) } }
            # Antibiotic generators: reproduce the deployed option set + groups + group-sets in place (same ids),
            # plus one new option (optAbx1 replacing the deployed optAbxOld by membership).
            Mock New-NeoIPCAntimicrobialOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osAbx'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES' }); options = @([ordered]@{ id = 'optAbx1'; code = 'J01AA01'; optionSet = [ordered]@{ id = 'osAbx' } }) } }
            Mock New-NeoIPCAntibioticOptionGroup { [ordered]@{ optionGroups = @([ordered]@{ id = 'ogAtc'; code = 'J01AA' }, [ordered]@{ id = 'ogAw'; code = 'WHO_AWARE_WATCH' }) } }
            Mock New-NeoIPCAntibioticOptionGroupSet { [ordered]@{ optionGroupSets = @([ordered]@{ id = 'ogsAtc'; code = 'ATC5' }, [ordered]@{ id = 'ogsAw'; code = 'WHO_AWARE' }) } }
        }

        It 'replaces the generated classes (by id/code/name) and keeps non-generated objects' {
            $out = Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{})
            @($out['optionSets'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('osAbx', 'osOther', 'osP')              # other kept, pathogen + antimicrobial replaced, no dup
            @($out['options'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('optA', 'optAbx1', 'optNEW', 'optOther')  # optA + optAbxOld replaced, optNEW added, other kept
            @($out['dataElements'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('deOther', 'deP1', 'deS1', 'deSrc')
            @($out['programRuleVariables'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('prvFG1', 'prvOther', 'prvR1', 'prvS1')
            @($out['optionGroups'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('ogAtc', 'ogAw')                     # antibiotic ATC + AWaRe groups, replaced in place
            @($out['optionGroupSets'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('ogsAtc', 'ogsAw')
        }
        It 'drops the stale HAP aggregate rule and its actions; keeps the definition rule' {
            $out = Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{})
            @($out['programRules'] | Where-Object { [string]$_['id'] -eq 'ruleAgg' }).Count | Should -Be 0
            @($out['programRuleActions'] | Where-Object { [string]$_['id'] -eq 'actAgg' }).Count | Should -Be 0
            @($out['programRules'] | Where-Object { [string]$_['id'] -eq 'ruleDef' }).Count | Should -Be 1
            @($out['programRuleActions'] | Where-Object { [string]$_['id'] -eq 'actDef' }).Count | Should -Be 1
        }
        It 'salvages a non-family-target hand-authored action onto the regenerated rule' {
            $out = Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{})
            $ws = @($out['programRules'] | Where-Object { [string]$_['id'] -eq 'ruleWS' })[0]
            @($ws['programRuleActions'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('actNoPos', 'actWSsrc')
            $salv = @($out['programRuleActions'] | Where-Object { [string]$_['id'] -eq 'actNoPos' })
            $salv.Count | Should -Be 1
            $salv[0]['programRule']['id'] | Should -BeExactly 'ruleWS'
        }
        It 'does NOT salvage an action the generator already reproduces (the validate SHOWERROR)' {
            $out = Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{})
            @($out['programRuleActions'] | Where-Object { [string]$_['id'] -eq 'actSV' }).Count | Should -Be 1
        }
        It 'produces no duplicate ids across the spliced types' {
            $out = Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{})
            foreach ($t in 'optionSets', 'options', 'optionGroups', 'optionGroupSets', 'dataElements', 'programRuleVariables', 'programRules', 'programRuleActions') {
                $ids = @($out[$t] | ForEach-Object { [string]$_['id'] })
                ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
            }
        }
        It 'fails loud on a duplicate id introduced by the splice' {
            Mock New-NeoIPCPathogenDataElement { [ordered]@{ dataElements = @([ordered]@{ id = 'dup'; code = 'A' }, [ordered]@{ id = 'dup'; code = 'B' }) } }
            { Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{}) } | Should -Throw '*duplicate id*'
        }
        It 'forwards the slot counts to the generators' {
            $null = Add-NeoIPCGeneratedMetadata -Config (New-SpliceConfig) -Export ([ordered]@{}) -PathogenCount 5 -SubstanceCount 7
            Should -Invoke New-NeoIPCPathogenRule -ParameterFilter { $PathogenCount -eq 5 } -Times 1 -Exactly
            Should -Invoke New-NeoIPCSubstanceRule -ParameterFilter { $SubstanceCount -eq 7 } -Times 1 -Exactly
        }
    }

    Describe 'Add-NeoIPCGeneratedOptionMetadata (export-free option-domain splice)' {
        # The export-independent build path. The four option-domain generators are MOCKED to small fragments that
        # carry NO sharing / dataDimension, so this exercises only the splice: the pure ADD into the directory
        # config, the PUBLIC_RW sharing default + dataDimension=true default the export used to supply, the
        # no-override of a generator-supplied value, and the duplicate-id guard. No -Export, no seed.
        BeforeEach {
            Mock New-NeoIPCPathogenOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osP'; code = 'NEOIPC_PATHOGENS' }); options = @([ordered]@{ id = 'optP0'; code = '0'; optionSet = [ordered]@{ id = 'osP' } }) } }
            Mock New-NeoIPCAntimicrobialOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osAbx'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES' }); options = @([ordered]@{ id = 'optAbx1'; code = 'J01AA01'; optionSet = [ordered]@{ id = 'osAbx' } }) } }
            Mock New-NeoIPCAntibioticOptionGroup { [ordered]@{ optionGroups = @([ordered]@{ id = 'ogAtc'; code = 'J01AA' }) } }
            Mock New-NeoIPCAntibioticOptionGroupSet { [ordered]@{ optionGroupSets = @([ordered]@{ id = 'ogsAtc'; code = 'ATC5' }) } }
        }
        It 'adds the generated option-domain to the directory config (pure ADD; keeps the materialised matrix + config)' {
            $config = [ordered]@{
                dataElements = @([ordered]@{ id = 'deDir'; code = 'NEOIPC_BSI_PATHOGEN_1' })       # materialised matrix DE — untouched
                optionSets   = @([ordered]@{ id = 'osYn'; code = 'NEOIPC_YES_NO_NOT_TESTED' })       # config option set — kept
            }
            $out = Add-NeoIPCGeneratedOptionMetadata -Config $config
            @($out['dataElements'] | ForEach-Object { [string]$_['id'] }) | Should -Be @('deDir')
            @($out['optionSets'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('osAbx', 'osP', 'osYn')
            @($out['options'] | ForEach-Object { [string]$_['id'] } | Sort-Object) | Should -Be @('optAbx1', 'optP0')
            @($out['optionGroups'] | ForEach-Object { [string]$_['id'] }) | Should -Be @('ogAtc')
            @($out['optionGroupSets'] | ForEach-Object { [string]$_['id'] }) | Should -Be @('ogsAtc')
        }
        It 'applies the PUBLIC_RW sharing default to the generated option sets + groups (the export used to supply it)' {
            $out = Add-NeoIPCGeneratedOptionMetadata -Config ([ordered]@{})
            foreach ($o in @($out['optionSets']) + @($out['optionGroups'])) {
                [string]$o['sharing']['public'] | Should -BeExactly 'rw------'
            }
        }
        It 'defaults dataDimension=true and PUBLIC_RW on the option-group-set' {
            $out = Add-NeoIPCGeneratedOptionMetadata -Config ([ordered]@{})
            $gs = @($out['optionGroupSets'])[0]
            $gs['dataDimension'] | Should -BeTrue
            [string]$gs['sharing']['public'] | Should -BeExactly 'rw------'
        }
        It 'does not override a sharing / dataDimension value a generator already supplied' {
            Mock New-NeoIPCAntibioticOptionGroupSet { [ordered]@{ optionGroupSets = @([ordered]@{ id = 'ogsAtc'; code = 'ATC5'; dataDimension = $false; sharing = [ordered]@{ public = 'r-------' } }) } }
            $out = Add-NeoIPCGeneratedOptionMetadata -Config ([ordered]@{})
            $gs = @($out['optionGroupSets'])[0]
            $gs['dataDimension'] | Should -BeFalse
            [string]$gs['sharing']['public'] | Should -BeExactly 'r-------'
        }
        It 'fails loud on a duplicate id introduced by the splice' {
            $config = [ordered]@{ optionSets = @([ordered]@{ id = 'osP'; code = 'SOME_CONFIG_SET' }) }   # collides with the generated pathogen-set id
            { Add-NeoIPCGeneratedOptionMetadata -Config $config } | Should -Throw '*duplicate id*'
        }
    }

    Describe 'Antibiotic-domain generation (option set + ATC/AWaRe groups + group-sets)' {
        # Synthetic fixtures: a 5-substance source (incl. the Minocycline route-split + the Micronomicin tmp code)
        # and a 2-group source. UIDs are SOURCE identity (the `uid` column); the oral split J01AA08_O carries no uid
        # (not yet deployed -> minted). The mock export supplies only sharing + the validation/deployed code set.
        BeforeAll {
            $script:abxCsv = Join-Path $TestDrive 'NeoIPC-Antibiotics.csv'
            @('id,atc_code,name,atc_group,aware_category,uid',
                'J01AA01,J01AA01,Demeclocycline,J01AA,Watch,OptAbxAA011',
                'J01AA08_O,J01AA08,Minocycline (oral),J01AA,Watch,',
                'J01AA08_P,J01AA08,Minocycline (i. v.),J01AA,Reserve,OptAbxAA081',
                'tmp_001,,Micronomicin,J01GB,Watch,OptAbxMicr1',
                'J01GB06,J01GB06,Amikacin,J01GB,Access,OptAbxGB061') | Set-Content -LiteralPath $script:abxCsv -Encoding utf8NoBOM
            $script:abxGrpCsv = Join-Path $TestDrive 'NeoIPC-Antibiotic-Groups.csv'
            @('code,name,shortName,description,uid',
                'J01AA,Tetracyclines,Tetracyclines,Tetracycline antibacterials.,GrpAtcAA001',
                'J01GB,Other aminoglycosides,Aminoglycosides,Aminoglycoside antibacterials.,GrpAtcGB001') | Set-Content -LiteralPath $script:abxGrpCsv -Encoding utf8NoBOM
            function New-AbxExport {
                [ordered]@{
                    optionSets      = @([ordered]@{ id = 'OptSetAbx01'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; name = 'NeoIPC Antimicrobial Substances'; valueType = 'TEXT' })
                    options         = @(
                        [ordered]@{ id = 'OptAbxAA011'; code = 'J01AA01'; optionSet = [ordered]@{ id = 'OptSetAbx01' } },
                        [ordered]@{ id = 'OptAbxAA081'; code = 'J01AA08'; optionSet = [ordered]@{ id = 'OptSetAbx01' } },        # -> J01AA08_P
                        [ordered]@{ id = 'OptAbxMicr1'; code = 'Micronomicin'; optionSet = [ordered]@{ id = 'OptSetAbx01' } }, # -> tmp_001
                        [ordered]@{ id = 'OptAbxGB061'; code = 'J01GB06'; optionSet = [ordered]@{ id = 'OptSetAbx01' } })
                    optionGroups    = @(
                        [ordered]@{ id = 'GrpAtcAA001'; code = 'J01AA'; name = 'Tetracyclines'; shortName = 'Tetracyclines' },
                        [ordered]@{ id = 'GrpAtcGB001'; code = 'J01GB'; name = 'Other aminoglycosides'; shortName = 'Aminoglycosides' },
                        [ordered]@{ id = 'GrpAwAcce01'; code = 'WHO_AWARE_ACCESS'; name = 'AWaRe Access'; shortName = 'AWaRe A'; description = 'Access antibiotics.' },
                        [ordered]@{ id = 'GrpAwWatc01'; code = 'WHO_AWARE_WATCH'; name = 'AWaRe Watch'; shortName = 'AWaRe W' },
                        [ordered]@{ id = 'GrpAwRese01'; code = 'WHO_AWARE_RESERVE'; name = 'AWaRe Reserve'; shortName = 'AWaRe R' })
                    optionGroupSets = @(
                        [ordered]@{ id = 'GrpSetAtc01'; code = 'ATC5'; name = 'ATC-5 Groups'; dataDimension = $true; optionSet = [ordered]@{ id = 'OptSetAbx01' } },
                        [ordered]@{ id = 'GrpSetAware'; code = 'WHO_AWARE'; name = 'AWaRe Groups'; description = 'AWaRe classification.'; dataDimension = $true; optionSet = [ordered]@{ id = 'OptSetAbx01' } })
                }
            }
        }

        It 'option set: one option per substance; UID from the source column; mints the new oral split (blank uid)' {
            $f = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -OptionSetUid 'OptSetAbx01' -ExistingPackage (New-AbxExport)
            @($f['options']).Count | Should -Be 5
            $f['optionSets'][0]['id'] | Should -BeExactly 'OptSetAbx01'   # from -OptionSetUid (source)
            $f['optionSets'][0]['valueType'] | Should -BeExactly 'TEXT'
            @($f['options'] | Where-Object { $_['code'] -eq 'J01AA01' })[0]['id'] | Should -BeExactly 'OptAbxAA011'
            @($f['options'] | Where-Object { $_['code'] -eq 'J01AA08_O' })[0]['id'] | Should -Not -BeNullOrEmpty   # blank uid -> minted
        }
        It 'option set: the documented code renames carry the inherited deployed UID in the source column' {
            $f = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            @($f['options'] | Where-Object { $_['code'] -eq 'J01AA08_P' })[0]['id'] | Should -BeExactly 'OptAbxAA081'
            @($f['options'] | Where-Object { $_['code'] -eq 'tmp_001' })[0]['id'] | Should -BeExactly 'OptAbxMicr1'
        }
        It 'option set: sortOrder is 1-based alphabetical by name' {
            $f = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            @($f['options'] | Sort-Object { $_['sortOrder'] } | ForEach-Object { $_['name'] })[0] | Should -BeExactly 'Amikacin'
        }
        It 'option set: fails loud when a deployed code is absent from the source' {
            $pkg = New-AbxExport
            $pkg['options'] = @($pkg['options']) + @([ordered]@{ id = 'GhostOpt001'; code = 'J01ZZ99'; optionSet = [ordered]@{ id = 'OptSetAbx01' } })
            { New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage $pkg } | Should -Throw '*J01ZZ99*'
        }
        It 'option set: fails loud when the set is absent from the package' {
            { New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage ([ordered]@{ optionSets = @(); options = @() }) } | Should -Throw '*was not found*'
        }
        It 'option set: localizes option names from the antibiotic catalogue (property NAME)' {
            $poDir = Join-Path $TestDrive 'abxpo'; New-Item -ItemType Directory -Path $poDir -Force | Out-Null
            @('msgid ""', 'msgstr ""', '', 'msgid "Amikacin"', 'msgstr "Amikacin DE"') | Set-Content -LiteralPath (Join-Path $poDir 'antibiotics.de.po') -Encoding utf8NoBOM
            $f = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport) -PoDirectory $poDir
            $t = @(@($f['options'] | Where-Object { $_['code'] -eq 'J01GB06' })[0]['translations'] | Where-Object { $_['locale'] -eq 'de' })[0]
            $t['property'] | Should -BeExactly 'NAME'
            $t['value'] | Should -BeExactly 'Amikacin DE'
        }
        It 'option groups: ATC + AWaRe groups with derived membership; tmp assigned to its clinical ATC group' {
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage (New-AbxExport)
            @($og['optionGroups']).Count | Should -Be 5
            $byUid = @{}; $os['options'] | ForEach-Object { $byUid[$_['id']] = $_['code'] }
            $gb = @($og['optionGroups'] | Where-Object { $_['code'] -eq 'J01GB' })[0]
            @($gb['options'] | ForEach-Object { $byUid[$_['id']] }) | Should -Contain 'tmp_001'
            @(@($og['optionGroups'] | Where-Object { $_['code'] -eq 'WHO_AWARE_WATCH' })[0]['options']).Count | Should -Be 3
        }
        It 'option groups: each option in <=1 group per group-set (the pivot_wider invariant)' {
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage (New-AbxExport)
            foreach ($fam in @('ATC', 'AWaRe')) {
                $grps = @($og['optionGroups'] | Where-Object { if ($fam -eq 'AWaRe') { $_['code'] -like 'WHO_AWARE_*' } else { $_['code'] -notlike 'WHO_AWARE_*' } })
                $count = @{}; $grps | ForEach-Object { foreach ($o in @($_['options'])) { $count[[string]$o['id']] = 1 + $count[[string]$o['id']] } }
                @($count.Values | Where-Object { $_ -gt 1 }).Count | Should -Be 0
            }
        }
        It 'option groups: fails loud when an ATC group has no member options' {
            $grp2 = Join-Path $TestDrive 'grp2.csv'
            @('code,name,shortName,description', 'J01AA,Tetracyclines,Tetra,x', 'J01ZZ,Empty group,Empty,y') | Set-Content -LiteralPath $grp2 -Encoding utf8NoBOM
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            { New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $grp2 -ExistingPackage (New-AbxExport) } | Should -Throw '*J01ZZ*'
        }
        It 'option group-sets: ATC5 enrols the ATC groups, WHO_AWARE the AWaRe groups (UID from the source constant)' {
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -OptionSetUid 'OptSetAbx01' -ExistingPackage (New-AbxExport)
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage (New-AbxExport)
            $ogs = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $og -ExistingPackage (New-AbxExport)
            @($ogs['optionGroupSets']).Count | Should -Be 2
            $atc5 = @($ogs['optionGroupSets'] | Where-Object { $_['code'] -eq 'ATC5' })[0]
            $atc5['id'] | Should -BeExactly $script:NeoIPCAntibioticGroupSet['ATC5'].Uid   # source identity (the module constant)
            $atc5['optionSet']['id'] | Should -BeExactly 'OptSetAbx01'                      # ref threaded from the option set, not the export
            @($atc5['optionGroups']).Count | Should -Be 2
            @(@($ogs['optionGroupSets'] | Where-Object { $_['code'] -eq 'WHO_AWARE' })[0]['optionGroups']).Count | Should -Be 3
        }
        It 'option group-sets: name comes from the canonical constant and is localized from the catalogue (-PoDirectory)' {
            $poDir = Join-Path $TestDrive 'abxgspo'; New-Item -ItemType Directory -Path $poDir -Force | Out-Null
            @('msgid ""', 'msgstr ""', '', 'msgid "ATC-5 Groups"', 'msgstr "ATC-5-Gruppen"', '', 'msgid "AWaRe Groups"', 'msgstr "AWaRe-Gruppen"') | Set-Content -LiteralPath (Join-Path $poDir 'antibiotics.de.po') -Encoding utf8NoBOM
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage (New-AbxExport)
            $ogs = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $og -ExistingPackage (New-AbxExport) -PoDirectory $poDir
            $atc5 = @($ogs['optionGroupSets'] | Where-Object { $_['code'] -eq 'ATC5' })[0]
            $atc5['name'] | Should -BeExactly 'ATC-5 Groups'   # canonical English name from $script:NeoIPCAntibioticGroupSet
            @($atc5['translations'] | Where-Object { $_['locale'] -eq 'de' -and $_['property'] -eq 'NAME' })[0]['value'] | Should -BeExactly 'ATC-5-Gruppen'
            @(@($ogs['optionGroupSets'] | Where-Object { $_['code'] -eq 'WHO_AWARE' })[0]['translations'] | Where-Object { $_['locale'] -eq 'de' -and $_['property'] -eq 'NAME' })[0]['value'] | Should -BeExactly 'AWaRe-Gruppen'
        }
        It 'ConvertTo-NeoIPCAntibioticCanonicalCode maps the migrated codes and passes others through' {
            ConvertTo-NeoIPCAntibioticCanonicalCode -Code 'J01AA08' | Should -BeExactly 'J01AA08_P'
            ConvertTo-NeoIPCAntibioticCanonicalCode -Code 'Cefoselis' | Should -BeExactly 'tmp_002'
            ConvertTo-NeoIPCAntibioticCanonicalCode -Code 'J01GB06' | Should -BeExactly 'J01GB06'
        }
        It 'Get-NeoIPCAntibioticSubstance fails loud on a duplicate id' {
            $dup = Join-Path $TestDrive 'dup.csv'
            @('id,atc_code,name,atc_group,aware_category', 'J01AA01,J01AA01,A,J01AA,Watch', 'J01AA01,J01AA01,B,J01AA,Watch') | Set-Content -LiteralPath $dup -Encoding utf8NoBOM
            { Get-NeoIPCAntibioticSubstance -Path $dup } | Should -Throw '*Duplicate*'
        }
        It 'Test-NeoIPCMetadataGeneratedExcluded excludes antibiotic option groups + group-sets, spares others' {
            $gk = Get-NeoIPCMetadataGeneratedKeys -Package (New-AbxExport)
            (Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroups' -Object ([ordered]@{ code = 'J01AA' }) -GeneratedKeys $gk) | Should -BeTrue
            (Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroups' -Object ([ordered]@{ code = 'WHO_AWARE_WATCH' }) -GeneratedKeys $gk) | Should -BeTrue
            (Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroupSets' -Object ([ordered]@{ code = 'ATC5' }) -GeneratedKeys $gk) | Should -BeTrue
            (Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroupSets' -Object ([ordered]@{ code = 'WHO_AWARE' }) -GeneratedKeys $gk) | Should -BeTrue
            (Test-NeoIPCMetadataGeneratedExcluded -Type 'optionGroups' -Object ([ordered]@{ code = 'NEO_ORGANISM_GROUP' }) -GeneratedKeys $gk) | Should -BeFalse
        }
        It 'the code-rename map is exactly the four documented migrations (pins the gate''s SubstanceCodeMigration trust)' {
            $script:NeoIPCAntibioticCodeRename.Count | Should -Be 4
            $script:NeoIPCAntibioticCodeRename['J01AA08'] | Should -BeExactly 'J01AA08_P'
            $script:NeoIPCAntibioticCodeRename['J01XX01'] | Should -BeExactly 'J01XX01_P'
            $script:NeoIPCAntibioticCodeRename['Cefoselis'] | Should -BeExactly 'tmp_002'
            $script:NeoIPCAntibioticCodeRename['Micronomicin'] | Should -BeExactly 'tmp_001'
        }
        It 'option groups: localizes both ATC and AWaRe group names from the antibiotic catalogue' {
            $poDir = Join-Path $TestDrive 'abxpogrp'; New-Item -ItemType Directory -Path $poDir -Force | Out-Null
            @('msgid ""', 'msgstr ""', '', 'msgid "Tetracyclines"', 'msgstr "Tetrazykline"', '', 'msgid "AWaRe Watch"', 'msgstr "AWaRe Watch DE"') | Set-Content -LiteralPath (Join-Path $poDir 'antibiotics.de.po') -Encoding utf8NoBOM
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage (New-AbxExport) -PoDirectory $poDir
            @(@($og['optionGroups'] | Where-Object { $_['code'] -eq 'J01AA' })[0]['translations'] | Where-Object { $_['locale'] -eq 'de' })[0]['value'] | Should -BeExactly 'Tetrazykline'
            @(@($og['optionGroups'] | Where-Object { $_['code'] -eq 'WHO_AWARE_WATCH' })[0]['translations'] | Where-Object { $_['locale'] -eq 'de' })[0]['value'] | Should -BeExactly 'AWaRe Watch DE'
        }
        It 'option groups: localizes the full surface (shortName + description), not just the name' {
            $poDir = Join-Path $TestDrive 'abxpofull'; New-Item -ItemType Directory -Path $poDir -Force | Out-Null
            @('msgid ""', 'msgstr ""', '', 'msgid "Tetracyclines"', 'msgstr "Tetrazykline"', '', 'msgid "Tetracycline antibacterials."', 'msgstr "Tetrazyklin-Mittel."') | Set-Content -LiteralPath (Join-Path $poDir 'antibiotics.de.po') -Encoding utf8NoBOM
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage (New-AbxExport)
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage (New-AbxExport) -PoDirectory $poDir
            $de = @(@($og['optionGroups'] | Where-Object { $_['code'] -eq 'J01AA' })[0]['translations'] | Where-Object { $_['locale'] -eq 'de' })
            @($de | Where-Object { $_['property'] -eq 'NAME' })[0]['value'] | Should -BeExactly 'Tetrazykline'
            @($de | Where-Object { $_['property'] -eq 'SHORT_NAME' })[0]['value'] | Should -BeExactly 'Tetrazykline'
            @($de | Where-Object { $_['property'] -eq 'DESCRIPTION' })[0]['value'] | Should -BeExactly 'Tetrazyklin-Mittel.'
        }
        It 'reuses the deployed sharing onto the generated option set, group, and group-set' {
            $pkg = New-AbxExport
            $sh = [ordered]@{ owner = 'OwnerUser01'; external = $false; users = [ordered]@{}; userGroups = [ordered]@{}; public = 'rw------' }
            $pkg['optionSets'][0]['sharing'] = $sh
            @($pkg['optionGroups'] | Where-Object { $_['code'] -eq 'J01AA' })[0]['sharing'] = $sh
            @($pkg['optionGroupSets'] | Where-Object { $_['code'] -eq 'ATC5' })[0]['sharing'] = $sh
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -ExistingPackage $pkg
            $os['optionSets'][0]['sharing'] | Should -Not -BeNullOrEmpty
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv -ExistingPackage $pkg
            @($og['optionGroups'] | Where-Object { $_['code'] -eq 'J01AA' })[0]['sharing'] | Should -Not -BeNullOrEmpty
            $ogs = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $og -ExistingPackage $pkg
            @($ogs['optionGroupSets'] | Where-Object { $_['code'] -eq 'ATC5' })[0]['sharing'] | Should -Not -BeNullOrEmpty
        }
        It 'readers expose the optional uid column (present -> value; absent column -> empty)' {
            (@(Get-NeoIPCAntibioticSubstance -Path $script:abxCsv) | Where-Object { $_.Id -eq 'J01AA01' }).Uid | Should -BeExactly 'OptAbxAA011'
            (@(Get-NeoIPCAntibioticSubstance -Path $script:abxCsv) | Where-Object { $_.Id -eq 'J01AA08_O' }).Uid | Should -BeExactly ''
            (@(Get-NeoIPCAntibioticGroup -Path $script:abxGrpCsv) | Where-Object { $_.Code -eq 'J01AA' }).Uid | Should -BeExactly 'GrpAtcAA001'
            $noUid = Join-Path $TestDrive 'no-uid.csv'
            @('id,atc_code,name,atc_group,aware_category', 'J01AA01,J01AA01,A,J01AA,Watch') | Set-Content -LiteralPath $noUid -Encoding utf8NoBOM
            (@(Get-NeoIPCAntibioticSubstance -Path $noUid)[0]).Uid | Should -BeExactly ''
        }
        It 'generates the whole antibiotic domain from source alone (no -ExistingPackage; identity preserved, no sharing)' {
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -OptionSetUid 'OptSetAbx01'
            $os['optionSets'][0]['id'] | Should -BeExactly 'OptSetAbx01'
            $os['optionSets'][0].Contains('sharing') | Should -BeFalse
            @($os['options'] | Where-Object { $_['code'] -eq 'J01AA01' })[0]['id'] | Should -BeExactly 'OptAbxAA011'
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $script:abxGrpCsv
            $j01aa = @($og['optionGroups'] | Where-Object { $_['code'] -eq 'J01AA' })[0]
            $j01aa['id'] | Should -BeExactly 'GrpAtcAA001'
            $j01aa.Contains('sharing') | Should -BeFalse
            $ogs = New-NeoIPCAntibioticOptionGroupSet -OptionGroup $og
            $atc5 = @($ogs['optionGroupSets'] | Where-Object { $_['code'] -eq 'ATC5' })[0]
            $atc5['id'] | Should -BeExactly $script:NeoIPCAntibioticGroupSet['ATC5'].Uid
            $atc5['optionSet']['id'] | Should -BeExactly 'OptSetAbx01'
        }
        It 'identity is SOURCE, not the export: a source uid that differs from the export option id wins' {
            # The export carries DIFFERENT well-formed UIDs for the option set + the deployed code J01AA01 — they must
            # be ignored for identity. Pins the guarantee against a future export-by-code identity fallback.
            $csv = Join-Path $TestDrive 'abx-divergent.csv'
            @('id,atc_code,name,atc_group,aware_category,uid', 'J01AA01,J01AA01,Demeclocycline,J01AA,Watch,srcAbxUID01') | Set-Content -LiteralPath $csv -Encoding utf8NoBOM
            $export = [ordered]@{
                optionSets = @([ordered]@{ id = 'osExpAbx011'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; valueType = 'TEXT' })
                options    = @([ordered]@{ id = 'expAbxUID01'; code = 'J01AA01'; optionSet = [ordered]@{ id = 'osExpAbx011' } })
            }
            $f = New-NeoIPCAntimicrobialOptionSet -Path $csv -OptionSetUid 'osSrcAbx011' -ExistingPackage $export
            $f['optionSets'][0]['id'] | Should -BeExactly 'osSrcAbx011'   # from -OptionSetUid (source)
            $f['optionSets'][0]['id'] | Should -Not -Be 'osExpAbx011'
            $opt = @($f['options'] | Where-Object { $_['code'] -eq 'J01AA01' })[0]
            $opt['id'] | Should -BeExactly 'srcAbxUID01'                   # from the source uid column
            $opt['id'] | Should -Not -Be 'expAbxUID01'                     # NOT the export option id, even though the code matches
        }
        It 'mints a group UID deterministically when the source uid is blank' {
            $grpBlank = Join-Path $TestDrive 'grp-blank-uid.csv'
            @('code,name,shortName,description,uid', 'J01AA,Tetracyclines,Tetra,x,', 'J01GB,Other aminoglycosides,Aminoglycosides,y,') | Set-Content -LiteralPath $grpBlank -Encoding utf8NoBOM
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -OptionSetUid 'OptSetAbx01'
            $og = New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $grpBlank
            @($og['optionGroups'] | Where-Object { $_['code'] -eq 'J01AA' })[0]['id'] | Should -BeExactly (New-NeoIPCMetadataUid -Type 'optionGroups' -NaturalKey 'J01AA')
        }
        It 'fails loud on a group UID collision across the generated groups' {
            $grpDup = Join-Path $TestDrive 'grp-dup-uid.csv'
            @('code,name,shortName,description,uid', 'J01AA,Tetracyclines,Tetra,x,SharedGrp01', 'J01GB,Other aminoglycosides,Amino,y,SharedGrp01') | Set-Content -LiteralPath $grpDup -Encoding utf8NoBOM
            $os = New-NeoIPCAntimicrobialOptionSet -Path $script:abxCsv -OptionSetUid 'OptSetAbx01'
            { New-NeoIPCAntibioticOptionGroup -OptionSet $os -SubstancePath $script:abxCsv -GroupPath $grpDup } | Should -Throw '*collision*'
        }
    }

    Describe 'Compare-NeoIPCGeneratedMetadata (antibiotic buckets)' {
        # The pathogen/substance generators are mocked EMPTY and the antibiotic generators mocked to a small
        # controlled domain, so the diff classifier produces only the antibiotic deltas — exercising each antibiotic
        # bucket (SubstanceCodeMigration / SubstanceNaming / SubstanceAddition / GroupMembership / GroupSetNormalisation
        # / OptionSetGrowth) and the Unclassified failure path for an UNDOCUMENTED code change.
        BeforeAll {
            function New-AbxDiffDeployed {
                [ordered]@{
                    optionSets      = @([ordered]@{ id = 'OptSetAbx01'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; valueType = 'TEXT'; options = @([ordered]@{ id = 'AbxOptRen01' }, [ordered]@{ id = 'AbxOptNam01' }) })
                    options         = @(
                        [ordered]@{ id = 'AbxOptRen01'; code = 'J01AA08'; name = 'Minocycline (i. v.)'; sortOrder = 1; optionSet = [ordered]@{ id = 'OptSetAbx01' } },
                        [ordered]@{ id = 'AbxOptNam01'; code = 'J01GB06'; name = 'Amikacin'; sortOrder = 2; optionSet = [ordered]@{ id = 'OptSetAbx01' } })
                    optionGroups    = @([ordered]@{ id = 'AbxGrpAA01'; code = 'J01AA'; name = 'Tetracyclines'; options = @([ordered]@{ id = 'AbxOptRen01' }) })
                    optionGroupSets = @([ordered]@{ id = 'AbxSetAtc1'; code = 'ATC5'; optionGroups = @([ordered]@{ id = 'AbxGrpAA01' }, [ordered]@{ id = 'AbxGrpZZ01' }) })
                }
            }
        }
        BeforeEach {
            Mock New-NeoIPCPathogenOptionSet { [ordered]@{ optionSets = @(); options = @() } }
            Mock New-NeoIPCPathogenDataElement { [ordered]@{ dataElements = @() } }
            Mock New-NeoIPCSubstanceDataElement { [ordered]@{ dataElements = @() } }
            Mock New-NeoIPCPathogenVariable { [ordered]@{ programRuleVariables = @() } }
            Mock New-NeoIPCPathogenFieldGatingVariable { [ordered]@{ programRuleVariables = @() } }
            Mock New-NeoIPCSubstanceVariable { [ordered]@{ programRuleVariables = @() } }
            Mock New-NeoIPCPathogenRule { [ordered]@{ programRules = @(); programRuleActions = @() } }
            Mock New-NeoIPCPathogenFieldGatingRule { [ordered]@{ programRules = @(); programRuleActions = @() } }
            Mock New-NeoIPCSubstanceRule { [ordered]@{ programRules = @(); programRuleActions = @() } }
            Mock New-NeoIPCAntimicrobialOptionSet { [ordered]@{
                    optionSets = @([ordered]@{ id = 'OptSetAbx01'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; valueType = 'TEXT'; options = @([ordered]@{ id = 'AbxOptRen01' }, [ordered]@{ id = 'AbxOptNam01' }, [ordered]@{ id = 'AbxOptAdd01' }) })
                    options    = @(
                        [ordered]@{ id = 'AbxOptRen01'; code = 'J01AA08_P'; name = 'Minocycline (i. v.)'; sortOrder = 1; optionSet = [ordered]@{ id = 'OptSetAbx01' } },
                        [ordered]@{ id = 'AbxOptNam01'; code = 'J01GB06'; name = 'Amikacin renamed'; sortOrder = 2; optionSet = [ordered]@{ id = 'OptSetAbx01' } },
                        [ordered]@{ id = 'AbxOptAdd01'; code = 'J01AA08_O'; name = 'Minocycline (oral)'; sortOrder = 3; optionSet = [ordered]@{ id = 'OptSetAbx01' } }) } }
            Mock New-NeoIPCAntibioticOptionGroup { [ordered]@{ optionGroups = @([ordered]@{ id = 'AbxGrpAA01'; code = 'J01AA'; name = 'Tetracyclines'; options = @([ordered]@{ id = 'AbxOptRen01' }, [ordered]@{ id = 'AbxOptAdd01' }) }) } }
            Mock New-NeoIPCAntibioticOptionGroupSet { [ordered]@{ optionGroupSets = @([ordered]@{ id = 'AbxSetAtc1'; code = 'ATC5'; optionGroups = @([ordered]@{ id = 'AbxGrpZZ01' }, [ordered]@{ id = 'AbxGrpAA01' }) }) } }
        }
        It 'classifies every antibiotic delta into its bucket and reports nothing Unclassified' {
            $r = @(Compare-NeoIPCGeneratedMetadata -ExistingPackage (New-AbxDiffDeployed))
            function HasC($type, $kind, $class) { @($r | Where-Object { $_.Type -eq $type -and $_.Kind -eq $kind -and $_.Class -eq $class }).Count }
            (HasC 'optionSets' 'Changed' 'OptionSetGrowth') | Should -BeGreaterThan 0
            (HasC 'options' 'Changed' 'SubstanceCodeMigration') | Should -BeGreaterThan 0
            (HasC 'options' 'Changed' 'SubstanceNaming') | Should -BeGreaterThan 0
            (HasC 'options' 'Added' 'SubstanceAddition') | Should -BeGreaterThan 0
            (HasC 'optionGroups' 'Changed' 'GroupMembership') | Should -BeGreaterThan 0
            (HasC 'optionGroupSets' 'Changed' 'GroupSetNormalisation') | Should -BeGreaterThan 0
            @($r | Where-Object { $_.Class -eq 'Unclassified' }).Count | Should -Be 0
        }
        It 'flags an UNDOCUMENTED antibiotic code change as Unclassified (not a benign SubstanceCodeMigration)' {
            Mock New-NeoIPCAntimicrobialOptionSet { [ordered]@{
                    optionSets = @([ordered]@{ id = 'OptSetAbx01'; code = 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'; valueType = 'TEXT'; options = @([ordered]@{ id = 'AbxOptRen01' }, [ordered]@{ id = 'AbxOptNam01' }) })
                    options    = @(
                        [ordered]@{ id = 'AbxOptRen01'; code = 'J01ZZ99'; name = 'Minocycline (i. v.)'; sortOrder = 1; optionSet = [ordered]@{ id = 'OptSetAbx01' } },
                        [ordered]@{ id = 'AbxOptNam01'; code = 'J01GB06'; name = 'Amikacin'; sortOrder = 2; optionSet = [ordered]@{ id = 'OptSetAbx01' } }) } }
            $r = @(Compare-NeoIPCGeneratedMetadata -ExistingPackage (New-AbxDiffDeployed))
            @($r | Where-Object { $_.Id -eq 'AbxOptRen01' -and $_.Kind -eq 'Changed' -and $_.Class -eq 'Unclassified' }).Count | Should -Be 1
        }
    }

    Describe 'Compare-NeoIPCGeneratedMetadata (classified-diff validation gate)' {
        # The nine generators are MOCKED to return small controlled fragments; the deployed package uses REAL
        # generated-family codes/names (slot-1 BSI + the retired aggregate) so the real Get-NeoIPCMetadataGeneratedKeys
        # scopes them in-family. This exercises the diff + classification (every bucket + the Unclassified failure
        # path) without a full pathogen-machinery fixture or a real export.
        BeforeAll {
            function New-DiffDeployed {
                [ordered]@{
                    optionSets   = @([ordered]@{ id = 'osP'; code = 'NEOIPC_PATHOGENS'; version = 1 })
                    options      = @([ordered]@{ id = 'optA'; code = '0'; name = 'Acinetobacter sp'; sortOrder = 1; optionSet = [ordered]@{ id = 'osP' } })
                    dataElements = @(
                        [ordered]@{ id = 'deP1'; code = 'NEOIPC_BSI_PATHOGEN_1'; name = 'Organism 1'; valueType = 'INTEGER_ZERO_OR_POSITIVE' },
                        [ordered]@{ id = 'deSrc'; code = 'NEOIPC_BSI_PATHOGEN_1_SOURCE'; name = 'src'; valueType = 'INTEGER_POSITIVE' }
                    )
                    programRuleVariables = @()
                    programRules = @(
                        [ordered]@{ id = 'ruleAgg'; name = 'NeoIPC HAP - set pathogen attribute variables' },
                        [ordered]@{ id = 'ruleWS'; name = 'NeoIPC BSI Pathogen 1 - when set'; programRuleActions = @([ordered]@{ id = 'actWSsrc' }, [ordered]@{ id = 'actNoPos' }) }
                    )
                    programRuleActions = @(
                        [ordered]@{ id = 'actAgg'; programRule = [ordered]@{ id = 'ruleAgg' }; programRuleActionType = 'ASSIGN' },
                        [ordered]@{ id = 'actWSsrc'; programRule = [ordered]@{ id = 'ruleWS' }; programRuleActionType = 'SETMANDATORYFIELD'; dataElement = [ordered]@{ id = 'deSrc' } },
                        [ordered]@{ id = 'actNoPos'; programRule = [ordered]@{ id = 'ruleWS' }; programRuleActionType = 'HIDEFIELD'; dataElement = [ordered]@{ id = 'deNoPos' } }
                    )
                }
            }
        }
        BeforeEach {
            # Generated side: optA renamed (TaxonomicNaming) + optNEW added; osP version bump; deP1 renamed
            # (DataElementNormalisation), deSrc unchanged; ruleSet added (+ its action); ruleWS reproduced but with
            # only the SOURCE action (so deployed actNoPos -> HandAuthoredAction, the aggregate -> Superseded).
            Mock New-NeoIPCPathogenOptionSet { [ordered]@{ optionSets = @([ordered]@{ id = 'osP'; code = 'NEOIPC_PATHOGENS'; version = 2 }); options = @([ordered]@{ id = 'optA'; code = '0'; name = 'Acinetobacter'; sortOrder = 1; optionSet = [ordered]@{ id = 'osP' } }, [ordered]@{ id = 'optNEW'; code = '999'; name = 'New organism'; sortOrder = 2; optionSet = [ordered]@{ id = 'osP' } }) } }
            Mock New-NeoIPCPathogenDataElement { [ordered]@{ dataElements = @([ordered]@{ id = 'deP1'; code = 'NEOIPC_BSI_PATHOGEN_1'; name = 'Organism 1 renamed'; valueType = 'INTEGER_ZERO_OR_POSITIVE' }, [ordered]@{ id = 'deSrc'; code = 'NEOIPC_BSI_PATHOGEN_1_SOURCE'; name = 'src'; valueType = 'INTEGER_POSITIVE' }) } }
            Mock New-NeoIPCSubstanceDataElement { [ordered]@{ dataElements = @() } }
            Mock New-NeoIPCPathogenVariable { [ordered]@{ programRuleVariables = @() } }
            Mock New-NeoIPCPathogenFieldGatingVariable { [ordered]@{ programRuleVariables = @() } }
            Mock New-NeoIPCSubstanceVariable { [ordered]@{ programRuleVariables = @() } }
            Mock New-NeoIPCPathogenRule { [ordered]@{ programRules = @([ordered]@{ id = 'ruleSet'; name = 'NeoIPC BSI Pathogen 1 - set 3GCR'; programRuleActions = @([ordered]@{ id = 'actSet' }) }); programRuleActions = @([ordered]@{ id = 'actSet'; programRule = [ordered]@{ id = 'ruleSet' }; programRuleActionType = 'ASSIGN'; data = 'enum' }) } }
            Mock New-NeoIPCPathogenFieldGatingRule { [ordered]@{ programRules = @([ordered]@{ id = 'ruleWS'; name = 'NeoIPC BSI Pathogen 1 - when set'; programRuleActions = @([ordered]@{ id = 'actWSsrc' }) }); programRuleActions = @([ordered]@{ id = 'actWSsrc'; programRule = [ordered]@{ id = 'ruleWS' }; programRuleActionType = 'SETMANDATORYFIELD'; dataElement = [ordered]@{ id = 'deSrc' } }) } }
            Mock New-NeoIPCSubstanceRule { [ordered]@{ programRules = @(); programRuleActions = @() } }
            # Antibiotic generators mocked empty: this Describe exercises the pathogen/substance classification.
            # The antibiotic buckets are exercised in the 'Compare-NeoIPCGeneratedMetadata (antibiotic buckets)' Describe.
            Mock New-NeoIPCAntimicrobialOptionSet { [ordered]@{ optionSets = @(); options = @() } }
            Mock New-NeoIPCAntibioticOptionGroup { [ordered]@{ optionGroups = @() } }
            Mock New-NeoIPCAntibioticOptionGroupSet { [ordered]@{ optionGroupSets = @() } }
        }
        It 'classifies every delta into its documented bucket and reports nothing Unclassified' {
            $r = @(Compare-NeoIPCGeneratedMetadata -ExistingPackage (New-DiffDeployed))
            function HasDelta($type, $kind, $class) { @($r | Where-Object { $_.Type -eq $type -and $_.Kind -eq $kind -and $_.Class -eq $class }).Count }
            (HasDelta 'optionSets' 'Changed' 'OptionSetGrowth') | Should -BeGreaterThan 0
            (HasDelta 'options' 'Changed' 'TaxonomicNaming') | Should -BeGreaterThan 0
            (HasDelta 'options' 'Added' 'TaxonomicAddition') | Should -BeGreaterThan 0
            (HasDelta 'dataElements' 'Changed' 'DataElementNormalisation') | Should -BeGreaterThan 0
            (HasDelta 'programRules' 'Removed' 'SupersededAggregate') | Should -BeGreaterThan 0
            (HasDelta 'programRules' 'Added' 'CoverageAddition') | Should -BeGreaterThan 0
            (HasDelta 'programRuleActions' 'Removed' 'HandAuthoredAction') | Should -BeGreaterThan 0
            (HasDelta 'programRuleActions' 'Added' 'CoverageAddition') | Should -BeGreaterThan 0
            @($r | Where-Object { $_.Class -eq 'Unclassified' }).Count | Should -Be 0
        }
        It 'flags an unexpected data-element field change (valueType) as Unclassified — the gate failure path' {
            Mock New-NeoIPCPathogenDataElement { [ordered]@{ dataElements = @([ordered]@{ id = 'deP1'; code = 'NEOIPC_BSI_PATHOGEN_1'; name = 'Organism 1'; valueType = 'TEXT' }, [ordered]@{ id = 'deSrc'; code = 'NEOIPC_BSI_PATHOGEN_1_SOURCE'; name = 'src'; valueType = 'INTEGER_POSITIVE' }) } }
            $r = @(Compare-NeoIPCGeneratedMetadata -ExistingPackage (New-DiffDeployed))
            @($r | Where-Object { $_.Id -eq 'deP1' -and $_.Kind -eq 'Changed' -and $_.Class -eq 'Unclassified' }).Count | Should -Be 1
        }
        It 'flags an unexpected in-family rule removal (not the retired aggregate) as Unclassified' {
            Mock New-NeoIPCPathogenFieldGatingRule { [ordered]@{ programRules = @(); programRuleActions = @() } }   # ruleWS no longer reproduced
            $r = @(Compare-NeoIPCGeneratedMetadata -ExistingPackage (New-DiffDeployed))
            @($r | Where-Object { $_.Id -eq 'ruleWS' -and $_.Kind -eq 'Removed' -and $_.Class -eq 'Unclassified' }).Count | Should -Be 1
        }
    }

    Describe 'Antibiotic translation catalogue (po/antibiotics.*)' {
        BeforeAll {
            $script:tcDir = Join-Path $TestDrive 'abxtrans'
            New-Item -ItemType Directory -Path $script:tcDir -Force | Out-Null
            # Substances WITH the optional short_name/description columns (one populated, one not).
            $script:tcSub = Join-Path $script:tcDir 'NeoIPC-Antibiotics.csv'
            @('id,atc_code,name,atc_group,aware_category,short_name,description',
                'J01AA01,J01AA01,Demeclocycline,J01AA,Watch,,',
                'tmp_001,,Micronomicin,J01GB,Watch,Micron,A demo description.') | Set-Content -LiteralPath $script:tcSub -Encoding utf8NoBOM
            $script:tcGrp = Join-Path $script:tcDir 'NeoIPC-Antibiotic-Groups.csv'
            @('code,name,shortName,description',
                'J01AA,Tetracyclines,Tetracyclines,Tetracycline antibacterials.',
                'J01GB,Other aminoglycosides,Aminoglycosides,') | Set-Content -LiteralPath $script:tcGrp -Encoding utf8NoBOM
            $script:tcAware = Join-Path $script:tcDir 'NeoIPC-Antibiotic-AWaRe-Groups.csv'
            @('code,category,name,shortName,description',
                'WHO_AWARE_ACCESS,Access,AWaRe Access,AWaRe A,Access desc.',
                'WHO_AWARE_WATCH,Watch,AWaRe Watch,AWaRe W,Watch desc.',
                'WHO_AWARE_RESERVE,Reserve,AWaRe Reserve,AWaRe R,Reserve desc.') | Set-Content -LiteralPath $script:tcAware -Encoding utf8NoBOM
            $script:tcList = Join-Path $script:tcDir 'ListElements.csv'
            @('id,value', 'substance,Substance', 'atc_code,ATC-Code') | Set-Content -LiteralPath $script:tcList -Encoding utf8NoBOM
        }

        It 'Get-NeoIPCAntibioticSubstance carries optional short_name/description when present' {
            $s = @(Get-NeoIPCAntibioticSubstance -Path $script:tcSub)
            $m = @($s | Where-Object { $_.Id -eq 'tmp_001' })[0]
            $m.ShortName | Should -BeExactly 'Micron'
            $m.Description | Should -BeExactly 'A demo description.'
            @($s | Where-Object { $_.Id -eq 'J01AA01' })[0].Description | Should -BeExactly ''
        }
        It 'Get-NeoIPCAntibioticSubstance defaults optional fields to empty when the columns are absent' {
            $p = Join-Path $TestDrive 'nocols.csv'
            @('id,atc_code,name,atc_group,aware_category', 'J01AA01,J01AA01,Demeclocycline,J01AA,Watch') | Set-Content -LiteralPath $p -Encoding utf8NoBOM
            $s = @(Get-NeoIPCAntibioticSubstance -Path $p)[0]
            $s.ShortName | Should -BeExactly ''
            $s.FormName | Should -BeExactly ''
            $s.Description | Should -BeExactly ''
        }
        It 'Get-NeoIPCAntibioticTranslatableValues keeps name always + only non-empty optionals, in field order' {
            (Get-NeoIPCAntibioticTranslatableValues -Name 'N' -ShortName '' -FormName $null -Description 'D').Keys | Should -Be @('name', 'description')
            (Get-NeoIPCAntibioticTranslatableValues -Name 'N' -ShortName 'S' -FormName 'F' -Description 'D').Keys | Should -Be @('name', 'shortName', 'formName', 'description')
        }
        It 'Get-NeoIPCAntibioticAwareGroup reads the groups with category + content, fails loud on a bad category' {
            $a = @(Get-NeoIPCAntibioticAwareGroup -Path $script:tcAware)
            $a.Count | Should -Be 3
            @($a | Where-Object { $_.Code -eq 'WHO_AWARE_WATCH' })[0].Category | Should -BeExactly 'Watch'
            $bad = Join-Path $TestDrive 'badaware.csv'
            @('code,category,name,shortName,description', 'WHO_AWARE_X,Nonsense,X,X,X') | Set-Content -LiteralPath $bad -Encoding utf8NoBOM
            { Get-NeoIPCAntibioticAwareGroup -Path $bad } | Should -Throw '*category*'
        }
        It 'Add-NeoIPCAntibioticTranslations emits one entry per locale per non-empty differing field' {
            $de = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
            $de['Carbapenems'] = 'Carbapeneme'; $de['A group desc'] = 'Gruppenbeschreibung'
            $maps = [System.Collections.Generic.List[object]]::new()
            $maps.Add([pscustomobject]@{ Locale = 'de'; Map = $de })
            $fields = [ordered]@{ name = 'Carbapenems'; shortName = 'Carbapenems'; description = 'A group desc' }
            $obj = Add-NeoIPCAntibioticTranslations -Object ([ordered]@{ id = 'g1' }) -EnglishValue $fields -LocaleMaps $maps
            $t = @($obj['translations'])
            @($t | Where-Object { $_.property -eq 'NAME' })[0].value | Should -BeExactly 'Carbapeneme'
            @($t | Where-Object { $_.property -eq 'SHORT_NAME' })[0].value | Should -BeExactly 'Carbapeneme'
            @($t | Where-Object { $_.property -eq 'DESCRIPTION' })[0].value | Should -BeExactly 'Gruppenbeschreibung'
        }
        It 'Add-NeoIPCAntibioticTranslations skips empty/identical fields and is a no-op without locale maps' {
            $m = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal); $m['Name'] = 'Name'   # identical -> no translation
            $maps = [System.Collections.Generic.List[object]]::new(); $maps.Add([pscustomobject]@{ Locale = 'de'; Map = $m })
            (Add-NeoIPCAntibioticTranslations -Object ([ordered]@{ id = 'x' }) -EnglishValue ([ordered]@{ name = 'Name'; description = '' }) -LocaleMaps $maps).Contains('translations') | Should -BeFalse
            (Add-NeoIPCAntibioticTranslations -Object ([ordered]@{ id = 'y' }) -EnglishValue ([ordered]@{ name = 'Z' }) -LocaleMaps ([System.Collections.Generic.List[object]]::new())).Contains('translations') | Should -BeFalse
        }
        It 'ConvertTo-NeoIPCAntibioticPoField renders single-line and splits multi-line at newlines' {
            (ConvertTo-NeoIPCAntibioticPoField -Keyword 'msgid' -Value 'Hello').Trim() | Should -BeExactly 'msgid "Hello"'
            $ml = ConvertTo-NeoIPCAntibioticPoField -Keyword 'msgid' -Value "a`nb"
            $ml | Should -Match '(?m)^msgid ""'
            $ml | Should -Match '(?m)^"a\\n"'
            $ml | Should -Match '(?m)^"b"'
        }
        It 'Write/Read-NeoIPCAntibioticPoText round-trips entries incl. fuzzy + multi-line, skipping the header' {
            $entries = [System.Collections.Generic.List[object]]::new()
            $entries.Add([ordered]@{ Msgid = 'Simple'; Msgstr = 'Einfach'; Fuzzy = $false })
            $entries.Add([ordered]@{ Msgid = "multi`nline"; Msgstr = ''; Fuzzy = $true })
            $text = Write-NeoIPCAntibioticPoText -Entry $entries -Locale 'de'
            $text | Should -Match '(?m)^"Language: de\\n"'
            $parsed = Read-NeoIPCAntibioticPoText -Text $text
            $parsed.Count | Should -Be 2
            @($parsed | Where-Object { $_.Msgid -eq 'Simple' })[0].Msgstr | Should -BeExactly 'Einfach'
            $mlEntry = @($parsed | Where-Object { $_.Msgid -eq "multi`nline" })[0]
            $mlEntry | Should -Not -BeNullOrEmpty
            $mlEntry.Fuzzy | Should -BeTrue
        }
        It 'Merge-NeoIPCAntibioticPoEntry preserves msgstr by msgid, drops obsolete, adds new empty' {
            $existing = [System.Collections.Generic.List[object]]::new()
            $existing.Add([ordered]@{ Msgid = 'Keep'; Msgstr = 'Behalten'; Fuzzy = $false })
            $existing.Add([ordered]@{ Msgid = 'Gone'; Msgstr = 'Weg'; Fuzzy = $false })
            $src = [System.Collections.Generic.List[string]]::new(); $src.Add('Keep'); $src.Add('New')
            $merged = Merge-NeoIPCAntibioticPoEntry -SourceMsgid $src -Existing $existing
            @($merged | ForEach-Object { $_.Msgid }) | Should -Be @('Keep', 'New')
            @($merged | Where-Object { $_.Msgid -eq 'Keep' })[0].Msgstr | Should -BeExactly 'Behalten'
            @($merged | Where-Object { $_.Msgid -eq 'New' })[0].Msgstr | Should -BeExactly ''
        }
        It 'Get-NeoIPCAntibioticTranslationString collects the full surface, de-duplicated' {
            $strings = Get-NeoIPCAntibioticTranslationString -SubstancePath $script:tcSub -GroupPath $script:tcGrp -AwareGroupPath $script:tcAware -ListElementsPath $script:tcList
            $strings | Should -Contain 'Demeclocycline'                  # substance name
            $strings | Should -Contain 'A demo description.'             # substance description (optional col)
            $strings | Should -Contain 'Tetracycline antibacterials.'    # ATC group description
            $strings | Should -Contain 'AWaRe Watch'                     # AWaRe group name
            $strings | Should -Contain 'Watch desc.'                     # AWaRe group description
            $strings | Should -Contain 'Substance'                       # printed-list UI label
            $strings | Should -Contain 'ATC-5 Groups'                    # group-set name (structural constant)
            @($strings | Where-Object { $_ -ceq 'Tetracyclines' }).Count | Should -Be 1   # name == shortName -> one entry
        }
        It 'Export-NeoIPCAntibioticTranslation writes the .pot and msgmerge-updates an existing .po' {
            $poDir = Join-Path $TestDrive 'exportpo'; New-Item -ItemType Directory -Path $poDir -Force | Out-Null
            @('msgid ""', 'msgstr ""', '', 'msgid "Demeclocycline"', 'msgstr "Demeclocyclin"', '', 'msgid "Obsolete term"', 'msgstr "Veraltet"') | Set-Content -LiteralPath (Join-Path $poDir 'antibiotics.de.po') -Encoding utf8NoBOM
            $r = Export-NeoIPCAntibioticTranslation -SubstancePath $script:tcSub -GroupPath $script:tcGrp -AwareGroupPath $script:tcAware -ListElementsPath $script:tcList -PoDirectory $poDir
            Test-Path (Join-Path $poDir 'antibiotics.pot') | Should -BeTrue
            $r.UpdatedLocales | Should -Contain 'de'
            $de = Read-NeoIPCAntibioticPoText -Text (Get-Content -LiteralPath (Join-Path $poDir 'antibiotics.de.po') -Raw)
            @($de | Where-Object { $_.Msgid -eq 'Demeclocycline' })[0].Msgstr | Should -BeExactly 'Demeclocyclin'   # preserved
            @($de | Where-Object { $_.Msgid -eq 'Obsolete term' }).Count | Should -Be 0                              # dropped
            $pot = Read-NeoIPCAntibioticPoText -Text (Get-Content -LiteralPath (Join-Path $poDir 'antibiotics.pot') -Raw)
            @($pot | Where-Object { $_.Msgstr -ne '' }).Count | Should -Be 0                                          # template: all empty
        }
        It 'Export-NeoIPCAntibioticTranslation creates no new locales (only updates existing .po)' {
            $poDir = Join-Path $TestDrive 'exportpo2'; New-Item -ItemType Directory -Path $poDir -Force | Out-Null
            Export-NeoIPCAntibioticTranslation -SubstancePath $script:tcSub -GroupPath $script:tcGrp -AwareGroupPath $script:tcAware -ListElementsPath $script:tcList -PoDirectory $poDir | Out-Null
            Test-Path (Join-Path $poDir 'antibiotics.pot') | Should -BeTrue
            @(Get-ChildItem -Path $poDir -Filter 'antibiotics.*.po').Count | Should -Be 0
        }
    }

    Describe 'Reconcile mode (Update-NeoIPCMetadataDirectory)' {
        BeforeEach {
            # A directory with committed-style files: authored org units (must never be re-emitted from the export),
            # a config CSV, and an authored sharing.yaml. The heavy engine is mocked; only the orchestration is tested.
            $script:rcDir = Join-Path $TestDrive ('rc-dir-' + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $script:rcDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:rcDir 'organisationUnits.csv') -Value "id,code,name`nOUaaaaaaaa1,AT,Austria" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:rcDir 'dataElements.csv') -Value "id,code,name`nDEaaaaaaaa1,OLD_DE,Old" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:rcDir 'sharing.yaml') -Value "PUBLIC_RW:`n  public: `"rw------`"" -NoNewline
            # Tiny export the cmdlet parses for the template-presence check; includes a template (present case).
            $script:rcExport = Join-Path $TestDrive ('rc-exp-' + [System.IO.Path]::GetRandomFileName() + '.json')
            Set-Content -LiteralPath $script:rcExport -Value '{ "dataElements": [ { "id": "DEaaaaaaaa1", "code": "OLD_DE", "name": "Old" } ], "programNotificationTemplates": [ { "id": "PNTaaaaaaa1", "name": "T" } ] }'

            Mock ConvertTo-NeoIPCMetadataJson { '{}' }                       # the directory's "current" package (core diff is mocked, so content is irrelevant)
            Mock Compare-NeoIPCMetadataCore {
                @(
                    [pscustomobject]@{ Type = 'dataElements'; Id = 'DEnewwwwww1'; Kind = 'Added' }
                    [pscustomobject]@{ Type = 'indicatorTypes'; Id = 'ITaaaaaaaa1'; Kind = 'Added' }
                    [pscustomobject]@{ Type = 'organisationUnits'; Id = 'OUbbbbbbbb2'; Kind = 'Added' }   # authored -> report-only
                )
            }
            Mock Compare-NeoIPCGeneratedMetadata {
                # Returned as ONE protected collection (unary-comma), like the real cmdlet — so this also locks the
                # @()-enumeration: the report must count these as 3 (2 classified + 1 Unclassified), not 1.
                $l = [System.Collections.Generic.List[object]]::new()
                $l.Add([pscustomobject]@{ Type = 'options'; Kind = 'Changed'; Id = 'o1'; Key = '1'; Class = 'TaxonomicNaming' })
                $l.Add([pscustomobject]@{ Type = 'programRuleActions'; Kind = 'Removed'; Id = 'a1'; Key = ''; Class = 'HandAuthoredAction' })
                $l.Add([pscustomobject]@{ Type = 'dataElements'; Kind = 'Added'; Id = 'd9'; Key = 'X'; Class = 'Unclassified' })
                , $l
            }
            Mock Export-NeoIPCMetadataTranslation { }
            Mock ConvertFrom-NeoIPCMetadataJson {
                # Simulate the re-emit into the temp dir: the affected config CSVs PLUS an anonymised org-units CSV
                # (which the cmdlet must NOT copy back, because organisationUnits is authored / report-only).
                Set-Content -LiteralPath (Join-Path $OutputDirectory 'dataElements.csv') -Value "id,code,name`nDEnewwwwww1,NEW_DE,New" -NoNewline
                Set-Content -LiteralPath (Join-Path $OutputDirectory 'indicatorTypes.csv') -Value "id,name`nITaaaaaaaa1,Number" -NoNewline
                Set-Content -LiteralPath (Join-Path $OutputDirectory 'organisationUnits.csv') -Value "id,code,name`nOUanon00001,," -NoNewline
            }
            # The SCOPED incoming. The config diff / generated diff are mocked, so the scope content is irrelevant —
            # an empty package keeps Get-NeoIPCMetadataScopedConfig from running the real closure on the tiny export.
            Mock Get-NeoIPCMetadataScopedConfig { [ordered]@{} }
            # The git safety net has its own (real-git) tests below; the orchestration tests skip it.
            Mock Assert-NeoIPCReconcileGitClean { }
        }

        It 'report-only by default: classifies the drift and writes nothing' {
            $r = Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -WarningAction SilentlyContinue
            $r.Applied | Should -BeFalse
            @($r.AutoWrite | ForEach-Object { $_.Type }) | Should -Contain 'dataElements'
            @($r.AutoWrite | ForEach-Object { $_.Type }) | Should -Contain 'indicatorTypes'
            @($r.AutoWrite | ForEach-Object { $_.Type }) | Should -Not -Contain 'organisationUnits'
            $r.AuthoredReportOnly | Should -Contain 'organisationUnits'
            (Get-Content -LiteralPath (Join-Path $script:rcDir 'dataElements.csv') -Raw) | Should -Match 'OLD_DE'   # untouched
            Should -Not -Invoke ConvertFrom-NeoIPCMetadataJson
            Should -Not -Invoke Export-NeoIPCMetadataTranslation
            Should -Invoke Get-NeoIPCMetadataScopedConfig                  # the diff is against the SCOPED package, never the raw export
            Should -Not -Invoke Assert-NeoIPCReconcileGitClean             # report-only never touches the git safety net
        }

        It 'enumerates the generated collection (the protected-list return), not a 1-element wrapper' {
            $r = Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -WarningAction SilentlyContinue
            (@($r.GeneratedReportOnly) | Measure-Object Count -Sum).Sum | Should -Be 2          # the 2 non-Unclassified deltas
            @($r.GeneratedReportOnly | Where-Object { $_.Class -eq 'HandAuthoredAction' }).Count | Should -Be 1
            $r.Unclassified.Count | Should -Be 1
            $r.Unclassified[0].Id | Should -BeExactly 'd9'
        }

        It 'surfaces Unclassified deltas as a warning' {
            Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            @($w | Where-Object { $_ -match 'Unclassified' }).Count | Should -BeGreaterThan 0
        }

        It '-Apply row-merges the affected config CSVs (keeping existing rows), never organisationUnits, and refreshes the PO from the scoped package' {
            $poDir = Join-Path $TestDrive ('rc-po-' + [System.IO.Path]::GetRandomFileName())
            $r = Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -PoDirectory $poDir -Apply -WarningAction SilentlyContinue
            $r.Applied | Should -BeTrue
            $deCsv = (Get-Content -LiteralPath (Join-Path $script:rcDir 'dataElements.csv') -Raw)
            $deCsv | Should -Match 'NEW_DE'                                                                                # the Added row is merged in
            $deCsv | Should -Match 'OLD_DE'                                                                               # the directory's existing row is KEPT (row-merge, not whole-file replace)
            (Test-Path -LiteralPath (Join-Path $script:rcDir 'indicatorTypes.csv')) | Should -BeTrue                       # new type materialised
            (Get-Content -LiteralPath (Join-Path $script:rcDir 'organisationUnits.csv') -Raw) | Should -Match 'Austria'    # authored org units untouched
            (Get-Content -LiteralPath (Join-Path $script:rcDir 'organisationUnits.csv') -Raw) | Should -Not -Match 'OUanon00001'
            $r.PoUpdated | Should -BeTrue
            Should -Invoke Assert-NeoIPCReconcileGitClean -Times 1                                                         # -Apply runs the git safety net
            Should -Invoke Export-NeoIPCMetadataTranslation -Times 1 -Exactly -ParameterFilter { $Package -and -not $Path }   # PO sourced from the scoped package, not a raw -Path export
        }

        It 'treats programNotificationTemplates as report-only when the export lacks them' {
            $noTpl = Join-Path $TestDrive ('rc-notpl-' + [System.IO.Path]::GetRandomFileName() + '.json')
            Set-Content -LiteralPath $noTpl -Value '{ "dataElements": [ { "id": "DEaaaaaaaa1", "code": "OLD_DE", "name": "Old" } ] }'
            Mock Compare-NeoIPCMetadataCore { @([pscustomobject]@{ Type = 'programNotificationTemplates'; Id = 'PNTxxxxxxx9'; Kind = 'Removed' }) }
            $r = Update-NeoIPCMetadataDirectory -ExportPath $noTpl -MetadataDirectory $script:rcDir -WarningAction SilentlyContinue
            @($r.AutoWrite | ForEach-Object { $_.Type }) | Should -Not -Contain 'programNotificationTemplates'
            $r.AuthoredReportOnly | Should -Contain 'programNotificationTemplates'
        }
        It '-Apply mirrors a changed program-rule-ACTION expression even when only programRuleActions is affected' {
            # An action `data` expression lives under expressions/programRules/<rule>/<actionId>.data.dhis2 (co-located
            # with its owning rule), so a data-only change makes programRuleActions the sole affected type. The mirror
            # must still re-sync the owning programRules subtree, or the new expression is silently dropped.
            $exprDir = Join-Path $script:rcDir (Join-Path 'expressions' (Join-Path 'programRules' 'rl_test'))
            New-Item -ItemType Directory -Path $exprDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $exprDir 'acT1.data.dhis2') -Value '1 + 1' -NoNewline      # OLD content in the directory
            Mock Compare-NeoIPCMetadataCore { @([pscustomobject]@{ Type = 'programRuleActions'; Id = 'acT1'; Kind = 'Changed' }) }
            Mock ConvertFrom-NeoIPCMetadataJson {
                $d = Join-Path $OutputDirectory (Join-Path 'expressions' (Join-Path 'programRules' 'rl_test'))
                New-Item -ItemType Directory -Path $d -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $d 'acT1.data.dhis2') -Value '2 + 2' -NoNewline        # NEW content from the export
                Set-Content -LiteralPath (Join-Path $OutputDirectory 'programRuleActions.csv') -Value "id,programRuleActionType,data`nacT1,ASSIGN,expressions/programRules/rl_test/acT1.data.dhis2" -NoNewline
            }
            Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -Apply -WarningAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath (Join-Path $exprDir 'acT1.data.dhis2') -Raw) | Should -BeExactly '2 + 2'
        }

        It 'keeps a Removed config object: reports it, never auto-deletes it from the directory' {
            Mock Compare-NeoIPCMetadataCore { @([pscustomobject]@{ Type = 'dataElements'; Id = 'DEaaaaaaaa1'; Kind = 'Removed' }) }
            $r = Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -Apply -WarningAction SilentlyContinue
            @($r.AutoWrite | ForEach-Object { $_.Type }) | Should -Not -Contain 'dataElements'           # a Removed-only type is not auto-written
            @($r.RemovedReportOnly | ForEach-Object { $_.Type }) | Should -Contain 'dataElements'         # reported, report-only
            (Get-Content -LiteralPath (Join-Path $script:rcDir 'dataElements.csv') -Raw) | Should -Match 'OLD_DE'   # the row is KEPT, not deleted
            Should -Not -Invoke ConvertFrom-NeoIPCMetadataJson                                            # no Changed/Added -> nothing to re-emit
        }

        It 'warns before -Apply when the deployment is not yet migrated (large generated diff)' {
            Mock Compare-NeoIPCGeneratedMetadata {
                $l = [System.Collections.Generic.List[object]]::new()
                1..150 | ForEach-Object { $l.Add([pscustomobject]@{ Type = 'options'; Kind = 'Changed'; Id = "o$_"; Key = "$_"; Class = 'TaxonomicNaming' }) }
                , $l
            }
            Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -Apply -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            @($w | Where-Object { $_ -match 'not yet migrated' }).Count | Should -BeGreaterThan 0
        }

        It 'does not warn about migration when the generated diff is small (below the threshold)' {
            Update-NeoIPCMetadataDirectory -ExportPath $script:rcExport -MetadataDirectory $script:rcDir -Apply -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            @($w | Where-Object { $_ -match 'not yet migrated' }).Count | Should -Be 0     # the BeforeEach mock returns 3 deltas
        }
    }

    Describe 'Reconcile -Apply git safety net (Assert-NeoIPCReconcileGitClean)' {
        It 'passes for a clean git working tree' {
            $repo = Join-Path $TestDrive ('git-clean-' + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'a.csv') -Value 'x' -NoNewline
            & git -C $repo init -q
            & git -C $repo -c user.email=t@t -c user.name=t add -A
            & git -C $repo -c user.email=t@t -c user.name=t commit -q -m init
            { Assert-NeoIPCReconcileGitClean -Path $repo } | Should -Not -Throw
        }
        It 'refuses a dirty git working tree' {
            $repo = Join-Path $TestDrive ('git-dirty-' + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $repo -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'a.csv') -Value 'x' -NoNewline
            & git -C $repo init -q
            & git -C $repo -c user.email=t@t -c user.name=t add -A
            & git -C $repo -c user.email=t@t -c user.name=t commit -q -m init
            Set-Content -LiteralPath (Join-Path $repo 'a.csv') -Value 'y' -NoNewline       # uncommitted change
            { Assert-NeoIPCReconcileGitClean -Path $repo } | Should -Throw '*CLEAN*'
        }
        It 'refuses a directory that is not under git at all' {
            $bare = Join-Path $TestDrive ('git-none-' + [System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $bare -Force | Out-Null
            { Assert-NeoIPCReconcileGitClean -Path $bare } | Should -Throw '*git working tree*'
        }
    }
}
