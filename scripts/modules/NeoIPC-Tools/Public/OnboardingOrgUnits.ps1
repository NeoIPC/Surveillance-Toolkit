#Requires -Version 7.6

<#
.SYNOPSIS
Create a partner's hospital and department org units in DHIS2 and set them up for the NeoIPC Core program.

.DESCRIPTION
Creates the hospital below its country's org unit and the department below the hospital, puts each in its
org-unit groups, and assigns the department to the program NEOIPC_CORE. The units, the groups, and the program are
found by code. A country the country list holds is also looked for by the UID the list gives it, which it keeps in
DHIS2: to tell whether it exists, whether another org unit carries that UID, and whether a creation DHIS2 refused left
it behind.

A country the instance lacks is created first, from the toolkit's country list, the org-unit scaffold
common/organisationUnits.csv of -MetadataDirectory, so that the country in DHIS2 and in the list carry the same UID: it
gets the UID, name, short name, and opening date the list gives it, goes below the org unit that carries the code of its
parent there, and joins the group COUNTRY and the groups its rows in common/organisationUnitGroupMemberships.csv name,
its World Bank income classes. A country the list lacks too is added to it first, as Add-NeoIPCMetadataCountry adds
one, with -CountryName and -CountryShortName where given, which writes three files: common/organisationUnits.csv,
the country's income classes in common/organisationUnitGroupMemberships.csv, and its test units in
play/organisationUnits.csv. Its UID is drawn anew on each call, so the one -WhatIf shows is not the one a later run
writes. The files are written once the instance has been read and the country can be created there, and before it is;
a file that another run changed after the call read it ends the call before anything is written, since the entry would
discard that change. When the creation fails, what DHIS2 holds decides. A country DHIS2 refused and does not hold, as a
read by its UID after the refusal shows, leaves the files as they were, except one changed since by another run and
one that can no longer be read or written, each of which is named. A country DHIS2 holds although it answered with an
error, a failure DHIS2 did not answer with its refusal, such as a gateway's error or a dropped connection, after which
DHIS2 may still create the country, and a call stopped in between keep the list entry for the next run, which completes
the country or creates it with that UID; the call ends with a reminder to commit the three files. An org unit below the
parent which carries the country's name under another code, or one which carries the country's UID, ends the call before
anything is written, since the country would then exist twice.

The hospital joins the group HOSPITAL. The department joins the group NEO_DEPARTMENT and, by switch, the groups
NEOIPC_ALL_PATIENTS_ELIGIBLE and TEST_UNITS. A country that exists with the UID the country list gives it is completed
from the list: it joins COUNTRY when it is not in it, and the list's income-class group of each fiscal year the
instance gives it no class for, so that a run cut short after creating the country leaves no gap behind. A class the
instance gives for a year the list gives another for is left alone, with a warning, as is a group the instance lacks.
The groups of any other country that exists are not touched; it has to be in the group COUNTRY. A country without a
World Bank class draws a warning.

The cmdlet is safe to repeat. A unit that exists is kept, not changed, and only its missing memberships and, for the
department, a missing assignment to the program are added. A code names one unit in DHIS2, so a hospital whose
parent is not the country, or a department whose parent is not the hospital, ends the call before anything is
written, and so does a hospital or department that DHIS2 holds under another name than the one given, which may be
another partner's unit under the same code; names that differ only in case, in spaces at either end, or in whether a
letter with a diacritic is written as one character or two, count as the same. Every unit and membership is looked up
and written only within your hierarchy and with your authorities, so an org unit outside it reads as missing. A write
counts as done only when DHIS2's own answer says so, and the answer to a creation names the id; a write that fails
after the call wrote something names everything the call wrote, with its id.

Once everything has been read, the cmdlet asks once before it writes, naming the instance and listing every write:
the addition to the country list, the units it creates, and the memberships and the program assignment it adds.
-WhatIf shows that list and writes nothing, -Confirm:$false writes without asking, and a call with nothing to write
asks nothing. Where PowerShell cannot ask, as when it was started with -NonInteractive or its input has ended, the call
ends before it writes anything, listing what it would have written. Whatever -ErrorAction says, an error ends the call.

DHIS2 requires an opening date, a name of at most 230 characters, and a short name and a code of at most 50. The short
name defaults to the name when that fits, and the call stops when it does not, instead of cutting the name, as it stops
for a name or a code longer than DHIS2 allows. A code that an org unit outside your hierarchy carries reads as missing,
so DHIS2 refuses it only when the call writes the unit.

.PARAMETER Auth
Auth hashtable from Resolve-NeoIPCAuth (Token or Basic).

.PARAMETER CountryCode
The code of the country's org unit, such as DE.

.PARAMETER HospitalCode
The hospital code as New-NeoIPCHospitalCode builds it. It must begin with the country code and an underscore.

.PARAMETER HospitalName
The hospital's name.

.PARAMETER HospitalShortName
The hospital's short name. Default: the name.

.PARAMETER DepartmentCode
The department's code: the hospital code, an underscore, and upper-case letters A-Z or digits 0-9. Default: the
hospital code and '_NEO', since a hospital has one neonatology department; give it for the hospital that has more.

.PARAMETER DepartmentName
The department's name.

.PARAMETER DepartmentShortName
The department's short name. Default: the name.

.PARAMETER OpeningDate
The opening date of both units. Default: today. Tracker Capture, which DHIS2 2.41 and earlier bundle beside the
Capture app, offers no enrolment or event date before a unit's opening date, though neither the Capture app nor the
server checks it, so give the day surveillance starts when it comes before the onboarding.

.PARAMETER HospitalLatitude
The hospital's latitude in decimal degrees, with -HospitalLongitude: a number, or text that writes one with a decimal
point; blank text counts as none. A unit created with a position gets it as its point geometry; a unit that exists is
not changed.

.PARAMETER HospitalLongitude
The hospital's longitude in decimal degrees, given as -HospitalLatitude is.

.PARAMETER DepartmentLatitude
The department's latitude, given as -HospitalLatitude is, with -DepartmentLongitude, for a department that stands
elsewhere than its hospital. Default: the hospital's position.

.PARAMETER DepartmentLongitude
The department's longitude, given as -HospitalLatitude is.

.PARAMETER AllPatientsEligible
Put the department in the group NEOIPC_ALL_PATIENTS_ELIGIBLE.

.PARAMETER TestUnit
Put the department in the group TEST_UNITS.

.PARAMETER MetadataDirectory
The metadata directory whose country list a country the instance lacks is created from, and added to when the list
lacks it too. Default: the toolkit's own.

.PARAMETER CountryName
The name of a country the call adds to the country list. Default: the English name .NET gives the region; NeoIPC
names countries as the WHO style guide does, so give the WHO name where the two differ.

.PARAMETER CountryShortName
The short name of a country the call adds to the country list. Default: the name, when it fits in the 50 characters
DHIS2 allows.

.PARAMETER Scheme
http or https. Default https.

.PARAMETER Hostname
The DHIS2 host. Mandatory, with no default, so that every call names the instance it writes to.

.PARAMETER Port
The DHIS2 port. Default: the scheme's.

.OUTPUTS
System.Management.Automation.PSCustomObject. One record each for the hospital and the department, after one for a
country the call creates or completes, with Kind, Code, Id (empty for a unit that does not exist yet when -WhatIf or
a declined question leaves it uncreated), Created, the codes of the GroupsAdded, for the country whether the call
AddedToList, and for the department whether it was ProgramAssigned.

.EXAMPLE
Add-NeoIPCPartnerSite -Auth $auth -Hostname dhis2.example.org -CountryCode DE -HospitalCode DE_BER_CHA -HospitalName 'Example Hospital' -DepartmentName 'Example Hospital Neonatology' -WhatIf

Reads the instance and lists what would be written there: the hospital DE_BER_CHA and its department DE_BER_CHA_NEO,
their groups, and the department's assignment to NEOIPC_CORE.
#>
function Add-NeoIPCPartnerSite {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Auth,

        [Parameter(Mandatory)]
        [ValidateScript({ $_ -cmatch $script:NeoIPCHospitalCodeParts.Country.Pattern }, ErrorMessage = "The country code '{0}' is not two upper-case letters.")]
        [string]$CountryCode,

        [Parameter(Mandatory)]
        [ValidateScript({ $_ -cmatch $script:NeoIPCHospitalCodePattern }, ErrorMessage = "The hospital code '{0}' does not have the form <country>_<location>_<acronym>.")]
        [string]$HospitalCode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrWhiteSpace()]
        [string]$HospitalName,

        [Parameter()]
        [string]$HospitalShortName,

        [Parameter()]
        [string]$DepartmentCode,

        [Parameter(Mandatory)]
        [ValidateNotNullOrWhiteSpace()]
        [string]$DepartmentName,

        [Parameter()]
        [string]$DepartmentShortName,

        [Parameter()]
        [datetime]$OpeningDate = [datetime]::Today,

        [Parameter()]
        [object]$HospitalLatitude,

        [Parameter()]
        [object]$HospitalLongitude,

        [Parameter()]
        [object]$DepartmentLatitude,

        [Parameter()]
        [object]$DepartmentLongitude,

        [Parameter()]
        [switch]$AllPatientsEligible,

        [Parameter()]
        [switch]$TestUnit,

        [Parameter()]
        [string]$MetadataDirectory = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata'),

        [Parameter()]
        [string]$CountryName,

        [Parameter()]
        [string]$CountryShortName,

        [Parameter()] [string]$Scheme = 'https',
        [Parameter(Mandatory)] [string]$Hostname,
        [Parameter()] [Nullable[int]]$Port = $null
    )

    # Everything runs under Stop, so that a failure ends the call whatever the caller's preference: under
    # SilentlyContinue or Ignore, PowerShell drops a throw that no try encloses and runs on past it, into the writes.
    $ErrorActionPreference = 'Stop'
    # Resolved before anything is read, so that the question names the host the requests go to, and a host of white
    # space only ends the call first.
    $Hostname = Resolve-NeoIPCDhis2Hostname -Hostname $Hostname
    $target = Get-NeoIPCDhis2BaseUrl -Scheme $Scheme -Hostname $Hostname -Port $Port
    if (-not $HospitalCode.StartsWith("${CountryCode}_", [System.StringComparison]::Ordinal)) {
        throw [System.ArgumentException]::new("The hospital code '$HospitalCode' does not begin with the country code '${CountryCode}_'.", 'HospitalCode')
    }
    if ([string]::IsNullOrWhiteSpace($DepartmentCode)) { $DepartmentCode = "${HospitalCode}_NEO" }
    $HospitalLatitude = ConvertTo-NeoIPCCoordinate -Value $HospitalLatitude -Name 'HospitalLatitude'
    $HospitalLongitude = ConvertTo-NeoIPCCoordinate -Value $HospitalLongitude -Name 'HospitalLongitude'
    $DepartmentLatitude = ConvertTo-NeoIPCCoordinate -Value $DepartmentLatitude -Name 'DepartmentLatitude'
    $DepartmentLongitude = ConvertTo-NeoIPCCoordinate -Value $DepartmentLongitude -Name 'DepartmentLongitude'
    foreach ($pair in @(@('Hospital', $HospitalLatitude, $HospitalLongitude), @('Department', $DepartmentLatitude, $DepartmentLongitude))) {
        # The message names both halves, and the error the pair by its first, as Get-NeoIPCMapCoordinates does.
        if (($null -ne $pair[1]) -xor ($null -ne $pair[2])) {
            throw [System.ArgumentException]::new("Give the $($pair[0].ToLowerInvariant())'s latitude and longitude together, or neither.", "$($pair[0])Latitude")
        }
        # Asked as "within range", so that NaN, which no comparison holds for, is refused too.
        if ($null -ne $pair[1] -and -not ([math]::Abs($pair[1]) -le 90)) {
            throw [System.ArgumentOutOfRangeException]::new("$($pair[0])Latitude", $pair[1], "The $($pair[0].ToLowerInvariant())'s latitude lies between -90 and 90 degrees.")
        }
        if ($null -ne $pair[2] -and -not ([math]::Abs($pair[2]) -le 180)) {
            throw [System.ArgumentOutOfRangeException]::new("$($pair[0])Longitude", $pair[2], "The $($pair[0].ToLowerInvariant())'s longitude lies between -180 and 180 degrees.")
        }
    }
    # A department stands where its hospital does unless it is given a position of its own.
    $departmentAt = $null -ne $DepartmentLatitude ? @($DepartmentLatitude, $DepartmentLongitude) : ($null -ne $HospitalLatitude ? @($HospitalLatitude, $HospitalLongitude) : $null)
    $opening = $OpeningDate.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $units = @(
        @{ Kind = 'Hospital'; Code = $HospitalCode; Name = $HospitalName; ShortName = ($HospitalShortName ? $HospitalShortName : $HospitalName); OpeningDate = $opening; At = ($null -ne $HospitalLatitude ? @($HospitalLatitude, $HospitalLongitude) : $null) }
        @{ Kind = 'Department'; Code = $DepartmentCode; Name = $DepartmentName; ShortName = ($DepartmentShortName ? $DepartmentShortName : $DepartmentName); OpeningDate = $opening; At = $departmentAt }
    )
    # DHIS2 keeps a name to 230 characters, a short name and a code to 50, and a code to one org unit, so a value that
    # breaks any of these would be refused only after an earlier write, the country's or the hospital's.
    if ($DepartmentCode -ceq $HospitalCode) {
        throw [System.ArgumentException]::new("The department code '$DepartmentCode' is the hospital's code, and DHIS2 gives a code to one org unit only.", 'DepartmentCode')
    }
    # A department's code is its hospital's and a suffix, as <hospital>_NEO and the test departments' <country>_TEST_TEST
    # are, in the letters of the hospital code, so that one of another shape, such as one ending in a line feed, is refused
    # before it is looked up.
    if ($DepartmentCode -cnotmatch "\A$([regex]::Escape($HospitalCode))_[A-Z0-9]+\z") {
        throw [System.ArgumentException]::new("The department code '$DepartmentCode' is not the hospital code '$HospitalCode', an underscore, and upper-case letters A-Z or digits 0-9.", 'DepartmentCode')
    }
    foreach ($unit in $units) {
        if ($unit.Name.Length -gt 230) {
            throw [System.ArgumentException]::new("The $($unit.Kind.ToLowerInvariant()) name '$($unit.Name)' is $($unit.Name.Length) characters long, and DHIS2 allows 230.", "$($unit.Kind)Name")
        }
        if ($unit.ShortName.Length -gt 50) {
            throw [System.ArgumentException]::new("The $($unit.Kind.ToLowerInvariant()) short name '$($unit.ShortName)' is $($unit.ShortName.Length) characters long, and DHIS2 allows 50: give a short name.", "$($unit.Kind)ShortName")
        }
        if ($unit.Code.Length -gt 50) {
            throw [System.ArgumentException]::new("The $($unit.Kind.ToLowerInvariant()) code '$($unit.Code)' is $($unit.Code.Length) characters long, and DHIS2 allows 50.", "$($unit.Kind)Code")
        }
    }
    $units[0].Groups = @('HOSPITAL')
    $units[1].Groups = @('NEO_DEPARTMENT') +
        @(@{ NEOIPC_ALL_PATIENTS_ELIGIBLE = $AllPatientsEligible; TEST_UNITS = $TestUnit }.GetEnumerator() |
            Where-Object { $_.Value } | ForEach-Object { $_.Key } | Sort-Object)

    # A scheme given as empty text is left to the helpers, whose default, https, is the one the question names.
    $endpoint = @{ Auth = $Auth; Hostname = $Hostname }
    if ($Scheme) { $endpoint.Scheme = $Scheme }
    if ($null -ne $Port) { $endpoint.Port = $Port }
    $ordinal = [System.StringComparer]::Ordinal

    $readFields = 'name', 'parent[id]', 'organisationUnitGroups[code]', 'programs[id]'
    $found = Resolve-NeoIPCOrgUnit -Endpoint $endpoint -Code @($CountryCode, $HospitalCode, $DepartmentCode) -Fields $readFields
    $country = $found.ByCode.ContainsKey($CountryCode) ? $found.ByCode[$CountryCode] : $null
    $metadataRoot = [System.IO.Path]::GetFullPath($PSCmdlet.GetUnresolvedProviderPathFromPSPath($MetadataDirectory))
    $listPath = Join-Path $metadataRoot 'common' 'organisationUnits.csv'
    $listed = (Test-Path -LiteralPath $listPath -PathType Leaf) ? (Read-NeoIPCAuthoredOrgUnit -Path $listPath) : @()
    $entry = @($listed | Where-Object { [string]$_['code'] -ceq $CountryCode })
    $membershipPath = Join-Path $metadataRoot 'common' 'organisationUnitGroupMemberships.csv'
    $readListedGroups = {
        @(if (Test-Path -LiteralPath $membershipPath -PathType Leaf) {
                Read-NeoIPCMetadataCsv -Path $membershipPath | Where-Object { ([string]$_['organisationUnit']).Trim() -ceq $CountryCode } | ForEach-Object { ([string]$_['organisationUnitGroup']).Trim() }
            })
    }
    $listPlan = $null
    # The groups that complete a country that exists, which the instance may lack without ending the call.
    $completion = @()
    if ($country) {
        $present = @(Get-NeoIPCOrgUnitGroupCode -Unit $country)
        $countryId = [string]$country['id']
        $parentId = $countryId
        # A country with the UID the list gives it is the list's country, so it gets the list's groups it lacks:
        # COUNTRY, and an income class for each fiscal year the instance gives it none for. A run cut short after
        # creating the country thus leaves no gap. A class the instance gives for a year the list gives another for is
        # left alone, with a warning.
        if ($entry.Count -gt 0 -and [string]$entry[0]['id'] -ceq $countryId) {
            $lacking = [System.Collections.Generic.List[string]]::new()
            foreach ($groupCode in @('COUNTRY') + @(& $readListedGroups)) {
                if ($present -ccontains $groupCode -or $lacking -ccontains $groupCode) { continue }
                if ($groupCode -cmatch '^WORLD_BANK_CLASS_(?:H|UM|LM|L)_FY_(?<year>[0-9]{4})$') {
                    $year = $Matches['year']
                    $held = @($present | Where-Object { $_ -cmatch "^WORLD_BANK_CLASS_(?:H|UM|LM|L)_FY_$year`$" })
                    if ($held.Count -gt 0) {
                        Write-Warning "DHIS2 puts the country '$CountryCode' in $($held -join ' and ') for fiscal year $year, the country list in $groupCode; the country's class is left as it is."
                        continue
                    }
                }
                $lacking.Add($groupCode)
            }
            if ($lacking.Count -gt 0) {
                $completion = @($lacking | Where-Object { $_ -cne 'COUNTRY' })
                $units = @(@{
                        Kind = 'Country'; Code = $CountryCode; Id = $countryId; Name = [string]$entry[0]['name']; ShortName = [string]$entry[0]['shortName']
                        OpeningDate = [string]$entry[0]['openingDate']; At = $null; Groups = [string[]]$lacking.ToArray()
                    }) + $units
            }
            $present = @($present) + @($lacking)
        }
        elseif ($present -cnotcontains 'COUNTRY') {
            throw [System.InvalidOperationException]::new("The org unit '$CountryCode' is not a member of the group COUNTRY.")
        }
        if (@($present -match '^WORLD_BANK_CLASS_').Count -eq 0) {
            Write-Warning "The country '$CountryCode' is in no World Bank income class group, so its hospitals have no income class in reports."
        }
    }
    else {
        # The lookups stay within the hierarchy, so an org unit outside it reads as missing; the messages say both.
        $missing = "No org unit with the code '$CountryCode', which the country part of the hospital code '$HospitalCode' names, lies within the hierarchy these credentials reach"
        if ($entry.Count -gt 0) {
            $entry = $entry[0]
            $parentEntry = @($listed | Where-Object { $entry.Contains('parent') -and [string]$_['id'] -ceq [string]$entry['parent']['id'] })
            $parentCode = $parentEntry.Count -eq 1 ? [string]$parentEntry[0]['code'] : ''
            if (-not $parentCode) {
                throw [System.InvalidOperationException]::new("The country '$CountryCode' of the country list '$listPath' has no parent with a code there, and its parent is found in DHIS2 by that code.")
            }
            $planned = @{ Id = [string]$entry['id']; Name = [string]$entry['name']; ShortName = [string]$entry['shortName']; OpeningDate = [string]$entry['openingDate'] }
            $listedGroups = & $readListedGroups
        }
        else {
            # A country the list lacks is planned into it here and written into it below, once DHIS2 has been read.
            $listPlan = Get-NeoIPCMetadataCountryPlan -Code $CountryCode -Name $CountryName -ShortName $CountryShortName -MetadataDirectory $metadataRoot
            $parentCode = $listPlan.ParentCode
            $planned = @{ Id = $listPlan.Id; Name = $listPlan.Name; ShortName = $listPlan.ShortName; OpeningDate = $listPlan.OpeningDate }
            $listedGroups = @($listPlan.Groups)
        }
        $countryId = $planned.Id
        $near = Resolve-NeoIPCOrgUnit -Endpoint $endpoint -Code @($parentCode) -Id @($countryId) -Fields 'name'
        if ($near.ById.ContainsKey($countryId)) {
            throw [System.InvalidOperationException]::new("${missing}, but the org unit '$([string]$near.ById[$countryId]['code'])' there carries the UID $countryId, which is the one '$CountryCode' has in the country list '$listPath'.")
        }
        if (-not $near.ByCode.ContainsKey($parentCode)) {
            throw [System.InvalidOperationException]::new("${missing}, and the country cannot be created there, since its parent in the country list, '$parentCode', lies outside that hierarchy too.")
        }
        $parentId = [string]$near.ByCode[$parentCode]['id']
        # An org unit below the parent that carries the country's name under another code is the country already.
        $siblings = Get-NeoIPCHierarchyOrgUnit -Endpoint $endpoint -Filter "parent.id:eq:$parentId" -Fields 'name', 'code'
        $twin = @($siblings | Where-Object { [string]::Equals(([string]$_['name']).Trim().Normalize([System.Text.NormalizationForm]::FormD), $planned.Name.Trim().Normalize([System.Text.NormalizationForm]::FormD), [System.StringComparison]::OrdinalIgnoreCase) })
        if ($twin.Count -gt 0) {
            throw [System.InvalidOperationException]::new("${missing}, but the org unit '$([string]$twin[0]['name'])' below '$parentCode' carries the country's name under the code '$([string]$twin[0]['code'])': give it the code $CountryCode, or correct the country list, so that the country does not exist twice.")
        }
        $countryUnit = @{
            Kind = 'Country'; Code = $CountryCode; Id = $countryId; Name = $planned.Name; ShortName = $planned.ShortName; OpeningDate = $planned.OpeningDate; At = $null
            Groups = @('COUNTRY') + @($listedGroups | Where-Object { $_ -cne 'COUNTRY' } | Sort-Object -Unique -CaseSensitive)
        }
        if ($countryUnit.Name.Length -gt 230) {
            throw [System.InvalidOperationException]::new("The country list '$listPath' gives '$CountryCode' the name '$($countryUnit.Name)', which is longer than the 230 characters DHIS2 allows.")
        }
        if ($countryUnit.ShortName.Length -gt 50) {
            throw [System.InvalidOperationException]::new("The country list '$listPath' gives '$CountryCode' the short name '$($countryUnit.ShortName)', which is longer than the 50 characters DHIS2 allows.")
        }
        if (@($countryUnit.Groups -match '^WORLD_BANK_CLASS_').Count -eq 0) {
            Write-Warning "The country '$CountryCode' joins no World Bank income class group in the country list, so its hospitals have no income class in reports."
        }
        $units = @($countryUnit) + $units
    }
    # A unit that exists below another parent ends the call before anything is written, since a code names one unit.
    # A department found while its hospital is missing lies below another org unit too, as does a hospital found while
    # its country is.
    $hospital = $found.ByCode.ContainsKey($HospitalCode) ? $found.ByCode[$HospitalCode] : $null
    $department = $found.ByCode.ContainsKey($DepartmentCode) ? $found.ByCode[$DepartmentCode] : $null
    if ($hospital -and [string]$hospital['parent']['id'] -cne $countryId) {
        throw [System.InvalidOperationException]::new("The hospital '$HospitalCode' exists below another org unit than the country '$CountryCode'.")
    }
    if ($department -and -not $hospital) {
        throw [System.InvalidOperationException]::new("The department '$DepartmentCode' exists below another org unit than the hospital '$HospitalCode', which does not exist yet.")
    }
    if ($department -and [string]$department['parent']['id'] -cne [string]$hospital['id']) {
        throw [System.InvalidOperationException]::new("The department '$DepartmentCode' exists below another org unit than the hospital '$HospitalCode'.")
    }
    # Nothing keeps two partners from being given the same code, so a unit found by its code is this partner's only when
    # it carries the name given: otherwise the call would add memberships to another partner's unit, TEST_UNITS among
    # them.
    foreach ($check in @(
            @{ Kind = 'hospital'; Unit = $hospital; Code = $HospitalCode; Name = $HospitalName; Remedy = "give -HospitalName as DHIS2 has it if the hospital is this partner's, or another acronym" }
            @{ Kind = 'department'; Unit = $department; Code = $DepartmentCode; Name = $DepartmentName; Remedy = "give -DepartmentName as DHIS2 has it if the department is this partner's, or another -DepartmentCode" })) {
        if (-not $check.Unit) { continue }
        $held = [string]$check.Unit['name']
        # Decomposed, since a letter with a diacritic can be written as one character or two, as input methods differ, and
        # composing would make a pair that differs in case unequal where only one case has a character of its own (J and
        # j with a caron).
        $form = [System.Text.NormalizationForm]::FormD
        if (-not [string]::Equals($held.Trim().Normalize($form), $check.Name.Trim().Normalize($form), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw [System.InvalidOperationException]::new("The $($check.Kind) '$($check.Code)' exists in DHIS2 with the name '$held' and the id $([string]$check.Unit['id']), not with the name '$($check.Name)', so it may be another partner's: $($check.Remedy).")
        }
    }

    $groupCodes = [string[]]@($units | ForEach-Object { $_.Groups } | Sort-Object -Unique -CaseSensitive)
    $groupRead = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/organisationUnitGroups' -Filter "code:in:[$($groupCodes -join ',')]" -Fields 'id', 'code' -AsHashtable -Confirm:$false -WhatIf:$false
    $groupIds = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    foreach ($group in @($groupRead['organisationUnitGroups'])) { $groupIds[[string]$group['code']] = [string]$group['id'] }
    # DHIS2 returns only the metadata shared with the user, so a group or program it does not return may exist. A group
    # that would only complete a country that exists is left out with a warning, since the hospital and the department
    # do not need it; any other ends the call.
    $unknownGroups = @($groupCodes | Where-Object { -not $groupIds.ContainsKey($_) })
    $skipped = @($unknownGroups | Where-Object { $completion -ccontains $_ })
    $unknownGroups = @($unknownGroups | Where-Object { $completion -cnotcontains $_ })
    if ($unknownGroups.Count -gt 0) {
        throw [System.InvalidOperationException]::new("DHIS2 returns no org-unit group with the code $($unknownGroups -join ', ') to these credentials: it is missing, or not shared with this user.")
    }
    if ($skipped.Count -gt 0) {
        Write-Warning "DHIS2 returns no org-unit group with the code $($skipped -join ', ') to these credentials, so the country '$CountryCode' does not join it."
        foreach ($unit in @($units | Where-Object { $_.Kind -ceq 'Country' })) { $unit.Groups = [string[]]@($unit.Groups | Where-Object { $skipped -cnotcontains $_ }) }
        $units = @($units | Where-Object { $_.Kind -cne 'Country' -or $_.Groups.Count -gt 0 })
    }

    $programRead = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/programs' -Filter 'code:eq:NEOIPC_CORE' -Fields 'id', 'code' -AsHashtable -Confirm:$false -WhatIf:$false
    $program = @($programRead['programs'] | Where-Object { [string]$_['code'] -ceq 'NEOIPC_CORE' })
    if ($program.Count -ne 1) { throw [System.InvalidOperationException]::new('DHIS2 returns no program with the code NEOIPC_CORE to these credentials: it is missing, or not shared with this user.') }
    $programId = [string]$program[0]['id']

    # What each unit gets: created when it does not exist, then the groups it lacks, and for the department the program
    # assignment it lacks.
    foreach ($unit in $units) {
        $unit.Existing = $found.ByCode.ContainsKey($unit.Code) ? $found.ByCode[$unit.Code] : $null
        $present = $unit.Existing ? @(Get-NeoIPCOrgUnitGroupCode -Unit $unit.Existing) : @()
        $unit.Joins = [string[]]@($unit.Groups | Where-Object { $present -cnotcontains $_ })
        $unit.Assigns = $unit.Kind -ceq 'Department' -and -not ($unit.Existing -and @(@($unit.Existing['programs']) | Where-Object { $null -ne $_ -and [string]$_['id'] -ceq $programId }).Count -gt 0)
    }
    $andList = { param([string[]]$Items) $Items.Count -le 1 ? "$Items" : "$(@($Items | Select-Object -SkipLast 1) -join ', ')$($Items.Count -gt 2 ? ',' : '') and $($Items[-1])" }
    $groupText = { param([string[]]$Codes) "the group$($Codes.Count -gt 1 ? 's' : '') $(& $andList $Codes)" }
    # The files an entry is written to, the country list itself among them, as the messages name them.
    $listFiles = ''
    if ($listPlan) {
        $listFiles = "$(& $andList @($listPlan.Files | ForEach-Object { [System.IO.Path]::GetRelativePath($metadataRoot, $_.Path).Replace('\', '/') })) of '$metadataRoot'"
    }

    # Everything the call writes, in words, for the one question, which names the instance: a question for each write
    # would let a site be left half written, such as a country without its groups or a hospital without its department.
    $planned = [System.Collections.Generic.List[string]]::new()
    if ($listPlan) { $planned.Add("add $($listPlan.Summary) to the country list, in $listFiles") }
    foreach ($unit in $units) {
        $kind = $unit.Kind.ToLowerInvariant()
        $steps = [System.Collections.Generic.List[string]]::new()
        if (-not $unit.Existing) {
            $below = switch ($unit.Kind) { 'Country' { "'$parentCode'" } 'Hospital' { "the country '$CountryCode'" } default { "the hospital '$HospitalCode'" } }
            $steps.Add("create the $kind '$($unit.Code)' named '$($unit.Name)'$($unit.Id ? " with the id $($unit.Id)" : '') below $below")
        }
        $subject = $unit.Existing ? "the $kind '$($unit.Code)'" : 'it'
        if ($unit.Joins.Count -gt 0) { $steps.Add("add $subject to $(& $groupText $unit.Joins)") }
        if ($unit.Assigns) { $steps.Add("assign $($steps.Count -gt 0 ? 'it' : $subject) to the program NEOIPC_CORE") }
        if ($steps.Count -gt 0) { $planned.Add((& $andList $steps.ToArray())) }
    }
    $listing = @(for ($i = 0; $i -lt $planned.Count; $i++) { "  $($i + 1). $($planned[$i])" }) -join "`n"

    $listWritten = $false
    $newRecord = {
        param($Unit, $Id, [bool]$Created, [string[]]$Added, [bool]$Assigned)
        $record = [ordered]@{ Kind = $Unit.Kind; Code = $Unit.Code; Id = $Id; Created = $Created; GroupsAdded = [string[]]$Added }
        if ($Unit.Kind -ceq 'Country') { $record.AddedToList = $listWritten }
        if ($Unit.Kind -ceq 'Department') { $record.ProgramAssigned = $Assigned }
        [pscustomobject]$record
    }
    if ($planned.Count -gt 0) {
        # A PowerShell that cannot ask, one started with -NonInteractive, one whose input has ended, or a host without a
        # user interface, fails the question with an error, which under Stop ends the call before any write; the catch
        # gives that error the writes it would have made and the way to make them without asking.
        try { $confirmed = $PSCmdlet.ShouldProcess("On ${target}:`n$listing", "Write this on ${target}?`n$listing", 'Onboarding a partner site') }
        catch {
            throw [System.InvalidOperationException]::new("PowerShell could not ask before writing on $target, so nothing is written: give -Confirm:`$false to write without asking. The call would:`n$listing", $_.Exception)
        }
        if (-not $confirmed) {
            # Under -WhatIf, or declined: nothing is written, and the records show what exists.
            foreach ($unit in $units) { & $newRecord $unit ($unit.Existing ? [string]$unit.Existing['id'] : $null) $false @() $false }
            return
        }
    }

    # What this call writes: the list entry, the units it creates, and the memberships and the program assignment it
    # adds. The error of a later write names only identifiers, and a caller that keeps the output loses the records
    # written before it, so the error names them.
    $written = [System.Collections.Generic.List[string]]::new()
    $describeWrites = {
        param([string]$Kind, [string]$Code, [string]$Id, [bool]$Created, [string[]]$Added, [bool]$Assigned)
        $unitText = "the $($Kind.ToLowerInvariant()) '$Code' with the id $Id"
        if ($Created) { "created $unitText" }
        if ($Added.Count -gt 0) { "added $($Created ? 'it' : $unitText) to $(& $groupText $Added)" }
        if ($Assigned) { "assigned $(($Created -or $Added.Count -gt 0) ? 'it' : $unitText) to the program NEOIPC_CORE" }
    }
    # The list entry comes first, so that a run failing after it leaves a listed country that the next run creates, and
    # never a country in DHIS2 whose UID the list lacks. The writer keeps what the files held, for a country DHIS2
    # refuses, such as one outside the hierarchy that the lookups read as missing.
    $listBackup = $null
    if ($listPlan) {
        try { $listBackup = Write-NeoIPCMetadataCountryPlan -Plan $listPlan }
        catch { throw [System.InvalidOperationException]::new("The country '$CountryCode' could not be added to the country list: $($_.Exception.Message)", $_.Exception) }
        $listWritten = $true
        $written.Add("added the country '$CountryCode' to the country list with the id $countryId, in $listFiles")
    }
    # A call stopped by Ctrl+C during a write runs no catch block and nothing after the loop, so the finally block below
    # gives the reminder that the list entry is to be kept.
    $finished = $false
    $reported = $false
    try {
        foreach ($unit in $units) {
            $created = $false
            $id = $unit.Existing ? [string]$unit.Existing['id'] : $null
            $added = [System.Collections.Generic.List[string]]::new()
            $assigned = $false
            # Set for each unit, so that a failure before an answer reads no earlier answer, nor a variable of the session.
            $response = $null
            try {
                if (-not $unit.Existing) {
                    # A country brings the UID of the country list, which DHIS2 keeps for an object it creates.
                    $payload = [ordered]@{}
                    if ($unit.Id) { $payload['id'] = $unit.Id }
                    $payload['name'] = $unit.Name
                    $payload['shortName'] = $unit.ShortName
                    $payload['code'] = $unit.Code
                    $payload['openingDate'] = $unit.OpeningDate
                    $payload['parent'] = [ordered]@{ id = $parentId }
                    # GeoJSON orders a position longitude first.
                    if ($unit.At) { $payload['geometry'] = [ordered]@{ type = 'Point'; coordinates = @([double]$unit.At[1], [double]$unit.At[0]) } }
                    $body = ConvertTo-Json -Depth 100 -Compress -InputObject $payload
                    $response = Invoke-NeoIPCDhis2Post @endpoint -Path 'api/organisationUnits' -Body $body -Confirm:$false
                    Assert-NeoIPCDhis2WriteOk -Response $response -Path 'api/organisationUnits' -Auth $Auth
                    # DHIS2's answer to a creation names what it created (the object report's uid).
                    $id = [string]$response.Body.response.uid
                    if (-not $id) {
                        throw [System.InvalidOperationException]::new("DHIS2's answer to the creation of the $($unit.Kind.ToLowerInvariant()) '$($unit.Code)' names no id.")
                    }
                    $created = $true
                    if ($unit.Id -and $id -cne $unit.Id) {
                        throw [System.InvalidOperationException]::new("DHIS2 created the $($unit.Kind.ToLowerInvariant()) '$($unit.Code)' with the id $id instead of $($unit.Id), the one the country list gives it.")
                    }
                }
                foreach ($groupCode in $unit.Joins) {
                    $path = "api/organisationUnitGroups/$($groupIds[$groupCode])/organisationUnits/$id"
                    Assert-NeoIPCDhis2WriteOk -Response (Invoke-NeoIPCDhis2Post @endpoint -Path $path -Confirm:$false) -Path $path -Auth $Auth
                    $added.Add($groupCode)
                }
                if ($unit.Assigns) {
                    $path = "api/programs/$programId/organisationUnits/$id"
                    Assert-NeoIPCDhis2WriteOk -Response (Invoke-NeoIPCDhis2Post @endpoint -Path $path -Confirm:$false) -Path $path -Auth $Auth
                    $assigned = $true
                }
            }
            catch {
                $failure = $_
                $reported = $true
                if ($unit.Kind -ceq 'Country' -and $listWritten -and -not $created) {
                    # What DHIS2 holds decides whether the list is put back. After its refusal, which it gives once its
                    # transactions have ended, a read by UID tells; after any other failure DHIS2 may still commit the
                    # country, and a read would show only that it has not yet. Where the list keeps the entry, the next run
                    # completes the country or creates it with that UID.
                    $message = $failure.Exception.Message
                    if (-not (Test-NeoIPCDhis2Refusal -Response $response)) {
                        throw [System.InvalidOperationException]::new("Creating the country '$($unit.Code)' failed without DHIS2 refusing it, so DHIS2 may still create it: the country list keeps it with the id $($unit.Id), and the next run completes the country or creates it with that id; commit $($listFiles): $message", $failure.Exception)
                    }
                    $held = try { (Resolve-NeoIPCOrgUnit -Endpoint $endpoint -Id @($unit.Id) -Fields 'name').ById.ContainsKey($unit.Id) } catch { $null }
                    if ($null -eq $held) {
                        throw [System.InvalidOperationException]::new("DHIS2 refused the country '$($unit.Code)', and whether it holds the country could not be read, so the country list keeps it with the id $($unit.Id), and the next run completes the country or creates it with that id; commit $($listFiles): $message", $failure.Exception)
                    }
                    if ($held) {
                        throw [System.InvalidOperationException]::new("DHIS2 refused the country '$($unit.Code)' but holds it with the id $($unit.Id), so the country list keeps it, and the next run completes the country; commit $($listFiles): $message", $failure.Exception)
                    }
                    $why = @{ Changed = 'changed since the call wrote it'; Unreadable = 'could not be read'; Unwritable = 'could not be written back' }
                    $kept = @(Restore-NeoIPCFileBackup -Backup $listBackup.Before -Written $listBackup.Written | ForEach-Object { "$($_.Path), which $($why[$_.Reason])" })
                    $state = $kept.Count -eq 0 ? 'the country list is as it was before the call' : "the call put the country list back but for $($kept.Count -le 2 ? ($kept -join ', and ') : "$(@($kept | Select-Object -SkipLast 1) -join ', '), and $($kept[-1])")"
                    throw [System.InvalidOperationException]::new("DHIS2 refused the country '$($unit.Code)' and does not hold it, so $($state): $message", $failure.Exception)
                }
                $done = @($written) + @(& $describeWrites $unit.Kind $unit.Code $id $created $added.ToArray() $assigned)
                if ($done.Count -gt 0) {
                    # A country DHIS2 created with another UID than the list's would make the list wrong to commit.
                    $reminder = ($listWritten -and -not ($unit.Kind -ceq 'Country' -and $id -cne $countryId)) ? " Commit $listFiles, which give the country '$CountryCode' the id $countryId it has in DHIS2." : ''
                    throw [System.InvalidOperationException]::new("The call $($done -join '; '), but a later write failed: $($failure.Exception.Message)$reminder", $failure.Exception)
                }
                throw
            }

            & $newRecord $unit $id $created $added.ToArray() $assigned
            $written.AddRange([string[]]@(& $describeWrites $unit.Kind $unit.Code $id $created $added.ToArray() $assigned))

            $parentId = $id
        }
        $finished = $true
    }
    finally {
        if ($listWritten -and -not $finished -and -not $reported) {
            Write-Warning "The call stopped after it added the country '$CountryCode' to the country list with the id $countryId, in $($listFiles): DHIS2 may hold the country with that id, so keep the entry and commit the files; the next run completes the country or creates it with that id."
        }
    }
    if ($listWritten) {
        Write-Warning "The call added the country '$CountryCode' to the country list with the UID $countryId, in $($listFiles): commit them, since the country takes that UID in DHIS2 and the list has to keep it."
    }
}
