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
