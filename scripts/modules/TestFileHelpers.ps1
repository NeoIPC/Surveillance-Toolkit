#Requires -Version 7.6

# Shared test-only file writer for the Pester suites under scripts/modules/*/Tests/.
#
# Dot-source it from a test file's OUTERMOST BeforeAll, inside its InModuleScope block:
#
#     InModuleScope 'NeoIPC-Tools' {
#         BeforeAll {
#             . (Join-Path $PSScriptRoot '..' '..' 'TestFileHelpers.ps1')
#             ...
#         }
#
# That placement is not stylistic, it is the only one that works. Three were tried:
#   - a function at the test file's script scope is NOT visible inside InModuleScope (the block runs
#     in the module's session state, which does not see the test script's scope);
#   - a function defined at the top of the InModuleScope block body is defined during Pester's
#     DISCOVERY phase and is gone by the run phase;
#   - a dot-source (or definition) in the outermost BeforeAll runs in the RUN phase and lands in the
#     container scope every nested Describe/It — and their own BeforeAll blocks — inherits.
# All three were verified empirically against Pester 5 before this file was written.

function Set-TestFileContent {
    <#
    .SYNOPSIS
        Write a test fixture with LF line endings and UTF-8 without a BOM, on every platform.

    .DESCRIPTION
        A drop-in replacement for `Set-Content -LiteralPath ... -Encoding utf8` in fixture setup.
        Set-Content joins pipeline items with [Environment]::NewLine and appends one more, so the
        same fixture was CRLF on a Windows developer machine and LF on the Linux CI runner. Two
        consequences, and the second is the one that bites:

          - the suite silently exercised a different input encoding depending on where it ran, so a
            failure could reproduce on one platform and not the other;
          - a fixture built from a single string containing "`n" (the -Value form) came out MIXED —
            LF inside, CRLF terminator — which is the state that is corrupt rather than merely wrong.

        Line endings are pinned here so a fixture means the same thing everywhere. Tests that need to
        exercise CRLF input do so explicitly, by writing CRLF themselves, rather than by relying on
        which machine happens to run them.

        Every parameter mirrors Set-Content, including -Encoding, so converting a call site is a
        pure rename with nothing deleted. That matters: deleting ` -Encoding utf8` from ~100 call
        sites by textual replacement silently swallowed the trailing newline at every line that
        ended with it, merging statement pairs onto one line. A rename cannot do that.

    .PARAMETER LiteralPath
        Destination path. Its directory must already exist.

    .PARAMETER InputObject
        Fixture lines from the pipeline. Joined with LF.

    .PARAMETER Value
        Fixture lines passed as an argument instead of through the pipeline. A single string
        containing "`n" is written as-is (its embedded newlines are already LF).

    .PARAMETER NoNewline
        Omit the trailing newline, matching Set-Content's switch of the same name.

    .PARAMETER Encoding
        Accepted for drop-in compatibility with Set-Content, and honoured rather than ignored:
        'utf8' and 'utf8NoBOM' both write UTF-8 without a BOM (they are synonyms in PowerShell 7),
        'utf8BOM' writes one. Any other name throws instead of silently writing something else — an
        ignored parameter would hand a caller who asked for utf8BOM a BOM-less file and say nothing.

    .EXAMPLE
        @('id,code', 'ouAAAAAAAA1,AT') | Set-TestFileContent -LiteralPath (Join-Path $TestDrive 'ou.csv')

    .EXAMPLE
        Set-TestFileContent -LiteralPath $p -Value "id,code`nouAAAAAAAA1,AT" -NoNewline
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,

        [Parameter(ValueFromPipeline)]
        [AllowEmptyString()]
        [string[]]$InputObject,

        [string[]]$Value,

        [switch]$NoNewline,

        [string]$Encoding = 'utf8'
    )

    begin {
        $withBom = switch ($Encoding) {
            'utf8'      { $false }
            'utf8NoBOM' { $false }
            'utf8BOM'   { $true }
            default     { throw "Set-TestFileContent does not implement -Encoding '$Encoding'. Use utf8, utf8NoBOM or utf8BOM." }
        }
        $accumulated = [System.Collections.Generic.List[string]]::new()
    }

    process {
        if ($null -ne $InputObject) {
            foreach ($item in $InputObject) { $accumulated.Add($item) }
        }
    }

    end {
        $lines = if ($PSBoundParameters.ContainsKey('Value')) { @($Value) } else { $accumulated.ToArray() }
        $text = $lines -join "`n"
        if (-not $NoNewline -and $lines.Count) { $text += "`n" }
        # Normalize any CRLF the caller's own string literal carried in, so the written bytes are LF
        # regardless of how the fixture text was constructed.
        [System.IO.File]::WriteAllText($LiteralPath, ($text -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($withBom))
    }
}
