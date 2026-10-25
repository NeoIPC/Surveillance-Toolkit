#Requires -Version 7.6

<#
.SYNOPSIS
Build the NeoIPC hospital code from a hospital's UN/LOCODE and its acronym.

.DESCRIPTION
The hospital code is the UN/LOCODE of the hospital's location, written with an underscore for the space UN/LOCODE
puts between its country and location parts, another underscore, and the partner's acronym: country DE, location
BER, and acronym CHA give DE_BER_CHA. The code names the hospital organisation unit.

Every part must be upper case. The country is two letters, the location three characters of A-Z and 2-9 as
UN/LOCODE allows, and the acronym letters and digits: an underscore in it would make the code ambiguous. The cmdlet
checks the shape only. It does not look the UN/LOCODE up.

A part left out is asked for, in the order country, location, acronym. Before it asks for a missing country, the
cmdlet opens the UN/LOCODE list of countries in the default browser; before it asks for a missing location, it
opens the directory of the country, given or just entered, so each code can be looked up before it is typed. With
-NonInteractive, or in a session that Windows reports as having no user, a missing part is an error and nothing is
opened. Elsewhere .NET reports every session as having a user, so only -NonInteractive turns the questions off there.

.PARAMETER Country
The two-letter country part of the UN/LOCODE.

.PARAMETER Location
The three-character location part of the UN/LOCODE.

.PARAMETER Acronym
The partner's acronym, as commonly used.

.PARAMETER NonInteractive
Fail on a missing part instead of opening the directory and asking.

.OUTPUTS
System.String. The hospital code.

.EXAMPLE
New-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA

DE_BER_CHA

.EXAMPLE
New-NeoIPCHospitalCode -Country DE

Opens the UN/LOCODE directory of Germany, then asks for the location and the acronym.
#>
function New-NeoIPCHospitalCode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It builds a string in memory and changes no state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Country,

        [Parameter()]
        [string]$Location,

        [Parameter()]
        [string]$Acronym,

        [Parameter()]
        [switch]$NonInteractive
    )

    $shapes = [ordered]@{
        Country  = @{ Pattern = '^[A-Z]{2}$'; Expected = 'two upper-case letters, the UN/LOCODE country code' }
        Location = @{ Pattern = '^[A-Z2-9]{3}$'; Expected = 'three upper-case characters of A-Z and 2-9, the UN/LOCODE location code' }
        Acronym  = @{ Pattern = '^[A-Z0-9]+$'; Expected = 'upper-case letters and digits only' }
    }
    $values = @{ Country = $Country; Location = $Location; Acronym = $Acronym }

    foreach ($name in $shapes.Keys) {
        if (-not [string]::IsNullOrEmpty($values[$name]) -and $values[$name] -cnotmatch $shapes[$name].Pattern) {
            throw [System.ArgumentException]::new("The $($name.ToLowerInvariant()) '$($values[$name])' is not $($shapes[$name].Expected).", $name)
        }
    }

    $missing = @($shapes.Keys | Where-Object { [string]::IsNullOrEmpty($values[$_]) })
    if ($missing.Count -gt 0) {
        if (-not (Test-NeoIPCInteractive -NonInteractive:$NonInteractive)) {
            throw [System.ArgumentException]::new("Missing: $($missing -join ', ').", $missing[0])
        }
        # The directory page depends on the country, so the country is asked first and the page for the location is
        # opened once it is known; the list of countries is opened only to look the country up.
        foreach ($name in $missing) {
            if ($name -ceq 'Country' -or $name -ceq 'Location') {
                $url = Get-NeoIPCLocodeUrl -Country $values['Country']
                # Shown unless the caller says otherwise.
                Write-Information -MessageData "Opening the UN/LOCODE directory: $url" -InformationAction ($PSBoundParameters['InformationAction'] ?? 'Continue')
                Open-NeoIPCUrl -Url $url
            }
            $values[$name] = Read-NeoIPCHospitalCodePart -Name $name -Pattern $shapes[$name].Pattern -Expected $shapes[$name].Expected
        }
    }

    "$($values['Country'])_$($values['Location'])_$($values['Acronym'])"
}

<#
.SYNOPSIS
Settle the NeoIPC hospital code from the code itself, its parts, or both.

.DESCRIPTION
The code and its parts say the same thing, so either alone is enough, and both are accepted when they agree. With
the code alone, it is returned. With parts alone, New-NeoIPCHospitalCode builds the code and asks for what is
missing. With both, each part given is compared with the same part of the code; when they agree the code is
returned, and when any differs the call stops with -NonInteractive and otherwise asks which to use: the code, or the
parts, whose missing members then come from the code.

.PARAMETER HospitalCode
The whole code, such as DE_BER_CHA.

.PARAMETER Country
The two-letter country part of the UN/LOCODE.

.PARAMETER Location
The three-character location part of the UN/LOCODE.

.PARAMETER Acronym
The partner's acronym.

.PARAMETER NonInteractive
Fail on a contradiction or a missing part instead of asking.

.OUTPUTS
System.String. The hospital code.

.EXAMPLE
Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country DE

DE_BER_CHA
#>
function Resolve-NeoIPCHospitalCode {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$HospitalCode,

        [Parameter()]
        [string]$Country,

        [Parameter()]
        [string]$Location,

        [Parameter()]
        [string]$Acronym,

        [Parameter()]
        [switch]$NonInteractive
    )

    if ([string]::IsNullOrEmpty($HospitalCode)) {
        return New-NeoIPCHospitalCode -Country $Country -Location $Location -Acronym $Acronym -NonInteractive:$NonInteractive
    }
    if ($HospitalCode -cnotmatch '^(?<Country>[A-Z]{2})_(?<Location>[A-Z2-9]{3})_(?<Acronym>[A-Z0-9]+)$') {
        throw [System.ArgumentException]::new("The hospital code '$HospitalCode' does not have the form <country>_<location>_<acronym>.", 'HospitalCode')
    }
    $fromCode = @{ Country = $Matches['Country']; Location = $Matches['Location']; Acronym = $Matches['Acronym'] }
    $given = @{ Country = $Country; Location = $Location; Acronym = $Acronym }

    # The parts are checked for shape by New-NeoIPCHospitalCode, which also builds the code of a part set that is
    # complete once the code has filled in what is missing.
    $differing = @($fromCode.Keys | Sort-Object | Where-Object { -not [string]::IsNullOrEmpty($given[$_]) -and $given[$_] -cne $fromCode[$_] })
    if ($differing.Count -eq 0) { return $HospitalCode }

    $detail = ($differing | ForEach-Object { "$($_.ToLowerInvariant()) '$($given[$_])' against '$($fromCode[$_])'" }) -join ', '
    if (-not (Test-NeoIPCInteractive -NonInteractive:$NonInteractive)) {
        throw [System.ArgumentException]::new("The hospital code '$HospitalCode' and its parts contradict each other: $detail.", 'HospitalCode')
    }
    Write-Warning "The hospital code '$HospitalCode' and its parts contradict each other: $detail."
    while ($true) {
        $choice = Read-Host -Prompt 'Use the code (c) or the parts (p)?'
        # Read-Host returns nothing at the end of its input, where a session that looks interactive has nobody to ask.
        if ($null -eq $choice) {
            throw [System.ArgumentException]::new("The hospital code '$HospitalCode' and its parts contradict each other: $detail.", 'HospitalCode')
        }
        if ($choice.Trim() -ieq 'c') { return $HospitalCode }
        if ($choice.Trim() -ieq 'p') {
            $merged = @{}
            foreach ($name in $fromCode.Keys) { $merged[$name] = [string]::IsNullOrEmpty($given[$name]) ? $fromCode[$name] : $given[$name] }
            return New-NeoIPCHospitalCode -Country $merged.Country -Location $merged.Location -Acronym $merged.Acronym -NonInteractive
        }
        Write-Warning "'$choice' is neither c nor p."
    }
}
