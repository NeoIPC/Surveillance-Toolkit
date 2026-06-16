# Play/test-package assembly: stitch the captured config (the NEOIPC_CORE dependency closure + the
# non-closure group / role / level DEFINITIONS) together with the authored org units, users, and group
# memberships into one importable package. The captured org-unit instances and user accounts are anonymised
# in the export and excluded; the authored content replaces them. No DHIS2 API calls.

function Add-NeoIPCMetadataId {
    <#
    .SYNOPSIS
        Recursively collect every 'id' value found anywhere in a metadata node into a HashSet.
    .DESCRIPTION
        Walks dictionaries and collections, adding the value of every 'id' key — object identities AND {id}
        reference targets alike. The assembly collision check uses this: an authored minted UID that appears
        here would clash with a captured identity at idScheme=UID import. Over-collecting reference ids is
        intentional (conservative) — an authored mint matching even a referenced id signals a real clash.
        Mutates the passed accumulator in place.
    .PARAMETER Node
        The metadata node to walk (package, object, array, or scalar).
    .PARAMETER Accumulator
        The HashSet to add discovered ids to.
    #>
    param(
        [AllowNull()]$Node,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Accumulator
    )
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            if ($k -eq 'id') {
                $v = [string]$Node[$k]
                if ($v) { [void]$Accumulator.Add($v) }
            }
            else { Add-NeoIPCMetadataId -Node $Node[$k] -Accumulator $Accumulator }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) { Add-NeoIPCMetadataId -Node $item -Accumulator $Accumulator }
    }
}

function Join-NeoIPCMetadataPackage {
    <#
    .SYNOPSIS
        Combine a captured config package with authored org units, users, and group memberships.
    .DESCRIPTION
        The pure assembly step (no I/O). Given the captured config (closure types + non-closure group / role /
        level definitions, already noise-stripped so the anonymised per-deployment membership is gone) and the
        authored content, it:
          1. Collision-checks every authored minted UID (org units, users) against every id already present in
             the config AND against each other — a clash would silently clobber a real config object at
             idScheme=UID import, so it is a fail-loud error.
          2. Sets organisationUnits / users to the authored objects (the captured, anonymised ones are excluded).
          3. Drops categoryOptionCombos (server-generated, regenerated on import).
          4. Applies the group memberships group-side (organisationUnitGroups.organisationUnits,
             userGroups.users) via Set-NeoIPCGroupMembership — these arrays deliberately do not ride the
             round-trip type-map/strip path, so assembly is where they are written.
        Mutates and returns the Config dictionary. No DHIS2 API calls.
    .PARAMETER Config
        The captured config package (ordered dict: type -> object array), noise-stripped.
    .PARAMETER OrgUnit
        The authored organisationUnit objects (from ConvertFrom-NeoIPCAuthoredOrgUnitCsv).
    .PARAMETER User
        The authored user objects (from ConvertFrom-NeoIPCAuthoredUserCsv).
    .PARAMETER OrgUnitGroupMembership
        Optional org-unit-group membership map (group code -> [member UID]).
    .PARAMETER UserGroupMembership
        Optional user-group membership map (group code -> [member UID]).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$OrgUnit,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$User,
        [System.Collections.IDictionary]$OrgUnitGroupMembership,
        [System.Collections.IDictionary]$UserGroupMembership
    )
    # Collision check: authored minted UIDs vs every captured identity, and vs each other.
    $captured = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    Add-NeoIPCMetadataId -Node $Config -Accumulator $captured
    foreach ($o in $OrgUnit) {
        $id = [string]$o['id']
        if (-not $captured.Add($id)) { throw "Authored org unit '$($o['code'])' minted UID '$id', which collides with a captured object id (or another authored UID)." }
    }
    foreach ($u in $User) {
        $id = [string]$u['id']
        if (-not $captured.Add($id)) { throw "Authored user '$($u['username'])' minted UID '$id', which collides with a captured object id (or another authored UID)." }
    }

    # Authored instances replace the excluded (anonymised) captured ones.
    $Config['organisationUnits'] = @($OrgUnit)
    $Config['users'] = @($User)
    if ($Config.Contains('categoryOptionCombos')) { $Config.Remove('categoryOptionCombos') }

    # Memberships applied group-side (not via the strip/round-trip path).
    if ($OrgUnitGroupMembership -and @($OrgUnitGroupMembership.Keys).Count -and $Config.Contains('organisationUnitGroups')) {
        [void](Set-NeoIPCGroupMembership -Group $Config['organisationUnitGroups'] -Membership $OrgUnitGroupMembership -MemberProperty 'organisationUnits')
    }
    if ($UserGroupMembership -and @($UserGroupMembership.Keys).Count -and $Config.Contains('userGroups')) {
        [void](Set-NeoIPCGroupMembership -Group $Config['userGroups'] -Membership $UserGroupMembership -MemberProperty 'users')
    }
    $Config
}
