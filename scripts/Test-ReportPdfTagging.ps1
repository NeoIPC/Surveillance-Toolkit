#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Assert that rendered report PDFs carry the tagging structure their declarations claim.

.DESCRIPTION
    The reports declare archival PDF/A-4 alone, and a declaration a file does not honour is worse
    than no declaration: consumers trust it. This script opens the rendered PDFs and checks what
    the declarations oblige, in the file itself:

    1. every report's XMP declares pdfaid:part 4, since that identifier is where a consumer reads
       the archival claim, and none declares an accessibility standard, so no rendered file may
       carry a pdfuaid:part identifier of any value;
    2. no report is a tagged PDF: Quarto turns tagging on only for a standard that requires
       tagged structure, so a /StructTreeRoot or a /MarkInfo /Marked true under an a-4-only
       declaration means the file and its declaration disagree — a silently tagged file under an
       untagged declaration is the defect this catches;
    3. where a file nevertheless carries figure structure despite 2, the number of /Alt entries is
       at least the number of /S /Figure structure elements, so no figure stands wholly without
       accessible text. This one is a count, not a mapping: pairing each figure with its text is a
       conforming validator's job, and the count only proves no figure is missing one outright.
       Where an /Alt decodes to the image's own file name or path — the tagging engine's fallback
       whenever a figure reaches LaTeX without an alt key, which includes the bare Markdown image
       alt slot that Quarto hands to the caption instead of the graphicx alt key — the script
       reports it as a warning, which --FailOnPathAlt turns into a failure.

    A report-table row with Ua2 set turns the accessibility half around: that file must then carry
    /StructTreeRoot, /MarkInfo /Marked true, at least one /S /Sect heading structure element, and
    pdfuaid:part 2 in its XMP.

    The PDF objects live in compressed object streams, so there is nothing to read raw: the
    script decompresses each file with qpdf (`qpdf --decrypt --qdf --object-streams=disable`,
    which also rewrites cross-stream objects as ordinary ones) and matches the decoded text.
    There is no PDF parser in PowerShell; the qpdf QDF dump is the documented means of reading
    these files as text, and the patterns are line-anchored against it. qpdf is required.

    PDFs are matched to reports by file name: the rendered document of the Reference Report,
    whatever the build names it inside the report's output directory, must be handed in under a
    name containing the directory's (so Reference-Report.pdf or Reference-Report.de.pdf is
    accepted for the Reference Report). Every missing file fails the run: a green result always
    means all five were inspected. The run also fails when the report table and the `reports/`
    directories of the checkout holding this script disagree, so a report cannot join the tree on
    one side of the gate only.

.EXAMPLE
    pwsh scripts/Test-ReportPdfTagging.ps1 -RenderedDir tmp/renders

.PARAMETER RenderedDir
    Directory holding the rendered PDFs, named as above. Required.

.PARAMETER FailOnPathAlt
    Fail instead of warn where a figure's /Alt text decodes to its image's own file name or path.

.OUTPUTS
    Exit code 0 when every check passes, 1 otherwise. Nothing is modified.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RenderedDir,

    [switch] $FailOnPathAlt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command qpdf -ErrorAction Ignore)) {
    Write-Error 'qpdf is required to decompress the PDF object streams this script reads.' -ErrorAction Continue
    exit 1
}

# One row per report: whether it declares PDF/UA-2 next to a-4. No report declares ua-2 while the
# caption package — which Quarto's own pandoc filters load into the reports' PDF renders — stays
# recorded currently-incompatible with LaTeX tagging. The gate
# scripts/modules/NeoIPC-Tools/Tests/ReportPdfStandards.Tests.ps1 holds the configuration side.
$reports = @(
    @{ Name = 'Partner-Certificate'; Ua2 = $false }
    @{ Name = 'Partner-Report'; Ua2 = $false }
    @{ Name = 'Patient-Data-Report'; Ua2 = $false }
    @{ Name = 'Reference-Report'; Ua2 = $false }
    @{ Name = 'Validation-Report'; Ua2 = $false }
)

# The table must hold exactly the reports this checkout configures: a directory with a
# _quarto.yml outside the table would render ungated, and a row whose directory is gone inspects
# a PDF no build produces any more.
$configured = @(
    Get-ChildItem -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'reports') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '_quarto.yml') } |
        ForEach-Object Name
)
$drift = @(Compare-Object -ReferenceObject @($configured | Sort-Object) -DifferenceObject @($reports.Name | Sort-Object))
if ($drift) {
    $untabled = @($drift | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject) -join ', '
    $obsolete = @($drift | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject) -join ', '
    Write-Error "the report table and reports/ disagree: untabled [$untabled], obsolete [$obsolete]" -ErrorAction Continue
    exit 1
}

$resolved = (Resolve-Path -LiteralPath $RenderedDir).Path
$pdfs = Get-ChildItem -LiteralPath $resolved -File -Filter '*.pdf'
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($report in $reports) {
    $pdf = $pdfs | Where-Object Name -Like "*$($report.Name)*.pdf" | Select-Object -First 1
    if (-not $pdf) {
        $failures.Add("$($report.Name): no rendered PDF found in $resolved")
        continue
    }

    # qpdf exit 2 means errors, so it wrote nothing usable; exit 1 is reserved for how qpdf was
    # invoked. Exit 3 means warnings only, and these renders' duplicated-key warnings leave the
    # QDF stdout complete. Only 0 and 3 continue.
    $dump = (& qpdf --decrypt --qdf --object-streams=disable $pdf.FullName -) -join "`n"
    if ($LASTEXITCODE -ge 2 -and $LASTEXITCODE -ne 3) {
        $failures.Add("$($pdf.Name): qpdf found errors, so nothing usable was read (exit $LASTEXITCODE)")
        continue
    }

    $failuresBeforeFile = $failures.Count
    $hasStruct = $dump -match '(?m)^  /StructTreeRoot '
    # /MarkInfo may be inline or a reference; require /Marked true in whichever dictionary it
    # names, wherever it sits in it — key order is unconstrained.
    $markInfoInline = [regex]::Match($dump, '(?ms)^  /MarkInfo <<(.*?)>>')
    $markInfoRef = [regex]::Match($dump, '(?m)^  /MarkInfo (\d+) 0 R')
    $marked = $false
    if ($markInfoInline.Success) {
        $marked = $markInfoInline.Groups[1].Value -match '/Marked\s+true'
    }
    elseif ($markInfoRef.Success) {
        $markInfoObj = [regex]::Match($dump, "(?ms)^\r?\n?$($markInfoRef.Groups[1].Value) 0 obj\b(.*?)\r?\nendobj\b")
        $marked = $markInfoObj.Success -and $markInfoObj.Groups[1].Value -match '/Marked\s+true'
    }
    if ($report.Ua2) {
        if (-not $hasStruct) {
            $failures.Add("$($pdf.Name): declares ua-2 but has no /StructTreeRoot")
        }
        if (-not $markInfoInline.Success -and -not $markInfoRef.Success) {
            $failures.Add("$($pdf.Name): declares ua-2 but has no /MarkInfo")
        }
        elseif (-not $marked) {
            $failures.Add("$($pdf.Name): declares ua-2 but its /MarkInfo does not say /Marked true")
        }
        if ($dump -notmatch '(?m)^  /S /Sect$') {
            $failures.Add("$($pdf.Name): declares ua-2 but carries no /S /Sect heading structure")
        }
    }
    elseif ($hasStruct) {
        $failures.Add("$($pdf.Name): declares a-4 alone but is a tagged PDF")
    }
    elseif ($marked) {
        $failures.Add("$($pdf.Name): declares a-4 alone but marks its content /Marked true")
    }

    if ($dump -notmatch 'pdfaid:part>4') {
        $failures.Add("$($pdf.Name): XMP does not declare pdfaid:part 4")
    }
    $hasUaId = $dump -match 'pdfuaid:part>\d'
    if ($report.Ua2 -and $dump -notmatch 'pdfuaid:part>2') {
        $failures.Add("$($pdf.Name): XMP does not declare pdfuaid:part 2")
    }
    if (-not $report.Ua2 -and $hasUaId) {
        $failures.Add("$($pdf.Name): XMP declares a pdfuaid:part it does not conform to")
    }

    $figures = ([regex]::Matches($dump, '(?m)^  /S /Figure$')).Count
    $alts = ([regex]::Matches($dump, '(?m)^  /Alt ')).Count
    if ($figures -gt $alts) {
        $failures.Add("$($pdf.Name): $figures Figure elements but only $alts /Alt entries")
    }
    # The tagging engine defaults a figure's /Alt to its file path when the figure carries no
    # alt key. The decoded values come out of qpdf as UTF-16 hex strings; a written description
    # ends in prose, so anything ending in an image file name is that fallback — including a
    # same-directory figure's bare file name, which a path separator alone would miss.
    $pathAlts = [regex]::Matches($dump, '(?mi)^  /Alt <feff([0-9a-f]{4})+>$') |
        ForEach-Object {
            $bytes = [byte[]]::new($_.Groups[1].Captures.Count * 2)
            for ($i = 0; $i -lt $_.Groups[1].Captures.Count; $i++) {
                $hi = [Convert]::ToByte($_.Groups[1].Captures[$i].Value.Substring(0, 2), 16)
                $lo = [Convert]::ToByte($_.Groups[1].Captures[$i].Value.Substring(2, 2), 16)
                $bytes[2 * $i] = $hi
                $bytes[2 * $i + 1] = $lo
            }
            [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
        } |
        Where-Object { $_ -match '\.(?:png|jpe?g|pdf)$' }
    if ($pathAlts) {
        $message = "$($pdf.Name): figure /Alt decodes to its image's file name or path ($($pathAlts -join ', '))"
        if ($FailOnPathAlt) {
            $failures.Add($message)
        } else {
            Write-Warning $message
        }
    }

    $verdict = if ($failures.Count -gt $failuresBeforeFile) { 'FAIL' } else { 'OK  ' }
    Write-Host ("{0} {1}" -f $verdict, $pdf.Name) -NoNewline
    Write-Host (" struct={0} figures={1} alts={2}" -f $hasStruct, $figures, $alts)
}

if ($failures.Count) {
    foreach ($failure in $failures) {
        Write-Host "FAIL $failure"
    }
    exit 1
}
exit 0
