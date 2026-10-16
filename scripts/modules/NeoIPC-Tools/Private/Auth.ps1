#Requires -Version 7.6
# The DHIS2 personal access token a caller gives, through -Token or the environment variable NEOIPC_DHIS2_TOKEN.

function Read-NeoIPCToken {
    # The token -Token holds or, when -Token is empty, the environment variable NEOIPC_DHIS2_TOKEN holds; $null when
    # neither holds a value, so that the caller can ask for a username and password instead. A value of a token's shape
    # (Test-DHIS2PersonalAccessToken) is the token; any other value must be the path of an existing file whose first line
    # is the token. A value that is neither ends the call with an error that names where the value came from. No message
    # holds the value or the file's content, since either may be a token.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Token)

    $value = $Token
    $source = '-Token'
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $env:NEOIPC_DHIS2_TOKEN
        $source = 'the environment variable NEOIPC_DHIS2_TOKEN'
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $value = $value.Trim()
    if (Test-DHIS2PersonalAccessToken -Token $value) { return $value }

    function New-TokenError([string]$ErrorId, [string]$Message, [System.Management.Automation.ErrorCategory]$Category, [Exception]$InnerException) {
        [System.Management.Automation.ErrorRecord]::new([System.ArgumentException]::new($Message, $InnerException), "NeoIPCToken$ErrorId", $Category, $source)
    }
    # Test-Path answers a value no path can be (one holding a NUL character, or one too long) with an error besides $false,
    # which would reach the console unless it stops here; and it takes an item of any provider for a leaf, an environment
    # variable (Env:\PATH) among them, while only a file counts.
    [bool]$isFile = $false
    try {
        $isFile = (Test-Path -LiteralPath $value -PathType Leaf -ErrorAction Stop) -and
            (Get-Item -LiteralPath $value -Force -ErrorAction Stop).PSProvider.Name -ceq 'FileSystem'
    }
    catch { $isFile = $false }
    if (-not $isFile) {
        $sentenceSource = $source.Substring(0, 1).ToUpperInvariant() + $source.Substring(1)
        throw (New-TokenError -ErrorId 'NotFound' -Category 'ObjectNotFound' `
                -Message "$sentenceSource holds neither a DHIS2 personal access token nor the path of an existing file.")
    }
    # The reason a read fails stays in the inner exception, whose message names the file.
    try { $line = Get-Content -LiteralPath $value -TotalCount 1 -Encoding utf8 -ErrorAction Stop }
    catch {
        throw (New-TokenError -ErrorId 'FileUnreadable' -Category 'ReadError' -InnerException $_.Exception `
                -Message "The token file that $source names could not be read.")
    }
    if ($null -eq $line) { throw (New-TokenError -ErrorId 'FileEmpty' -Category 'InvalidData' -Message "The token file that $source names is empty.") }
    $line = ([string]$line).Trim()
    if (-not (Test-DHIS2PersonalAccessToken -Token $line)) {
        throw (New-TokenError -ErrorId 'FileWithoutToken' -Category 'InvalidData' `
                -Message "The first line of the token file that $source names holds no DHIS2 personal access token.")
    }
    $line
}

function Format-NeoIPCMessageValue {
    # What a message or a result shows for a value the caller gave as an id: the value itself, unless it holds a personal
    # access token's prefix (d2p_ or d2pat_) anywhere, in any case, since a token given by mistake, even behind a space or
    # "ApiToken ", must not reach the console or a log. No UID holds a '_', so no UID is withheld.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([regex]::IsMatch($Value, 'd2p(?:at)?_', [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant')) {
        return '(a personal access token, not shown)'
    }
    $Value
}
