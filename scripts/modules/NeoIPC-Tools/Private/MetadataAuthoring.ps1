# Authoring-input helpers: compile human-friendly, code-keyed authoring sources into the UID-keyed package
# objects the converter consumes. Org-unit INSTANCES and user accounts are anonymised in the export, so their
# package content is authored here rather than captured — minting deterministic UIDs (idScheme=UID) and
# resolving references by natural key, exactly the values New-NeoIPCMetadataUid produces on the round-trip
# path. (Closure config and the access-control / org-unit-group DEFINITIONS keep their real export UIDs and are
# captured by the converter, not authored here.)

function ConvertFrom-NeoIPCAuthoredOrgUnitCsv {
    <#
    .SYNOPSIS
        Compile code-keyed org-unit authoring CSV(s) into UID-keyed organisationUnit objects.
    .DESCRIPTION
        The org-unit hierarchy is authored in a human-readable code-keyed form
        (code,name,shortName,openingDate,parent_code) because org-unit instances are anonymised in the export
        and therefore authored, not captured. This mints a deterministic UID per org unit from its code (the
        same value New-NeoIPCMetadataUid mints on the round-trip path, so an authored unit and a captured one
        agree), resolves parent_code to the parent's minted UID, and computes the tree depth as `level`.

        Multiple CSVs are merged before resolution so a later file's units (e.g. the play test hospitals /
        departments) can reference parents defined in an earlier file (e.g. the common country / region
        scaffold). The result is UID-keyed organisationUnit objects ready for ConvertTo-NeoIPCMetadataRow or
        direct inclusion in a package. No DHIS2 API calls.
    .PARAMETER Path
        One or more code-keyed org-unit CSV paths. Order does not matter for resolution (all rows are merged
        first), but every referenced parent_code must appear in some file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string[]]$Path)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Authored org-unit CSV not found: '$p'." }
        foreach ($r in (Import-Csv -LiteralPath $p)) { $rows.Add($r) }
    }

    # code -> row and code -> minted UID. Codes are the authored identity and must be unique across files.
    $rowByCode = @{}
    $uidByCode = @{}
    foreach ($r in $rows) {
        $code = [string]$r.code
        if ([string]::IsNullOrEmpty($code)) { throw "Authored org unit with empty code (name '$($r.name)')." }
        if ($rowByCode.ContainsKey($code)) { throw "Duplicate authored org-unit code '$code'." }
        $rowByCode[$code] = $r
        $uidByCode[$code] = New-NeoIPCMetadataUid -Type 'organisationUnits' -NaturalKey $code
    }

    $objects = [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]::new()
    foreach ($r in $rows) {
        $code = [string]$r.code
        # level = tree depth: 1 for a root (no parent_code), +1 per ancestor. Walked per node (cheap at this
        # scale) with a guard so a malformed parent cycle fails loudly instead of looping.
        $level = 1
        $pc = [string]$r.parent_code
        $guard = 0
        while (-not [string]::IsNullOrEmpty($pc)) {
            if (-not $rowByCode.ContainsKey($pc)) { throw "Org unit '$code' references unknown parent_code '$pc'." }
            $level++
            $pc = [string]$rowByCode[$pc].parent_code
            if (++$guard -gt 100) { throw "Cycle detected in the org-unit parent chain at '$code'." }
        }

        # name / shortName / openingDate are not-null on a DHIS2 organisationUnit (OrganisationUnit.hbm.xml);
        # a blank cell would emit an empty string that imports-rejects. Fail in the compiler instead — the
        # round-trip self-test cannot catch this (the normalizer drops empty strings on both sides).
        $name = [string]$r.name
        $shortName = [string]$r.shortName
        $openingDate = [string]$r.openingDate
        if ([string]::IsNullOrEmpty($name)) { throw "Org unit '$code' needs a non-empty name (DHIS2 requirement)." }
        if ([string]::IsNullOrEmpty($shortName)) { throw "Org unit '$code' needs a non-empty shortName (DHIS2 requirement)." }
        if ([string]::IsNullOrEmpty($openingDate)) { throw "Org unit '$code' needs a non-empty openingDate (DHIS2 requirement)." }

        $obj = [ordered]@{
            id          = $uidByCode[$code]
            code        = $code
            name        = $name
            shortName   = $shortName
            openingDate = $openingDate
            level       = $level
        }
        $parentCode = [string]$r.parent_code
        if (-not [string]::IsNullOrEmpty($parentCode)) {
            $obj['parent'] = [ordered]@{ id = $uidByCode[$parentCode] }
        }
        $objects.Add($obj)
    }
    , $objects.ToArray()
}

function ConvertFrom-NeoIPCAuthoredUserCsv {
    <#
    .SYNOPSIS
        Compile the normalized play-user authoring tables into UID-keyed DHIS2 user objects.
    .DESCRIPTION
        Real users are anonymised in the export and stay excluded; the play variant gets a small set of
        synthetic, clearly-test accounts authored here. The authoring is NORMALIZED — one user record per row,
        with the many-to-many role and org-unit assignments in their own one-row-per-assignment junction tables
        rather than as arrays packed into a cell:
            users.csv                  -> username, firstName, surname
            userRoleAssignments.csv    -> username, role             (role NAME, resolved to the captured role's real UID)
            userOrgUnitAssignments.csv -> username, organisationUnit  (org-unit CODE, resolved to the authored minted UID)
        Each user is minted a deterministic UID from its username, given the supplied password, and assembled
        with its resolved roles and org-unit scopes (capture / data-view / TEI-search all set to the assigned
        units, matching the export's per-user shape). This function sets a user's identity, roles and org-unit
        scopes only; it does not place the user in any userGroup. No DHIS2 API calls.
    .PARAMETER UserPath
        users.csv (username, firstName, surname).
    .PARAMETER RoleAssignmentPath
        userRoleAssignments.csv (username, role). Every user must have at least one role.
    .PARAMETER OrgUnitAssignmentPath
        userOrgUnitAssignments.csv (username, organisationUnit).
    .PARAMETER RoleUid
        Map of userRole name -> real UID (from the captured package).
    .PARAMETER OrgUnitUid
        Map of org-unit code -> minted UID (from ConvertFrom-NeoIPCAuthoredOrgUnitCsv).
    .PARAMETER Password
        The login password set on every authored user. Defaults to the DHIS2 demo password.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Synthetic play accounts use a known, clearly-test demo password committed in play data by design — it is not a real secret.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$UserPath,
        [Parameter(Mandatory)][string]$RoleAssignmentPath,
        [Parameter(Mandatory)][string]$OrgUnitAssignmentPath,
        [Parameter(Mandatory)][hashtable]$RoleUid,
        [Parameter(Mandatory)][hashtable]$OrgUnitUid,
        [string]$Password = 'district'
    )
    foreach ($p in $UserPath, $RoleAssignmentPath, $OrgUnitAssignmentPath) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Authored user file not found: '$p'." }
    }

    # Group the junction rows by username (one assignment per row, no in-cell arrays).
    function Group-NeoIPCAuthoredAssignment([string]$Path, [string]$ValueColumn) {
        $byUser = @{}
        foreach ($a in (Import-Csv -LiteralPath $Path)) {
            $un = ([string]$a.username).Trim()
            $val = ([string]$a.$ValueColumn).Trim()
            if ([string]::IsNullOrEmpty($un) -or [string]::IsNullOrEmpty($val)) { continue }
            if (-not $byUser.ContainsKey($un)) { $byUser[$un] = [System.Collections.Generic.List[string]]::new() }
            $byUser[$un].Add($val)
        }
        $byUser
    }
    $rolesByUser = Group-NeoIPCAuthoredAssignment $RoleAssignmentPath 'role'
    $ouByUser    = Group-NeoIPCAuthoredAssignment $OrgUnitAssignmentPath 'organisationUnit'

    $users = [System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]]::new()
    $seen = @{}
    foreach ($r in (Import-Csv -LiteralPath $UserPath)) {
        $username = ([string]$r.username).Trim()
        if ([string]::IsNullOrEmpty($username)) { throw "Authored user with empty username." }
        if ($seen.ContainsKey($username)) { throw "Duplicate authored username '$username'." }
        $seen[$username] = $true

        $roleKeys = if ($rolesByUser.ContainsKey($username)) { @($rolesByUser[$username]) } else { @() }
        if ($roleKeys.Count -eq 0) { throw "User '$username' has no userRoles (DHIS2 requires at least one)." }
        $roleRefs = @(foreach ($k in $roleKeys) {
            if (-not $RoleUid.ContainsKey($k)) { throw "User '$username' references unknown role '$k'." }
            [ordered]@{ id = $RoleUid[$k] } })

        $ouKeys = if ($ouByUser.ContainsKey($username)) { @($ouByUser[$username]) } else { @() }
        $ouRefs = @(foreach ($k in $ouKeys) {
            if (-not $OrgUnitUid.ContainsKey($k)) { throw "User '$username' references unknown org unit '$k'." }
            [ordered]@{ id = $OrgUnitUid[$k] } })

        # DHIS2 requires firstName and surname to be >= 2 chars (User @PropertyRange(min = 2)); fail in the
        # compiler rather than silently at import.
        $firstName = ([string]$r.firstName).Trim()
        $surname   = ([string]$r.surname).Trim()
        if ($firstName.Length -lt 2 -or $surname.Length -lt 2) {
            throw "User '$username' needs a firstName and surname of at least 2 characters (DHIS2 requirement)."
        }

        $u = [ordered]@{
            id        = (New-NeoIPCMetadataUid -Type 'users' -NaturalKey $username)
            username  = $username
            firstName = $firstName
            surname   = $surname
            password  = $Password
            userRoles = $roleRefs
        }
        if ($ouRefs.Count) {
            $u['organisationUnits']          = $ouRefs
            $u['dataViewOrganisationUnits']  = $ouRefs
            $u['teiSearchOrganisationUnits'] = $ouRefs
        }
        $users.Add($u)
    }

    # Fail loud on a junction row that targets a username absent from users.csv (a typo, not a silent drop).
    foreach ($un in $rolesByUser.Keys) { if (-not $seen.ContainsKey($un)) { throw "Role assignment references unknown user '$un'." } }
    foreach ($un in $ouByUser.Keys)    { if (-not $seen.ContainsKey($un)) { throw "Org-unit assignment references unknown user '$un'." } }

    , $users.ToArray()
}

function Add-NeoIPCMembershipEntry {
    <#
    .SYNOPSIS
        Append a member UID to a group-code -> [member UID] membership map, de-duplicated, first-seen order.
    .DESCRIPTION
        Shared accumulator for the membership compilers: the ordered map preserves the order members are first
        seen; the parallel per-group HashSet keeps a member from being listed twice when the structural and
        authored sources (or two junction rows) name the same pair. Both containers are mutated in place.
    .PARAMETER Membership
        The group-code -> List[UID] map being built.
    .PARAMETER MemberSet
        The group-code -> HashSet[UID] de-dup index parallel to Membership.
    .PARAMETER GroupCode
        The group the member belongs to.
    .PARAMETER Uid
        The member object's UID.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Membership,
        [Parameter(Mandatory)][hashtable]$MemberSet,
        [Parameter(Mandatory)][string]$GroupCode,
        [Parameter(Mandatory)][string]$Uid
    )
    if (-not $Membership.Contains($GroupCode)) {
        $Membership[$GroupCode] = [System.Collections.Generic.List[string]]::new()
        $MemberSet[$GroupCode] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    }
    if ($MemberSet[$GroupCode].Add($Uid)) { $Membership[$GroupCode].Add($Uid) }
}

function ConvertFrom-NeoIPCAuthoredOrgUnitGroupMembership {
    <#
    .SYNOPSIS
        Compile the play org-unit-group memberships into a group-code -> [member org-unit UID] map.
    .DESCRIPTION
        Per-deployment org-unit-group membership is stripped on capture (common groups carry no members), so
        the play variant authors it here. Memberships come from two sources, merged into one map:

          STRUCTURAL (derived from the org-unit set, never authored) — the identity groups neoipc-app and
          neoipcr resolve from the hierarchy itself, keyed off the NeoIPC play code convention:
            NEO_DEPARTMENT <- every department (code ends '_TEST_TEST')
            HOSPITAL       <- every hospital   (code ends '_TEST', but not '_TEST_TEST')
            COUNTRY        <- every country    (level 2 — a direct child of the root)
          Deriving these keeps membership in lockstep with the org units instead of duplicating ~300 junction
          rows that drift the moment a unit is added, and mirrors how the app identifies org-unit roles by
          group code rather than by hierarchy level.

          DOMAIN (authored) — memberships that are NOT a function of structure. These split across the source
          layers by which org units they attach to: World-Bank income class sits on the COMMON countries
          (a stable real-world fact, authored in metadata/common), while reference centre / test units /
          trial sites / all-patients-eligible sit on the synthetic PLAY departments (authored in
          metadata/play). Read from one or more normalized junction files (organisationUnitGroup,
          organisationUnit), merged in order; the org-unit CODE is resolved to its UID. A row naming an org
          unit absent from the given org-unit set is a fail-loud error (a typo, not a silent drop).

        Returns an ordered map: group code -> List[UID] (de-duplicated, first-seen order). The group CODE is
        not validated here — Set-NeoIPCGroupMembership fails loud if it names a group absent from the package.
        No DHIS2 API calls.
    .PARAMETER OrgUnit
        The authored organisationUnit objects from ConvertFrom-NeoIPCAuthoredOrgUnitCsv (each carries id, code, level).
    .PARAMETER MembershipPath
        Optional normalized junction file(s) (organisationUnitGroup,organisationUnit) carrying the domain
        memberships — e.g. the common World-Bank-class file and the play designation file, merged.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$OrgUnit,
        [string[]]$MembershipPath
    )

    $idByCode = @{}
    $membership = [ordered]@{}
    $memberSet = @{}

    foreach ($ou in $OrgUnit) {
        $code = [string]$ou['code']
        if ([string]::IsNullOrEmpty($code)) { continue }
        $uid = [string]$ou['id']
        $idByCode[$code] = $uid
        # Structural identity groups — a function of the hierarchy, derived here rather than authored.
        if ($code.EndsWith('_TEST_TEST', [System.StringComparison]::Ordinal)) {
            Add-NeoIPCMembershipEntry -Membership $membership -MemberSet $memberSet -GroupCode 'NEO_DEPARTMENT' -Uid $uid
        }
        elseif ($code.EndsWith('_TEST', [System.StringComparison]::Ordinal)) {
            Add-NeoIPCMembershipEntry -Membership $membership -MemberSet $memberSet -GroupCode 'HOSPITAL' -Uid $uid
        }
        if (([int]$ou['level']) -eq 2) {
            Add-NeoIPCMembershipEntry -Membership $membership -MemberSet $memberSet -GroupCode 'COUNTRY' -Uid $uid
        }
    }

    foreach ($mp in $MembershipPath) {
        if ([string]::IsNullOrEmpty($mp)) { continue }
        if (-not (Test-Path -LiteralPath $mp)) { throw "Authored org-unit-group membership file not found: '$mp'." }
        foreach ($row in (Import-Csv -LiteralPath $mp)) {
            $group = ([string]$row.organisationUnitGroup).Trim()
            $ouCode = ([string]$row.organisationUnit).Trim()
            if ([string]::IsNullOrEmpty($group) -or [string]::IsNullOrEmpty($ouCode)) { continue }
            if (-not $idByCode.ContainsKey($ouCode)) {
                throw "Org-unit-group membership references unknown org unit '$ouCode' (not in the authored hierarchy)."
            }
            Add-NeoIPCMembershipEntry -Membership $membership -MemberSet $memberSet -GroupCode $group -Uid $idByCode[$ouCode]
        }
    }
    $membership
}

function ConvertFrom-NeoIPCAuthoredUserGroupMembership {
    <#
    .SYNOPSIS
        Compile the play user-group memberships into a group-code -> [member user UID] map.
    .DESCRIPTION
        userGroup.users is per-deployment, stripped on capture (common groups carry no members); the play
        variant authors a few synthetic members here. Read from a normalized junction file
        (userGroup,username); each username is resolved to its authored user's minted UID. A row naming a
        username absent from the authored user set is a fail-loud error. Returns an ordered map: userGroup
        code -> List[UID] (de-duplicated, first-seen order). The userGroup CODE is not validated here —
        Set-NeoIPCGroupMembership fails loud if it names a group absent from the package. No DHIS2 API calls.
    .PARAMETER MembershipPath
        Normalized junction file (userGroup,username).
    .PARAMETER User
        The authored user objects from ConvertFrom-NeoIPCAuthoredUserCsv (each carries id, username).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$MembershipPath,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$User
    )
    if (-not (Test-Path -LiteralPath $MembershipPath)) { throw "Authored user-group membership file not found: '$MembershipPath'." }

    $idByUsername = @{}
    foreach ($u in $User) {
        $un = [string]$u['username']
        if (-not [string]::IsNullOrEmpty($un)) { $idByUsername[$un] = [string]$u['id'] }
    }

    $membership = [ordered]@{}
    $memberSet = @{}
    foreach ($row in (Import-Csv -LiteralPath $MembershipPath)) {
        $group = ([string]$row.userGroup).Trim()
        $username = ([string]$row.username).Trim()
        if ([string]::IsNullOrEmpty($group) -or [string]::IsNullOrEmpty($username)) { continue }
        if (-not $idByUsername.ContainsKey($username)) {
            throw "User-group membership references unknown user '$username' (not in the authored users)."
        }
        Add-NeoIPCMembershipEntry -Membership $membership -MemberSet $memberSet -GroupCode $group -Uid $idByUsername[$username]
    }
    $membership
}

function Set-NeoIPCGroupMembership {
    <#
    .SYNOPSIS
        Apply an authored membership map onto group objects, group-side (sets organisationUnits[] / users[]).
    .DESCRIPTION
        The play package's per-deployment membership is authored, not captured, and the round-trip strip path
        deliberately drops the member arrays — so membership must be written straight onto the group objects
        when the package is assembled, not carried through the type-map conversion. This sets each named
        group's member property to {id} references (the export shape). A membership entry naming a group
        absent from the package is a fail-loud error (a typo, not a silent drop); groups with no membership
        entry are left untouched (member-less, as common groups are). Mutates the passed group objects in
        place and returns the number of groups populated. No DHIS2 API calls.
    .PARAMETER Group
        The group objects to populate (organisationUnitGroups or userGroups), each an ordered dict with a code.
    .PARAMETER Membership
        Map group code -> [member UID] from ConvertFrom-NeoIPCAuthored{OrgUnit,User}GroupMembership.
    .PARAMETER MemberProperty
        The reference-array property to set: 'organisationUnits' (org-unit groups) or 'users' (user groups).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Group,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Membership,
        [Parameter(Mandatory)][ValidateSet('organisationUnits', 'users')][string]$MemberProperty
    )
    $byCode = @{}
    foreach ($g in $Group) {
        $code = [string]$g['code']
        if (-not [string]::IsNullOrEmpty($code)) { $byCode[$code] = $g }
    }
    $applied = 0
    foreach ($code in $Membership.Keys) {
        if (-not $byCode.ContainsKey($code)) {
            throw "Membership references group '$code', which is not present among the $MemberProperty group objects."
        }
        $byCode[$code][$MemberProperty] = @(foreach ($uid in $Membership[$code]) { [ordered]@{ id = $uid } })
        $applied++
    }
    $applied
}
