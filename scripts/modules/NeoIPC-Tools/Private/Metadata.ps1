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
    # Normalize a sharing object to {public[, non-empty users][, non-empty userGroups]}.
    # Drops owner/external/empty grants (provenance/noise) while preserving real authorization
    # intent (public is NOT uniform across objects, so it must round-trip as data).
    param($Sharing)
    # A non-dictionary sharing (null, or a legacy scalar grant string) carries no normalizable intent;
    # return an empty map so the emit path ($result.Count) and the comparator (@($result.Keys).Count)
    # agree to drop it, rather than one keeping a scalar the other discards.
    if ($Sharing -isnot [System.Collections.IDictionary]) { return [ordered]@{} }
    $result = [ordered]@{}
    if ($null -ne $Sharing['public']) { $result['public'] = $Sharing['public'] }
    foreach ($grantKey in 'users', 'userGroups') {
        $grants = $Sharing[$grantKey]
        if ($grants -is [System.Collections.IDictionary] -and $grants.Count -gt 0) {
            $result[$grantKey] = $grants
        }
    }
    $result
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
        if ($sharing.Count -gt 0) { $row['sharing'] = ($sharing | ConvertTo-Json -Compress -Depth 5) }
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
        $obj['sharing'] = ConvertFrom-NeoIPCMetadataJsonText -Json $Row['sharing']
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

function ConvertFrom-NeoIPCMetadataPackage {
    # A parsed DHIS2 package (IDictionary: collection -> object[]) -> per-type flat rows
    # ([ordered] type -> List[row]). Extracts NestedOnly children out of their parents first
    # (mutating the parents to drop the nested array), then converts every object to a row.
    # System-default objects and excluded/deferred types are skipped. MUTATES the input package.
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

    $result = [ordered]@{}
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $map = $script:NeoIPCMetadataTypeMaps[$type]
        if ($script:NeoIPCMetadataExcludedTypes -contains $type -or $script:NeoIPCMetadataDeferredTypes -contains $type) { continue }
        $objects = if ($map.Nesting -eq 'NestedOnly') { $extracted[$type] } else { @($Package[$type]) }
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($obj in $objects) {
            if ($obj -isnot [System.Collections.IDictionary]) { continue }
            if ($script:NeoIPCMetadataDefaultUids -contains [string]$obj['id']) { continue }
            $row = ConvertTo-NeoIPCMetadataRow -Type $type -Object $obj
            if ($map.Nesting -eq 'NestedOnly') { $row['__fk'] = [string]$obj['__fk'] }
            $rows.Add($row)
        }
        if ($rows.Count -gt 0) { $result[$type] = $rows }
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
    foreach ($type in $types) {
        if (-not $script:NeoIPCMetadataTypeMaps.Contains($type)) { continue }                  # out-of-scope top-level key
        if ($script:NeoIPCMetadataTypeMaps[$type].Nesting -eq 'NestedOnly') { continue }        # compared via its parent
        if ($script:NeoIPCMetadataExcludedTypes -contains $type -or $script:NeoIPCMetadataDeferredTypes -contains $type) { continue }
        $refById = @{}
        foreach ($o in @($Reference[$type])) { if ($o -is [System.Collections.IDictionary] -and $script:NeoIPCMetadataDefaultUids -notcontains [string]$o['id']) { $refById[[string]$o['id']] = (Remove-NeoIPCMetadataNoise -Object $o) } }
        $difById = @{}
        foreach ($o in @($Difference[$type])) { if ($o -is [System.Collections.IDictionary] -and $script:NeoIPCMetadataDefaultUids -notcontains [string]$o['id']) { $difById[[string]$o['id']] = (Remove-NeoIPCMetadataNoise -Object $o) } }
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
