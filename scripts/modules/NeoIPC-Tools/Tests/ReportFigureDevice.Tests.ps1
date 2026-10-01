#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate holding the Partner and Reference Reports' PDF figures to the Cairo device in Noto Sans.

.DESCRIPTION
    Both reports declare PDF/A-4, which requires every font to be embedded. Quarto's `fig-format: pdf`
    selects R's pdf() device, which writes a figure's text in the standard Helvetica without embedding
    it; each report's _quarto.yml therefore sets knitr's chunk option `dev: cairo_pdf`, with the family
    "Noto Sans" as its device argument, under `format: pdf:`. Nothing else would notice that setting
    disappearing: the PDF still renders and still declares PDF/A-4.

    So the gate reads every Quarto configuration file of the two reports with powershell-yaml and
    requires the master to carry the setting. Everything else that could replace the device or its
    family is held to setting neither `dev` nor `dev.args` among knitr's chunk options, at the top level
    or under `format: pdf:`:
      1. a profile (`_quarto-*.yml`), which Quarto merges over the master. The language profiles
         other than English are generated from `_quarto-en.yml` and not checked in, so a fresh
         checkout holds them to it through their source;
      2. a directory's metadata (`_metadata.yml` or `_metadata.yaml`), which Quarto merges between
         the project's configuration and a document's, from the report's directory down to the
         document's (`directoryMetadataForInputFile` in quarto-cli's src/project/project-shared.ts);
      3. a document's own YAML, which Quarto reads from every block in a .qmd or .Rmd outside HTML
         comments and fenced code, concatenated. The blocks are found with the expressions Quarto
         itself uses (`readYamlFromMarkdown` in quarto-cli's src/core/yaml.ts), since no parser reads
         a .qmd's metadata short of Quarto, and each is then parsed with powershell-yaml;
      4. a figure chunk's own options, a line of its own (`#| dev: png`) or a key in the chunk header
         (`{r name, dev = "png"}`), indented or not, matched by regex because R's parser cannot read
         a whole .qmd file. Quarto hands a chunk's `dev-args` to knitr as `dev.args` and its
         `fig-format` as `dev` (src/resources/rmd/hooks.R in quarto-cli), so those names count too.
    Quarto's `fig-format` is not among them outside a chunk: Quarto derives knitr's `dev` from it and
    then merges the document's knitr chunk options over it (`knitr_options` in quarto-cli's
    src/resources/rmd/execute.R), so a `fig-format` in a profile or front matter cannot displace the
    Cairo device.

    What this cannot see is Quarto itself ceasing to honour format-level knitr options; the
    NeoIPC-Reporting integration test that inspects a rendered Partner Report's fonts covers that.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportFigureDevice.Tests.ps1
#>

BeforeDiscovery {
    $reports = @('Partner-Report', 'Reference-Report')
}

BeforeAll {
    Import-Module powershell-yaml -ErrorAction Stop
    $reportsDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'reports')).Path

    # Names each figure-device chunk option a parsed Quarto configuration sets, at the top level or
    # under `format: pdf:`.
    function Find-DeviceSetting {
        param([System.Collections.IDictionary] $Config)
        foreach ($scope in 'knitr', 'format.pdf.knitr') {
            $chunkOptions = $Config
            foreach ($key in $scope.Split('.') + 'opts_chunk') {
                $chunkOptions = if ($chunkOptions -is [System.Collections.IDictionary]) { $chunkOptions[$key] }
            }
            if ($chunkOptions -isnot [System.Collections.IDictionary]) { continue }
            foreach ($option in 'dev', 'dev.args') {
                if ($chunkOptions.Contains($option)) { "$scope.opts_chunk.$option" }
            }
        }
    }

    # The YAML Quarto reads from a .qmd or .Rmd, as one document, found the way quarto-cli's
    # readYamlFromMarkdown finds it.
    function Get-DocumentYaml {
        param([string] $Path)
        $multiline = [System.Text.RegularExpressions.RegexOptions]::Multiline
        $markdown = (Get-Content -Raw -LiteralPath $Path) -replace '\r\n?', "`n"
        $markdown = [regex]::Replace($markdown, '<!--[\W\w]*?-->', '', $multiline)
        $markdown = [regex]::Replace($markdown, '^([\t >]*`{3,})[^`\n]*\n[\W\w]*?\n\1\s*$', '', $multiline)
        $blocks = foreach ($match in [regex]::Matches($markdown,
                '(^)(---[ \t]*[\r\n]+(?![ \t]*[\r\n]+)[\W\w]*?[\r\n]+(?:---|\.\.\.))([ \t]*)$', $multiline)) {
            $block = $match.Groups[2].Value -replace '^---', '' -replace '---\s*$', ''
            $block = ($block -split "`n" | ForEach-Object TrimEnd) -join "`n"
            if (-not $block.StartsWith("`n`n") -and -not $block.StartsWith("`n---") -and $block.Trim()) { $block }
        }
        -join $blocks
    }
}

Describe 'The <_> draws its PDF figures with the Cairo device in Noto Sans' -ForEach $reports {
    BeforeAll {
        $reportDir = Join-Path $reportsDir $_
    }

    It 'sets dev: cairo_pdf with the family Noto Sans in its _quarto.yml' {
        $config = Get-Content -Raw -LiteralPath (Join-Path $reportDir '_quarto.yml') | ConvertFrom-Yaml
        $chunkOptions = $config.format.pdf.knitr.opts_chunk
        $chunkOptions.dev | Should -Be 'cairo_pdf'
        $chunkOptions.'dev.args'.cairo_pdf.family | Should -Be 'Noto Sans'
    }

    It 'has no profile that sets the device or its arguments' {
        $overrides = foreach ($file in Get-ChildItem -LiteralPath $reportDir -Filter '_quarto-*.yml') {
            $config = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Yaml
            if ($config -is [System.Collections.IDictionary]) {
                Find-DeviceSetting $config | ForEach-Object { "$($file.Name): $_" }
            }
        }
        $overrides | Should -BeNullOrEmpty
    }

    It 'has no directory metadata that sets the device or its arguments' {
        $overrides = foreach ($file in Get-ChildItem -LiteralPath $reportDir -Recurse -Include '_metadata.yml', '_metadata.yaml') {
            $config = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Yaml
            if ($config -is [System.Collections.IDictionary]) {
                $name = [System.IO.Path]::GetRelativePath($reportDir, $file.FullName)
                Find-DeviceSetting $config | ForEach-Object { "${name}: $_" }
            }
        }
        $overrides | Should -BeNullOrEmpty
    }

    It 'has no document whose YAML sets the device or its arguments' {
        $overrides = foreach ($file in Get-ChildItem -LiteralPath $reportDir -Recurse -Include '*.qmd', '*.Rmd') {
            $yaml = Get-DocumentYaml $file.FullName
            $config = if ($yaml) { ConvertFrom-Yaml $yaml }
            if ($config -is [System.Collections.IDictionary]) {
                Find-DeviceSetting $config | ForEach-Object { "$($file.Name): $_" }
            }
        }
        $overrides | Should -BeNullOrEmpty
    }

    It 'has no figure chunk that sets its own device or its arguments' {
        $chunkDevice = '^\s*#\|\s*(dev|dev[.-]args|fig-format|fig\.format)\s*:|^\s*`{3,}\s*\{r\b[^}]*\bdev(\.args)?\s*='
        $hits = Get-ChildItem -LiteralPath $reportDir -Recurse -Include '*.qmd', '*.Rmd' |
            Select-String -Pattern $chunkDevice |
            ForEach-Object { "$($_.Path | Split-Path -Leaf):$($_.LineNumber): $($_.Line.Trim())" }
        $hits | Should -BeNullOrEmpty
    }
}
