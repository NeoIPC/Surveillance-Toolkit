#Requires -Version 7.6

function Write-NeoIPCTextFile {
    <#
    .SYNOPSIS
        Write text to a file as UTF-8 without a BOM and with LF line endings, on every platform.

    .DESCRIPTION
        The single write point for this module's generated text artifacts, so the "LF and UTF-8
        without a BOM" contract is stated once instead of being re-derived at a dozen call sites.

        Two PowerShell defaults conspire against that contract on Windows, and both are easy to
        miss because each looks harmless on its own:

        - ConvertTo-Json indents with [Environment]::NewLine, so its output is ALREADY CRLF before
          anything is written. Passing it straight to [System.IO.File]::WriteAllText — which writes
          the string verbatim — produces a CRLF file even though WriteAllText itself adds nothing.
        - Set-Content / Out-File join pipeline items with [Environment]::NewLine and append one
          more, so they are never platform-neutral for multi-line output.

        Normalizing here catches both, and cannot be defeated by a caller that later switches to a
        different serialiser. Only CRLF is rewritten, never a lone CR: a bare 0x0D can be legitimate
        data inside a CSV cell, and silently rewriting it would corrupt content rather than reformat
        it. Callers writing CSV cells that may contain newlines handle that themselves.

        No trailing newline is added. The artifacts this writes are byte-compared against previous
        runs, so appending one would change every generated file for no benefit.

    .PARAMETER Path
        Destination file path. Its directory must already exist.

    .PARAMETER Text
        The full file contents. An empty string writes an empty file.

    .EXAMPLE
        Write-NeoIPCTextFile -Path $OutputPath -Text ($package | ConvertTo-Json -Depth 100)

        Writes the serialised package with LF line endings regardless of the platform that ran it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}
