#Requires -Version 7.6
# The single definition of a NeoIPC gettext catalogue header.
#
# Four writers produced these files — po4a (post-processed by scripts/Invoke-Localization.ps1),
# scripts/update-glossary-po.py, and the two exporters in this module — and each used to carry its own copy of
# the header. They drifted: eight different comment-block shapes, three spellings of the copyright line (one of
# them ASCII-transliterated), a product name that disagreed with its own Project-Id-Version, and a header
# serialised onto a single physical line. This file is why the two exporters can no longer drift from each
# other; the po4a post-processor implements the same contract in its own language, and all of them are held to
# it by Tests/PoHeader.Tests.ps1, which asserts against the committed files and runs in CI.
#
# Three writers now: the glossary generator emits only its template, because those catalogues became Weblate's,
# so it carries no per-language header machinery to drift.
#
# THE BLOCK STRUCTURE IS NOT COSMETIC. translate-toolkit's `updatecontributor` — which Weblate's
# "Contributors in comment" add-on delegates to — splits the comment block at the first line matching
# `.*<\S+@\S+>.*\d{4,4}` (an e-mail AND a four-digit year). Everything before that is `prelines` and is left
# alone; new contributors are appended after the last existing one; anything after them is `postlines`, and an
# empty one does not survive the round trip. So the bare `#` goes BELOW the licence and ABOVE the contributors:
# there it is the final preline and is stable, whereas placing contributors above it makes it a postline that
# Weblate silently deletes on its next write. For the same reason a retained contributor line MUST carry both
# an e-mail and a year — without them it fails the regex, is read as a preline, and the add-on appends a second
# copy of the same person.
#
# Fields deliberately absent, each because it was true when written and silently wrong afterwards:
# Project-Id-Version (its version suffix froze at 0.9 while the products moved on), X-Generator (a Weblate
# version string, which rewrote every catalogue on each upgrade until po_set_x_generator was turned off),
# Last-Translator (frozen by po_set_last_translator=false, so it named a translator who could never change),
# and POT-Creation-Date in a CATALOGUE — msgmerge does not refresh it, so it had drifted three weeks out in
# infectious_agents. It stays in the TEMPLATE, where the generator stamps it and it is true by construction.

# English language names as Weblate writes them into Language-Team, and the plural rule it writes per language.
# Sourced from the catalogues Weblate itself produced, not from a specification, so they match byte for byte.
$script:NeoIPCPoLanguageName = @{
    af = 'Afrikaans'; de = 'German'; el = 'Greek'; es = 'Spanish'; et = 'Estonian'
    fr = 'French'; it = 'Italian'; ne = 'Nepali'; tr = 'Turkish'
}
$script:NeoIPCPoPluralForms = @{
    af = 'nplurals=2; plural=n != 1;'; de = 'nplurals=2; plural=n != 1;'; el = 'nplurals=2; plural=n != 1;'
    es = 'nplurals=2; plural=n != 1;'; et = 'nplurals=2; plural=n != 1;'; fr = 'nplurals=2; plural=n > 1;'
    it = 'nplurals=2; plural=n != 1;'; ne = 'nplurals=2; plural=n != 1;'; tr = 'nplurals=2; plural=n != 1;'
}

function Test-NeoIPCPoNonHumanIdentity {
    # Whether a credit line names something other than a person, per po/non-human-identities.yaml.
    #
    # The list is DATA, shared with update-glossary-po.py (Python) and the report renderer (R), because a list
    # maintained separately in three languages is one that disagrees with itself. Matching is on the ADDRESS,
    # never the display name: `noreply@weblate.org` appears in this repository's history under two different
    # names, so a name-keyed rule excludes one and silently credits the other.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$AuthorLine)
    if (-not $script:NeoIPCPoNonHumanIdentities) {
        $path = Join-Path $PSScriptRoot '..' '..' '..' '..' 'po' 'non-human-identities.yaml'
        if (-not (Test-Path -LiteralPath $path)) { throw "Shared exclusion list not found at '$path'." }
        $data = ConvertFrom-Yaml (Get-Content -LiteralPath $path -Raw)
        $script:NeoIPCPoNonHumanIdentities = [pscustomobject]@{
            Domains   = [string[]]@($data.excluded_domains | ForEach-Object { $_.ToLowerInvariant() })
            Addresses = [string[]]@($data.excluded_addresses | ForEach-Object { ([string]$_.address).ToLowerInvariant() })
            Literals  = [string[]]@($data.excluded_literals)
        }
    }
    $known = $script:NeoIPCPoNonHumanIdentities
    foreach ($lit in $known.Literals) { if ($AuthorLine.Contains($lit)) { return $true } }
    if ($AuthorLine -notmatch '<([^>]+)>') { return $false }
    $address = $Matches[1].ToLowerInvariant()
    if ($known.Addresses -contains $address) { return $true }
    return ($known.Domains -contains ($address -replace '^.*@', ''))
}

function Get-NeoIPCPoLanguageName {
    # The English language name for a locale, as Weblate spells it. Throws on an unknown locale rather than
    # inventing one: a wrong name would be written into Language-Team and silently disagree with Weblate's.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Locale)
    if (-not $script:NeoIPCPoLanguageName.ContainsKey($Locale)) {
        throw "No English language name known for locale '$Locale'. Add it to `$NeoIPCPoLanguageName in Private/PoHeader.ps1 (and check what Weblate writes for it) rather than guessing."
    }
    $script:NeoIPCPoLanguageName[$Locale]
}

function Write-NeoIPCPoHeader {
    # Render the comment block and the empty-msgid header entry for one catalogue or template. Returns LF-
    # terminated text ending with a newline; the caller appends its entries. See the file header for why the
    # block is shaped the way it is and why several conventional fields are absent.
    #
    # -Locale ''            -> a TEMPLATE: language-less title, Language: en, POT-Creation-Date, no Plural-Forms.
    # -Locale '<lang>'      -> a CATALOGUE: per-language title, that language's Plural-Forms, no POT-Creation-Date.
    # -LanguageTeam         -> 'none' for a catalogue no Weblate component owns; otherwise the component URL
    #                          Weblate itself writes, so its next write is a no-op.
    # -Contributor          -> already-formatted 'Name <e-mail>, year.' lines, in order. Each MUST carry an
    #                          e-mail and a year (see the file header); the module does not fabricate either.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$License,
        [string]$Locale = '',
        [string]$PotCreationDate = '',
        [string]$LanguageTeam = 'none',
        [string[]]$Contributor = @()
    )
    foreach ($c in $Contributor) {
        if ($c -notmatch '<\S+@\S+>.*\d{4}') {
            throw "Contributor line '$c' carries no e-mail and four-digit year, so translate-toolkit will not recognise it as a contributor and Weblate will append a duplicate. Supply 'Name <e-mail>, year.'"
        }
    }
    $sb = [System.Text.StringBuilder]::new()
    $title = if ($Locale) { '# {0} translations for the {1}' -f (Get-NeoIPCPoLanguageName -Locale $Locale), $Product }
    else { "# Translations for the $Product" }
    [void]$sb.AppendLine($title)
    [void]$sb.AppendLine('# Copyright (C) Charité – Universitätsmedizin Berlin')
    [void]$sb.AppendLine("# This file is distributed under the $License license")
    [void]$sb.AppendLine('#')
    foreach ($c in $Contributor) { [void]$sb.AppendLine("# $c") }
    [void]$sb.AppendLine('msgid ""')
    [void]$sb.AppendLine('msgstr ""')
    [void]$sb.AppendLine('"Report-Msgid-Bugs-To: NeoIPC-Support@charite.de\n"')
    if (-not $Locale) {
        $stamp = if ($PotCreationDate) { $PotCreationDate } else { (Get-Date).ToString('yyyy-MM-dd HH:mmzzz') -replace ':(\d\d)$', '$1' }
        [void]$sb.AppendLine(('"POT-Creation-Date: {0}\n"' -f $stamp))
    }
    [void]$sb.AppendLine('"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\n"')
    [void]$sb.AppendLine(('"Language-Team: {0}\n"' -f $LanguageTeam))
    [void]$sb.AppendLine(('"Language: {0}\n"' -f $(if ($Locale) { $Locale } else { 'en' })))
    [void]$sb.AppendLine('"MIME-Version: 1.0\n"')
    [void]$sb.AppendLine('"Content-Type: text/plain; charset=UTF-8\n"')
    [void]$sb.AppendLine('"Content-Transfer-Encoding: 8bit\n"')
    if ($Locale) {
        if (-not $script:NeoIPCPoPluralForms.ContainsKey($Locale)) {
            throw "No plural rule known for locale '$Locale'. Add it to `$NeoIPCPoPluralForms in Private/PoHeader.ps1, taking the value Weblate writes for that language."
        }
        [void]$sb.AppendLine(('"Plural-Forms: {0}\n"' -f $script:NeoIPCPoPluralForms[$Locale]))
    }
    return ($sb.ToString() -replace "`r`n", "`n")
}
