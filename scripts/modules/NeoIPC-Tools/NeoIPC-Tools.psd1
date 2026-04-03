# Module manifest for module 'NeoIPC-Tools'
#
# Author: Brar Piening
#
@{
    # Script module file associated with this manifest.
    RootModule = 'NeoIPC-Tools.psm1'

    # Version number of this module.
    ModuleVersion = '0.1.0.0'

    # ID used to uniquely identify this module
    GUID = 'd8df5879-3dff-4c3d-ba9e-cbc1205340c1'

    # Author of this module
    Author = 'Brar Piening'

    # Company or vendor of this module
    CompanyName = 'NeoIPC Project'

    # Copyright statement for this module
    Copyright = '(c) 2025, NeoIPC Project.'

    # Description of the functionality provided by this module
    Description = 'PowerShell tools for NeoIPC Surveillance: DHIS2 admin, report generation helpers, and pipeline-composable data inspection.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.5'

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
    FunctionsToExport = @(
        # Auth
        'Resolve-NeoipcToken'
        'Resolve-NeoipcAuth'
        'Get-NeoipcAuthPassword'
        'Test-DHIS2PersonalAccessToken'
        # OrgUnits
        'Get-NeoipcDepartments'
        'Get-NeoipcServerKey'
        'Read-OrgUnitInfo'
        # QuartoHelpers
        'Invoke-WithNeoipcAuth'
        'Invoke-QuartoRender'
        'Invoke-Rscript'
        'Build-QmdParamPairs'
        'Write-NeoipcBuildReport'
        'Test-QuartoInstallation'
        'Split-NeoipcLocale'
        'Resolve-NeoipcLocaleQmd'
        # PAT
        'Read-DHIS2PersonalAccessToken'
        'Remove-DHIS2PersonalAccessToken'
        'Clear-DHIS2PersonalAccessTokens'
        # UserInfo
        'Read-UserInfo'
        # Tracker
        'Read-PatientInfo'
        'Read-EnrolmentInfo'
        'Read-EventSummary'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @(
        'Read-PAT'
        'Remove-PAT'
        'Clear-PATs'
    )

    # Private data to pass to the module specified in RootModule/ModuleToProcess.
    PrivateData = @{

        PSData = @{
            Tags = 'NeoIPC', 'Surveillance', 'DHIS2'
            LicenseUri = 'https://opensource.org/license/mit'
            ProjectUri = 'https://neoipc.org'
            IconUri = 'https://neoipc.org/wp-content/uploads/2021/06/LOGO-NEOIPC-SQUARE-COLOR.png'
            Prerelease = 'Alpha1'
            RequireLicenseAcceptance = $false
        }
    }
}
