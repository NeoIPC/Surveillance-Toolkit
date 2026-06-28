# Pester 5 tests for the round-trip import verifier (Public/MetadataVerify.ps1). Self-contained: the DHIS2
# read-back (Invoke-NeoIPCDhis2Get) is mocked from a synthetic in-memory "server state", so no live instance
# is needed. The mock returns, per `api/<type>` request, a { <type> = [...] } envelope built from
# $script:VState — the shape fields=:owner produces (owned ref-collections as bare { id } objects). NestedOnly
# children are diffed out of their PARENT's expanded read-back (the verifier requests
# fields=:owner,<arrayProp>[:owner]), so the parent's VState entry carries the children as FULL objects — there
# is no separate child-type endpoint (it does not exist in DHIS2 2.40).
#
# Discrepancies are read via Get-VDisc, which filters to the records that carry a Kind — matching how the
# seed gate consumes the result (`$disc | Where-Object { $_.Kind -in ... }`). That also sidesteps the
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
                [pscustomobject]@{ $t = $items }
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

        It 'round-trips option sortOrder by value (1-based dense — no spurious FieldMismatch)' {
            # DHIS2 stores option sortOrder as the persisted 1-based list position (OptionSet.hbm.xml <list-index base=1>);
            # the package already emits 1-based contiguous sortOrder, so the value matches and optionSet.options
            # (idArray) reordering is ignored. Guards the "#4 is a non-issue" finding.
            $script:VState = @{
                optionSets = @([pscustomobject]@{ id = 'os1'; code = 'OS1'; name = 'N'; valueType = 'TEXT'
                        options = @([pscustomobject]@{ id = 'o3' }, [pscustomobject]@{ id = 'o1' }, [pscustomobject]@{ id = 'o2' }) })
                options    = @(
                    [pscustomobject]@{ id = 'o1'; code = '1'; name = 'A'; sortOrder = 1; optionSet = [pscustomobject]@{ id = 'os1' } }
                    [pscustomobject]@{ id = 'o2'; code = '2'; name = 'B'; sortOrder = 2; optionSet = [pscustomobject]@{ id = 'os1' } }
                    [pscustomobject]@{ id = 'o3'; code = '3'; name = 'C'; sortOrder = 3; optionSet = [pscustomobject]@{ id = 'os1' } })
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
    }
}
