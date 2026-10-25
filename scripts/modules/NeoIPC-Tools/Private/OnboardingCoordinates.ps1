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
# with a point, separated by a comma, semicolon, or white space, optionally in parentheses. Returns nothing for text
# of another shape or a value outside the valid ranges.
function ConvertFrom-NeoIPCCoordinateText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $number = '[+-]?[0-9]{1,3}(?:\.[0-9]+)?'
    if ($Text.Trim() -cnotmatch "^\(?\s*(?<lat>$number)\s*[,;\s]\s*(?<lon>$number)\s*\)?$") { return }
    $latitude = [double]::Parse($Matches['lat'], [cultureinfo]::InvariantCulture)
    $longitude = [double]::Parse($Matches['lon'], [cultureinfo]::InvariantCulture)
    if ([math]::Abs($latitude) -gt 90 -or [math]::Abs($longitude) -gt 180) { return }
    [pscustomobject]@{ Latitude = $latitude; Longitude = $longitude }
}
