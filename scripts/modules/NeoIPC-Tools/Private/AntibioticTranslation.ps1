# NeoIPC metadata pipeline — antibiotic translation catalogue (PO) helpers (private, not exported).
# The antibiotic domain is translated in its OWN bilingual gettext component (po/antibiotics.pot + .po), keyed by
# the English STRING (bare msgid, no msgctxt — so Get-NeoIPCPoTranslationMap reads it, like po4a's infectious_agents
# catalogue), NOT by the metadata PO's msgctxt scheme. This file builds that catalogue from the canonical antibiotic
# sources. See metadata/common/antibiotics/README.md. The PO-string escapers (ConvertTo/From-NeoIPCPoString) and the
# msgfmt validator (Test-NeoIPCMetadataPoSyntax) are reused from MetadataTranslation.ps1.

function Get-NeoIPCAntibioticTranslationString {
    # Collect the full set of English translatable strings of the antibiotic domain, de-duplicated and in a stable
    # order (substances, then ATC groups, AWaRe groups, group-sets, then the printed-list UI labels). For every
    # object the non-empty translatable fields are taken via Get-NeoIPCAntibioticTranslatableValues (name +
    # shortName/formName/description where present), so the surface tracks whatever the sources carry. Identical
    # strings collapse to one entry (gettext merges identical msgids; one English term -> one translation). Returns
    # an ordered List[string].
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param(
        [string]$SubstancePath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotics.csv'),
        [string]$GroupPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotic-Groups.csv'),
        [string]$AwareGroupPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'NeoIPC-Antibiotic-AWaRe-Groups.csv'),
        [string]$ListElementsPath = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'antibiotics' 'ListElements.csv')
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $list = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($value)
        $v = [string]$value
        if (-not [string]::IsNullOrEmpty($v) -and $seen.Add($v)) { $list.Add($v) }
    }
    foreach ($s in @(Get-NeoIPCAntibioticSubstance -Path $SubstancePath)) {
        $f = Get-NeoIPCAntibioticTranslatableValues -Name $s.Name -ShortName $s.ShortName -FormName $s.FormName -Description $s.Description
        foreach ($v in $f.Values) { & $add $v }
    }
    foreach ($g in @(Get-NeoIPCAntibioticGroup -Path $GroupPath)) {
        $f = Get-NeoIPCAntibioticTranslatableValues -Name $g.Name -ShortName $g.ShortName -Description $g.Description
        foreach ($v in $f.Values) { & $add $v }
    }
    foreach ($a in @(Get-NeoIPCAntibioticAwareGroup -Path $AwareGroupPath)) {
        $f = Get-NeoIPCAntibioticTranslatableValues -Name $a.Name -ShortName $a.ShortName -Description $a.Description
        foreach ($v in $f.Values) { & $add $v }
    }
    foreach ($code in $script:NeoIPCAntibioticGroupSet.Keys) {
        $gs = $script:NeoIPCAntibioticGroupSet[$code]
        $f = Get-NeoIPCAntibioticTranslatableValues -Name $gs.Name -Description $gs.Description
        foreach ($v in $f.Values) { & $add $v }
    }
    $resolvedList = Resolve-Path -LiteralPath $ListElementsPath -ErrorAction Stop
    foreach ($r in @(Import-Csv -LiteralPath $resolvedList -Encoding utf8NoBOM)) { & $add ([string]$r.value) }
    , $list
}

function ConvertTo-NeoIPCAntibioticPoField {
    # Render one PO keyword + quoted value, splitting at embedded newlines (po4a's `--wrap-po newlines` style, as the
    # other catalogues under po/ use): a single-line value is `<kw> "value"`; a multi-line value (e.g. the AWaRe
    # group-set description) becomes `<kw> ""` followed by one quoted continuation line per newline-terminated
    # segment. Returns LF-terminated text.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Keyword, [AllowEmptyString()][AllowNull()][string]$Value)
    $v = [string]$Value
    $sb = [System.Text.StringBuilder]::new()
    if ($v -notmatch "`n") {
        [void]$sb.AppendLine(('{0} "{1}"' -f $Keyword, (ConvertTo-NeoIPCPoString $v)))
    }
    else {
        [void]$sb.AppendLine(('{0} ""' -f $Keyword))
        foreach ($seg in ($v -split "(?<=`n)")) {
            if ($seg -eq '') { continue }
            [void]$sb.AppendLine(('"{0}"' -f (ConvertTo-NeoIPCPoString $seg)))
        }
    }
    return ($sb.ToString() -replace "`r`n", "`n")
}

function Write-NeoIPCAntibioticPoText {
    # Render bare-msgid PO entries [{ Msgid; Msgstr; Fuzzy }] to PO text. -Locale '' (default) writes the .pot header
    # (Language: en); a real locale writes that language's header. The header is the standard empty-msgid entry with
    # the NeoIPC copyright + CC BY-NC-SA 3.0 IGO attribution: the list is a derivative of the WHO AWaRe
    # classification (CC BY-NC-SA 3.0 IGO), whose ShareAlike term requires the derivative to keep the same
    # licence; the substance names it carries are International Nonproprietary Names (factual), and the ATC
    # codes and group names are the WHOCC's classification reproduced verbatim. Output is LF-terminated.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Entry,
        [string]$Locale = ''
    )
    $lang = if ($Locale) { $Locale } else { 'en' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Translations for the NeoIPC antibiotic substance and group lists.')
    [void]$sb.AppendLine('# Copyright (C) Charité – Universitätsmedizin Berlin')
    [void]$sb.AppendLine('# This file is distributed under the Creative Commons Attribution-NonCommercial-ShareAlike 3.0 IGO license')
    [void]$sb.AppendLine('# Automatically generated')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('msgid ""')
    [void]$sb.AppendLine('msgstr ""')
    [void]$sb.AppendLine('"Project-Id-Version: NeoIPC Antibiotics\n"')
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
        if ($e.Fuzzy) { [void]$sb.AppendLine('#, fuzzy') }
        [void]$sb.Append((ConvertTo-NeoIPCAntibioticPoField -Keyword 'msgid' -Value ([string]$e.Msgid)))
        [void]$sb.Append((ConvertTo-NeoIPCAntibioticPoField -Keyword 'msgstr' -Value ([string]$e.Msgstr)))
    }
    return ($sb.ToString() -replace "`r`n", "`n")
}

function Read-NeoIPCAntibioticPoText {
    # Parse bare-msgid PO text into entries [{ Msgid; Msgstr; Fuzzy }], preserving the fuzzy flag and the (possibly
    # empty) msgstr so a merge can keep translator state. Handles multi-line continuation, skips the header (empty
    # msgid) and obsolete "#~" entries. Tolerant of CRLF. (Distinct from Get-NeoIPCPoTranslationMap, which is the
    # lossy read used at GENERATION time — it drops fuzzy/empty/identical to build a clean english->localized map.)
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $entries = [System.Collections.Generic.List[object]]::new()
    $id = $null; $str = $null; $field = $null; $fuzzy = $false; $obsolete = $false
    $unq = {
        param($s)
        if ($s.StartsWith('"') -and $s.EndsWith('"') -and $s.Length -ge 2) { ConvertFrom-NeoIPCPoString $s.Substring(1, $s.Length - 2) } else { '' }
    }
    $flush = {
        if ($null -ne $id -and -not $obsolete -and -not [string]::IsNullOrEmpty([string]$id)) {
            $entries.Add([ordered]@{ Msgid = [string]$id; Msgstr = [string]$str; Fuzzy = $fuzzy })
        }
    }
    foreach ($raw in ($Text -split "`n")) {
        $trim = $raw.TrimEnd("`r").Trim()
        if ($trim -eq '') { & $flush; $id = $null; $str = $null; $field = $null; $fuzzy = $false; $obsolete = $false; continue }
        if ($trim.StartsWith('#~')) { $obsolete = $true; $field = $null; continue }
        if ($trim.StartsWith('#')) {
            if ($trim.StartsWith('#,') -and $trim -match '\bfuzzy\b') { $fuzzy = $true }
            $field = $null; continue
        }
        if ($trim.StartsWith('msgid ')) { $id = & $unq ($trim.Substring(6).Trim()); $field = 'id'; continue }
        if ($trim.StartsWith('msgstr ')) { $str = & $unq ($trim.Substring(7).Trim()); $field = 'str'; continue }
        if ($trim.StartsWith('"') -and $trim.EndsWith('"') -and $field) {
            $piece = & $unq $trim
            if ($field -eq 'id') { $id = [string]$id + $piece } else { $str = [string]$str + $piece }
        }
    }
    & $flush
    return , $entries
}

function Merge-NeoIPCAntibioticPoEntry {
    # msgmerge-equivalent for the bare-msgid catalogue: the source string list (SourceMsgid) is authoritative for
    # which entries exist and their order; each existing entry's msgstr + fuzzy flag is carried over by msgid (the
    # English string is itself the key, so an unchanged source keeps its translation; a string removed from the
    # source drops out — obsolete; a string new to the source gets an empty msgstr). Returns ordered merged entries.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$SourceMsgid,
        [Parameter(Mandatory)][AllowNull()][System.Collections.Generic.List[object]]$Existing
    )
    $byId = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($e in @($Existing)) { if (-not [string]::IsNullOrEmpty([string]$e.Msgid)) { $byId[[string]$e.Msgid] = $e } }
    $merged = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $SourceMsgid) {
        $old = $byId[$id]
        $msgstr = if ($old) { [string]$old.Msgstr } else { '' }
        $fuzzy = if ($old) { [bool]$old.Fuzzy } else { $false }
        $merged.Add([ordered]@{ Msgid = $id; Msgstr = $msgstr; Fuzzy = $fuzzy })
    }
    return , $merged
}
