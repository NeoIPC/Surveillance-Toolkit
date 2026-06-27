# Round-trip verification of a metadata import: the companion to Import-NeoIPCMetadata. After a package is
# imported it proves the import did not SILENTLY drop objects or owned-collection memberships. This guards a real
# DHIS2 import behaviour: a single combined /api/metadata import does NOT connect an optionGroupSet's
# `optionGroups` membership to optionGroups created in the SAME payload (verified empirically — the groups and the
# option->optionGroup links persist, only the group-set->group link is dropped), so an import that reports
# status=OK can still leave a group set with zero members. Reading every object back with fields=:owner and
# diffing it against the package catches that and any analogous drop across every type at once.

function Test-NeoIPCMetadataImport {
    <#
    .SYNOPSIS
        Round-trip verification: assert every object in a metadata package is present in DHIS2 and correctly
        linked after import.
    .DESCRIPTION
        For every object in $Package, fetches the imported object from DHIS2 with fields=:owner (all OWNED
        properties, including owned reference collections) and compares it against the package object. Emits one
        record per discrepancy:
          - Missing      — a package object absent from DHIS2 (the import dropped the whole object).
          - LinkDrop     — an owned reference / reference-collection the package specifies that DHIS2 did not
                           store: a dropped group-set membership (optionGroupSet.optionGroups), or any other
                           reference field (optionSet.options, optionGroup.options, program.programStages,
                           programStage.programStageDataElements, ...). Reference collections are compared as
                           id-SETS: a member the package lists but DHIS2 lacks IS caught, but a difference in
                           member ORDER is NOT — for ordered collections (optionGroupSet.optionGroups,
                           programStageSection.dataElements, ...) a wrong-order reconnection passes clean. A
                           known limitation; the membership check is the proven part.
          - FieldMismatch — a non-reference scalar/array field whose stored value differs from the package.
          - FetchFailed  — a whole type could not be read back (network / endpoint error). Reported as a record;
                           the caller decides severity — the seed's round-trip gate (Initialize-TestDhis2.ps1)
                           treats it as fatal, since its objects are then unverified.

        The PACKAGE is the source of truth: only the fields the package actually specifies are checked, so
        server-filled defaults never produce false positives. Server-managed / noisy dimensions (translations,
        sharing, audit, access) are skipped by default (-IgnoreField). An empty result means a perfect
        round-trip — every object present, every link intact.

        Read-only (GETs only). It DRIVES a DHIS2 instance, so it is intended for the local / test stack; pass
        -Scheme http -Hostname localhost -Port 8080 with a Basic-auth hashtable for the local stack.
    .PARAMETER Path
        Path to a metadata package JSON file to verify.
    .PARAMETER Package
        The package to verify instead of -Path: the JSON string or the parsed hashtable from
        New-NeoIPCMetadataPackage.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).
    .PARAMETER Scheme
        DHIS2 scheme (http/https). Default https.
    .PARAMETER Hostname
        DHIS2 hostname. Default neoipc.charite.de.
    .PARAMETER Port
        DHIS2 port. Default none (scheme default).
    .PARAMETER IgnoreField
        Object property names to skip. Defaults to the server-managed / noisy set (translations, sharing,
        access, audit) plus `password`, so a synthetic user's login password is never echoed into a
        FieldMismatch detail.
    .PARAMETER BatchSize
        Maximum object ids per `id:in:[...]` request. Default 120 (keeps the request URL well within limits).
    .OUTPUTS
        [object[]] of discrepancy records { Type; Id; Code; Kind; Field; Detail }. Empty = perfect round-trip.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Package')]$Package,
        [Parameter(Mandatory)][hashtable]$Auth,
        [string]$Scheme = 'https',
        [string]$Hostname = 'neoipc.charite.de',
        [Nullable[int]]$Port = $null,
        [string[]]$IgnoreField = @(
            'translations', 'sharing', 'access', 'publicAccess', 'externalAccess',
            'user', 'userAccesses', 'userGroupAccesses', 'favorites', 'favorite',
            'password', 'created', 'lastUpdated', 'createdBy', 'lastUpdatedBy',
            'createdByUserInfo', 'lastUpdatedByUserInfo', 'href'),
        [ValidateRange(1, 1000)][int]$BatchSize = 120
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata package not found: '$Path'." }
        $pkg = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -Depth 100
    }
    elseif ($Package -is [string]) { $pkg = $Package | ConvertFrom-Json -AsHashtable -Depth 100 }
    elseif ($Package -is [System.Collections.IDictionary]) { $pkg = $Package }
    else { throw 'Package must be a JSON string, a parsed hashtable, or supply -Path.' }

    $ignore = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $IgnoreField) { [void]$ignore.Add($f) }

    $getArgs = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
    if ($null -ne $Port) { $getArgs['Port'] = $Port }

    # A reference is any object carrying an `id`; in fields=:owner output DHIS2 returns owned references as bare
    # { id } objects, matching the package. Extract the id whether the object is a package hashtable or a parsed
    # DHIS2 PSCustomObject.
    function Get-NeoIPCRefId($x) {
        if ($null -eq $x) { return $null }
        if ($x -is [System.Collections.IDictionary]) { if ($x.Contains('id')) { return [string]$x['id'] } return $null }
        $p = $x.PSObject.Properties['id']; if ($p) { return [string]$p.Value } return $null
    }
    function Test-NeoIPCIsRef($x) {
        if ($x -is [System.Collections.IDictionary]) { return $x.Contains('id') }
        return ($null -ne $x -and $null -ne $x.PSObject -and $null -ne $x.PSObject.Properties['id'])
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $ordinal = [System.StringComparer]::Ordinal

    foreach ($type in @($pkg.Keys)) {
        $objs = @(@($pkg[$type]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
        if ($objs.Count -eq 0) { continue }
        Write-Verbose "Verifying $($objs.Count) $type ..."

        # Read the imported objects of this type back with all owned fields, batched by id.
        $importedById = @{}
        $fetchFailed = $false
        for ($i = 0; $i -lt $objs.Count; $i += $BatchSize) {
            $batch = @($objs[$i..([Math]::Min($i + $BatchSize, $objs.Count) - 1)])
            $ids = @($batch | ForEach-Object { [string]$_['id'] })
            try {
                $resp = Invoke-NeoIPCDhis2Get @getArgs -Path "api/$type" -Fields ':owner' -Filter "id:in:[$($ids -join ',')]" -Confirm:$false
            }
            catch {
                $records.Add([pscustomobject]@{ Type = $type; Id = ''; Code = ''; Kind = 'FetchFailed'; Field = ''; Detail = $_.Exception.Message })
                $fetchFailed = $true
                break
            }
            # A 200 with no `$type` collection key (an unexpected envelope) is a read-back failure, not "all
            # objects missing" — record FetchFailed (fatal at the seed gate) rather than let `$resp.$type` throw
            # under StrictMode or flood every object as Missing.
            if ($null -eq $resp -or -not $resp.PSObject.Properties[$type]) {
                $records.Add([pscustomobject]@{ Type = $type; Id = ''; Code = ''; Kind = 'FetchFailed'; Field = ''; Detail = "response did not contain a '$type' collection" })
                $fetchFailed = $true
                break
            }
            foreach ($o in @($resp.$type)) { if ($null -ne $o -and $o.id) { $importedById[[string]$o.id] = $o } }
        }
        if ($fetchFailed) { continue }
        Write-Verbose "  read back $($importedById.Count) of $($objs.Count) $type"

        foreach ($pObj in $objs) {
            $id = [string]$pObj['id']
            $code = [string]$pObj['code']
            if (-not $importedById.ContainsKey($id)) {
                $records.Add([pscustomobject]@{ Type = $type; Id = $id; Code = $code; Kind = 'Missing'; Field = ''; Detail = 'object not present in DHIS2 after import' })
                continue
            }
            $imp = $importedById[$id]
            foreach ($field in @($pObj.Keys)) {
                $fname = [string]$field
                if ($fname -eq 'id' -or $ignore.Contains($fname)) { continue }
                $expected = $pObj[$field]
                $impProp = $imp.PSObject.Properties[$fname]
                $actual = if ($impProp) { $impProp.Value } else { $null }

                $expArr = @($expected)
                if ($expArr.Count -gt 0 -and (Test-NeoIPCIsRef $expArr[0])) {
                    # Reference (single or collection): compare as id-sets so order is irrelevant; a member the
                    # package lists but DHIS2 lacks is a dropped link.
                    $expIds = @($expArr | ForEach-Object { Get-NeoIPCRefId $_ } | Where-Object { $_ })
                    $actSet = [System.Collections.Generic.HashSet[string]]::new($ordinal)
                    foreach ($a in @($actual)) { $rid = Get-NeoIPCRefId $a; if ($rid) { [void]$actSet.Add($rid) } }
                    $missing = @($expIds | Where-Object { -not $actSet.Contains($_) })
                    if ($missing.Count -gt 0) {
                        $shown = (@($missing) | Select-Object -First 8) -join ','
                        if ($missing.Count -gt 8) { $shown += ',…' }
                        $records.Add([pscustomobject]@{ Type = $type; Id = $id; Code = $code; Kind = 'LinkDrop'; Field = $fname
                                Detail = "package lists $($expIds.Count) ref(s), DHIS2 has $($actSet.Count); missing $($missing.Count): $shown" })
                    }
                    continue
                }
                $e = $expected | ConvertTo-Json -Compress -Depth 20
                $a = $actual | ConvertTo-Json -Compress -Depth 20
                if ($e -cne $a) {
                    $records.Add([pscustomobject]@{ Type = $type; Id = $id; Code = $code; Kind = 'FieldMismatch'; Field = $fname
                            Detail = "package=$e DHIS2=$a" })
                }
            }
        }
    }

    $summary = $records | Group-Object Kind | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Verbose ("Round-trip verification: {0}." -f $(if ($summary) { $summary -join ' ' } else { 'no discrepancies' }))
    , [object[]]$records.ToArray()
}
