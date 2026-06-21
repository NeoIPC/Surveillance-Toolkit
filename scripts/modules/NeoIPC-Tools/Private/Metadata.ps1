# NeoIPC metadata pipeline — shared core (private, not exported).
# Type-map-independent primitives: UID validity + deterministic mint, the one list
# tokenizer, parent-id grouping, and the recursive noise normalizer. Static data tables
# (strip-list, excluded types, default UIDs) live in Private/MetadataTypeMaps.ps1.

function ConvertFrom-NeoIPCMetadataJsonText {
    # The single JSON->package parse for the whole pipeline. -DateKind String is the load-bearing flag: it
    # keeps ISO-8601 date strings (e.g. organisationUnit.openingDate / closedDate) as opaque strings instead of
    # converting them to [datetime]. A [datetime] would then be formatted in the CURRENT CULTURE by the [string]
    # cast in ConvertTo-NeoIPCMetadataCell's string class (e.g. "06/15/2025 00:00:00" under de-DE) when emitted to
    # a CSV cell, breaking the round-trip. (ConvertTo-Json itself serialises a [datetime] in invariant ISO, so the
    # comparator path is unaffected — it is the CSV-cell emit path that bites.) Dates are carried verbatim as strings.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $Json | ConvertFrom-Json -AsHashtable -DateKind String
}

function Test-NeoIPCMetadataUid {
    # True when $Id is a valid DHIS2 UID (11 chars, leading letter, then alphanumerics).
    # -Invert returns the negation ("this id needs minting"). Same shape as the DHIS2 CodeGenerator.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Id,
        [switch]$Invert
    )
    $isUid = $Id -cmatch '^[A-Za-z][A-Za-z0-9]{10}$'
    if ($Invert) { -not $isUid } else { $isUid }
}

function New-NeoIPCMetadataUid {
    # Deterministic UID = f(type, natural key): SHA-256 of "<type>\0<key>" mapped onto the DHIS2
    # alphabet, leading char forced to a letter. Pure (no RNG) so re-runs and other machines
    # produce byte-identical ids — the comparator then sees zero id churn.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$NaturalKey
    )
    $alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'  # 62, DHIS2 set
    $letters  = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'           # 52, leading char
    # NUL-joined so a type and a key can never combine to the same byte string as another pair.
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Type + [char]0 + $NaturalKey)
    $hash  = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $sb = [System.Text.StringBuilder]::new(11)
    [void]$sb.Append($letters[$hash[0] % $letters.Length])
    for ($i = 1; $i -lt 11; $i++) {
        [void]$sb.Append($alphabet[$hash[$i] % $alphabet.Length])
    }
    $sb.ToString()
}

function Split-NeoIPCMetadataList {
    # The single whitespace-collapsing tokenizer for every id/int/string array cell.
    # Trailing/double/tab whitespace yields no spurious empty elements; empty input -> @().
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split '\s+' | Where-Object { $_ -ne '' })
}

function Group-NeoIPCMetadataByParentId {
    # O(n) index of a child collection bucketed by a caller-supplied key, for re-nesting in O(1).
    # The KeySelector scriptblock receives each child as $_; children with a null/empty key are
    # skipped. A parent with no children is simply absent from the index (callers emit @()).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$KeySelector,
        [Parameter(ValueFromPipeline)]$Children
    )
    begin { $index = @{} }
    process {
        foreach ($child in $Children) {
            if ($null -eq $child) { continue }
            $key = $child | ForEach-Object $KeySelector
            if ($null -eq $key -or "$key" -eq '') { continue }
            if (-not $index.ContainsKey($key)) {
                $index[$key] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$index[$key].Add($child)
        }
    }
    end { $index }
}

function Convert-NeoIPCSharing {
    # Normalize a sharing object to {public[, non-empty users][, non-empty userGroups]}, each grant reduced
    # to {id, access}. Drops owner/external/empty grants (provenance/noise) and the per-grant displayName
    # (a server-derived mirror of the id — the recursive display* strip never reaches into the sharing
    # branch, so it is dropped explicitly here) while preserving real authorization intent (public is NOT
    # uniform across objects, so it must round-trip as data).
    param($Sharing)
    # A non-dictionary sharing (null, or a legacy scalar grant string) carries no normalizable intent;
    # return an empty map so the emit path ($result.Count) and the comparator (@($result.Keys).Count)
    # agree to drop it, rather than one keeping a scalar the other discards.
    if ($Sharing -isnot [System.Collections.IDictionary]) { return [ordered]@{} }
    $result = [ordered]@{}
    if ($null -ne $Sharing['public']) { $result['public'] = [string]$Sharing['public'] }
    foreach ($grantKey in 'users', 'userGroups') {
        $grants = $Sharing[$grantKey]
        if ($grants -is [System.Collections.IDictionary] -and $grants.Count -gt 0) {
            $normalized = [ordered]@{}
            foreach ($gid in $grants.Keys) {
                $grant = $grants[$gid]
                $entry = [ordered]@{ id = [string]$gid }
                if ($grant -is [System.Collections.IDictionary]) {
                    if ($null -ne $grant['id']) { $entry['id'] = [string]$grant['id'] }
                    if ($null -ne $grant['access']) { $entry['access'] = [string]$grant['access'] }
                }
                else {
                    # Compact form (the profile spec): the grant value IS the access string.
                    $entry['access'] = [string]$grant
                }
                $normalized[[string]$gid] = $entry
            }
            $result[$grantKey] = $normalized
        }
    }
    $result
}

# Named sharing profiles: a handful of distinct sharing shapes recur across the package, so they are named
# ONCE in <metadata-dir>/sharing.yaml and each CSV `sharing` cell carries just the key. Loaded into this
# module-scoped registry by Import-NeoIPCSharingProfile; the row converter resolves a key on emit and
# expands it on read. Null until loaded (a directory with no non-empty sharing needs no profiles).
$script:NeoIPCSharingProfiles = $null

function Get-NeoIPCSharingCanonicalKey {
    # The order-independent identity of a normalized sharing object: its canonical (recursively key-sorted)
    # compact JSON. Used both to index profiles by value at load and to look one up on emit, so the two are
    # provably the same comparison.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Sharing)
    (ConvertTo-NeoIPCMetadataCanonical $Sharing) | ConvertTo-Json -Compress -Depth 10
}

function Get-NeoIPCUserGroupKeyMap {
    # Build {KeyToId, IdToKey} from a set of userGroup objects/rows (each carrying id, code, name), so sharing
    # profiles can key grants by a human-readable handle while the DHIS2 sharing object keeps the UID. The
    # preferred handle is the group CODE; a codeless group falls back to its (unique) NAME. KeyToId resolves
    # EITHER a code or a name to the UID; IdToKey gives the preferred handle (code, else name) for writing.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([object[]]$UserGroups)
    $keyToId = @{}
    $idToKey = @{}
    foreach ($ug in $UserGroups) {
        if ($ug -isnot [System.Collections.IDictionary]) { continue }
        $id = [string]$ug['id']
        if (-not $id) { continue }
        $code = [string]$ug['code']
        $name = [string]$ug['name']
        # A handle (code or name) that already maps to a DIFFERENT group is ambiguous: a sharing grant
        # authored as that handle could resolve to the wrong UID, or two grants collapse onto one key on
        # write. Fail loud here — the same fail-on-collision the module's other identity maps enforce —
        # rather than silently last-wins. (A group's own code and name both pointing at its own id is fine.)
        foreach ($handle in @($code, $name)) {
            if (-not $handle) { continue }
            if ($keyToId.ContainsKey($handle) -and $keyToId[$handle] -ne $id) {
                throw "Ambiguous user-group handle '$handle' resolves to both '$($keyToId[$handle])' and '$id'; sharing grants need an unambiguous code or unique name."
            }
            $keyToId[$handle] = $id
        }
        $idToKey[$id] = if ($code) { $code } elseif ($name) { $name } else { $id }
    }
    @{ KeyToId = $keyToId; IdToKey = $idToKey }
}

function ConvertTo-NeoIPCSharingFromProfileSpec {
    # Expand a profile spec (the sharing.yaml shape: {public, userGroups:{<code-or-name>:<access>}, users:{<id>:<access>}})
    # into a normalized DHIS2 sharing object ({public, userGroups:{<id>:{id, access}}, ...}) — the same shape
    # Convert-NeoIPCSharing produces, so the two canonicalize identically. userGroups are keyed by the group
    # CODE (or unique NAME) for human-editability and resolved to the UID via KeyToId; an unknown handle fails
    # loud (a human-edited typo surfaces, instead of silently writing an opaque UID). `users` grants (rare; PII)
    # stay keyed by their UID.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Spec, [hashtable]$KeyToId = @{})
    if ($Spec -isnot [System.Collections.IDictionary]) { throw 'Sharing profile spec must be a mapping.' }
    $sharing = [ordered]@{}
    if ($null -ne $Spec['public']) { $sharing['public'] = [string]$Spec['public'] }
    foreach ($grantKey in 'users', 'userGroups') {
        $grants = $Spec[$grantKey]
        if ($grants -is [System.Collections.IDictionary] -and $grants.Count -gt 0) {
            $entries = [ordered]@{}
            foreach ($gkey in $grants.Keys) {
                $id = [string]$gkey
                if ($grantKey -eq 'userGroups') {
                    if ($KeyToId.ContainsKey($id)) { $id = [string]$KeyToId[$id] }
                    else { throw "Sharing profile references unknown user group '$gkey' (expected a userGroup code or unique name)." }
                }
                $entries[$id] = [ordered]@{ id = $id; access = [string]$grants[$gkey] }
            }
            $sharing[$grantKey] = $entries
        }
    }
    $sharing
}

function Import-NeoIPCSharingProfile {
    # Load the named sharing profiles from a sharing.yaml into the module-scoped registry the row converter
    # consults (key -> sharing object, and sharing-value -> key). A no-op when the file is absent: a
    # directory with no non-empty sharing needs no profiles, and resolution fails loud later if one is met
    # without a match. Two profiles resolving to the same sharing object is an authoring error (throws).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [hashtable]$KeyToId = @{})
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Import-Module powershell-yaml -ErrorAction Stop
    $specs = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
    if ($specs -isnot [System.Collections.IDictionary]) { throw "Sharing profiles file '$Path' is not a mapping of profile-key -> sharing spec." }
    $byKey = [ordered]@{}
    $byValue = @{}
    foreach ($key in $specs.Keys) {
        $sharing = ConvertTo-NeoIPCSharingFromProfileSpec -Spec $specs[$key] -KeyToId $KeyToId
        $byKey[[string]$key] = $sharing
        $canon = Get-NeoIPCSharingCanonicalKey -Sharing $sharing
        if ($byValue.ContainsKey($canon)) { throw "Sharing profiles '$($byValue[$canon])' and '$key' resolve to the same sharing object in '$Path'." }
        $byValue[$canon] = [string]$key
    }
    $script:NeoIPCSharingProfiles = @{ ByKey = $byKey; ByValue = $byValue }
}

function Resolve-NeoIPCSharingProfileKey {
    # Map a normalized sharing object to its profile key (the value written to a CSV `sharing` cell). Fails
    # loud on an unrecognized shape so a new sharing pattern is named in sharing.yaml, never silently
    # serialized as an opaque blob.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Sharing)
    if (-not $script:NeoIPCSharingProfiles) { throw 'No sharing profiles loaded (expected a sharing.yaml in the metadata directory).' }
    $canon = Get-NeoIPCSharingCanonicalKey -Sharing $Sharing
    $key = $script:NeoIPCSharingProfiles.ByValue[$canon]
    if (-not $key) { throw "Unrecognized sharing pattern (no matching profile in sharing.yaml): $canon" }
    $key
}

function Expand-NeoIPCSharingProfile {
    # Inverse of Resolve-NeoIPCSharingProfileKey: a profile key from a CSV `sharing` cell -> a fresh DHIS2
    # sharing object (callers may mutate it). Fails loud on an unknown key.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:NeoIPCSharingProfiles) {
        throw "No sharing profiles loaded (expected a sharing.yaml beside the CSVs) — cannot expand sharing key '$Key'."
    }
    if (-not $script:NeoIPCSharingProfiles.ByKey.Contains($Key)) {
        throw "Unknown sharing profile key '$Key' (not defined in sharing.yaml)."
    }
    # Deep-clone the registry template via JSON so a caller never mutates it.
    ConvertFrom-NeoIPCMetadataJsonText -Json ($script:NeoIPCSharingProfiles.ByKey[$Key] | ConvertTo-Json -Compress -Depth 10)
}

function ConvertTo-NeoIPCSharingProfileSpec {
    # Inverse of ConvertTo-NeoIPCSharingFromProfileSpec: a normalized sharing object -> the compact
    # sharing.yaml spec ({public, userGroups:{<code-or-name>:<access>}, users:{<id>:<access>}}) used when
    # writing the file. userGroups are written keyed by the preferred human handle (code, else unique name)
    # via IdToKey; an unmapped id falls back to the literal UID.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Sharing, [hashtable]$IdToKey = @{})
    $spec = [ordered]@{}
    if ($null -ne $Sharing['public']) { $spec['public'] = [string]$Sharing['public'] }
    foreach ($grantKey in 'users', 'userGroups') {
        $grants = $Sharing[$grantKey]
        if ($grants -is [System.Collections.IDictionary] -and $grants.Count -gt 0) {
            $entries = [ordered]@{}
            foreach ($gid in $grants.Keys) {
                $key = if ($grantKey -eq 'userGroups' -and $IdToKey.ContainsKey([string]$gid)) { [string]$IdToKey[[string]$gid] } else { [string]$gid }
                $entries[$key] = [string]$grants[$gid]['access']
            }
            $spec[$grantKey] = $entries
        }
    }
    $spec
}

function Initialize-NeoIPCSharingProfileFromPackage {
    # Build the sharing-profile registry by collecting every distinct sharing shape in a package and minting
    # a deterministic key per shape (sorted by canonical value -> SHARING_NNN). Used when no authored
    # sharing.yaml is present, so emit can still resolve and a self-contained file can be written afterwards.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)
    $byCanon = [ordered]@{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        foreach ($obj in @($Package[$type])) {
            if ($obj -isnot [System.Collections.IDictionary] -or -not $obj.Contains('sharing') -or -not $obj['sharing']) { continue }
            $sharing = Convert-NeoIPCSharing $obj['sharing']
            if ($sharing.Count -eq 0) { continue }
            $canon = Get-NeoIPCSharingCanonicalKey -Sharing $sharing
            if (-not $byCanon.Contains($canon)) { $byCanon[$canon] = $sharing }
        }
    }
    $byKey = [ordered]@{}
    $byValue = @{}
    $i = 0
    # Ordinal (locale-independent) sort so the minted SHARING_NNN numbering is reproducible across machines.
    foreach ($canon in (Get-NeoIPCMetadataOrdinalSort -Values @($byCanon.Keys))) {
        $i++
        $key = 'SHARING_{0:D3}' -f $i
        $byKey[$key] = $byCanon[$canon]
        $byValue[$canon] = $key
    }
    $script:NeoIPCSharingProfiles = @{ ByKey = $byKey; ByValue = $byValue }
}

function Export-NeoIPCSharingProfile {
    # Write the loaded sharing-profile registry to a sharing.yaml (spec form), UTF-8 no-BOM / LF, so a
    # freshly materialised directory is self-contained. A no-op when no profiles are loaded.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [hashtable]$IdToKey = @{})
    if (-not $script:NeoIPCSharingProfiles) { return }
    Import-Module powershell-yaml -ErrorAction Stop
    $doc = [ordered]@{}
    foreach ($key in $script:NeoIPCSharingProfiles.ByKey.Keys) {
        $doc[$key] = ConvertTo-NeoIPCSharingProfileSpec -Sharing $script:NeoIPCSharingProfiles.ByKey[$key] -IdToKey $IdToKey
    }
    $yaml = (ConvertTo-Yaml $doc) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $yaml, [System.Text.UTF8Encoding]::new($false))
}

function Remove-NeoIPCMetadataNoise {
    # Canonical normalizer: recursively removes $script:NeoIPCMetadataStripList keys and the
    # display* prefix family at every depth, normalizes sharing, and drops empty attributeValues
    # (keeps + warns if populated). Mutates and returns the dictionary in place. The comparator
    # reuses this so its ignore set is provably the strip-list (plus translations).
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowNull()]$Object,
        # Set when the parent recursed into an order-significant ref-collection ($NeoIPCMetadataOrderedRefProps):
        # its elements are compared positionally instead of being sorted, mirroring the cell's preserved order.
        [switch]$PreserveOrder
    )
    process {
        if ($Object -is [System.Collections.IDictionary]) {
            foreach ($key in @($Object.Keys)) {
                if ($script:NeoIPCMetadataStripList -contains $key -or
                    $script:NeoIPCMetadataDeferredFields -contains $key) { $Object.Remove($key); continue }
                if ($script:NeoIPCMetadataDisplayProjections -contains $key) { $Object.Remove($key); continue }
                if ($key -eq 'attributeValues') {
                    $values = $Object[$key]
                    if (-not $values -or @($values).Count -eq 0) { $Object.Remove($key); continue }
                    Write-Warning "Retaining non-empty attributeValues on object id '$($Object['id'])'."
                    continue
                }
                if ($key -eq 'sharing') {
                    $normalizedSharing = Convert-NeoIPCSharing $Object[$key]
                    if (@($normalizedSharing.Keys).Count -eq 0) { $Object.Remove($key) } else { $Object[$key] = $normalizedSharing }
                    continue
                }
                $value = $Object[$key]
                # null / empty string / empty dict / empty collection == absent (DHIS2 treats them
                # equivalently on import, and the flat-cell representation cannot distinguish them from
                # absent). The export carries explicit nulls (e.g. an anonymiser nulls an org unit's
                # address/email) and empty {} dicts (e.g. an org unit's unset image) — both must normalise
                # to absent so a source that has them round-trips equal to a directory that omits them.
                if ($null -eq $value -or
                    ($value -is [string] -and $value -eq '') -or
                    ($value -is [System.Collections.IDictionary] -and $value.Count -eq 0) -or
                    ($value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and
                     $value -isnot [System.Collections.IDictionary] -and @($value).Count -eq 0)) {
                    $Object.Remove($key); continue
                }
                $keepOrder = $script:NeoIPCMetadataOrderedRefProps.Contains($key)
                $Object[$key] = Remove-NeoIPCMetadataNoise -Object $Object[$key] -PreserveOrder:$keepOrder
            }
            return $Object
        }
        if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
            $items = @(foreach ($item in $Object) { Remove-NeoIPCMetadataNoise -Object $item })
            # Order-significant collections (DHIS2 <list> mappings whose order is the data and is not
            # recoverable from an element sortOrder — see $NeoIPCMetadataOrderedRefProps) are compared
            # positionally. Every other ref-collection is a set (or its order rides on an element-level
            # sortOrder that survives as data), so sort it deterministically by CANONICAL (key-sorted)
            # JSON: order-insensitive AND dictionary-key-order-insensitive (a round-tripped object emits
            # 'id' first, the source emits it elsewhere; a raw ConvertTo-Json key would mis-sort
            # identical-content elements).
            # Unary comma on every array return: `return $array` STREAMS its elements, so a single-element
            # collection is unwrapped to a scalar on capture — which then serializes as a JSON object, not a
            # 1-element array (DHIS2 import rejects e.g. a one-option optionGroup.options as a HashSet from an
            # object). The round-trip self-test cannot catch this: both sides unwrap symmetrically and compare
            # equal. `,` emits the array as a single item so it survives at any length.
            if ($PreserveOrder) { return , $items }
            return , @($items | Sort-Object -CaseSensitive -Property { (ConvertTo-NeoIPCMetadataCanonical $_) | ConvertTo-Json -Compress -Depth 40 })
        }
        return $Object
    }
}

function Get-NeoIPCMetadataOrdinalSort {
    # Ordinal (culture-invariant, byte-order) sort of a string list, so id/string arrays serialize
    # deterministically across locales. PowerShell's Sort-Object is culture-sensitive; this is not.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Values)
    $arr = [string[]]@($Values)
    [array]::Sort($arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Get-NeoIPCMetadataInt64 {
    # Coerce a JSON-parsed numeric to Int64, rejecting fractional values. A fractional value reaching an
    # int-class property means the type map assigned the wrong class — fail loud rather than silently
    # round (PowerShell's [int]/[long] casts round). Int64 (not Int32) avoids overflow on large counts.
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)]$Value)
    if (($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) -and
        [double]$Value -ne [System.Math]::Truncate([double]$Value)) {
        throw "Non-integer value '$Value' for an int-class property (type map class is wrong)."
    }
    [long]$Value
}

function ConvertTo-NeoIPCMetadataCell {
    # Serialize a typed JSON value to its flat CSV-cell string per the property class. Inverse of
    # ConvertFrom-NeoIPCMetadataCell. 'idArray'/'stringArray'/'intArray' are sorted so the cell is
    # deterministic (the collection is a set, or its order is recoverable from element sortOrder);
    # 'idArrayOrdered' preserves array order because that order is the data (DHIS2 <list> mapping).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Class, $Value)
    switch ($Class) {
        'bool'           { if ($Value -is [bool]) { $Value.ToString() } else { ([bool]::Parse([string]$Value)).ToString() } }
        'int'            { (Get-NeoIPCMetadataInt64 $Value).ToString([cultureinfo]::InvariantCulture) }
        'string'         { [string]$Value }
        'idString'       { [string]$Value }   # bare-string UID ref (e.g. templateUid); serialized like a string
        'id'             { [string]$Value.id }
        'idArray'        { (Get-NeoIPCMetadataOrdinalSort @($Value | ForEach-Object { [string]$_.id })) -join ' ' }
        'idArrayOrdered' { (@($Value | ForEach-Object { [string]$_.id })) -join ' ' }
        'stringArray'    { (Get-NeoIPCMetadataOrdinalSort @($Value | ForEach-Object { [string]$_ })) -join ' ' }
        'intArray'       { (@($Value | ForEach-Object { Get-NeoIPCMetadataInt64 $_ } | Sort-Object) | ForEach-Object { $_.ToString([cultureinfo]::InvariantCulture) }) -join ' ' }
        default          { throw "Unknown property class '$Class'." }
    }
}

function ConvertFrom-NeoIPCMetadataCell {
    # Parse a flat CSV-cell string to its typed JSON value per the property class. Invariant-culture
    # numeric parsing and explicit bool parsing (never the [bool] cast — fixes the slidingWindow flip).
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$Class, [AllowEmptyString()][string]$Cell)
    switch ($Class) {
        'bool'           { [bool]::Parse($Cell) }
        'int'            { [long]::Parse($Cell, [Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture) }
        'string'         { $Cell }
        'idString'       { $Cell }            # bare-string UID ref (e.g. templateUid); parsed like a string
        'id'             { [ordered]@{ id = $Cell } }
        # Unary comma on every array case: a switch branch streams its output, so a single-element collection
        # is unwrapped to a scalar on capture (at ConvertFrom-NeoIPCMetadataRow) — which then serializes as a
        # JSON object, not a 1-element array, and DHIS2 import rejects it. Same hazard, same idiom as the array
        # returns in Remove-NeoIPCMetadataNoise; the round-trip self-test is blind to it (symmetric normalize).
        'idArray'        { , @(Split-NeoIPCMetadataList $Cell | ForEach-Object { [ordered]@{ id = $_ } }) }
        'idArrayOrdered' { , @(Split-NeoIPCMetadataList $Cell | ForEach-Object { [ordered]@{ id = $_ } }) }
        'stringArray'    { , @(Split-NeoIPCMetadataList $Cell) }
        'intArray'       { , @(Split-NeoIPCMetadataList $Cell | ForEach-Object { [long]::Parse($_, [Globalization.NumberStyles]::Integer, [cultureinfo]::InvariantCulture) }) }
        default          { throw "Unknown property class '$Class'." }
    }
}

function ConvertTo-NeoIPCMetadataRow {
    # One package object -> one flat row ([ordered] cells): id + the declared typed properties +
    # normalized sharing (compact JSON) + translations (compact JSON, currently comparator-ignored).
    # Audit/noise is not carried; empty cells round-trip as "property absent".
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)]$Object)
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    if (-not $map) { throw "No type map for object type '$Type'." }
    $row = [ordered]@{ id = [string]$Object['id'] }
    foreach ($prop in $map.Properties.Keys) {
        if ($Object.Contains($prop)) {
            $row[$prop] = ConvertTo-NeoIPCMetadataCell -Class $map.Properties[$prop] -Value $Object[$prop]
        }
    }
    if ($map.Nested) {
        foreach ($np in $map.Nested.Keys) {
            if (-not $Object.Contains($np)) { continue }
            $spec = $map.Nested[$np]
            $sub = $Object[$np]
            if ($sub -isnot [System.Collections.IDictionary]) { continue }
            foreach ($field in $spec.Fields.Keys) {
                if (-not $sub.Contains($field)) { continue }
                $raw = if ($spec.Wrap) { $sub[$field].type } else { $sub[$field] }
                if ($null -ne $raw -and "$raw" -ne '') {
                    $row["${np}_${field}"] = ConvertTo-NeoIPCMetadataCell -Class $spec.Fields[$field] -Value $raw
                }
            }
        }
    }
    if ($Object.Contains('sharing') -and $Object['sharing']) {
        $sharing = Convert-NeoIPCSharing $Object['sharing']
        if ($sharing.Count -gt 0) { $row['sharing'] = Resolve-NeoIPCSharingProfileKey -Sharing $sharing }
    }
    $row
}

function ConvertFrom-NeoIPCMetadataRow {
    # One flat row -> one package object. Inverse of ConvertTo-NeoIPCMetadataRow. An empty cell means
    # the property is absent (an empty string and an absent property are not distinguished).
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)]$Row)
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    if (-not $map) { throw "No type map for object type '$Type'." }
    $obj = [ordered]@{ id = [string]$Row['id'] }
    foreach ($prop in $map.Properties.Keys) {
        if ($Row.Contains($prop) -and -not [string]::IsNullOrEmpty([string]$Row[$prop])) {
            $obj[$prop] = ConvertFrom-NeoIPCMetadataCell -Class $map.Properties[$prop] -Cell ([string]$Row[$prop])
        }
    }
    if ($map.Nested) {
        foreach ($np in $map.Nested.Keys) {
            $spec = $map.Nested[$np]
            $sub = [ordered]@{}
            foreach ($field in $spec.Fields.Keys) {
                $col = "${np}_${field}"
                if ($Row.Contains($col) -and -not [string]::IsNullOrEmpty([string]$Row[$col])) {
                    $val = ConvertFrom-NeoIPCMetadataCell -Class $spec.Fields[$field] -Cell ([string]$Row[$col])
                    $sub[$field] = if ($spec.Wrap) { [ordered]@{ type = $val } } else { $val }
                }
            }
            if ($sub.Count -gt 0) { $obj[$np] = $sub }
        }
    }
    if ($Row.Contains('sharing') -and $Row['sharing']) {
        $obj['sharing'] = Expand-NeoIPCSharingProfile -Key ([string]$Row['sharing'])
    }
    $obj
}

function Get-NeoIPCMetadataNaturalKey {
    # The deterministic-mint SEED for an object, per its type map's NaturalKey recipe (a property
    # name, a composite @('a','b'), or a scriptblock). Id-ref values contribute their inner id.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)]$Object)
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    if (-not $map) { throw "No type map for object type '$Type'." }
    $recipe = $map.NaturalKey
    $valueOf = {
        param($v)
        if ($v -is [System.Collections.IDictionary]) { [string]$v['id'] } else { [string]$v }
    }
    if ($recipe -is [scriptblock]) { return [string]($Object | ForEach-Object $recipe) }
    if ($recipe -is [array]) { return (($recipe | ForEach-Object { & $valueOf $Object[$_] }) -join '|') }
    return (& $valueOf $Object[$recipe])
}

function Resolve-NeoIPCMetadataUid {
    # The single preserve-if-present + collision chokepoint. Keep a valid existing id; otherwise mint
    # deterministically from the natural key. $SeenSet is metadata-set-scoped (pre-populate with all
    # preserved ids before minting); a collision is surfaced as an error, never silently re-rolled.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$SeenSet
    )
    $existing = [string]$Object['id']
    if ($existing -and (Test-NeoIPCMetadataUid -Id $existing)) {
        $uid = $existing
    }
    else {
        $uid = New-NeoIPCMetadataUid -Type $Type -NaturalKey (Get-NeoIPCMetadataNaturalKey -Type $Type -Object $Object)
    }
    if (-not $SeenSet.Add($uid)) {
        throw "UID collision for '$Type' (uid '$uid', natural key '$(Get-NeoIPCMetadataNaturalKey -Type $Type -Object $Object)') — resolve the duplicate natural key or id."
    }
    $uid
}

function ConvertTo-NeoIPCMetadataCanonical {
    # Recursively key-sort dictionaries so two semantically-equal objects serialize identically.
    # (Collections are already ordinal-sorted by Remove-NeoIPCMetadataNoise.) Used by the comparator.
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][AllowNull()]$Object)
    if ($Object -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in (@($Object.Keys) | Sort-Object -CaseSensitive)) { $h["$k"] = ConvertTo-NeoIPCMetadataCanonical $Object[$k] }
        return $h
    }
    if ($Object -is [System.Collections.IEnumerable] -and $Object -isnot [string]) {
        return @(foreach ($i in $Object) { ConvertTo-NeoIPCMetadataCanonical $i })
    }
    return $Object
}

function Get-NeoIPCMetadataDomainOptionSetIds {
    # Resolve the domain-authored optionSet CODES ($NeoIPCMetadataDomainOptionSetCodes) to their UIDs within a
    # package. Those sets' member options live in a richer canonical source (the infectious-agents YAML / the
    # antibiotics CSV), not the directory, so both the directory emit and the comparator drop the sets AND every
    # option whose optionSet is one of them. Returns a HashSet of optionSet UIDs (empty when the package has none).
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory)]$Package)
    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($os in @($Package['optionSets'])) {
        if ($os -is [System.Collections.IDictionary] -and
            $script:NeoIPCMetadataDomainOptionSetCodes.Contains([string]$os['code'])) {
            [void]$ids.Add([string]$os['id'])
        }
    }
    # Unary comma: a HashSet is IEnumerable, so `return $ids` STREAMS its elements — an empty set then collapses
    # to $null on capture (breaking the downstream Mandatory [HashSet] param) and a 1-element set to a scalar.
    # `,` returns the set itself as a single object at any size (same idiom as the array returns above).
    return , $ids
}

function Test-NeoIPCMetadataDomainExcluded {
    # True when an object is domain-authored option content excluded from BOTH the directory and the comparator: a
    # domain optionSet (code in $NeoIPCMetadataDomainOptionSetCodes) or an option belonging to one (its optionSet
    # UID in $DomainSetIds). The single exclusion predicate shared by the emit and the comparator so they agree.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$DomainSetIds
    )
    if ($Type -eq 'optionSets') { return $script:NeoIPCMetadataDomainOptionSetCodes.Contains([string]$Object['code']) }
    if ($Type -eq 'options') {
        $os = $Object['optionSet']
        return ($os -is [System.Collections.IDictionary] -and $DomainSetIds.Contains([string]$os['id']))
    }
    return $false
}

function Get-NeoIPCMetadataGeneratedKeys {
    # Build the per-package identification context for the ontology- / matrix-GENERATED metadata families the
    # directory does NOT materialise (the infectious-agent YAML + capability matrix are their single source — the
    # same families New-NeoIPCMetadataPackage regenerates via Add-NeoIPCGeneratedMetadata). Mirrors
    # Get-NeoIPCMetadataDomainOptionSetIds: resolved once, shared by the directory emit and the round-trip
    # comparator so the two agree on exactly what the directory omits. Identification is taken from the generator
    # PLANS (not a name regex), so it stays exactly in step with what the generators produce:
    #   - generated per-slot pathogen + substance data-element CODES;
    #   - resistance / field-gating / substance program-rule-variable + rule NAMES, each slot-normalised via
    #     ConvertTo-NeoIPCSubstanceUnpaddedName so a deployed unpadded `substance 1` matches the padded plan
    #     `substance 01` (the same padding trap the assembler seam handles), plus the retired rule names;
    #   - ExcludedRuleIds: resolved WITHIN $Package — the UID of every programRule whose (normalised) name is a
    #     generated/retired rule name — so a program-rule action (which carries no name) can be excluded by its
    #     owning-rule id, the same id-membership idiom options use against their optionSet.
    # Counts default to the module-wide slot counts, which match the deployed export the directory is built from.
    #
    # CONSEQUENCE — actions are keyed purely by owning rule, so a HAND-AUTHORED action bundled onto a generated rule
    # drops with that rule too: the BSI no-positive-culture interlock (a HIDEFIELD on NEOIPC_BSI_NO_POS_CULTURE,
    # carried on the regenerated 'when set' rule) is reproduced by no generator yet still leaves the directory here.
    # This is intentional — Add-NeoIPCGeneratedMetadata reinstates it onto the generated rule from the EXPORT (the
    # assembler builds the package from the export, never the directory), so the importable package keeps it;
    # promoting such an interlock to a stand-alone directory business rule belongs to the reconcile path, not this
    # exclusion. The gettext-PO path (MetadataTranslation.ps1) deliberately does NOT apply this predicate — that PO
    # is the sole translation source for the regenerated objects, so excluding them there would drop their translations.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Package,
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount
    )
    $ordinal = [System.StringComparer]::Ordinal

    $deCodes = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($p in @(Get-NeoIPCPathogenDataElementPlan -PathogenCount $PathogenCount)) { [void]$deCodes.Add([string]$p['Code']) }
    foreach ($p in @(Get-NeoIPCSubstanceDataElementPlan -SubstanceCount $SubstanceCount)) { [void]$deCodes.Add([string]$p['Code']) }

    $varNames = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($p in @(Get-NeoIPCPathogenVariablePlan -PathogenCount $PathogenCount)) { [void]$varNames.Add((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))) }
    foreach ($p in @(Get-NeoIPCPathogenFieldGatingVariablePlan -PathogenCount $PathogenCount)) { [void]$varNames.Add((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))) }
    foreach ($p in @(Get-NeoIPCSubstanceVariablePlan -SubstanceCount $SubstanceCount)) { [void]$varNames.Add((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))) }

    $ruleNames = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($p in @(Get-NeoIPCPathogenRulePlan -PathogenCount $PathogenCount)) { [void]$ruleNames.Add((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))) }
    foreach ($p in @(Get-NeoIPCPathogenFieldGatingRulePlan -PathogenCount $PathogenCount)) { [void]$ruleNames.Add((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))) }
    foreach ($p in @(Get-NeoIPCSubstanceRulePlan -SubstanceCount $SubstanceCount)) { [void]$ruleNames.Add((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))) }
    foreach ($n in $script:NeoIPCMetadataRetiredRuleNames) { [void]$ruleNames.Add($n) }

    $excludedRuleIds = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($r in @($Package['programRules'])) {
        if ($r -isnot [System.Collections.IDictionary]) { continue }
        if ($ruleNames.Contains((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$r['name'])))) { [void]$excludedRuleIds.Add([string]$r['id']) }
    }

    [pscustomobject]@{
        DataElementCodes = $deCodes
        VariableNames    = $varNames
        RuleNames        = $ruleNames
        ExcludedRuleIds  = $excludedRuleIds
    }
}

function Test-NeoIPCMetadataGeneratedExcluded {
    # True when an object belongs to an ontology- / matrix-GENERATED family the directory does not materialise, so
    # it is skipped by BOTH the directory emit and the round-trip comparator — exactly as the domain option content
    # is (Test-NeoIPCMetadataDomainExcluded): a generated per-slot pathogen / substance data element (code in
    # DataElementCodes), a resistance / field-gating / substance program-rule variable or rule (slot-normalised
    # name in VariableNames / RuleNames, the latter incl. the retired rules), or a program-rule action whose owning
    # rule is excluded (programRule id in ExcludedRuleIds). The single predicate shared by emit and comparator so
    # they agree on what the directory omits; $GeneratedKeys is one Get-NeoIPCMetadataGeneratedKeys context.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)]$GeneratedKeys
    )
    switch ($Type) {
        'dataElements'         { return $GeneratedKeys.DataElementCodes.Contains([string]$Object['code']) }
        'programRuleVariables' { return $GeneratedKeys.VariableNames.Contains((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$Object['name']))) }
        'programRules'         { return $GeneratedKeys.RuleNames.Contains((ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$Object['name']))) }
        'programRuleActions' {
            $pr = $Object['programRule']
            $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { [string]$pr }
            return $GeneratedKeys.ExcludedRuleIds.Contains($rid)
        }
    }
    return $false
}

function Get-NeoIPCMetadataRowSortKey {
    # Deterministic, human-reviewable row-sort key for a per-type CSV. Row order never affects the
    # round-trip (objects match by id; nested collections are sorted/positional by the normalizer), so the
    # rows are free to be ordered for review. The key groups nested-only rows under their parent (__fk) and
    # options under their optionSet, then orders by sortOrder (zero-padded so 10 sorts after 2) for the types
    # that carry one, then by the natural key (code, else name), and finally by id as a guaranteed-unique,
    # never-empty tiebreaker. Parts are joined with the ASCII unit separator (U+001F — cannot occur in a UID /
    # code / DHIS2 name) and the caller compares the keys ORDINALLY, so the emitted order is identical across
    # locales and machines (matching the module's other ordinal sorts).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)]$Row)
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($map -and $map.Nesting -eq 'NestedOnly') { $parts.Add([string]$Row['__fk']) }
    elseif ($Type -eq 'options') { $parts.Add([string]$Row['optionSet']) }
    if ($map -and $map.Properties.Contains('sortOrder')) {
        $n = 0
        $so = [string]$Row['sortOrder']
        if ([int]::TryParse($so, [ref]$n)) { $parts.Add($n.ToString('D9', [cultureinfo]::InvariantCulture)) }
        else { $parts.Add($so) }
    }
    if ($map -and $map.Properties.Contains('code') -and -not [string]::IsNullOrEmpty([string]$Row['code'])) { $parts.Add([string]$Row['code']) }
    elseif ($map -and $map.Properties.Contains('name') -and -not [string]::IsNullOrEmpty([string]$Row['name'])) { $parts.Add([string]$Row['name']) }
    else { $parts.Add('') }
    $parts.Add([string]$Row['id'])
    return ($parts -join ([char]0x1f))
}

function Get-NeoIPCMetadataSortedRowSet {
    # Reorder a row set by a precomputed, parallel key array — ordinally and deterministically. NOTE: the
    # 3-arg [System.Array]::Sort(keys, items, comparer) does NOT reorder under PowerShell's overload
    # resolution (silently a no-op), so the rows are decorated with their key and sorted via
    # List<object>.Sort with an explicit ordinal Comparison. Every type-map key ends in the unique id, so
    # there are no ties and the (non-stable) sort is fully determined. Keys and rows must be parallel/equal.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Key
    )
    if ($Row.Count -ne $Key.Count) { throw "Get-NeoIPCMetadataSortedRowSet: row/key length mismatch ($($Row.Count) vs $($Key.Count))." }
    $decorated = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Row.Count; $i++) { $decorated.Add([pscustomobject]@{ K = $Key[$i]; R = $Row[$i] }) }
    $decorated.Sort([System.Comparison[object]] { param($x, $y) [System.StringComparer]::Ordinal.Compare([string]$x.K, [string]$y.K) })
    return , [object[]]@($decorated | ForEach-Object { $_.R })
}

function ConvertFrom-NeoIPCMetadataPackage {
    # A parsed DHIS2 package (IDictionary: collection -> object[]) -> per-type flat rows
    # ([ordered] type -> List[row]), each type's rows ordinally sorted by Get-NeoIPCMetadataRowSortKey for
    # stable, human-reviewable diffs. Extracts NestedOnly children out of their parents first
    # (mutating the parents to drop the nested array), then converts every object to a row.
    # System-default objects, excluded/deferred types, and the domain-authored + ontology-generated families
    # (Test-NeoIPCMetadataDomain/GeneratedExcluded) are skipped. MUTATES the input package.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Package)

    $extracted = @{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        if ($map.Nesting -ne 'NestedOnly') { continue }
        $p = $map.Parent
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($parent in @($Package[$p.Type])) {
            if ($parent -isnot [System.Collections.IDictionary] -or -not $parent.Contains($p.ArrayProp)) { continue }
            foreach ($child in @($parent[$p.ArrayProp])) {
                if ($child -is [System.Collections.IDictionary]) {
                    $child['__fk'] = [string]$parent['id']   # carry the parent id for re-nesting
                    $list.Add($child)
                }
            }
            $parent.Remove($p.ArrayProp)
        }
        $extracted[$type] = $list
    }

    $domainSetIds = Get-NeoIPCMetadataDomainOptionSetIds -Package $Package
    $generatedKeys = Get-NeoIPCMetadataGeneratedKeys -Package $Package
    $result = [ordered]@{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        if ($script:NeoIPCMetadataExcludedTypes -contains $type -or $script:NeoIPCMetadataDeferredTypes -contains $type) { continue }
        $objects = if ($map.Nesting -eq 'NestedOnly') { $extracted[$type] } else { @($Package[$type]) }
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($obj in $objects) {
            if ($obj -isnot [System.Collections.IDictionary]) { continue }
            if ($script:NeoIPCMetadataDefaultUids -contains [string]$obj['id']) { continue }
            if (Test-NeoIPCMetadataDomainExcluded -Type $type -Object $obj -DomainSetIds $domainSetIds) { continue }
            if (Test-NeoIPCMetadataGeneratedExcluded -Type $type -Object $obj -GeneratedKeys $generatedKeys) { continue }
            $row = ConvertTo-NeoIPCMetadataRow -Type $type -Object $obj
            if ($map.Nesting -eq 'NestedOnly') { $row['__fk'] = [string]$obj['__fk'] }
            $rows.Add($row)
        }
        if ($rows.Count -gt 0) {
            # Stable, locale-independent row order for clean diffs (does not affect the id-matched round-trip).
            $arr = [object[]]$rows.ToArray()
            $keys = [string[]]@(foreach ($r in $arr) { Get-NeoIPCMetadataRowSortKey -Type $type -Row $r })
            $result[$type] = Get-NeoIPCMetadataSortedRowSet -Row $arr -Key $keys
        }
    }
    return $result
}

function ConvertTo-NeoIPCMetadataPackage {
    # Per-type flat rows -> a parsed DHIS2 package (IDictionary: collection -> object[]).
    # Inverse of ConvertFrom-NeoIPCMetadataPackage: converts rows to objects, then re-nests
    # NestedOnly children into their parents (grouped by the carried parent id), and emits a
    # top-level array only for non-NestedOnly types.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Rows)

    $objectsByType = @{}
    $fkByType = @{}
    foreach ($type in @($Rows.Keys)) {
        $objs = [System.Collections.Generic.List[object]]::new()
        $fks = [System.Collections.Generic.List[string]]::new()
        foreach ($row in @($Rows[$type])) {
            $objs.Add((ConvertFrom-NeoIPCMetadataRow -Type $type -Row $row))
            $fks.Add([string]$row['__fk'])
        }
        $objectsByType[$type] = $objs
        $fkByType[$type] = $fks
    }

    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        if ($map.Nesting -ne 'NestedOnly' -or -not $objectsByType.ContainsKey($type)) { continue }
        $p = $map.Parent
        $index = @{}
        $objs = $objectsByType[$type]; $fks = $fkByType[$type]
        for ($k = 0; $k -lt $objs.Count; $k++) {
            $fk = $fks[$k]
            if (-not $fk) { continue }
            if (-not $index.ContainsKey($fk)) { $index[$fk] = [System.Collections.Generic.List[object]]::new() }
            $index[$fk].Add($objs[$k])
        }
        foreach ($parent in @($objectsByType[$p.Type])) {
            $parentId = [string]$parent['id']
            if ($index.ContainsKey($parentId)) { $parent[$p.ArrayProp] = @($index[$parentId]) }
        }
    }

    $pkg = [ordered]@{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        if ($script:NeoIPCMetadataTypeMaps[$type].Nesting -eq 'NestedOnly') { continue }
        if ($objectsByType.ContainsKey($type)) { $pkg[$type] = @($objectsByType[$type]) }
    }
    return $pkg
}

function Get-NeoIPCMetadataColumns {
    # The canonical, deterministic CSV column order for a type: id, then declared properties, then
    # flattened nested-property columns (`<prop>_<field>`), then sharing, then the carried parent fk
    # for nested-only types. Both the writer and any reader share this so the CSV is git-stable.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Type)
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    if (-not $map) { throw "No type map for object type '$Type'." }
    $cols = [System.Collections.Generic.List[string]]::new()
    $cols.Add('id')
    foreach ($p in $map.Properties.Keys) { $cols.Add($p) }
    if ($map.Nested) { foreach ($np in $map.Nested.Keys) { foreach ($f in $map.Nested[$np].Fields.Keys) { $cols.Add("${np}_${f}") } } }
    $cols.Add('sharing')
    if ($map.Nesting -eq 'NestedOnly') { $cols.Add('__fk') }
    return $cols.ToArray()
}

function ConvertTo-NeoIPCCsvField {
    # RFC 4180 field escaping: quote (and double internal quotes) only when the value contains a
    # comma, quote, CR/LF, or has significant leading/trailing whitespace. Minimal quoting -> clean diffs.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value -match '[,"\r\n]' -or $Value -ne $Value.Trim()) { return '"' + ($Value -replace '"', '""') + '"' }
    return $Value
}

function Write-NeoIPCMetadataCsv {
    # Write rows to a CSV with a fixed column order, UTF-8 no-BOM, and LF line endings (cross-platform,
    # git-stable). Cells absent from a row are written empty (== "property absent" on read-back).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Columns, [Parameter(Mandatory)]$Rows)
    $writer = [System.IO.StreamWriter]::new($Path, $false, [System.Text.UTF8Encoding]::new($false))
    $writer.NewLine = "`n"
    try {
        $writer.WriteLine((($Columns | ForEach-Object { ConvertTo-NeoIPCCsvField $_ }) -join ','))
        foreach ($row in $Rows) {
            $writer.WriteLine((($Columns | ForEach-Object { ConvertTo-NeoIPCCsvField ([string]$row[$_]) }) -join ','))
        }
    }
    finally { $writer.Dispose() }
}

function Read-NeoIPCMetadataCsv {
    # Read a CSV into ordered-hashtable rows (every cell a string; empty cells preserved as '').
    # Import-Csv handles RFC 4180 parsing (quoted commas/newlines) and BOM/no-BOM transparently.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([Parameter(Mandatory)][string]$Path)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in (Import-Csv -Path $Path)) {
        $row = [ordered]@{}
        foreach ($prop in $record.PSObject.Properties) { $row[$prop.Name] = [string]$prop.Value }
        $rows.Add($row)
    }
    return $rows
}

function Compare-NeoIPCMetadataCore {
    # Semantic diff of two parsed packages. Both sides are normalized via Remove-NeoIPCMetadataNoise
    # (so the strip-list + deferred fields are ignored by construction) and matched by id per type.
    # Excluded/deferred whole types are skipped. Returns structured diff records; empty == equal.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([Parameter(Mandatory)]$Reference, [Parameter(Mandatory)]$Difference)
    $diffs = [System.Collections.Generic.List[object]]::new()
    $types = @(@($Reference.Keys) + @($Difference.Keys) | Select-Object -Unique)
    # Domain-authored option content (the NEOIPC_PATHOGENS / NEOIPC_ANTIMICROBIAL_SUBSTANCES sets + their options)
    # is excluded from the directory, so a directory-derived package will not carry it; resolve the set UIDs from
    # whichever side has them (union) and skip both sets and their options on both sides, exactly as for excluded
    # types — their absence is a known, intentional non-difference, not a Removed/Added/Changed.
    $domainSetIds = Get-NeoIPCMetadataDomainOptionSetIds -Package $Reference
    $domainSetIds.UnionWith((Get-NeoIPCMetadataDomainOptionSetIds -Package $Difference))
    # Generated families (pathogen / substance / resistance / field-gating) are likewise directory-omitted: skip
    # them on both sides so their absence on a directory-derived side is not a false Removed/Added. The plan-derived
    # codes/names are package-independent; ExcludedRuleIds (action owning-rule ids) is resolved per side, so union it
    # — the export side carries the generated rules+actions, a directory side does not.
    $generatedKeys = Get-NeoIPCMetadataGeneratedKeys -Package $Reference
    $generatedKeys.ExcludedRuleIds.UnionWith((Get-NeoIPCMetadataGeneratedKeys -Package $Difference).ExcludedRuleIds)
    foreach ($type in $types) {
        if (-not $script:NeoIPCMetadataTypeMaps.Contains($type)) { continue }                  # out-of-scope top-level key
        if ($script:NeoIPCMetadataTypeMaps[$type].Nesting -eq 'NestedOnly') { continue }        # compared via its parent
        if ($script:NeoIPCMetadataExcludedTypes -contains $type -or $script:NeoIPCMetadataDeferredTypes -contains $type) { continue }
        $refById = @{}
        foreach ($o in @($Reference[$type])) {
            if ($o -isnot [System.Collections.IDictionary] -or $script:NeoIPCMetadataDefaultUids -contains [string]$o['id']) { continue }
            if (Test-NeoIPCMetadataDomainExcluded -Type $type -Object $o -DomainSetIds $domainSetIds) { continue }
            if (Test-NeoIPCMetadataGeneratedExcluded -Type $type -Object $o -GeneratedKeys $generatedKeys) { continue }
            $refById[[string]$o['id']] = (Remove-NeoIPCMetadataNoise -Object $o)
        }
        $difById = @{}
        foreach ($o in @($Difference[$type])) {
            if ($o -isnot [System.Collections.IDictionary] -or $script:NeoIPCMetadataDefaultUids -contains [string]$o['id']) { continue }
            if (Test-NeoIPCMetadataDomainExcluded -Type $type -Object $o -DomainSetIds $domainSetIds) { continue }
            if (Test-NeoIPCMetadataGeneratedExcluded -Type $type -Object $o -GeneratedKeys $generatedKeys) { continue }
            $difById[[string]$o['id']] = (Remove-NeoIPCMetadataNoise -Object $o)
        }
        foreach ($id in $refById.Keys) { if (-not $difById.ContainsKey($id)) { $diffs.Add([pscustomobject]@{ Type = $type; Id = $id; Kind = 'Removed' }) } }
        foreach ($id in $difById.Keys) { if (-not $refById.ContainsKey($id)) { $diffs.Add([pscustomobject]@{ Type = $type; Id = $id; Kind = 'Added' }) } }
        foreach ($id in $refById.Keys) {
            if (-not $difById.ContainsKey($id)) { continue }
            $a = (ConvertTo-NeoIPCMetadataCanonical $refById[$id]) | ConvertTo-Json -Compress -Depth 40
            $b = (ConvertTo-NeoIPCMetadataCanonical $difById[$id]) | ConvertTo-Json -Compress -Depth 40
            if ($a -ne $b) { $diffs.Add([pscustomobject]@{ Type = $type; Id = $id; Kind = 'Changed'; Reference = $a; Difference = $b }) }
        }
    }
    return $diffs
}
