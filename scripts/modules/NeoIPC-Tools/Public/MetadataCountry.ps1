#Requires -Version 7.6

<#
.SYNOPSIS
Add a country to the org-unit scaffold of the metadata directory, with its World Bank income classes and its test units
in the play package.

.DESCRIPTION
Adds the country with the ISO 3166-1 alpha-2 code -Code to common/organisationUnits.csv of -MetadataDirectory, the
org-unit scaffold that the play package is built from and that Add-NeoIPCPartnerSite creates a country from when a
DHIS2 instance lacks it. The country gets a random UID, drawn once and kept from then on, so that the country an
onboarding creates in DHIS2 and the scaffold carry the same UID. Its parent, its level, and its opening date follow
from the scaffold's root.

Its name is the English name .NET gives the region, from the platform's globalization data, so that it can differ
between machines, unless -Name gives another. NeoIPC names countries as the WHO style guide does, which differs for
some: .NET calls KR "Korea", WHO the "Republic of Korea".

Its memberships in the World Bank income-class groups come from the World Bank, one for each fiscal year that the
scaffold's groups WORLD_BANK_CLASS_<class>_FY_<year> cover, and go into common/organisationUnitGroupMemberships.csv.
The class of each year is read from the World Bank's "historical classification by income" workbook, which is
downloaded unless -ClassificationHistoryPath names a copy. The World Bank's
API gives the economy's own code, by which the workbook lists it, and its current class, which the workbook's newest
year has to match, so that a workbook older than the API's classification stops the call. A year in which the World Bank
did not classify the economy gets no membership and a warning. The World Bank publishes both under the Creative Commons
Attribution 4.0 licence, which asks for it to be credited as the source.

The play package gets the country's test hospital <code>_TEST and test department <code>_TEST_TEST in
play/organisationUnits.csv, as every country has there.

Each row goes where the order of its file puts it, and every other row stays as it is. Nothing is written until every
source has been read and checked, and the three files are written all or none: a write that fails puts back the files
written before it and ends the call. -WhatIf reads the sources and writes nothing. No DHIS2 instance is called.

The World Bank's API does not serve every economy its workbook classifies (TW, which the workbook lists as TWN); for
such a code the workbook is read by the ISO alpha-3 code, without the API's check of its newest year, and a warning
says so.

.PARAMETER Code
The country's ISO 3166-1 alpha-2 code, such as AR, which becomes its org-unit code.

.PARAMETER Name
The country's name. Default: the English name .NET gives the region.

.PARAMETER ShortName
The country's short name, which DHIS2 allows 50 characters. Default: the name, when it fits.

.PARAMETER MetadataDirectory
The metadata directory, which holds common/ and play/. Default: the toolkit's own.

.PARAMETER ClassificationHistoryPath
A copy of the World Bank's "historical classification by income" workbook (OGHIST.xlsx). Without it, the workbook is
downloaded from the World Bank and deleted after reading. Reading it needs the DocumentFormat.OpenXml assembly that the
module provisions under lib/.

.OUTPUTS
System.Management.Automation.PSCustomObject. The country: Code, Id, Name, ShortName, IncomeClass (fiscal year to class,
for the years the groups cover), the Groups it joins, the codes of its TestHospital and TestDepartment, and whether it
was Added, which it is not under -WhatIf, whose Id a real run draws anew.

.EXAMPLE
Add-NeoIPCMetadataCountry -Code AR -WhatIf

Reads the World Bank's classification of Argentina and shows what would be added, without writing.

.EXAMPLE
Add-NeoIPCMetadataCountry -Code KR -Name 'Republic of Korea'

Adds the Republic of Korea under the name the WHO style guide gives it.
#>
function Add-NeoIPCMetadataCountry {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ $_ -cmatch '^[A-Z]{2}$' }, ErrorMessage = "The country code '{0}' is not two upper-case letters.")]
        [string]$Code,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$ShortName,

        [Parameter()]
        [string]$MetadataDirectory = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata'),

        [Parameter()]
        [string]$ClassificationHistoryPath
    )

    $plan = Get-NeoIPCMetadataCountryPlan -Code $Code -Name $Name -ShortName $ShortName -MetadataDirectory $MetadataDirectory -ClassificationHistoryPath $ClassificationHistoryPath
    $added = $false
    if ($PSCmdlet.ShouldProcess($plan.Directory, "Add $($plan.Summary)")) {
        [void](Write-NeoIPCMetadataCountryPlan -Plan $plan)
        $added = $true
    }

    [pscustomobject]@{
        Code           = $plan.Code
        Id             = $plan.Id
        Name           = $plan.Name
        ShortName      = $plan.ShortName
        IncomeClass    = $plan.IncomeClass
        Groups         = $plan.Groups
        TestHospital   = $plan.TestHospital
        TestDepartment = $plan.TestDepartment
        Added          = $added
    }
}
