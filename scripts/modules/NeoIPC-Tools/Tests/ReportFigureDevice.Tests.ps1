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

    So the gate reads every Quarto configuration file of the two reports, profiles included, with
    powershell-yaml and requires the master to carry the setting and no profile to set another device.
    A figure chunk can override the device in its own options as well, so the report sources are held
    to setting none. Those are matched by regex, because R's parser cannot read a .qmd whole and a chunk
    option is a line of its own (`#| dev: png`) or a key in the chunk header (`{r name, dev = "png"}`).

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

    It 'has no profile that sets another device' {
        $overrides = foreach ($file in Get-ChildItem -LiteralPath $reportDir -Filter '_quarto-*.yml') {
            $config = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Yaml
            $device = $config.format.pdf.knitr.opts_chunk.dev
            if ($null -ne $device -and $device -ne 'cairo_pdf') { "$($file.Name): dev: $device" }
        }
        $overrides | Should -BeNullOrEmpty
    }

    It 'has no figure chunk that sets its own device' {
        $chunkDevice = '^\s*#\|\s*(dev|fig-format|fig\.format)\s*:|^```\{r[^}]*\bdev\s*='
        $hits = Get-ChildItem -LiteralPath $reportDir -Recurse -Include '*.qmd', '*.Rmd' |
            Select-String -Pattern $chunkDevice |
            ForEach-Object { "$($_.Path | Split-Path -Leaf):$($_.LineNumber): $($_.Line.Trim())" }
        $hits | Should -BeNullOrEmpty
    }
}
