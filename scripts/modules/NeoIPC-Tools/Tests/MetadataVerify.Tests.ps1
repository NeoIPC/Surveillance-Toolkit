#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the round-trip metadata import verifier.

.DESCRIPTION
    Covers Public/MetadataVerify.ps1. Self-contained: the DHIS2 read-back is mocked from a synthetic
    in-memory server state, so no live instance is needed and no API call is made.

    The mock returns, for each per-type request, the envelope shape that an owner-field projection produces —
    owned reference collections as bare id objects. Nested-only children are diffed out of their PARENT's
    expanded read-back, because the verifier requests the parent with its child array expanded and DHIS2 2.40
    exposes no separate endpoint for those child types. So a parent's mocked state carries its children as
    full objects rather than as references.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/MetadataVerify.Tests.ps1
#>
#
# Discrepancies are read via Get-VDisc, which filters to the records that carry a Kind — matching how
# Deploy-NeoIPCMetadata consumes the result (`$disc | Where-Object { $_.Kind }`). That also sidesteps the
# verifier's `, [object[]]@()` return idiom, which an `@(...)` wrapper would otherwise count as one element.
#
# Run:  Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/MetadataVerify.Tests.ps1

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    Describe 'Test-NeoIPCMetadataImport (round-trip verifier)' {
        BeforeAll {
            $script:VAuth = @{ Basic = 'ignored-by-the-mock' }
            function Get-VDisc($Package) {
                $d = Test-NeoIPCMetadataImport -Package $Package -Auth $script:VAuth
                , @($d | Where-Object { $_.Kind })
            }
        }
        BeforeEach {
            $script:VState = @{}
            Mock Invoke-NeoIPCDhis2Get {
                $t = $Path -replace '^api/', ''
                $items = if ($script:VState.ContainsKey($t)) { @($script:VState[$t]) } else { @() }
                $body = [pscustomobject]@{ $t = $items }
                # -AsHashtable parses the response text, so the mock goes through JSON the same way.
                if ($AsHashtable) { ConvertTo-Json -InputObject $body -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String } else { $body }
            }
        }

        It 'reports nothing for a perfect round-trip' {
            $script:VState = @{ optionGroupSets = @([pscustomobject]@{ id = 'ogsAAA00001'; code = 'OGS1'
                        optionGroups = @([pscustomobject]@{ id = 'og0000000a1' }, [pscustomobject]@{ id = 'og0000000b2' }) }) }
            $pkg = @{ optionGroupSets = @([ordered]@{ id = 'ogsAAA00001'; code = 'OGS1'
                        optionGroups = @([ordered]@{ id = 'og0000000a1' }, [ordered]@{ id = 'og0000000b2' }) }) }
            (Get-VDisc $pkg).Count | Should -Be 0
        }

        It 'flags Missing when an object is absent after import' {
            $script:VState = @{ optionSets = @() }
            $pkg = @{ optionSets = @([ordered]@{ id = 'optSet00001'; code = 'OS1'; name = 'N'; valueType = 'TEXT' }) }
            $disc = Get-VDisc $pkg
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'Missing'
        }

        It 'flags LinkDrop when a ref-collection member is missing' {
            $script:VState = @{ optionGroupSets = @([pscustomobject]@{ id = 'ogs1'; code = 'OGS1'
                        optionGroups = @([pscustomobject]@{ id = 'a' }) }) }
            $pkg = @{ optionGroupSets = @([ordered]@{ id = 'ogs1'; code = 'OGS1'
                        optionGroups = @([ordered]@{ id = 'a' }, [ordered]@{ id = 'b' }) }) }
            $disc = Get-VDisc $pkg
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'LinkDrop'
            $disc[0].Field | Should -Be 'optionGroups'
        }

        It 'flags OrderDrift when a genuinely ORDERED <list> reconnects out of order' {
            # optionGroupSets.optionGroups is a DHIS2 <list> with sort_order -> in $NeoIPCMetadataServerOrderedRefs.
            $script:VState = @{ optionGroupSets = @([pscustomobject]@{ id = 'ogs1'; code = 'OGS1'
                        optionGroups = @([pscustomobject]@{ id = 'b' }, [pscustomobject]@{ id = 'a' }, [pscustomobject]@{ id = 'c' }) }) }
            $pkg = @{ optionGroupSets = @([ordered]@{ id = 'ogs1'; code = 'OGS1'
                        optionGroups = @([ordered]@{ id = 'a' }, [ordered]@{ id = 'b' }, [ordered]@{ id = 'c' }) }) }
            $disc = Get-VDisc $pkg
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'OrderDrift'
            $disc[0].Field | Should -Be 'optionGroups'
        }

        It 'does NOT flag dataElementGroups.dataElements reordered (idArrayOrdered in the type map, but a DHIS2 <set>)' {
            # dataElementGroups.members is a <set> (read back in hash order); it is excluded from the server-ordered
            # set, so a reordering must NOT produce a (fatal) OrderDrift. This is the regression the review caught.
            $script:VState = @{ dataElementGroups = @([pscustomobject]@{ id = 'deg1'; code = 'DEG1'; name = 'G'
                        dataElements = @([pscustomobject]@{ id = 'de2' }, [pscustomobject]@{ id = 'de1' }, [pscustomobject]@{ id = 'de3' }) }) }
            $pkg = @{ dataElementGroups = @([ordered]@{ id = 'deg1'; code = 'DEG1'; name = 'G'
                        dataElements = @([ordered]@{ id = 'de1' }, [ordered]@{ id = 'de2' }, [ordered]@{ id = 'de3' }) }) }
            (Get-VDisc $pkg).Count | Should -Be 0
        }

        It 'does NOT flag an UNORDERED ref-collection (idArray) that is merely reordered' {
            $script:VState = @{ organisationUnitGroupSets = @([pscustomobject]@{ id = 'ougs1'; code = 'OUGS1'
                        organisationUnitGroups = @([pscustomobject]@{ id = 'oug2' }, [pscustomobject]@{ id = 'oug1' }) }) }
            $pkg = @{ organisationUnitGroupSets = @([ordered]@{ id = 'ougs1'; code = 'OUGS1'
                        organisationUnitGroups = @([ordered]@{ id = 'oug1' }, [ordered]@{ id = 'oug2' }) }) }
            (Get-VDisc $pkg).Count | Should -Be 0
        }

        It 'flags ValueDrop on a dropped stringArray value and ignores reordering' {
            $script:VState = @{ userRoles = @([pscustomobject]@{ id = 'ur1'; code = 'UR1'; name = 'R'
                        authorities = @('F_Z', 'F_X') }) }   # F_Y dropped; remaining reordered
            $pkg = @{ userRoles = @([ordered]@{ id = 'ur1'; code = 'UR1'; name = 'R'
                        authorities = @('F_X', 'F_Y', 'F_Z') }) }
            $disc = Get-VDisc $pkg
            $vd = @($disc | Where-Object { $_.Kind -eq 'ValueDrop' })
            $vd.Count | Should -Be 1
            $vd[0].Field | Should -Be 'authorities'
            $vd[0].Detail | Should -Match 'F_Y'
            @($disc | Where-Object { $_.Kind -eq 'FieldMismatch' }).Count | Should -Be 0
        }

        It 'flags ValueDrop when a stringArray is entirely absent from the read-back' {
            $script:VState = @{ userRoles = @([pscustomobject]@{ id = 'ur1'; code = 'UR1'; name = 'R' }) }   # authorities not returned
            $pkg = @{ userRoles = @([ordered]@{ id = 'ur1'; code = 'UR1'; name = 'R'; authorities = @('F_A', 'F_B') }) }
            $disc = Get-VDisc $pkg
            $vd = @($disc | Where-Object { $_.Kind -eq 'ValueDrop' -and $_.Field -eq 'authorities' })
            $vd.Count | Should -Be 1
            $vd[0].Detail | Should -Match 'F_A'
        }

        It 'flags ValueDrop on a dropped intArray value (same branch as stringArray)' {
            # dataElements.aggregationLevels is intArray; integer values coerce via [string].
            $script:VState = @{ dataElements = @([pscustomobject]@{ id = 'deX0000001'; code = 'DEX'; name = 'N'; valueType = 'NUMBER'
                        aggregationLevels = @(1) }) }
            $pkg = @{ dataElements = @([ordered]@{ id = 'deX0000001'; code = 'DEX'; name = 'N'; valueType = 'NUMBER'
                        aggregationLevels = @(1, 2, 3) }) }
            $disc = Get-VDisc $pkg
            $vd = @($disc | Where-Object { $_.Kind -eq 'ValueDrop' -and $_.Field -eq 'aggregationLevels' })
            $vd.Count | Should -Be 1
            $vd[0].Detail | Should -Match '2'
        }

        It 'verifies NestedOnly children inner fields (FieldMismatch on drift) from the parent read-back, membership intact' {
            # The parent is fetched with the child collection expanded (fields=:owner,programStageDataElements[:owner]),
            # so the inner field (compulsory) is diffed out of the parent response — there is no child-type endpoint.
            $script:VState = @{
                programStages = @([pscustomobject]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([pscustomobject]@{ id = 'psde1'; compulsory = $false
                                dataElement = [pscustomobject]@{ id = 'de1' }; programStage = [pscustomobject]@{ id = 'ps1' } }) }) }
            $pkg = @{ programStages = @([ordered]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([ordered]@{ id = 'psde1'; compulsory = $true
                                dataElement = [ordered]@{ id = 'de1' }; programStage = [ordered]@{ id = 'ps1' } }) }) }
            $disc = Get-VDisc $pkg
            $fm = @($disc | Where-Object { $_.Type -eq 'programStageDataElements' -and $_.Kind -eq 'FieldMismatch' -and $_.Field -eq 'compulsory' })
            $fm.Count | Should -Be 1
            @($disc | Where-Object { $_.Kind -eq 'LinkDrop' }).Count | Should -Be 0
        }

        It 'flags Missing for a NestedOnly child dropped from its parent on import' {
            # The reason children are diffed at all: a silently-dropped child must surface, not hide behind the parent.
            $script:VState = @{ programStages = @([pscustomobject]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @() }) }   # psde1 dropped
            $pkg = @{ programStages = @([ordered]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([ordered]@{ id = 'psde1'; compulsory = $true
                                dataElement = [ordered]@{ id = 'de1' }; programStage = [ordered]@{ id = 'ps1' } }) }) }
            $disc = Get-VDisc $pkg
            $m = @($disc | Where-Object { $_.Type -eq 'programStageDataElements' -and $_.Kind -eq 'Missing' -and $_.Id -eq 'psde1' })
            $m.Count | Should -Be 1
        }

        It 'flags OrderDrift on a reordered NestedOnly attribute <list> (trackedEntityTypeAttributes)' {
            # TrackedEntityType.trackedEntityTypeAttributes is a genuine <list> with sort_order, but the child has
            # NO element-level sortOrder — its order lives solely on the parent, so it is checked positionally on
            # the parent's child-id sequence (verified against refs/dhis2-core TrackedEntityType.hbm.xml).
            $script:VState = @{ trackedEntityTypes = @([pscustomobject]@{ id = 'tet1'; name = 'T'
                        trackedEntityTypeAttributes = @(
                            [pscustomobject]@{ id = 'tta2'; trackedEntityAttribute = [pscustomobject]@{ id = 'tea2' }; trackedEntityType = [pscustomobject]@{ id = 'tet1' } }
                            [pscustomobject]@{ id = 'tta1'; trackedEntityAttribute = [pscustomobject]@{ id = 'tea1' }; trackedEntityType = [pscustomobject]@{ id = 'tet1' } }) }) }
            $pkg = @{ trackedEntityTypes = @([ordered]@{ id = 'tet1'; name = 'T'
                        trackedEntityTypeAttributes = @(
                            [ordered]@{ id = 'tta1'; trackedEntityAttribute = [ordered]@{ id = 'tea1' }; trackedEntityType = [ordered]@{ id = 'tet1' } }
                            [ordered]@{ id = 'tta2'; trackedEntityAttribute = [ordered]@{ id = 'tea2' }; trackedEntityType = [ordered]@{ id = 'tet1' } }) }) }
            $disc = Get-VDisc $pkg
            $od = @($disc | Where-Object { $_.Kind -eq 'OrderDrift' -and $_.Field -eq 'trackedEntityTypeAttributes' })
            $od.Count | Should -Be 1
            $od[0].Type | Should -Be 'trackedEntityTypes'
        }

        It 'does NOT flag a NestedOnly attribute <list> kept in the same order' {
            $script:VState = @{ trackedEntityTypes = @([pscustomobject]@{ id = 'tet1'; name = 'T'
                        trackedEntityTypeAttributes = @(
                            [pscustomobject]@{ id = 'tta1'; trackedEntityAttribute = [pscustomobject]@{ id = 'tea1' }; trackedEntityType = [pscustomobject]@{ id = 'tet1' } }
                            [pscustomobject]@{ id = 'tta2'; trackedEntityAttribute = [pscustomobject]@{ id = 'tea2' }; trackedEntityType = [pscustomobject]@{ id = 'tet1' } }) }) }
            $pkg = @{ trackedEntityTypes = @([ordered]@{ id = 'tet1'; name = 'T'
                        trackedEntityTypeAttributes = @(
                            [ordered]@{ id = 'tta1'; trackedEntityAttribute = [ordered]@{ id = 'tea1' }; trackedEntityType = [ordered]@{ id = 'tet1' } }
                            [ordered]@{ id = 'tta2'; trackedEntityAttribute = [ordered]@{ id = 'tea2' }; trackedEntityType = [ordered]@{ id = 'tet1' } }) }) }
            (Get-VDisc $pkg).Count | Should -Be 0
        }

        It 'leaves a synthetic-fk NestedOnly child (analyticsPeriodBoundaries) membership-only, not expanded/diffed' {
            # analyticsPeriodBoundaries (FkSynthetic) is not expanded; its inner field drift below must NOT surface,
            # and the parent membership stays intact -> clean.
            $script:VState = @{ programIndicators = @([pscustomobject]@{ id = 'pi1'; code = 'PI1'; name = 'N'
                        analyticsPeriodBoundaries = @([pscustomobject]@{ id = 'apb1' }) }) }
            $pkg = @{ programIndicators = @([ordered]@{ id = 'pi1'; code = 'PI1'; name = 'N'
                        analyticsPeriodBoundaries = @([ordered]@{ id = 'apb1'; analyticsPeriodBoundaryType = 'BEFORE_END_OF_REPORTING_PERIOD' }) }) }
            $disc = Get-VDisc $pkg
            @($disc | Where-Object { $_.Type -eq 'analyticsPeriodBoundaries' }).Count | Should -Be 0
            $disc.Count | Should -Be 0
        }

        It 'does not compare an option''s absolute sortOrder, which DHIS2 renumbers' {
            # From 2.41 the set's write renumbers every option's sortOrder to its 0-based list position, while the
            # package numbers options from 1; the order itself is checked on optionSet.options instead.
            $script:VState = @{
                optionSets = @([pscustomobject]@{ id = 'os1'; code = 'OS1'; name = 'N'; valueType = 'TEXT'
                        options = @([pscustomobject]@{ id = 'o1' }, [pscustomobject]@{ id = 'o2' }, [pscustomobject]@{ id = 'o3' }) })
                options    = @(
                    [pscustomobject]@{ id = 'o1'; code = '1'; name = 'A'; sortOrder = 0; optionSet = [pscustomobject]@{ id = 'os1' } }
                    [pscustomobject]@{ id = 'o2'; code = '2'; name = 'B'; sortOrder = 1; optionSet = [pscustomobject]@{ id = 'os1' } }
                    [pscustomobject]@{ id = 'o3'; code = '3'; name = 'C'; sortOrder = 2; optionSet = [pscustomobject]@{ id = 'os1' } })
            }
            $pkg = @{
                optionSets = @([ordered]@{ id = 'os1'; code = 'OS1'; name = 'N'; valueType = 'TEXT'
                        options = @([ordered]@{ id = 'o1' }, [ordered]@{ id = 'o2' }, [ordered]@{ id = 'o3' }) })
                options    = @(
                    [ordered]@{ id = 'o1'; code = '1'; name = 'A'; sortOrder = 1; optionSet = [ordered]@{ id = 'os1' } }
                    [ordered]@{ id = 'o2'; code = '2'; name = 'B'; sortOrder = 2; optionSet = [ordered]@{ id = 'os1' } }
                    [ordered]@{ id = 'o3'; code = '3'; name = 'C'; sortOrder = 3; optionSet = [ordered]@{ id = 'os1' } })
            }
            (Get-VDisc $pkg).Count | Should -Be 0
        }

        It 'flags OrderDrift when DHIS2 holds an option set''s options in another order than the package lists them' {
            # DHIS2 keeps optionSet.options in the order it receives, so a set posted out of order shows users a
            # scrambled choice list while every member is present.
            $script:VState = @{ optionSets = @([pscustomobject]@{ id = 'os1'; code = 'OS1'; name = 'N'; valueType = 'TEXT'
                        options = @([pscustomobject]@{ id = 'o3' }, [pscustomobject]@{ id = 'o1' }, [pscustomobject]@{ id = 'o2' }) }) }
            $pkg = @{ optionSets = @([ordered]@{ id = 'os1'; code = 'OS1'; name = 'N'; valueType = 'TEXT'
                        options = @([ordered]@{ id = 'o1' }, [ordered]@{ id = 'o2' }, [ordered]@{ id = 'o3' }) }) }
            $disc = Get-VDisc $pkg
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'OrderDrift'
            $disc[0].Type | Should -Be 'optionSets'
            $disc[0].Field | Should -Be 'options'
        }

        It 'verifies an object against its written body from -Expected, properties carried over from DHIS2 included' {
            # The package carries no org-unit memberships; a deployment writes the live ones back, so the written
            # body is what must hold afterwards.
            $script:VState = @{ organisationUnitGroups = @([pscustomobject]@{ id = 'oug1'; code = 'G'; name = 'G'
                        organisationUnits = @([pscustomobject]@{ id = 'ou1' }) }) }
            $pkg = @{ organisationUnitGroups = @([ordered]@{ id = 'oug1'; code = 'G'; name = 'G' }) }
            $written = @{ organisationUnitGroups = @([ordered]@{ id = 'oug1'; code = 'G'; name = 'G'
                        organisationUnits = @([ordered]@{ id = 'ou1' }, [ordered]@{ id = 'ou2' }) }) }
            $disc = @((Test-NeoIPCMetadataImport -Package $pkg -Auth $script:VAuth -Expected $written) | Where-Object { $_.Kind })
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'LinkDrop'
            $disc[0].Field | Should -Be 'organisationUnits'
            (Get-VDisc $pkg).Count | Should -Be 0 -Because 'the package alone says nothing about memberships'
        }

        It 'with -CheckTranslations flags a package translation DHIS2 lacks or holds with another value, and allows extra ones' {
            $script:VState = @{ dataElements = @([pscustomobject]@{ id = 'de1'; code = 'DE1'; name = 'N'
                        translations = @([pscustomobject]@{ locale = 'de'; property = 'NAME'; value = 'N (de)' }
                            [pscustomobject]@{ locale = 'fr'; property = 'NAME'; value = 'N (fr)' }) }) }
            $kept = @{ dataElements = @([ordered]@{ id = 'de1'; code = 'DE1'; name = 'N'
                        translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'N (de)' }) }) }
            @((Test-NeoIPCMetadataImport -Package $kept -Auth $script:VAuth -CheckTranslations) | Where-Object { $_.Kind }).Count | Should -Be 0
            $drifted = @{ dataElements = @([ordered]@{ id = 'de1'; code = 'DE1'; name = 'N'
                        translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'Anders' }
                            [ordered]@{ locale = 'es'; property = 'NAME'; value = 'N (es)' }) }) }
            $disc = @((Test-NeoIPCMetadataImport -Package $drifted -Auth $script:VAuth -CheckTranslations) | Where-Object { $_.Kind })
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'TranslationMismatch'
            $disc[0].Detail | Should -Match 'de/NAME differs'
            $disc[0].Detail | Should -Match 'missing es/NAME'
            (Get-VDisc $drifted).Count | Should -Be 0 -Because 'translations are compared only with -CheckTranslations'
        }

        It 'with -CheckTranslations requires exactly the written translations for an object in -Expected' {
            $script:VState = @{ dataElements = @([pscustomobject]@{ id = 'de1'; code = 'DE1'; name = 'N'
                        translations = @([pscustomobject]@{ locale = 'de'; property = 'NAME'; value = 'N (de)' }
                            [pscustomobject]@{ locale = 'fr'; property = 'NAME'; value = 'N (fr)' }) }) }
            $body = [ordered]@{ id = 'de1'; code = 'DE1'; name = 'N'; translations = @([ordered]@{ locale = 'de'; property = 'NAME'; value = 'N (de)' }) }
            $disc = @((Test-NeoIPCMetadataImport -Package @{ dataElements = @($body) } -Auth $script:VAuth -Expected @{ dataElements = @($body) } -CheckTranslations) |
                    Where-Object { $_.Kind })
            $disc.Count | Should -Be 1
            $disc[0].Kind | Should -Be 'TranslationMismatch'
            $disc[0].Detail | Should -Match 'unexpected fr/NAME'
        }

        It 'does NOT flag a nested object whose keys round-trip in a different order (renderType)' {
            # renderType is a multi-key nested object on programStageDataElements with no reference / *Array class,
            # so it reaches the FieldMismatch branch. DHIS2 can return its keys (DESKTOP/MOBILE) in a different
            # order than the package emitted; order-insensitive canonicalization must NOT flag identical data.
            $script:VState = @{ programStages = @([pscustomobject]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([pscustomobject]@{ id = 'psde1'; compulsory = $true
                                renderType  = [pscustomobject]@{ MOBILE = [pscustomobject]@{ type = 'DEFAULT' }; DESKTOP = [pscustomobject]@{ type = 'DEFAULT' } }
                                dataElement = [pscustomobject]@{ id = 'de1' }; programStage = [pscustomobject]@{ id = 'ps1' } }) }) }
            $pkg = @{ programStages = @([ordered]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([ordered]@{ id = 'psde1'; compulsory = $true
                                renderType  = [ordered]@{ DESKTOP = [ordered]@{ type = 'DEFAULT' }; MOBILE = [ordered]@{ type = 'DEFAULT' } }
                                dataElement = [ordered]@{ id = 'de1' }; programStage = [ordered]@{ id = 'ps1' } }) }) }
            @((Get-VDisc $pkg) | Where-Object { $_.Kind -eq 'FieldMismatch' }).Count | Should -Be 0
        }

        It 'still flags a nested object whose value genuinely differs (canonicalization does not mask real drift)' {
            # Same shape as above but DESKTOP.type genuinely differs — canonicalization sorts keys, it does not
            # collapse values, so a real value drift must still surface as a FieldMismatch on renderType.
            $script:VState = @{ programStages = @([pscustomobject]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([pscustomobject]@{ id = 'psde1'; compulsory = $true
                                renderType  = [pscustomobject]@{ DESKTOP = [pscustomobject]@{ type = 'VERTICAL_RADIOBUTTONS' }; MOBILE = [pscustomobject]@{ type = 'DEFAULT' } }
                                dataElement = [pscustomobject]@{ id = 'de1' }; programStage = [pscustomobject]@{ id = 'ps1' } }) }) }
            $pkg = @{ programStages = @([ordered]@{ id = 'ps1'; name = 'S'
                        programStageDataElements = @([ordered]@{ id = 'psde1'; compulsory = $true
                                renderType  = [ordered]@{ DESKTOP = [ordered]@{ type = 'DEFAULT' }; MOBILE = [ordered]@{ type = 'DEFAULT' } }
                                dataElement = [ordered]@{ id = 'de1' }; programStage = [ordered]@{ id = 'ps1' } }) }) }
            $fm = @((Get-VDisc $pkg) | Where-Object { $_.Kind -eq 'FieldMismatch' -and $_.Field -eq 'renderType' })
            $fm.Count | Should -Be 1
        }
    }

    Describe 'Test-NeoIPCProgramRuleActionServed (the rule-action collection clients read)' {
        BeforeAll {
            $script:SAuth = @{ Basic = 'ignored-by-the-mock' }
            # Two rules, the first with two actions and the second with one.
            $script:SPkg = @{
                programRules       = @([ordered]@{ id = 'rule0000001'; code = 'R1' }, [ordered]@{ id = 'rule0000002'; code = 'R2' })
                programRuleActions = @(
                    [ordered]@{ id = 'act00000011'; programRule = [ordered]@{ id = 'rule0000001' } }
                    [ordered]@{ id = 'act00000012'; programRule = [ordered]@{ id = 'rule0000001' } }
                    [ordered]@{ id = 'act00000021'; programRule = [ordered]@{ id = 'rule0000002' } })
            }
            function Get-SRecord { , @((Test-NeoIPCProgramRuleActionServed -Package $script:SPkg -Auth $script:SAuth) | Where-Object { $_.Kind }) }
        }
        BeforeEach {
            $script:SServed = @()
            Mock Invoke-NeoIPCDhis2Get { @{ programRules = @($script:SServed) } }
        }

        It 'reports nothing when every rule serves every declared action' {
            $script:SServed = @(@{ id = 'rule0000001'; programRuleActions = @(@{ id = 'act00000011' }, @{ id = 'act00000012' }) }
                @{ id = 'rule0000002'; programRuleActions = @(@{ id = 'act00000021' }) })
            (Get-SRecord).Count | Should -Be 0
        }

        It 'reports a declared action the rule does not serve, by id' {
            $script:SServed = @(@{ id = 'rule0000001'; programRuleActions = @(@{ id = 'act00000011' }) }
                @{ id = 'rule0000002'; programRuleActions = @(@{ id = 'act00000021' }) })
            $r = Get-SRecord
            $r.Count | Should -Be 1
            $r[0].Kind | Should -Be 'ActionNotServed'
            $r[0].RuleCode | Should -Be 'R1'
            @($r[0].ActionIds) | Should -Be @('act00000012')
        }

        It 'reports a rule served with no actions, as DHIS2 serves it (<Shape>)' -ForEach @(
            @{ Shape = 'an empty collection'; Rule = @{ id = 'rule0000002'; programRuleActions = @() } }
            @{ Shape = 'no collection'; Rule = @{ id = 'rule0000002' } }
        ) {
            $script:SServed = @(@{ id = 'rule0000001'; programRuleActions = @(@{ id = 'act00000011' }, @{ id = 'act00000012' }) }, $Rule)
            $r = Get-SRecord
            $r.Count | Should -Be 1
            $r[0].Kind | Should -Be 'ActionNotServed'
            $r[0].RuleId | Should -Be 'rule0000002'
        }

        It 'reports a rule the response leaves out entirely' {
            $script:SServed = @(@{ id = 'rule0000001'; programRuleActions = @(@{ id = 'act00000011' }, @{ id = 'act00000012' }) })
            $r = Get-SRecord
            $r.Count | Should -Be 1
            $r[0].Kind | Should -Be 'RuleNotServed'
            $r[0].RuleId | Should -Be 'rule0000002'
        }

        It 'refuses a package that declares no actions, which would pass without checking anything' {
            { Test-NeoIPCProgramRuleActionServed -Package @{ programRules = @([ordered]@{ id = 'rule0000001' }) } -Auth $script:SAuth } |
                Should -Throw '*declares no program-rule actions*'
        }
    }
}
