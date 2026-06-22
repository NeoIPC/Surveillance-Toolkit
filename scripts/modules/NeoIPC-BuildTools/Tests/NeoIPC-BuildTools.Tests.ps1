#requires -Module Pester

# Internals (Import-AntibioticPoTranslation) are exercised via InModuleScope so the private (non-exported) helpers
# are in scope. The Import-Module at file top runs during Pester's discovery phase, which InModuleScope requires
# (a BeforeAll import is too late — discovery would fail with "No modules named 'NeoIPC-BuildTools' are loaded").
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-BuildTools' {
    Describe 'Import-AntibioticPoTranslation' {
        BeforeAll {
            $script:poDir = Join-Path $TestDrive 'po'
            New-Item -ItemType Directory -Path $script:poDir -Force | Out-Null
            # A de catalogue exercising every branch: real translation, identical (untranslated), fuzzy, multi-line,
            # obsolete (#~), and the header. Only the real + multi-line entries should survive into the map.
            @(
                'msgid ""'
                'msgstr ""'
                '"Language: de\n"'
                ''
                'msgid "Meropenem"'
                'msgstr "Meropenem DE"'
                ''
                'msgid "Amikacin"'
                'msgstr "Amikacin"'
                ''
                '#, fuzzy'
                'msgid "Vancomycin"'
                'msgstr "Vancomycin DE"'
                ''
                'msgid "Multi"'
                'msgstr ""'
                '"Zeile1\n"'
                '"Zeile2"'
                ''
                '#~ msgid "Obsolete"'
                '#~ msgstr "Veraltet"'
                ''
                'msgid "Substance"'
                'msgstr "Substanz"'
            ) | Set-Content -LiteralPath (Join-Path $script:poDir 'antibiotics.de.po') -Encoding utf8NoBOM
        }

        It 'maps real translations and skips header / identical / fuzzy / obsolete entries' {
            $map = Import-AntibioticPoTranslation -PoDirectory $script:poDir -TargetCulture ([CultureInfo]'de')
            $map['Meropenem'] | Should -BeExactly 'Meropenem DE'
            $map['Substance'] | Should -BeExactly 'Substanz'
            $map.ContainsKey('Amikacin') | Should -BeFalse   # identical -> no real translation
            $map.ContainsKey('Vancomycin') | Should -BeFalse # fuzzy -> ignored (as gettext does)
            $map.ContainsKey('Obsolete') | Should -BeFalse   # #~ obsolete -> ignored
            $map.ContainsKey('') | Should -BeFalse            # header skipped
        }
        It 'reassembles a multi-line msgstr continuation' {
            $map = Import-AntibioticPoTranslation -PoDirectory $script:poDir -TargetCulture ([CultureInfo]'de')
            $map['Multi'] | Should -BeExactly "Zeile1`nZeile2"
        }
        It 'falls back along the culture parent chain (de-DE -> de)' {
            $map = Import-AntibioticPoTranslation -PoDirectory $script:poDir -TargetCulture ([CultureInfo]'de-DE')
            $map['Meropenem'] | Should -BeExactly 'Meropenem DE'
        }
        It 'returns an empty map when no catalogue exists for the culture' {
            $map = Import-AntibioticPoTranslation -PoDirectory $script:poDir -TargetCulture ([CultureInfo]'fr')
            $map.Count | Should -Be 0
        }
        It 'is case-sensitive (Ordinal) on the msgid key' {
            $map = Import-AntibioticPoTranslation -PoDirectory $script:poDir -TargetCulture ([CultureInfo]'de')
            $map.ContainsKey('meropenem') | Should -BeFalse
            $map.ContainsKey('Meropenem') | Should -BeTrue
        }
    }

    Describe 'New-AntibioticsList' {
        BeforeAll {
            $root = Join-Path $TestDrive 'abxlist'
            $abx = Join-Path $root 'meta' 'common' 'antibiotics'
            New-Item -ItemType Directory -Path $abx -Force | Out-Null
            @('id,atc_code,name,atc_group,aware_category',
                'J01DH02,J01DH02,Meropenem,J01DH,Watch',        # ATC code + AWaRe
                'tmp_001,,Micronomicin,J01GB,Watch',            # blank ATC code (tmp_* id) + AWaRe
                'J01XX99,J01XX99,Noclass,J01XX,') | Set-Content -LiteralPath (Join-Path $abx 'NeoIPC-Antibiotics.csv') -Encoding utf8NoBOM   # no AWaRe category
            @('id,value', 'substance,Substance', 'atc_code,ATC-Code', 'aware_category,AWaRe Category') | Set-Content -LiteralPath (Join-Path $abx 'ListElements.csv') -Encoding utf8NoBOM
            $po = Join-Path $root 'po'
            New-Item -ItemType Directory -Path $po -Force | Out-Null
            @('msgid ""', 'msgstr ""', '"Language: de\n"', '', 'msgid "Meropenem"', 'msgstr "Meropenem DE"', '', 'msgid "Substance"', 'msgstr "Substanz"') | Set-Content -LiteralPath (Join-Path $po 'antibiotics.de.po') -Encoding utf8NoBOM
            $script:listMeta = Join-Path $root 'meta'
        }

        It 'localizes the substance name and maps the AWaRe category to its badge letter' {
            $rows = @(New-AntibioticsList -TargetCulture ([CultureInfo]'de') -MetadataPath $script:listMeta)
            $rows.Count | Should -Be 3
            $mero = @($rows | Where-Object { $_.Id -eq 'J01DH02' })[0]
            $mero.Substance | Should -BeExactly 'Meropenem DE'
            $mero.AWaReCategory | Should -BeExactly 'W'
        }
        It 'guards a blank atc_code (tmp_* ids): no ATC code/url, AWaRe still present' {
            $rows = @(New-AntibioticsList -TargetCulture ([CultureInfo]'de') -MetadataPath $script:listMeta)
            $tmp = @($rows | Where-Object { $_.Id -eq 'tmp_001' })[0]
            $tmp.AtcCode | Should -BeExactly ''
            $tmp.AtcUrl | Should -BeNullOrEmpty
            $tmp.AWaReCategory | Should -BeExactly 'W'
        }
        It 'emits no AWaRe badge when the substance has no aware_category' {
            $rows = @(New-AntibioticsList -TargetCulture ([CultureInfo]'de') -MetadataPath $script:listMeta)
            $noclass = @($rows | Where-Object { $_.Id -eq 'J01XX99' })[0]
            $noclass.AWaReCategory | Should -BeNullOrEmpty
            $noclass.AWaReUrl | Should -BeNullOrEmpty
        }
        It 'falls back to the English name with a warning when no catalogue exists for the culture' {
            $rows = @(New-AntibioticsList -TargetCulture ([CultureInfo]'fr') -MetadataPath $script:listMeta -WarningAction SilentlyContinue)
            @($rows | Where-Object { $_.Id -eq 'J01DH02' })[0].Substance | Should -BeExactly 'Meropenem'
        }
        It 'AsciiDoc mode: localizes the header and renders a blank ATC cell for a tmp_* substance' {
            $ad = @(New-AntibioticsList -TargetCulture ([CultureInfo]'de') -MetadataPath $script:listMeta -AsciiDoc)
            @($ad | Where-Object { $_ -match '^\|Substanz \|' }).Count | Should -Be 1   # localized table header
            $tmpLine = @($ad | Where-Object { $_ -match 'Micronomicin' })[0]
            $tmpLine | Should -Match '^\|Micronomicin \| \|'                            # empty ATC cell
        }
    }
}
