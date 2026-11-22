#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester tests for the comment-based help of the report builders and the module's functions.

.DESCRIPTION
    Covers the five Build-*.ps1 wrappers under scripts/ and every function the NeoIPC-Tools module
    exports: Get-Help -Full lists no named parameter without a description, and a builder whose help
    block is missing altogether gets the synthesized syntax line instead of a synopsis.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ParameterHelp.Tests.ps1
#>

BeforeAll {
    Import-Module -Name (Join-Path $PSScriptRoot '..') -Force
    $script:ScriptsDir = Join-Path $PSScriptRoot '..' '..' '..'
    # Get-Help over Out-String: the description text, empty for a parameter no .PARAMETER entry
    # describes. Test-QuartoInstallation declares no parameter, and Get-Help lists one entry
    # without a name for it, which the checks pass over.
    $script:UndescribedParameters = {
        param($Command)
        @(Get-Help $Command -Full |
            ForEach-Object { $_.parameters.parameter } |
            Where-Object { $_.name -and -not ($_.description | Out-String).Trim() } |
            ForEach-Object name)
    }
}

Describe 'Report builders' {
    It 'describes every parameter of <Name>' -ForEach @(
        @{ Name = 'Build-PartnerCertificate.ps1' }
        @{ Name = 'Build-PartnerReport.ps1' }
        @{ Name = 'Build-ValidationReport.ps1' }
        @{ Name = 'Build-ReferenceReport.ps1' }
        @{ Name = 'Build-PatientDataReport.ps1' }
    ) {
        $path = Join-Path $ScriptsDir $Name
        $help = Get-Help $path -Full
        $undescribed = & $UndescribedParameters $path
        $undescribed | Should -BeNullOrEmpty -Because "the name and description of every parameter belong in the help block of $Name"
        $help.Synopsis | Should -Not -BeLike "*$Name*" -Because 'a missing help block leaves Get-Help a synthesized syntax line'
    }
}

Describe 'Exported functions' {
    It 'describes every parameter of every function the module exports' {
        $functions = @(Get-Command -Module NeoIPC-Tools -CommandType Function)
        $functions.Count | Should -BeGreaterThan 0 -Because 'a module import that fails cannot pass this test'
        $undescribed = @($functions | ForEach-Object {
            $function = $_
            & $UndescribedParameters $function | ForEach-Object { "$($function.Name) - $_" }
        })
        $undescribed | Should -BeNullOrEmpty -Because 'every exported function documents its parameters in its help block'
    }
}
