#Requires -Version 7.6

<#
.SYNOPSIS
Get the coordinates of a hospital, from parameters or from a person who looks them up on a map.

.DESCRIPTION
Returns the latitude and longitude, in decimal degrees (WGS 84, north and east positive), of the place a hospital
stands. Both given as parameters are validated and returned.

With neither given, in an interactive session, the cmdlet opens Google Maps in the default browser with a search for
-Query, and asks for the coordinates to be pasted as Google Maps copies them: right-click the place, click the
coordinates at the top of the menu, and paste ("52.5200, 13.4050"). An empty answer skips them, and an input that has
ended stops the call. A text of another shape, such as one number with a decimal comma, is asked for again. With
-NonInteractive, or in a session that Windows reports as having no user, nothing is opened or asked, and the cmdlet
returns nothing. A PowerShell started with -NonInteractive refuses the question, which the cmdlet learns only by
asking, so it returns nothing there too, after it has opened the map. Elsewhere than on Windows, .NET reports every
session as having a user.

Exactly one of -Latitude and -Longitude is an error, and so is a value outside +-90 degrees (latitude) or +-180
degrees (longitude). Whatever -ErrorAction says, an error ends the call.

.PARAMETER Latitude
The latitude in decimal degrees: a number, or text that writes one with a decimal point. Blank text counts as none.

.PARAMETER Longitude
The longitude in decimal degrees, given as -Latitude is.

.PARAMETER Query
What to search for on the map, usually the hospital's name and town. Required when coordinates may have to be asked
for.

.PARAMETER Label
What the coordinates are of, as the prompt names it, such as "the hospital". Default: "the place".

.PARAMETER NonInteractive
Return nothing for coordinates not given instead of opening the map and asking.

.OUTPUTS
System.Management.Automation.PSCustomObject. Latitude and Longitude as doubles, or nothing.

.EXAMPLE
Get-NeoIPCMapCoordinates -Query 'Example Hospital, Example Town'

Opens the map search and asks for the coordinates.
#>
function Get-NeoIPCMapCoordinates {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Coordinates is the established term for a latitude and longitude pair, and it is returned as one object.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [object]$Latitude,

        [Parameter()]
        [object]$Longitude,

        [Parameter()]
        [string]$Query,

        [Parameter()]
        [string]$Label = 'the place',

        [Parameter()]
        [switch]$NonInteractive
    )

    # Under Stop, so that a refused value ends the call whatever the caller's preference: under SilentlyContinue or
    # Ignore, PowerShell drops a throw that no try encloses and runs on past it, into returning the value.
    $ErrorActionPreference = 'Stop'
    $Latitude = ConvertTo-NeoIPCCoordinate -Value $Latitude -Name 'Latitude'
    $Longitude = ConvertTo-NeoIPCCoordinate -Value $Longitude -Name 'Longitude'
    if (($null -ne $Latitude) -xor ($null -ne $Longitude)) {
        throw [System.ArgumentException]::new('Give the latitude and the longitude together, or neither.', 'Latitude')
    }
    if ($null -ne $Latitude) {
        # Asked as "within range", so that NaN, which no comparison holds for, is refused too.
        if (-not ([math]::Abs($Latitude) -le 90)) { throw [System.ArgumentOutOfRangeException]::new('Latitude', $Latitude, 'The latitude lies between -90 and 90 degrees.') }
        if (-not ([math]::Abs($Longitude) -le 180)) { throw [System.ArgumentOutOfRangeException]::new('Longitude', $Longitude, 'The longitude lies between -180 and 180 degrees.') }
        return [pscustomobject]@{ Latitude = [double]$Latitude; Longitude = [double]$Longitude }
    }

    if (-not (Test-NeoIPCInteractive -NonInteractive:$NonInteractive)) { return }
    if ([string]::IsNullOrWhiteSpace($Query)) {
        throw [System.ArgumentException]::new('A query is needed to search the map.', 'Query')
    }

    $url = Get-NeoIPCMapSearchUrl -Query $Query
    # Shown unless the caller says otherwise.
    Write-Information -MessageData "Opening the map: $url" -InformationAction ($PSBoundParameters['InformationAction'] ?? 'Continue')
    Open-NeoIPCUrl -Url $url
    while ($true) {
        # A PowerShell started with -NonInteractive refuses the question (Test-NeoIPCInteractive says why that is not
        # known before): nobody can be asked, as with -NonInteractive.
        try { $answer = Read-Host -Prompt "Coordinates of $Label as copied from the map, latitude and longitude (empty to skip)" }
        catch [System.Management.Automation.PSInvalidOperationException] { return }
        # An empty answer skips the coordinates, so an input that has ended must not be taken for one.
        if ($null -eq $answer) { throw [System.OperationCanceledException]::new("The input ended before the coordinates of $Label.") }
        if ([string]::IsNullOrWhiteSpace($answer)) { return }
        $parsed = ConvertFrom-NeoIPCCoordinateText -Text $answer
        if ($parsed) { return $parsed }
        Write-Warning "'$answer' is not a latitude and a longitude in decimal degrees, such as 52.5200, 13.4050."
    }
}
