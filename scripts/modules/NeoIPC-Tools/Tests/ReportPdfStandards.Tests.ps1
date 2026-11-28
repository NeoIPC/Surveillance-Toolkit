#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate holding the five reports to the tagging-capable document class and to the PDF
    standard each report's own packages can honestly produce.

.DESCRIPTION
    PDF/UA-2 requires tagged structure, which only some classes and packages produce: the LaTeX
    Tagging Project's status table (https://latex3.github.io/tagging-project/tagging-status/)
    records scrartcl as incompatible with tagging — it emits every heading as ordinary paragraph
    text — and article as compatible, together with fancyhdr, float, placeins, geometry,
    graphicx, fontspec and the table packages the reports draw. Quarto turns tagging on only for
    a standard that requires tagged structure, so a ua-2 declaration belongs to the same change
    as a verified ground for it; with the caption package — which Quarto's own pandoc filters
    load into the reports' PDF renders — recorded currently-incompatible, no report declares ua-2
    and all five hold archival a-4. This gate reads each report's declaration and the class that
    grounds it with powershell-yaml from the master configuration, where Quarto resolves the
    declaration into \DocumentMetadata and the class into the \documentclass line.

    The Partner Certificate lays its single page out with the textpos package, which that table
    records as currently incompatible: under tagging its structure would be wrong, so its a-4
    declaration stands apart from the other reports', no matter what they declare.

    What this holds:
      1. each report's `_quarto.yml` sets `documentclass: article` and declares its standard
         under `format: pdf:` — all five article, and each `[a-4]` alone;
      2. no checked-in profile or local override sets `documentclass` or `pdf-standard` for a
         report, since Quarto merges profiles into the master's configuration (mergeProfiles in
         quarto-cli's src/project/project-profile.ts) and a language profile generated from
         `_quarto-en.yml` inherits whatever its source holds;
       3. nothing under `reports/` but `CHANGELOG.md` names KOMA-Script or its machinery — the
          classes, `scrlayer-scrpage` and its layer and font commands, its `footsepline` class
          option, `wrapfig` (incompatible with tagging and used nowhere), and the `\ihead` /
          `\ifoot` / `\ofoot` / `\pagemark` furniture. `\cfoot` names scrlayer-scrpage and
          fancyhdr alike, and bare `koma` is the German word for coma, so neither joins the
          needles; a returning KOMA class or package answers to the rest;
       4. the report table covers exactly the directories under `reports/` that hold a
          `_quarto.yml`, so a new report cannot grow beside the gate ungated.

    What this cannot see is whether a rendered PDF carries the tag tree the declaration asserts;
    scripts/Test-ReportPdfTagging.ps1 inspects rendered files for that.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportPdfStandards.Tests.ps1
#>

BeforeDiscovery {
    $reports = @(
        @{ Name = 'Partner-Certificate'; PdfStandard = @('a-4') }
        @{ Name = 'Partner-Report'; PdfStandard = @('a-4') }
        @{ Name = 'Patient-Data-Report'; PdfStandard = @('a-4') }
        @{ Name = 'Reference-Report'; PdfStandard = @('a-4') }
        @{ Name = 'Validation-Report'; PdfStandard = @('a-4') }
    )
}

BeforeAll {
    Import-Module powershell-yaml -ErrorAction Stop
    $reportsDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' 'reports')).Path
}

Describe 'The <Name> declares the tagging-capable class and an honest PDF standard' -ForEach $reports {
    It 'sets documentclass: article in its _quarto.yml' {
        $config = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $reportsDir $Name) '_quarto.yml') |
            ConvertFrom-Yaml
        $config.format.pdf.documentclass | Should -Be 'article'
    }

    It 'declares pdf-standard <PdfStandard> in its _quarto.yml' {
        $config = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $reportsDir $Name) '_quarto.yml') |
            ConvertFrom-Yaml
        @($config.format.pdf.'pdf-standard') | Should -Be $PdfStandard
    }

    It 'sets papersize: a4, the value the template turns into the a4paper class option' {
        # Quarto's template emits `$papersize$paper`, so `a4paper` reaches the class as
        # `a4paperpaper`: KOMA-Script ignores the unknown option and renders A4 from its
        # own default, article ignores it and renders US letter.
        $config = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $reportsDir $Name) '_quarto.yml') |
            ConvertFrom-Yaml
        $config.format.pdf.papersize | Should -Be 'a4'
    }

    It 'leaves documentclass and pdf-standard to the master in every checked-in profile' {
        $reportDir = Join-Path $reportsDir $Name
        $offenders = foreach ($file in Get-ChildItem -LiteralPath $reportDir -File |
                Where-Object Name -Match '^_quarto-.+\.ya?ml$|^_quarto\.ya?ml\.local$') {
            $config = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Yaml
            if ($config.format.pdf -is [System.Collections.IDictionary]) {
                foreach ($key in 'documentclass', 'pdf-standard') {
                    if ($config.format.pdf.Contains($key)) { "$($file.Name): $key" }
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Nothing under reports/ names KOMA-Script or its machinery' {
    It 'holds every source free of the class, its page furniture, and wrapfig' {
        # Plain-text patterns matched case-insensitively. CHANGELOG.md names the old class in
        # its history and is not rewritten, so it stays out of the scan.
        $needles = @(
            'scrartcl', 'scrbook', 'scrreprt', 'scrlayer', 'scrheadings', 'scrbase',
            'koma-script', 'komascript', 'komafont',
            'footsepline', 'wrapfig',
            '\ModifyLayer', '\ihead', '\ifoot', '\ofoot', '\pagemark'
        )
        $sources = Get-ChildItem -LiteralPath $reportsDir -Recurse -Include `
            '*.qmd', '*.Rmd', '*.R', '*.tex', '*.lua', '*.yml', '*.yaml', '*.json', '*.md' |
            Where-Object FullName -NotMatch '[\\/]_output[\\/]'
        $hits = foreach ($needle in $needles) {
            $sources | Select-String -SimpleMatch -Pattern $needle |
                Where-Object { -not $_.Path.EndsWith([System.IO.Path]::DirectorySeparatorChar + 'CHANGELOG.md') } |
                ForEach-Object {
                    "$needle at $([System.IO.Path]::GetRelativePath($reportsDir, $_.Path)):$($_.LineNumber)"
                }
        }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'The report table covers the reports that exist' -ForEach @(@{ Table = $reports }) {
    It 'holds one row per directory under reports/ with a _quarto.yml' {
        # A directory outside the table escapes the per-report tests; a row without its
        # directory fails those tests on the missing _quarto.yml.
        $configured = @(
            Get-ChildItem -LiteralPath $reportsDir -Directory |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '_quarto.yml') } |
                ForEach-Object Name | Sort-Object
        )
        $configured | Should -Be @($Table.Name | Sort-Object)
    }
}
