#Requires -Version 7.6

<#
.SYNOPSIS
Build the NeoIPC hospital code from a hospital's UN/LOCODE and its acronym.

.DESCRIPTION
The hospital code is the UN/LOCODE of the hospital's location, written with an underscore for the space UN/LOCODE
puts between its country and location parts, another underscore, and the partner's acronym: country DE, location
BER, and acronym CHA give DE_BER_CHA. The code names the hospital organisation unit.

Every part must be upper case. The country is two letters, the location three characters of A-Z and 2-9 as
UN/LOCODE allows, and the acronym the Latin letters A-Z and the digits 0-9: an underscore in it would make the code
ambiguous, and an acronym in another script or with diacritics is written in those letters. The cmdlet checks the
shape only. It does not look the UN/LOCODE up, and it asks for nothing: a part left out is an error.
Resolve-NeoIPCHospitalCode asks for a missing part instead, after opening the UN/LOCODE directory for a missing country
or location. Whatever -ErrorAction says, an error ends the call.

.PARAMETER Country
The two-letter country part of the UN/LOCODE.

.PARAMETER Location
The three-character location part of the UN/LOCODE.

.PARAMETER Acronym
The partner's acronym, as commonly used.

.OUTPUTS
System.String. The hospital code.

.EXAMPLE
New-NeoIPCHospitalCode -Country DE -Location BER -Acronym CHA

DE_BER_CHA
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
        [string]$Acronym
    )

    # Under Stop, so that a refused part ends the call whatever the caller's preference: under SilentlyContinue or
    # Ignore, PowerShell drops a throw that no try encloses and runs on past it, into a code of another shape.
    $ErrorActionPreference = 'Stop'
    $values = @{ Country = $Country; Location = $Location; Acronym = $Acronym }
    Assert-NeoIPCHospitalCodePart -Value $values
    $missing = @($script:NeoIPCHospitalCodeParts.Keys | Where-Object { [string]::IsNullOrEmpty($values[$_]) })
    if ($missing.Count -gt 0) {
        throw [System.ArgumentException]::new("Missing: $($missing -join ', ').", $missing[0])
    }

    "${Country}_${Location}_${Acronym}"
}

<#
.SYNOPSIS
Settle the NeoIPC hospital code from the code itself, its parts, or both, asking for what is missing.

.DESCRIPTION
The code and its parts say the same thing, so either alone is enough, and both are accepted when they agree. With
the code alone, it is returned. With parts alone, New-NeoIPCHospitalCode builds the code, after the cmdlet has asked
for any part left out, in the order country, location, acronym: before it asks for a missing country, it opens the
UN/LOCODE list of countries in the default browser, and before it asks for a missing location, the directory of the
country, given or just entered, so that each code can be looked up before it is typed. With both, each part given is
compared with the same part of the code; when they agree the code is returned, and when any differs the cmdlet asks
which to use: the code, or the parts, whose missing members then come from the code. A part given in another shape
than its own (New-NeoIPCHospitalCode describes them) ends the call before anything is opened or asked.

Nobody is asked, and a missing part or a contradiction is an error, with -NonInteractive or in a session that Windows
reports as having no user; nothing is opened then. A PowerShell started with -NonInteractive refuses the question, as
does a host without a user interface, such as the default host of a runspace a program creates, which the cmdlet
learns only by asking, so there it ends with the same error, after it has opened the UN/LOCODE page when the question
was for the country or the location; an input that has ended does the same. Elsewhere than on Windows, .NET reports
every session as having a user. Whatever -ErrorAction says, an error ends the call.

.PARAMETER HospitalCode
The whole code, such as DE_BER_CHA.

.PARAMETER Country
The two-letter country part of the UN/LOCODE.

.PARAMETER Location
The three-character location part of the UN/LOCODE.

.PARAMETER Acronym
The partner's acronym.

.PARAMETER NonInteractive
Fail on a missing part or a contradiction instead of opening the directory and asking.

.OUTPUTS
System.String. The hospital code.

.EXAMPLE
Resolve-NeoIPCHospitalCode -HospitalCode DE_BER_CHA -Country DE

DE_BER_CHA

.EXAMPLE
Resolve-NeoIPCHospitalCode -Country DE -Acronym CHA

Opens the UN/LOCODE directory of Germany, then asks for the location.
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

    # Under Stop, so that an error ends the call whatever the caller's preference: under SilentlyContinue or Ignore,
    # PowerShell drops a throw that no try encloses and runs on past it, into a code of another shape or, at a
    # contradiction nobody can settle, into asking without end.
    $ErrorActionPreference = 'Stop'
    $given = @{ Country = $Country; Location = $Location; Acronym = $Acronym }
    Assert-NeoIPCHospitalCodePart -Value $given

    if ([string]::IsNullOrEmpty($HospitalCode)) {
        $missing = @($script:NeoIPCHospitalCodeParts.Keys | Where-Object { [string]::IsNullOrEmpty($given[$_]) })
        if ($missing.Count -gt 0) {
            # Built when it is thrown, so that it names only the parts still missing then.
            $nobody = {
                $left = @($script:NeoIPCHospitalCodeParts.Keys | Where-Object { [string]::IsNullOrEmpty($given[$_]) })
                [System.ArgumentException]::new("Missing: $($left -join ', ').", $left[0])
            }
            if (-not (Test-NeoIPCInteractive -NonInteractive:$NonInteractive)) { throw (& $nobody) }
            try {
                # The directory page depends on the country, so the country is asked first and the page for the
                # location is opened once it is known; the list of countries is opened only to look the country up.
                foreach ($name in $missing) {
                    if ($name -ceq 'Country' -or $name -ceq 'Location') {
                        $url = Get-NeoIPCLocodeUrl -Country $given['Country']
                        # Shown unless the caller says otherwise.
                        Write-Information -MessageData "Opening the UN/LOCODE directory: $url" -InformationAction ($PSBoundParameters['InformationAction'] ?? 'Continue')
                        Open-NeoIPCUrl -Url $url
                    }
                    $answer = Read-NeoIPCHospitalCodePart -Name $name
                    # An input that has ended is nobody to ask, as at the contradiction below.
                    if ($null -eq $answer) { throw (& $nobody) }
                    $given[$name] = $answer
                }
            }
            # A PowerShell that cannot ask refuses the first question; Test-NeoIPCInteractive says why it is not known
            # before.
            catch [System.Management.Automation.PSInvalidOperationException], [System.Management.Automation.Host.HostException] { throw (& $nobody) }
        }
        return New-NeoIPCHospitalCode -Country $given['Country'] -Location $given['Location'] -Acronym $given['Acronym']
    }
    if ($HospitalCode -cnotmatch $script:NeoIPCHospitalCodePattern) {
        throw [System.ArgumentException]::new("The hospital code '$HospitalCode' does not have the form <country>_<location>_<acronym>.", 'HospitalCode')
    }
    $fromCode = @{ Country = $Matches['Country']; Location = $Matches['Location']; Acronym = $Matches['Acronym'] }

    $differing = @($fromCode.Keys | Sort-Object | Where-Object { -not [string]::IsNullOrEmpty($given[$_]) -and $given[$_] -cne $fromCode[$_] })
    if ($differing.Count -eq 0) { return $HospitalCode }

    $detail = ($differing | ForEach-Object { "$($_.ToLowerInvariant()) '$($given[$_])' against '$($fromCode[$_])'" }) -join ', '
    $contradiction = [System.ArgumentException]::new("The hospital code '$HospitalCode' and its parts contradict each other: $detail.", 'HospitalCode')
    if (-not (Test-NeoIPCInteractive -NonInteractive:$NonInteractive)) { throw $contradiction }
    Write-Warning "The hospital code '$HospitalCode' and its parts contradict each other: $detail."
    while ($true) {
        # Read-Host returns nothing at the end of its input, and a PowerShell that cannot ask refuses the question:
        # either way, nobody is there to choose.
        $choice = try { Read-Host -Prompt 'Use the code (c) or the parts (p)?' }
        catch [System.Management.Automation.PSInvalidOperationException], [System.Management.Automation.Host.HostException] { $null }
        if ($null -eq $choice) { throw $contradiction }
        if ($choice.Trim() -ieq 'c') { return $HospitalCode }
        if ($choice.Trim() -ieq 'p') {
            $merged = @{}
            foreach ($name in $fromCode.Keys) { $merged[$name] = [string]::IsNullOrEmpty($given[$name]) ? $fromCode[$name] : $given[$name] }
            return New-NeoIPCHospitalCode -Country $merged.Country -Location $merged.Location -Acronym $merged.Acronym
        }
        Write-Warning "'$choice' is neither c nor p."
    }
}
