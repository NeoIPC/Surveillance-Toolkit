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
        the process's working directory, which a Set-Location does not change. A path on a drive of a
        provider other than the file system, or one that cannot be resolved, is refused, and nothing is written.

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

    $resolved = Resolve-NeoIPCFileSystemPath -Path $Path -Noun 'path'
    [System.IO.File]::WriteAllText($resolved, ($Text -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}


function Resolve-NeoIPCFileSystemPath {
    <#
    .SYNOPSIS
        Resolve a PowerShell path to the file-system path .NET reads and writes, refusing one outside the file
        system.

    .DESCRIPTION
        Resolves a relative path against PowerShell's current location, as every cmdlet does, and a path on a
        PowerShell drive through its provider; .NET alone would resolve a relative path against the process's
        working directory, which a Set-Location does not change. A path on a drive of a provider other than the
        file system, such as Variable:, is refused, with the item named: its provider path, such as a variable's
        name, is no file-system path, and .NET would take it for one relative to the process's working directory. A
        path that cannot be resolved, such as one on a drive that does not exist, is refused with the reason. A
        refused path is never returned, so that under a caller's SilentlyContinue, which drops the refusal, the
        caller has no path to write to.

    .PARAMETER Path
        The path, which must name an existing item where Existing is given.

    .PARAMETER Noun
        What the path names, as the messages name it, such as 'list'.

    .PARAMETER Existing
        Resolve the path to the item it names, which must exist, as Resolve-Path does; otherwise to where the
        item would be, as for a file still to be written.

    .OUTPUTS
        [string] The absolute file-system path.

    .EXAMPLE
        $resolved = Resolve-NeoIPCFileSystemPath -Path $Path -Noun 'list' -Existing

        Returns the file-system path of the list, or refuses a path on a drive of another provider.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Noun,

        [switch]$Existing
    )

    $provider = $null
    try {
        if ($Existing) {
            $item = Resolve-Path -LiteralPath $Path -ErrorAction Stop
            $provider = $item.Provider
            $resolved = $item.ProviderPath
        }
        else {
            $drive = $null
            $resolved = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
        }
    }
    catch { throw "The $Noun '$Path' cannot be resolved: $((Get-NeoIPCMethodException -Exception $_.Exception).Message)" }
    # The path is handed on only once accepted: under a caller's SilentlyContinue or Ignore, PowerShell drops a throw
    # that no try encloses and runs on past it, and a path handed on after it would be written relative to the
    # process's working directory.
    if ($provider.ImplementingType -ne [Microsoft.PowerShell.Commands.FileSystemProvider]) {
        throw "The $Noun '$Path' is on a drive of the $($provider.Name) provider, not in the file system."
    }
    else { $resolved }
}


function Get-NeoIPCMethodException {
    <#
    .SYNOPSIS
        Return the exception a .NET method threw, without the wrapper PowerShell puts around it.

    .DESCRIPTION
        PowerShell wraps an exception that a .NET method throws in a MethodInvocationException, whose message
        ("Exception calling ... with ... argument(s)", in the user's language) adds nothing to a refusal that
        names the file it concerns. The exception is unwrapped down to the one the method threw; any other is
        returned as it is.

    .PARAMETER Exception
        The exception, as a catch block gives it in $_.Exception.

    .OUTPUTS
        [System.Exception]

    .EXAMPLE
        catch {
            $cause = Get-NeoIPCMethodException -Exception $_.Exception
            throw "The list '$Path' cannot be read: $($cause.Message)"
        }

        Refuses a file with the reason .NET gives for it, without PowerShell's wrapper.
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $cause = $Exception
    while ($cause -is [System.Management.Automation.MethodInvocationException] -and $null -ne $cause.InnerException) {
        $cause = $cause.InnerException
    }
    $cause
}


function Get-NeoIPCYamlRefusalMessage {
    <#
    .SYNOPSIS
        Return the message that refuses a text that is not valid YAML, naming the file and where the parser
        stopped.

    .DESCRIPTION
        powershell-yaml runs YamlDotNet's parser through a .NET method, so a parse error reaches its caller in
        PowerShell's wrapper (Get-NeoIPCMethodException), and the line and column that YamlDotNet's exception marks
        are in neither message. The refusal names the file, gives that line and column where the exception marks
        them, and gives the parser's own message. powershell-yaml parses the text with a line break appended, so a
        mark at or past the text's end, as for an unclosed sequence, lies beyond the file's last line and is given as
        the end of the file.

    .PARAMETER Noun
        What the file is, as the message names it, such as 'list'.

    .PARAMETER Path
        The file the text was read from.

    .PARAMETER Text
        The text that was parsed, as it was read from the file.

    .PARAMETER Exception
        The exception the parse threw, as a catch block gives it in $_.Exception.

    .OUTPUTS
        [string]

    .EXAMPLE
        catch {
            throw (Get-NeoIPCYamlRefusalMessage -Noun 'list' -Path $list.Path -Text $list.Text -Exception $_.Exception)
        }

        Refuses a list that is not valid YAML, saying where in it the parser stopped.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Noun,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $cause = Get-NeoIPCMethodException -Exception $Exception
    $start = $cause.PSObject.Properties['Start']
    $where = ''
    if ($null -ne $start -and $null -ne $start.Value) {
        $mark = $start.Value
        $where = if ($mark.Index -ge $Text.Length) { ' at the end of the file' } else { " at line $($mark.Line), column $($mark.Column)" }
    }
    "The $Noun '$Path' is not valid YAML${where}: $($cause.Message)"
}


function Read-NeoIPCTextFile {
    <#
    .SYNOPSIS
        Read a file that must be UTF-8 without a BOM, once, as its bytes and its text.

    .DESCRIPTION
        Returns the bytes and the text from one read, so that a hash of the bytes is the hash of the very text a
        caller parses. A file that begins with a byte order mark, or holds bytes that are no valid UTF-8, is refused,
        with the file named, rather than decoded with the invalid bytes replaced or the mark kept as text; so is a path
        that names no file in the file system, and a file that cannot be read.

    .PARAMETER Path
        The file. A relative path is resolved against PowerShell's current location, a path on a PowerShell drive of
        the file system through its provider (Resolve-NeoIPCFileSystemPath).

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

    $resolved = Resolve-NeoIPCFileSystemPath -Path $Path -Noun $Noun -Existing
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "The $Noun '$resolved' is no file." }
    # A .NET exception ends only its own statement under the default error preference, so a failed read is thrown
    # again here, ending the call rather than leaving the caller to hash and parse an empty read.
    try { $bytes = [System.IO.File]::ReadAllBytes($resolved) }
    catch { throw "The $Noun '$resolved' cannot be read: $((Get-NeoIPCMethodException -Exception $_.Exception).Message)" }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "The $Noun '$resolved' begins with a byte order mark; it must be UTF-8 without one."
    }
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch [System.Text.DecoderFallbackException] { throw "The $Noun '$resolved' is not valid UTF-8: $($_.Exception.Message)" }
    [pscustomobject]@{ Path = $resolved; Bytes = $bytes; Text = $text }
}
