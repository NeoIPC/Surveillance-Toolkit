#Requires -Version 7.6

# The Google Maps search for a place named by free text.
function Get-NeoIPCMapSearchUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Query
    )

    "https://www.google.com/maps/search/?api=1&query=$([uri]::EscapeDataString($Query))"
}

# A latitude and a longitude from the text Google Maps copies for a place ("52.5200, 13.4050"): two decimal numbers
# with a point and digits after it, separated by a comma, semicolon, or white space, optionally in parentheses, so
# that one number written with a decimal comma ("48,137") is no pair. Returns nothing for text of another shape or a
# value outside the valid ranges.
function ConvertFrom-NeoIPCCoordinateText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $number = '[+-]?[0-9]{1,3}\.[0-9]+'
    if ($Text.Trim() -cnotmatch "\A\(?\s*(?<lat>$number)\s*[,;\s]\s*(?<lon>$number)\s*\)?\z") { return }
    $latitude = [double]::Parse($Matches['lat'], [cultureinfo]::InvariantCulture)
    $longitude = [double]::Parse($Matches['lon'], [cultureinfo]::InvariantCulture)
    if ([math]::Abs($latitude) -gt 90 -or [math]::Abs($longitude) -gt 180) { return }
    [pscustomobject]@{ Latitude = $latitude; Longitude = $longitude }
}

# A coordinate a caller gives: nothing for $null or text that is empty or white space, the value of a number, and the
# number that text writes with a decimal point, read without thousands separators. A [double] parameter would take
# PowerShell's own conversion instead, which reads blank text as 0, and '6,5' as 65, its comma taken for a thousands
# separator. Anything else ends the call, naming the parameter.
function ConvertTo-NeoIPCCoordinate {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        $number = 0.0
        if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$number)) { return $number }
        throw [System.ArgumentException]::new("-$Name '$Value' is not a number of decimal degrees written with a point, such as 52.52.", $Name)
    }
    $type = [System.Type]::GetTypeCode($Value.GetType())
    if ($type -ge [System.TypeCode]::SByte -and $type -le [System.TypeCode]::Decimal) { return [double]$Value }
    throw [System.ArgumentException]::new("-$Name is a $($Value.GetType().Name), not a number of decimal degrees.", $Name)
}
