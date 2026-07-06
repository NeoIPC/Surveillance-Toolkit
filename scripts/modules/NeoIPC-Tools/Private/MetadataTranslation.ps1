# NeoIPC metadata translations <-> gettext PO engine.
#
# DHIS2 carries i18n inline on every object as translations[] = [{ property, locale, value }] (the property is
# the uppercase ObjectTranslation TOKEN — NAME, SHORT_NAME, ...; verified against refs/dhis2-core
# translation/Translation.java + Translatable.java, see MetadataTypeMaps.ps1). The reviewable, translator-facing
# form is a bilingual gettext PO (msgid = English source, msgstr = translation; one component beside the reports'
# documentation/glossary PO), disambiguated by a stable msgctxt: a metadata.pot
# template (English source) plus one metadata.<lang>.po per language, keyed by a stable msgctxt so a re-export
# never orphans a translation in Weblate.
#
#   msgctxt = "<type>/<key>/<TOKEN>"   key = optionSetCode/optionCode for options, else code, else id (the UID for
#                                      code-less types — not UID-regeneration-stable; the readable meaning is the msgid)
#   msgid   = the object's English/default base property value (e.g. its `name`)
#   msgstr  = the translated value (empty in the .pot)
#
# Two intermediate shapes flow through here:
#   UNIT  = { Type, Key, Property, Token, Msgctxt, Msgid, ObjectId, Translations(locale->value) } — extracted
#           from a package, one per (object, translatable field). Carries every locale's value at once.
#   ENTRY = { Msgctxt, Msgid, Msgstr, Fuzzy } — a single PO record for ONE language; what gets written/read/merged.
#
# Emit/parse/merge/inject are pure PowerShell (no external process), so the whole round-trip is Pester-testable on
# a standalone checkout — mirroring how the reports' glossary PO is managed in code (scripts/update-glossary-po.py),
# not via the msgmerge CLI. This engine never calls the DHIS2 API. PO output is UTF-8; msgfmt (WSL) can validate it.

function Get-NeoIPCMetadataTranslatableField {
    # The ordered (property, token) pairs translatable on a type: the INTERSECTION of the type map's mapped
    # Properties with $NeoIPCMetadataTranslatableProperties, so the set auto-tracks the type maps (a property
    # that isn't structurally carried is not translated either — base value and translation stay in lockstep).
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([Parameter(Mandatory)][string]$Type)
    $fields = [System.Collections.Generic.List[object]]::new()
    $map = $script:NeoIPCMetadataTypeMaps[$Type]
    if (-not $map) { return , $fields }
    foreach ($prop in $map.Properties.Keys) {
        if ($script:NeoIPCMetadataTranslatableProperties.Contains($prop)) {
            $fields.Add([ordered]@{ Property = $prop; Token = $script:NeoIPCMetadataTranslatableProperties[$prop] })
        }
    }
    return , $fields
}

function Get-NeoIPCMetadataOptionSetCodeIndex {
    # { optionSet UID -> optionSet code } from a package, so an option (which references its set by {id}) can be
    # keyed by the human-stable optionSet CODE rather than the UID in its translation msgctxt.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Package)
    $index = @{}
    foreach ($os in @($Package['optionSets'])) {
        if ($os -is [System.Collections.IDictionary] -and $os['id'] -and $os['code']) {
            $index[[string]$os['id']] = [string]$os['code']
        }
    }
    $index
}

function Get-NeoIPCMetadataGeneratedTranslationKeyIndex {
    # Build the lookup that gives every ontology/matrix-GENERATED code-less object (resistance / field-gating /
    # substance program-rule VARIABLES, RULES and their ACTIONS) a stable, name-independent translation key, so the
    # gettext msgctxt of those entries is a semantic key mirroring the DE code scheme (NEOIPC_BSI_PATHOGEN_1_SET_3GCR)
    # instead of the volatile minted UID. The key is derived from the generator PLANS — the same plans
    # Get-NeoIPCMetadataGeneratedKeys identifies the families from — so it stays in step with what the generators
    # produce and is independent of the display NAME: a reworded rule keeps its msgctxt (only the msgid changes, which
    # fuzzes the translation for re-review) and an added slot inserts a LOCAL block instead of reshuffling the whole
    # catalogue. Generated DATA ELEMENTS are NOT in this index — they already carry a stable code, so they key by code.
    # The lookup is by the object's slot-normalised name (variables / rules) or, for actions (which carry no name),
    # by the owning-rule id resolved within the package. Slot counts default to the module-wide counts, matching the
    # deployed export the package is built from.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Package,
        [ValidateRange(1, 9)][int]$PathogenCount = $script:NeoIPCPathogenSlotCount,
        [ValidateRange(1, 99)][int]$SubstanceCount = $script:NeoIPCSubstanceSlotCount
    )
    $ordinal = [System.StringComparer]::Ordinal
    $varKeyByName = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    $ruleKeyByName = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)

    foreach ($p in @(Get-NeoIPCPathogenVariablePlan -PathogenCount $PathogenCount)) {
        $base = Get-NeoIPCPathogenSlotBaseCode -Stage $p['Stage'] -SlotKind $p['SlotKind'] -Index $p['Index']
        $key = if ($p['Kind'] -eq 'value') { "${base}_VALUE" } else { "${base}_MAYBE_$($script:NeoIPCResistanceDeSuffixByCategory[$p['Category']])" }
        $varKeyByName[(ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))] = $key
    }
    foreach ($p in @(Get-NeoIPCPathogenFieldGatingVariablePlan -PathogenCount $PathogenCount)) {
        $base = Get-NeoIPCPathogenSlotBaseCode -Stage $p['Stage'] -SlotKind $p['SlotKind'] -Index $p['Index']
        $varKeyByName[(ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))] = "${base}_IS_RECOGNIZED"
    }
    foreach ($p in @(Get-NeoIPCSubstanceVariablePlan -SubstanceCount $SubstanceCount)) {
        # The substance/days DE code IS the slot base for these PRVs (each reads its DE on the current event).
        $varKeyByName[(ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))] = "$([string]$p['DataElementCode'])_VALUE"
    }

    foreach ($p in @(Get-NeoIPCPathogenRulePlan -PathogenCount $PathogenCount)) {
        $base = Get-NeoIPCPathogenSlotBaseCode -Stage $p['Stage'] -SlotKind $p['SlotKind'] -Index $p['Index']
        $cat = $script:NeoIPCResistanceDeSuffixByCategory[$p['Category']]
        $role = switch ($p['Kind']) { 'set' { "SET_$cat" } 'mayBe' { "MAYBE_$cat" } 'not' { "NOT_$cat" } }
        $ruleKeyByName[(ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))] = "${base}_$role"
    }
    foreach ($p in @(Get-NeoIPCPathogenFieldGatingRulePlan -PathogenCount $PathogenCount)) {
        $base = Get-NeoIPCPathogenSlotBaseCode -Stage $p['Stage'] -SlotKind $p['SlotKind'] -Index $p['Index']
        $role = switch ($p['Kind']) {
            'recognizedPathogen' { 'SET_RECOGNIZED' }
            'whenSet' { 'WHEN_SET' }
            'whenEmpty' { 'WHEN_EMPTY' }
            'whenEmptyOrListed' { 'WHEN_EMPTY_OR_LISTED' }
            'whenNotListed' { 'WHEN_NOT_LISTED' }
        }
        $ruleKeyByName[(ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))] = "${base}_$role"
    }
    foreach ($p in @(Get-NeoIPCSubstanceRulePlan -SubstanceCount $SubstanceCount)) {
        $nn = '{0:D2}' -f [int]$p['Index']
        $sBase = "NEOIPC_SURVEILLANCE_END_AB_SUBST_$nn"
        $key = switch ($p['Kind']) {
            'hide' { "${sBase}_HIDE" }
            'daysRequire' { "${sBase}_DAYS_REQUIRE" }
            'substanceRequire' { "${sBase}_REQUIRE" }
            'validate' { 'NEOIPC_SURVEILLANCE_END_AB_SUBST_DAYS_VALIDATE' }
        }
        $ruleKeyByName[(ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$p['Name']))] = $key
    }

    # Resolve within the package: owning-rule id -> rule struct key (actions carry no name), and DE id -> code, so a
    # generated action keys by its owning rule's struct key + action type (+ target DE code where it has one), which
    # keeps the multi-action hide / when-empty rules unique.
    $ruleStructKeyById = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    foreach ($r in @($Package['programRules'])) {
        if ($r -isnot [System.Collections.IDictionary]) { continue }
        $nn = ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$r['name'])
        if ($ruleKeyByName.ContainsKey($nn)) { $ruleStructKeyById[[string]$r['id']] = $ruleKeyByName[$nn] }
    }
    $deCodeById = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    foreach ($de in @($Package['dataElements'])) {
        if ($de -is [System.Collections.IDictionary] -and $de['id'] -and $de['code']) { $deCodeById[[string]$de['id']] = [string]$de['code'] }
    }

    [pscustomobject]@{
        VariableKeyByName   = $varKeyByName
        RuleKeyByName       = $ruleKeyByName
        RuleStructKeyById   = $ruleStructKeyById
        DataElementCodeById = $deCodeById
    }
}

function Get-NeoIPCMetadataGeneratedTranslationKey {
    # The stable semantic translation key for a GENERATED code-less object, or $null when the object is not a
    # generated variable / rule / action (it then falls back to the UID). Variables and rules look up by slot-
    # normalised name; an action keys by its owning rule's struct key + action type (+ target DE code where it has
    # one, so the multi-action hide / when-empty rules stay unique). Symmetric across extraction and injection — both
    # reach it through Get-NeoIPCMetadataTranslationKey with the same index, so the keys always match.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)]$Index
    )
    switch ($Type) {
        'programRuleVariables' {
            $nn = ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$Object['name'])
            if ($Index.VariableKeyByName.ContainsKey($nn)) { return $Index.VariableKeyByName[$nn] }
            return $null
        }
        'programRules' {
            $nn = ConvertTo-NeoIPCSubstanceUnpaddedName ([string]$Object['name'])
            if ($Index.RuleKeyByName.ContainsKey($nn)) { return $Index.RuleKeyByName[$nn] }
            return $null
        }
        'programRuleActions' {
            $pr = $Object['programRule']
            $rid = if ($pr -is [System.Collections.IDictionary]) { [string]$pr['id'] } else { [string]$pr }
            if ([string]::IsNullOrEmpty($rid) -or -not $Index.RuleStructKeyById.ContainsKey($rid)) { return $null }
            $ruleKey = $Index.RuleStructKeyById[$rid]
            $atype = [string]$Object['programRuleActionType']
            $de = $Object['dataElement']
            $deId = if ($de -is [System.Collections.IDictionary]) { [string]$de['id'] } else { [string]$de }
            $deCode = if (-not [string]::IsNullOrEmpty($deId) -and $Index.DataElementCodeById.ContainsKey($deId)) { $Index.DataElementCodeById[$deId] } else { $null }
            if (-not [string]::IsNullOrEmpty($deCode)) { return "$ruleKey/$atype/$deCode" }
            return "$ruleKey/$atype"
        }
    }
    return $null
}

function Get-NeoIPCMetadataTranslationKey {
    # The key segment of an object's translation msgctxt, guaranteeing a UNIQUE msgctxt per (object, token). Code-keyed
    # where a code exists (survives UID regeneration, matches the legacy .<locale>.csv sidecars; options have no unique
    # code on their own — Option.code repeats across sets — so they key by <optionSetCode>/<optionCode>). A code-less
    # GENERATED rule / variable / action keys by a stable SEMANTIC key from Get-NeoIPCMetadataGeneratedTranslationKey
    # (the DE-code-scheme key, name-independent — passed via $GeneratedKeyIndex). Any other code-less type (program
    # stages / sections, validation rules, hand-authored rules, ...) keys by the object UID, NOT the name: DHIS2 does
    # not constrain those names to be unique (e.g. two programStageSections can share a name), so a name key would
    # collide into a gettext-invalid duplicate msgctxt — the readable meaning is the English msgid. Returns $null when
    # no usable key exists (the object is then skipped).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$Object,
        [hashtable]$OptionSetCodeById = @{},
        $GeneratedKeyIndex = $null
    )
    if ($Type -eq 'options') {
        $code = [string]$Object['code']
        $os = $Object['optionSet']
        $setCode = if ($os -is [System.Collections.IDictionary]) { $OptionSetCodeById[[string]$os['id']] } else { $null }
        if ([string]::IsNullOrEmpty($code) -or [string]::IsNullOrEmpty($setCode)) { return $null }
        return "$setCode/$code"
    }
    $code = [string]$Object['code']
    if (-not [string]::IsNullOrEmpty($code)) { return $code }
    if ($null -ne $GeneratedKeyIndex) {
        $gen = Get-NeoIPCMetadataGeneratedTranslationKey -Type $Type -Object $Object -Index $GeneratedKeyIndex
        if (-not [string]::IsNullOrEmpty($gen)) { return $gen }
    }
    $id = [string]$Object['id']                                   # code-less, non-generated: UID, not name (names are not unique)
    if (-not [string]::IsNullOrEmpty($id)) { return $id }
    return $null
}

function Get-NeoIPCMetadataTranslationUnit {
    # Walk a package and extract one translation unit per (object, translatable field) that carries a non-empty
    # base value. Units are emitted in a deterministic order — type-map order, then the object key (ordinal),
    # then the type's field/token order — so the order is INTRINSIC TO THE DATA and independent of how the source
    # package happens to order its objects (a directory build and an assembled-package build then produce the
    # same .pot, and the .pot diffs cleanly even when the closure / generation reorders the package). Warns about
    # any existing translations[] entry whose (object, token) is not covered by an emitted unit (a translation on
    # a property the type map does not carry) so such drift is visible, not silently lost.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([Parameter(Mandatory)]$Package)
    $optionSetCodeById = Get-NeoIPCMetadataOptionSetCodeIndex -Package $Package
    $domainSetIds = Get-NeoIPCMetadataDomainOptionSetIds -Package $Package   # NEOIPC_PATHOGENS / _SUBSTANCES — excluded
    $generatedKeyIndex = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package $Package   # stable semantic keys for the generated code-less families
    $units = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $fields = Get-NeoIPCMetadataTranslatableField -Type $type
        if ($fields.Count -eq 0) { continue }
        if ($script:NeoIPCMetadataExcludedTypes -contains $type -or $script:NeoIPCMetadataDeferredTypes -contains $type) { continue }
        # Elevated-priority tokens for this type ($null if none); unlisted (type, token) deprioritise to LOW.
        $priorities = $script:NeoIPCMetadataTranslationPriorities[$type]
        $tokens = [System.Collections.Generic.HashSet[string]]::new([string[]]@($fields | ForEach-Object { $_.Token }), [System.StringComparer]::Ordinal)
        # Decorate each unit with its (key, field-index) so the type's units can be emitted ordinally by key (field
        # order kept within an object) regardless of the order the package carries its objects — see the sort below.
        $typeDecorated = [System.Collections.Generic.List[object]]::new()
        foreach ($obj in @($Package[$type])) {
            if ($obj -isnot [System.Collections.IDictionary]) { continue }
            $key = Get-NeoIPCMetadataTranslationKey -Type $type -Object $obj -OptionSetCodeById $optionSetCodeById -GeneratedKeyIndex $generatedKeyIndex
            if ($null -eq $key) { continue }
            # Antibiotic domain (ATC + AWaRe optionGroups, ATC5/WHO_AWARE optionGroupSets): every antibiotic-domain
            # name/description is translated in the dedicated antibiotic component (po/antibiotics.*), so it is excluded
            # here and in injection. See Test-NeoIPCAntibioticTranslationExcluded.
            if (Test-NeoIPCAntibioticTranslationExcluded -Type $type -Code ([string]$obj['code'])) { continue }
            # Domain option sets (pathogens / substances) are authored from the canonical YAML / antibiotics CSV, not
            # translated here — excluded from BOTH extraction and injection so the two stay symmetric (a raw export
            # carrying their translations[] must not be wiped on Import).
            if (Test-NeoIPCMetadataDomainExcluded -Type $type -Object $obj -DomainSetIds $domainSetIds) { continue }
            # NOTE — the ontology/matrix-GENERATED families (Test-NeoIPCMetadataGeneratedExcluded: per-slot pathogen /
            # substance DEs, resistance / field-gating / substance PRVs+rules+actions) are deliberately NOT excluded
            # here, unlike the directory emit + comparator. The generators do not copy translations[] and
            # New-NeoIPCMetadataPackage drops translations, so this PO is their SOLE translation source on the
            # importable package — mirroring the directory exclusion here would permanently drop every generated-family
            # translation. Do NOT add the generated predicate to the PO path.
            # Index this object's existing translations by token: token -> { locale -> value }.
            $existing = @{}
            foreach ($t in @($obj['translations'])) {
                if ($t -is [System.Collections.IDictionary] -and $t['property'] -and $t['locale']) {
                    $tok = [string]$t['property']
                    if (-not $existing.ContainsKey($tok)) { $existing[$tok] = [ordered]@{} }
                    $existing[$tok][[string]$t['locale']] = [string]$t['value']
                }
            }
            $fieldIndex = 0
            foreach ($field in $fields) {
                $base = $obj[$field.Property]
                if ($null -eq $base -or [string]$base -eq '') { continue }
                $translations = if ($existing.ContainsKey($field.Token)) { $existing[$field.Token] } else { [ordered]@{} }
                $priority = if ($priorities -and $priorities.Contains($field.Token)) { [int]$priorities[$field.Token] } else { $script:NeoIPCMetadataLowTranslationPriority }
                $typeDecorated.Add([pscustomobject]@{
                        SortKey   = $key
                        SortField = $fieldIndex
                        Unit      = [ordered]@{
                            Type         = $type
                            Key          = $key
                            Property     = $field.Property
                            Token        = $field.Token
                            Msgctxt      = "$type/$key/$($field.Token)"
                            Msgid        = [string]$base
                            ObjectId     = [string]$obj['id']
                            Priority     = $priority
                            Translations = $translations
                        }
                    })
                $fieldIndex++
            }
            $ignoredTokens = $script:NeoIPCMetadataTranslationIgnoredTokens[$type]
            foreach ($tok in $existing.Keys) {
                if (-not $tokens.Contains($tok) -and ($tok -notin $ignoredTokens)) {
                    Write-Warning ("translations[] entry on {0} '{1}' uses token {2}, which the type map does not carry as a translatable field; it is not exported to PO." -f $type, $key, $tok)
                }
            }
        }
        # Emit this type's units ordinally by key, field order preserved within an object (keys are unique per type
        # — the msgctxt collision gate below enforces it — so the tiebreak only orders an object's own fields).
        $typeDecorated.Sort([System.Comparison[object]] {
                param($x, $y)
                $c = [System.StringComparer]::Ordinal.Compare([string]$x.SortKey, [string]$y.SortKey)
                if ($c -ne 0) { return $c }
                return $x.SortField.CompareTo($y.SortField)
            })
        foreach ($d in $typeDecorated) { $units.Add($d.Unit) }
    }
    # Gettext-independent uniqueness gate: a duplicate msgctxt would make the PO invalid (msgfmt rejects it, Weblate
    # mangles it). Fail loud naming the colliding object UIDs rather than ship a broken catalogue. (Group-Object can't
    # read a dictionary key as a property, so collisions are tallied by hand.) Keyed ORDINALLY (case-sensitively),
    # matching the injection lookup, so two msgctxts that differ only in case stay distinct rather than conflated.
    $byCtx = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
    foreach ($u in $units) {
        $ctx = [string]$u.Msgctxt
        if (-not $byCtx.ContainsKey($ctx)) { $byCtx[$ctx] = [System.Collections.Generic.List[string]]::new() }
        [void]$byCtx[$ctx].Add([string]$u.ObjectId)
    }
    $collisions = @($byCtx.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
    if ($collisions.Count -gt 0) {
        $detail = ($collisions | ForEach-Object { "'{0}' on {1}" -f $_.Key, ((@($_.Value) | Sort-Object -Unique) -join ' + ') }) -join '; '
        throw "Duplicate translation msgctxt (would produce a gettext-invalid PO): $detail. Two metadata objects map to the same key."
    }
    return , $units
}

function ConvertTo-NeoIPCMetadataPoEntry {
    # Project translation units to single-language PO entries. -Locale '' yields .pot entries (empty msgstr);
    # a real locale fills msgstr from each unit's Translations[$Locale]. Fuzzy is always false here (fuzziness
    # only arises from a source-vs-translation mismatch during Merge-NeoIPCMetadataPoEntry).
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Unit,
        [string]$Locale = ''
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $Unit) {
        $msgstr = if ($Locale -and $u.Translations.Contains($Locale)) { [string]$u.Translations[$Locale] } else { '' }
        $priority = if ($u.Contains('Priority')) { [int]$u.Priority } else { 100 }
        $entries.Add([ordered]@{ Msgctxt = $u.Msgctxt; Msgid = $u.Msgid; Msgstr = $msgstr; Fuzzy = $false; Priority = $priority })
    }
    return , $entries
}

function ConvertTo-NeoIPCPoString {
    # Escape a value for a PO double-quoted string (the inverse of ConvertFrom-NeoIPCPoString). Order matters:
    # backslash first so the escapes it introduces are not re-escaped.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $s = $Value
    $s = $s -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    $s = $s -replace "`r", '\r'
    $s = $s -replace "`n", '\n'
    $s = $s -replace "`t", '\t'
    return $s
}

function ConvertFrom-NeoIPCPoString {
    # Unescape one PO double-quoted string body (without the surrounding quotes) back to its raw value.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $sb = [System.Text.StringBuilder]::new($Value.Length)
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($c -ne '\' -or $i -eq $Value.Length - 1) { [void]$sb.Append($c); continue }
        $n = $Value[++$i]
        switch ($n) {
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            default { [void]$sb.Append($n) }
        }
    }
    return $sb.ToString()
}

function Write-NeoIPCMetadataPoText {
    # Render PO entries to PO text. -Locale '' (default) writes a .pot header (Language: en, blank msgstr expected);
    # a non-empty -Locale writes that language's header. Each entry's Weblate flags line carries fuzzy + priority:NNN
    # (priority 100 = default, no flag). The header is the standard empty-msgid entry; metadata mirrors the reports'
    # glossary PO (NeoIPC copyright, CC BY 4.0). Output is LF-terminated (StringBuilder.AppendLine would emit the
    # platform newline) to match every other catalogue under po/.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Entry,
        [string]$Locale = ''
    )
    $lang = if ($Locale) { $Locale } else { 'en' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Translations for the NeoIPC DHIS2 metadata.')
    [void]$sb.AppendLine('# Copyright (C) Charité – Universitätsmedizin Berlin')
    [void]$sb.AppendLine('# This file is distributed under the Creative Commons Attribution 4.0 International license')
    [void]$sb.AppendLine('# Automatically generated')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('msgid ""')
    [void]$sb.AppendLine('msgstr ""')
    [void]$sb.AppendLine('"Project-Id-Version: NeoIPC Metadata\n"')
    [void]$sb.AppendLine('"Report-Msgid-Bugs-To: NeoIPC-Support@charite.de\n"')
    [void]$sb.AppendLine('"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\n"')
    [void]$sb.AppendLine('"Last-Translator: Automatically generated\n"')
    [void]$sb.AppendLine('"Language-Team: none\n"')
    [void]$sb.AppendLine(('"Language: {0}\n"' -f $lang))
    [void]$sb.AppendLine('"MIME-Version: 1.0\n"')
    [void]$sb.AppendLine('"Content-Type: text/plain; charset=UTF-8\n"')
    [void]$sb.AppendLine('"Content-Transfer-Encoding: 8bit\n"')
    foreach ($e in $Entry) {
        [void]$sb.AppendLine()
        # Weblate flags line: fuzzy (translator state) + priority:NNN (source-set focus). 100 is the default — no flag.
        $flags = [System.Collections.Generic.List[string]]::new()
        if ($e.Fuzzy) { $flags.Add('fuzzy') }
        $prio = if ($e.Contains('Priority')) { [int]$e.Priority } else { 100 }
        if ($prio -ne 100) { $flags.Add("priority:$prio") }
        if ($flags.Count -gt 0) { [void]$sb.AppendLine('#, ' + ($flags -join ', ')) }
        [void]$sb.AppendLine(('msgctxt "{0}"' -f (ConvertTo-NeoIPCPoString $e.Msgctxt)))
        [void]$sb.AppendLine(('msgid "{0}"' -f (ConvertTo-NeoIPCPoString $e.Msgid)))
        [void]$sb.AppendLine(('msgstr "{0}"' -f (ConvertTo-NeoIPCPoString ([string]$e.Msgstr))))
    }
    return ($sb.ToString() -replace "`r`n", "`n")
}

function Read-NeoIPCMetadataPoText {
    # Parse PO text into entries [{ Msgctxt, Msgid, Msgstr, Fuzzy }]. Handles gettext multi-line continuation (a
    # bare "..." line appends to the current field, e.g. after a wrapped long value), the "#, fuzzy" flag, and
    # skips the header (the empty-msgid entry). Other comment lines are ignored. Tolerant of CRLF.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $entries = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    $field = $null              # which keyword the continuation lines extend: msgctxt | msgid | msgstr
    $pendingFuzzy = $false      # a "#, fuzzy" seen since the last entry; attaches to the next one started
    $pendingPriority = 100      # a "#, priority:NNN" seen since the last entry (100 = Weblate default)
    $flush = {
        # A real entry has a msgctxt; the catalogue header (empty msgid, no msgctxt) does not, so it is skipped.
        if ($cur -and -not [string]::IsNullOrEmpty([string]$cur.Msgctxt)) {
            $entries.Add([ordered]@{ Msgctxt = $cur.Msgctxt; Msgid = $cur.Msgid; Msgstr = $cur.Msgstr; Fuzzy = $cur.Fuzzy; Priority = $cur.Priority })
        }
    }
    $quoted = {
        param($line, $keyword)
        $rest = $line.Substring($keyword.Length).Trim()
        if ($rest.StartsWith('"') -and $rest.EndsWith('"') -and $rest.Length -ge 2) {
            return ConvertFrom-NeoIPCPoString $rest.Substring(1, $rest.Length - 2)
        }
        return ''
    }
    foreach ($raw in ($Text -split "`n")) {
        $line = $raw.TrimEnd("`r")
        $trim = $line.Trim()
        if ($trim -eq '') { $field = $null; continue }
        if ($trim.StartsWith('#')) {
            if ($trim -match '^#,') {
                if ($trim -match '\bfuzzy\b') { $pendingFuzzy = $true }
                if ($trim -match 'priority:(\d+)') { $pendingPriority = [int]$Matches[1] }
            }
            $field = $null
            continue
        }
        if ($trim.StartsWith('msgctxt ')) {
            & $flush
            $cur = [ordered]@{ Msgctxt = (& $quoted $trim 'msgctxt'); Msgid = $null; Msgstr = ''; Fuzzy = $pendingFuzzy; Priority = $pendingPriority }
            $pendingFuzzy = $false; $pendingPriority = 100
            $field = 'msgctxt'
        }
        elseif ($trim.StartsWith('msgid ')) {
            if (-not $cur -or $null -ne $cur.Msgid) { & $flush; $cur = [ordered]@{ Msgctxt = $null; Msgid = $null; Msgstr = ''; Fuzzy = $pendingFuzzy; Priority = $pendingPriority }; $pendingFuzzy = $false; $pendingPriority = 100 }
            $cur.Msgid = (& $quoted $trim 'msgid')
            $field = 'msgid'
        }
        elseif ($trim.StartsWith('msgstr ')) {
            if (-not $cur) { $cur = [ordered]@{ Msgctxt = $null; Msgid = $null; Msgstr = ''; Fuzzy = $false; Priority = 100 } }
            $cur.Msgstr = (& $quoted $trim 'msgstr')
            $field = 'msgstr'
        }
        elseif ($trim.StartsWith('"') -and $field) {
            $piece = if ($trim.EndsWith('"') -and $trim.Length -ge 2) { ConvertFrom-NeoIPCPoString $trim.Substring(1, $trim.Length - 2) } else { '' }
            $cur.$field = [string]$cur.$field + $piece
        }
    }
    & $flush
    return , $entries
}

function Merge-NeoIPCMetadataPoEntry {
    # Merge freshly-extracted source entries (New, msgstr empty) with an existing language PO (Existing), the way
    # msgmerge would: key by msgctxt. New is authoritative for which entries exist and for the msgid (English
    # source). When the existing PO has the same msgctxt:
    #   - same msgid  -> keep its msgstr and fuzzy flag (an unchanged source keeps the translation untouched);
    #   - changed msgid -> keep the msgstr but mark fuzzy (the source moved; the translator must review).
    # Entries only in Existing are dropped (obsolete). Output preserves New's order. Returns the merged entries.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$New,
        [Parameter(Mandatory)][AllowNull()][System.Collections.Generic.List[object]]$Existing
    )
    $byCtx = @{}
    foreach ($e in @($Existing)) { if ($e.Msgctxt) { $byCtx[[string]$e.Msgctxt] = $e } }
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($n in $New) {
        $old = $byCtx[[string]$n.Msgctxt]
        $msgstr = ''
        $fuzzy = $false
        if ($old -and -not [string]::IsNullOrEmpty([string]$old.Msgstr)) {
            $msgstr = [string]$old.Msgstr
            $fuzzy = [bool]$old.Fuzzy -or ([string]$old.Msgid -ne [string]$n.Msgid)
        }
        $priority = if ($n.Contains('Priority')) { [int]$n.Priority } else { 100 }   # priority is source-set: New wins
        $merged.Add([ordered]@{ Msgctxt = $n.Msgctxt; Msgid = $n.Msgid; Msgstr = $msgstr; Fuzzy = $fuzzy; Priority = $priority })
    }
    return , $merged
}

function Add-NeoIPCMetadataTranslationToPackage {
    # Inject per-locale PO translations onto a package's objects as translations[] = [{ property, locale, value }].
    # PoByLocale is { locale -> parsed entry list (Read-NeoIPCMetadataPoText output) }. Fuzzy and empty entries
    # are skipped (unreviewed / untranslated). For each translatable object/field the msgctxt is recomputed
    # (identical scheme to extraction) and matched against each locale's PO; a kept msgstr becomes a translations[]
    # entry. The rebuilt array is sorted (locale, then token) for deterministic output, and replaces whatever
    # translations[] the object carried. Mutates and returns $Package.
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][hashtable]$PoByLocale
    )
    # locale -> { msgctxt -> msgstr } over the kept (non-fuzzy, non-empty) translations only.
    $byLocale = @{}
    foreach ($locale in $PoByLocale.Keys) {
        $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        foreach ($e in $PoByLocale[$locale]) {
            if ($e.Msgctxt -and -not $e.Fuzzy -and -not [string]::IsNullOrEmpty([string]$e.Msgstr)) { $map[[string]$e.Msgctxt] = [string]$e.Msgstr }
        }
        $byLocale[$locale] = $map
    }
    $tokenOrder = @{}
    $i = 0
    foreach ($tok in $script:NeoIPCMetadataTranslatableProperties.Values) { $tokenOrder[$tok] = $i++ }

    $optionSetCodeById = Get-NeoIPCMetadataOptionSetCodeIndex -Package $Package
    $domainSetIds = Get-NeoIPCMetadataDomainOptionSetIds -Package $Package
    $generatedKeyIndex = Get-NeoIPCMetadataGeneratedTranslationKeyIndex -Package $Package
    $locales = @($PoByLocale.Keys | Sort-Object)
    foreach ($type in $script:NeoIPCMetadataTypeMaps.Keys) {
        $fields = Get-NeoIPCMetadataTranslatableField -Type $type
        if ($fields.Count -eq 0) { continue }
        if ($script:NeoIPCMetadataExcludedTypes -contains $type -or $script:NeoIPCMetadataDeferredTypes -contains $type) { continue }
        $orderedFields = @($fields | Sort-Object { $tokenOrder[$_.Token] })
        foreach ($obj in @($Package[$type])) {
            if ($obj -isnot [System.Collections.IDictionary]) { continue }
            $key = Get-NeoIPCMetadataTranslationKey -Type $type -Object $obj -OptionSetCodeById $optionSetCodeById -GeneratedKeyIndex $generatedKeyIndex
            if ($null -eq $key) { continue }
            # Mirror extraction's exclusions, else this would REBUILD (and so wipe) translations[] the PO never owns —
            # the antibiotic domain (groups + group-sets) and the domain pathogen/substance option sets. Leave them intact.
            if (Test-NeoIPCAntibioticTranslationExcluded -Type $type -Code ([string]$obj['code'])) { continue }
            if (Test-NeoIPCMetadataDomainExcluded -Type $type -Object $obj -DomainSetIds $domainSetIds) { continue }
            # As in extraction, the ontology/matrix-GENERATED families are deliberately NOT excluded here — the PO is
            # their sole translation source on the import, so excluding them would drop those translations
            # (see Get-NeoIPCMetadataGeneratedKeys / Test-NeoIPCMetadataGeneratedExcluded).
            $rebuilt = [System.Collections.Generic.List[object]]::new()
            foreach ($locale in $locales) {
                $localeMap = $byLocale[$locale]
                foreach ($field in $orderedFields) {
                    $ctx = "$type/$key/$($field.Token)"
                    $val = if ($localeMap.ContainsKey($ctx)) { $localeMap[$ctx] } else { $null }
                    if (-not [string]::IsNullOrEmpty($val)) {
                        $rebuilt.Add([ordered]@{ property = $field.Token; locale = $locale; value = $val })
                    }
                }
            }
            if ($rebuilt.Count -gt 0) { $obj['translations'] = $rebuilt.ToArray() }
            elseif ($obj.Contains('translations')) { $obj.Remove('translations') }
        }
    }
    return $Package
}

function Test-NeoIPCMetadataPoSyntax {
    # Best-effort gettext validation of a generated .po with `msgfmt -c` (catches malformed PO: bad escapes,
    # duplicate msgctxt, header problems). gettext runs via WSL on Windows (as the reports' po4a does), directly
    # elsewhere. Returns $true when the file is valid OR when gettext is unavailable (validation skipped — never a
    # hard dependency); $false only when msgfmt actively reports an error. Never throws.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $abs = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if ($IsWindows) {
            if (-not (Get-Command wsl -ErrorAction SilentlyContinue) -or $abs -notmatch '^[A-Za-z]:\\') {
                Write-Verbose 'msgfmt validation skipped (WSL unavailable / non-drive path).'; return $true
            }
            # Build the WSL path directly — `wsl wslpath` is unreliable under a Git-Bash-launched shell and a noisy PATH.
            $wsl = '/mnt/' + $abs.Substring(0, 1).ToLowerInvariant() + ($abs.Substring(2) -replace '\\', '/')
            $out = & wsl msgfmt -c -o /dev/null "$wsl" 2>&1
        }
        else {
            if (-not (Get-Command msgfmt -ErrorAction SilentlyContinue)) { Write-Verbose 'msgfmt validation skipped (gettext not installed).'; return $true }
            $out = & msgfmt -c -o /dev/null "$abs" 2>&1
        }
        $real = @($out | Where-Object { $_ -notmatch 'Failed to translate' })   # drop the harmless WSL drive-map noise
        if ($LASTEXITCODE -eq 0) { return $true }
        if (($real -join ' ') -match 'command not found|not installed') {
            Write-Verbose 'msgfmt validation skipped (gettext not installed in WSL).'; return $true
        }
        Write-Warning ("msgfmt reported issues in {0}: {1}" -f $Path, (($real | Out-String).Trim()))
        return $false
    }
    catch {
        Write-Verbose ("msgfmt validation skipped ({0})." -f $_.Exception.Message)
        return $true
    }
}

function Test-NeoIPCAtcCode {
    # True when $Code is a WHO ATC code at the antibiotic-relevant levels: ATC level 4 (5 chars, e.g. J01CG — the
    # antibiotic option GROUPS) or level 5 (7 chars, e.g. J01AA01 — the substance OPTIONS). A pure code-shape test;
    # callers decide what to do with the answer. The optional trailing 2 digits (ATC-5) are INTENTIONAL — this
    # predicate spans both groups and substance options; do NOT narrow it to ATC-4 (use Test-NeoIPCAtcGroupCode for
    # the group-only shape).
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Code)
    return $Code -cmatch '^[A-Z][0-9]{2}[A-Z]{2}([0-9]{2})?$'
}

function Test-NeoIPCAtcGroupCode {
    # True when $Code is a WHO ATC level-4 (chemical-subgroup) code (5 chars, e.g. J01CG) — the antibiotic option
    # GROUP level, NOT the 7-char ATC-5 substance codes. The single source for this shape, called by the emit
    # (Test-NeoIPCMetadataGeneratedExcluded), the antibiotic group-set generator, and the classified-diff gate, so
    # the four antibiotic-domain decision sites cannot drift on what counts as an ATC-4 group code.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$Code)
    return $Code -cmatch '^[A-Z][0-9]{2}[A-Z]{2}$'
}

function Test-NeoIPCAntibioticTranslationExcluded {
    # True for an antibiotic-domain object whose translations live in the dedicated antibiotic PO component
    # (po/antibiotics.*), and so are excluded from the general metadata PO: the antibiotic optionGroups (ATC-coded
    # J01CG, … AND the AWaRe groups WHO_AWARE_*) and the antibiotic optionGroupSets (ATC5 / WHO_AWARE). The exclusion
    # is ORGANIZATIONAL — the whole antibiotic domain is translated in one component keyed by the English name, with
    # WHO attribution in the metadata CSVs — not a copyright bar. The antimicrobial-substance OPTIONS are excluded
    # separately, as a domain option set (Test-NeoIPCMetadataDomainExcluded). Mirrors the generated-class predicate.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [AllowEmptyString()][AllowNull()][string]$Code
    )
    switch ($Type) {
        'optionGroups'    { return (Test-NeoIPCAtcCode -Code $Code) -or ($Code -cmatch '^WHO_AWARE_') }
        'optionGroupSets' { return ($Code -ceq 'ATC5') -or ($Code -ceq 'WHO_AWARE') }
        default           { return $false }
    }
}
