# NeoIPC metadata pipeline — expression analysis + source transforms (private, not exported).
# Node-free (PowerShell/regex): no @dhis2/expression-parser dependency — NeoIPC's expressions reference
# variables by name (resolved structurally), and the issue classes linted below all parse/validate clean,
# so a parser would add nothing the closure and these regex passes don't already cover.
# Three concerns, all over DHIS2 expression text and embedded UID tokens:
#   (A) LINT  — flag the issue classes the parser does NOT catch (they all parse/validate clean):
#               mixed &&/|| precedence, negative-sentinel (== -1) comparisons, and the legacy
#               name-argument d2-function form (a style/forward-safety finding the canonicalizer fixes).
#   (B) CANONICALIZE — rewrite the name-argument d2-functions to the quoted-name form, byte-for-byte
#               the rewrite Tracker Capture's vendored engine applies (avoidReplacementFunctions), so the
#               SOURCE is engine-version-independent and forward-safe.
#   (C) REGENERATE UIDS — re-mint every owned object id and rewrite every reference (structured {id} AND
#               expression-embedded #{uid.uid} / I{uid}) consistently via a single bounded-token pass.
# The closure engine (Private/MetadataClosure.ps1) has the read-only expression-UID EXTRACTOR; this file
# is the WRITE/ANALYSIS side. Public cmdlets (Test-NeoIPCMetadataExpression / Update-NeoIPCMetadata) wrap these.

# The five d2-functions whose first argument is a program-rule-variable NAME, not a value — so the engine
# rewrites #{var}/A{var}/C{var}/V{var} -> 'var' BEFORE value substitution. Mirrors, verbatim and in order,
# refs/tracker-capture-app d2-tracker/dhis2.angular.services.js `avoidReplacementFunctions` (~line 1842),
# the engine NeoIPC's Tracker Capture client actually runs (byte-identical on v40 and v41).
$script:NeoIPCMetadataAvoidReplacementFunctions = @('d2:hasValue', 'd2:lastEventDate', 'd2:count', 'd2:countIfZeroPos', 'd2:countIfValue')

# Expression-bearing fields per top-level type. Dotted paths are exactly one level deep (the validation-rule
# leftSide/rightSide sub-objects). The precedence and negative-sentinel lint rules walk ALL of these (they are
# valid in any DHIS2 expression context), and never touch incidental expression-looking text elsewhere (e.g. a
# notification messageTemplate).
$script:NeoIPCMetadataExpressionFields = [ordered]@{
    programRules       = @('condition')
    programRuleActions = @('data')
    programIndicators  = @('expression', 'filter')
    validationRules    = @('leftSide.expression', 'rightSide.expression')
}

# The subset of expression fields evaluated by Tracker Capture's client engine — the ONLY contexts where the
# name-arg d2-functions take a program-rule-VARIABLE name and where the avoidReplacementFunctions rewrite is
# semantically valid. The canonicalizer and the LegacyD2FunctionArgForm lint are restricted to these: in a
# program-indicator / validation-rule (server-side) expression, `d2:count(#{ps.de})` is a genuine data-item
# reference, and rewriting it to `d2:count('ps.de')` would corrupt it into a (nonexistent) variable name.
$script:NeoIPCMetadataCanonicalFields = [ordered]@{
    programRules       = @('condition')
    programRuleActions = @('data')
}

# Engine-faithful per-function rewrite: (d2:func\() *[A#CV]\{<name>\} -> $1'$2'. The character class for
# the variable name is the engine's [\w \-\_\.] spelled out as ASCII (\w in .NET is Unicode by default; the
# JS engine is ASCII, and all 314 NeoIPC variable names are ASCII), so the match set is identical.
$script:NeoIPCMetadataD2NameArgClass = '[A-Za-z0-9_ .\-]+'

function ConvertTo-NeoIPCCanonicalExpression {
    # Rewrite the name-argument d2-functions in a single expression to the quoted-name form. Idempotent:
    # an already-canonical expression (no #/A/C/V{…} inside an avoid-function call) is returned unchanged.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expression)
    $result = $Expression
    foreach ($fn in $script:NeoIPCMetadataAvoidReplacementFunctions) {
        $pattern = '(' + [regex]::Escape($fn) + '\() *[A#CV]\{(' + $script:NeoIPCMetadataD2NameArgClass + ')\}'
        $result = [regex]::Replace($result, $pattern, "`$1'`$2'")
    }
    return $result
}

function Test-NeoIPCMetadataPrecedenceAmbiguity {
    # True when a SINGLE parenthesised group directly contains both && and || (ambiguous precedence — &&
    # binds tighter than ||). A stack holds one operator-set per currently-open group, so SIBLING groups at
    # the same depth ((a||b) && (c&&d)) are kept distinct and NOT flagged; only a group like `a && b || c`
    # is. Quoted-string and {curly-brace name} spans are skipped so literal operators / spaces inside them
    # don't count.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expression)
    $stack = [System.Collections.Generic.List[System.Collections.Generic.HashSet[string]]]::new()
    $stack.Add([System.Collections.Generic.HashSet[string]]::new())
    $i = 0; $n = $Expression.Length
    while ($i -lt $n) {
        $c = $Expression[$i]
        if ($c -eq "'" -or $c -eq '"') {
            $q = $c; $i++
            while ($i -lt $n -and $Expression[$i] -ne $q) { $i++ }
            $i++; continue
        }
        if ($c -eq '{') {
            while ($i -lt $n -and $Expression[$i] -ne '}') { $i++ }
            $i++; continue
        }
        if ($c -eq '(') { $stack.Add([System.Collections.Generic.HashSet[string]]::new()); $i++; continue }
        if ($c -eq ')') {
            if ($stack.Count -gt 1) {
                $grp = $stack[$stack.Count - 1]; $stack.RemoveAt($stack.Count - 1)
                if ($grp.Contains('&&') -and $grp.Contains('||')) { return $true }
            }
            $i++; continue
        }
        if ($i + 1 -lt $n -and $c -eq '&' -and $Expression[$i + 1] -eq '&') { [void]$stack[$stack.Count - 1].Add('&&'); $i += 2; continue }
        if ($i + 1 -lt $n -and $c -eq '|' -and $Expression[$i + 1] -eq '|') { [void]$stack[$stack.Count - 1].Add('||'); $i += 2; continue }
        $i++
    }
    foreach ($s in $stack) { if ($s.Contains('&&') -and $s.Contains('||')) { return $true } }
    return $false
}

function Get-NeoIPCMetadataExpressionFinding {
    # Run the three NeoIPC-specific lint rules on a single expression string; return finding objects.
    # Severities: precedence + negative-sentinel are Warning (likely bug); legacy-arg-form is Info (style /
    # the canonicalizer's target). The parser would pass all three, which is why they are linted here.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expression,
        [string]$ObjectType,
        [string]$ObjectId,
        [string]$ObjectName,
        [string]$Field
    )
    $out = [System.Collections.Generic.List[object]]::new()

    if (Test-NeoIPCMetadataPrecedenceAmbiguity -Expression $Expression) {
        $out.Add([pscustomobject]@{
                Rule = 'MixedBooleanPrecedence'; Severity = 'Warning'
                ObjectType = $ObjectType; ObjectId = $ObjectId; ObjectName = $ObjectName; Field = $Field
                Message = 'A parenthesised group mixes && and || directly; && binds tighter than || — verify the intended grouping and add parentheses to make it explicit.'
                Expression = $Expression
            })
    }

    # Lookahead excludes digits, '.', and the exponent marker e/E so a longer numeric literal (-10, -1.5, -1e5)
    # is not misread as the -1 sentinel.
    $sentinel = [regex]::Matches($Expression, '(==|!=)\s*-\s*1(?![0-9.eE])')
    if ($sentinel.Count -gt 0) {
        $out.Add([pscustomobject]@{
                Rule = 'NegativeSentinelComparison'; Severity = 'Warning'
                ObjectType = $ObjectType; ObjectId = $ObjectId; ObjectName = $ObjectName; Field = $Field
                Message = ('Equality/inequality comparison against -1 ({0} occurrence(s)); for a yes/no or categorical data item this is almost certainly a typo (e.g. should be "!= 1").' -f $sentinel.Count)
                Expression = $Expression
            })
    }

    # The legacy-arg-form rule (and the canonicalizer it points to) only applies in the Tracker-Capture-evaluated
    # fields, where the name-arg d2-functions take a program-rule-variable NAME. In a server-side
    # program-indicator / validation-rule expression, `d2:count(#{ps.de})` is a valid data-item reference, not a
    # legacy form — flagging it there would be a false positive and "canonicalizing" it would corrupt it.
    $legacy = 0
    if ($script:NeoIPCMetadataCanonicalFields[$ObjectType] -contains $Field) {
        foreach ($fn in $script:NeoIPCMetadataAvoidReplacementFunctions) {
            $pattern = '(' + [regex]::Escape($fn) + '\() *[A#CV]\{(' + $script:NeoIPCMetadataD2NameArgClass + ')\}'
            $legacy += ([regex]::Matches($Expression, $pattern)).Count
        }
    }
    if ($legacy -gt 0) {
        $out.Add([pscustomobject]@{
                Rule = 'LegacyD2FunctionArgForm'; Severity = 'Info'
                ObjectType = $ObjectType; ObjectId = $ObjectId; ObjectName = $ObjectName; Field = $Field
                Message = ("{0} name-argument d2-function call(s) use the #/A/C/V{{...}} reference form; the canonical, forward-safe form is the quoted name. Run Update-NeoIPCMetadata -Canonicalize." -f $legacy)
                Expression = $Expression
            })
    }
    return $out
}

function Get-NeoIPCMetadataExpressionSlot {
    # Enumerate the writable expression slots on one object: { Path; Container; Key; Value }. Container is the
    # dictionary that directly holds Key (the object itself, or its leftSide/rightSide sub-object), so callers
    # read/write via $slot.Container[$slot.Key]. Only non-empty string slots are returned. FieldMap selects which
    # fields to enumerate: all expression fields (the default, for linting) or the canonicalizable subset.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Type,
        [System.Collections.IDictionary]$FieldMap = $script:NeoIPCMetadataExpressionFields
    )
    $out = [System.Collections.Generic.List[object]]::new()
    $fields = $FieldMap[$Type]
    if (-not $fields) { return $out }
    foreach ($path in $fields) {
        $container = $Object
        $key = $path
        if ($path.Contains('.')) {
            $parts = $path.Split('.')
            $container = $Object[$parts[0]]
            $key = $parts[1]
        }
        if ($container -isnot [System.Collections.IDictionary]) { continue }
        $val = $container[$key]
        if ($val -is [string] -and $val.Length -gt 0) {
            $out.Add([pscustomobject]@{ Path = $path; Container = $container; Key = $key; Value = $val })
        }
    }
    return $out
}

function Get-NeoIPCMetadataOwnedId {
    # Collect every OWNED object identity in a package: each mapped, non-excluded top-level object's id + each
    # declared nested-only child's id (programStageDataElements / programTrackedEntityAttributes /
    # trackedEntityTypeAttributes / analyticsPeriodBoundaries, reached via their Parent.ArrayProp). Scoped to the
    # SAME types the closure / converter / comparator handle (iterate the type maps; skip NestedOnly — reached via
    # parent — and the excluded stop-types), so the import-time overlay / PII / server-generated collections
    # (org units, users, category option combos, …) keep their UIDs even when present top-level in a full export.
    # The four fixed system default UIDs are likewise never re-minted (they are present on every instance; the
    # default categoryCombo is referenced by every dataElement). It does NOT collect arbitrary {id} ref targets,
    # so an absent overlay reference is never mistaken for something we own. Nested-only types nest only one level
    # under their parent in DHIS2, so a single descent is complete.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory)]$Package)
    $childArrays = @{}
    foreach ($t in $script:NeoIPCMetadataTypeMaps.Keys) {
        $m = $script:NeoIPCMetadataTypeMaps[$t]
        if ($m.Nesting -eq 'NestedOnly' -and $m.Parent) {
            $pt = $m.Parent.Type
            if (-not $childArrays.ContainsKey($pt)) { $childArrays[$pt] = [System.Collections.Generic.List[string]]::new() }
            $childArrays[$pt].Add($m.Parent.ArrayProp)
        }
    }
    $owned = [System.Collections.Generic.HashSet[string]]::new()
    $add = {
        param($id)
        if ($id -and $script:NeoIPCMetadataDefaultUids -notcontains $id) { [void]$owned.Add([string]$id) }
    }
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        if ($script:NeoIPCMetadataTypeMaps[$type].Nesting -eq 'NestedOnly') { continue }   # reached via its parent's child array
        if ($script:NeoIPCMetadataExcludedTypes -contains $type) { continue }              # import-time overlays / PII / server-generated
        foreach ($o in @($Package[$type])) {
            if ($o -isnot [System.Collections.IDictionary]) { continue }
            & $add ([string]$o['id'])
            if ($childArrays.ContainsKey($type)) {
                foreach ($ap in $childArrays[$type]) {
                    foreach ($child in @($o[$ap])) {
                        if ($child -is [System.Collections.IDictionary]) { & $add ([string]$child['id']) }
                    }
                }
            }
        }
    }
    return $owned
}

function New-NeoIPCMetadataUidMap {
    # Build old-UID -> new-UID for every owned id. The new UID is a deterministic mint salted by the OLD id
    # (not the natural key) so regeneration is pure, repeatable across machines, and independent of whether a
    # natural key can be derived for every nested child. Collisions are astronomically unlikely but checked.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Package)
    $owned = Get-NeoIPCMetadataOwnedId -Package $Package
    $map = @{}
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($old in $owned) {
        $new = New-NeoIPCMetadataUid -Type 'uid-regeneration' -NaturalKey $old
        if (-not $seen.Add($new)) { throw "UID regeneration collision: two source ids mint the same new UID ('$new')." }
        $map[$old] = $new
    }
    return $map
}

function Convert-NeoIPCMetadataUidString {
    # Rewrite every standalone UID token in one string using $Map; tokens absent from $Map (overlay refs,
    # codes, free text) are left untouched. The lookbehind/lookahead require the 11-char UID to be bounded
    # by non-alphanumerics, so an 11-char run inside a longer token (or a code with separators) never matches.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [Parameter(Mandatory)][hashtable]$Map)
    if ($Value.Length -lt 11) { return $Value }
    $evaluator = {
        param($m)
        if ($Map.ContainsKey($m.Value)) { $Map[$m.Value] } else { $m.Value }
    }.GetNewClosure()
    # Boundary excludes '_' too (DHIS2 UIDs never contain one), so a UID-shaped substring inside a
    # snake_case code/name can't be mistaken for a reference and rewritten.
    return [regex]::Replace($Value, '(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]{10}(?![A-Za-z0-9_])', $evaluator)
}

function Update-NeoIPCMetadataUidToken {
    # Recursively rewrite UID tokens in every string value of an object tree (in place): id fields,
    # structured {id} references, and expression-embedded UIDs are all handled by the same bounded-token pass.
    [CmdletBinding()]
    param([AllowNull()]$Node, [Parameter(Mandatory)][hashtable]$Map)
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            $v = $Node[$k]
            if ($v -is [string]) { $Node[$k] = Convert-NeoIPCMetadataUidString -Value $v -Map $Map }
            else { Update-NeoIPCMetadataUidToken -Node $v -Map $Map }
        }
    }
    elseif ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            $v = $Node[$i]
            if ($v -is [string]) { $Node[$i] = Convert-NeoIPCMetadataUidString -Value $v -Map $Map }
            else { Update-NeoIPCMetadataUidToken -Node $v -Map $Map }
        }
    }
}

function Update-NeoIPCMetadataPackage {
    # Apply the requested transforms to a CLONE of the package (the input is never mutated). Returns a
    # hashtable: Package (the transformed clone) + per-transform counts (+ UidMap when regenerating).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Package,
        [switch]$Canonicalize,
        [switch]$RegenerateUids
    )
    # Deep clone via JSON round-trip (the package is JSON-origin; PS 7.5 -AsHashtable preserves key order).
    $clone = $Package | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $canonCount = 0
    if ($Canonicalize) {
        foreach ($type in $script:NeoIPCMetadataCanonicalFields.Keys) {
            foreach ($o in @($clone[$type])) {
                if ($o -isnot [System.Collections.IDictionary]) { continue }
                foreach ($slot in (Get-NeoIPCMetadataExpressionSlot -Object $o -Type $type -FieldMap $script:NeoIPCMetadataCanonicalFields)) {
                    $new = ConvertTo-NeoIPCCanonicalExpression -Expression $slot.Value
                    if ($new -cne $slot.Value) { $slot.Container[$slot.Key] = $new; $canonCount++ }
                }
            }
        }
    }
    $map = @{}
    if ($RegenerateUids) {
        $map = New-NeoIPCMetadataUidMap -Package $clone
        Update-NeoIPCMetadataUidToken -Node $clone -Map $map
    }
    return @{
        Package            = $clone
        CanonicalizedSlots = $canonCount
        RegeneratedUids    = $map.Count
        UidMap             = $map
    }
}
