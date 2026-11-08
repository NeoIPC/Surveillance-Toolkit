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
        Destination file path. Its directory must already exist. A relative path is resolved against
        PowerShell's current location, as every cmdlet resolves it; .NET alone would resolve it against
        the process's working directory, which a Set-Location does not change.

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

    $resolved = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.File]::WriteAllText($resolved, ($Text -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}


function Read-NeoIPCTextFile {
    <#
    .SYNOPSIS
        Read a file that must be UTF-8 without a BOM, once, as its bytes and its text.

    .DESCRIPTION
        Returns the bytes and the text from one read, so that a hash of the bytes is the hash of the very text a
        caller parses. A file that begins with a byte order mark, or holds bytes that are no valid UTF-8, is refused,
        with the file named, rather than decoded with the invalid bytes replaced or the mark kept as text; so is a path
        that names no file, and a file that cannot be read.

    .PARAMETER Path
        The file. A relative path is resolved against PowerShell's current location, a path on a PowerShell drive
        through its provider.

    .PARAMETER Noun
        What the file is, as the messages name it, such as 'list'.

    .OUTPUTS
        [pscustomobject] with Path, the file's full provider path, Bytes, and Text.

    .EXAMPLE
        $list = Read-NeoIPCTextFile -Path $Path -Noun 'list'

        Reads the list, refusing it if it is not UTF-8 without a BOM.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Noun
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "The $Noun '$resolved' is no file." }
    # A .NET exception ends only its own statement under the default error preference, so a failed read is thrown
    # again here, ending the call rather than leaving the caller to hash and parse an empty read.
    try { $bytes = [System.IO.File]::ReadAllBytes($resolved) }
    catch { throw "The $Noun '$resolved' cannot be read: $($_.Exception.Message)" }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "The $Noun '$resolved' begins with a byte order mark; it must be UTF-8 without one."
    }
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch [System.Text.DecoderFallbackException] { throw "The $Noun '$resolved' is not valid UTF-8: $($_.Exception.Message)" }
    [pscustomobject]@{ Path = $resolved; Bytes = $bytes; Text = $text }
}
