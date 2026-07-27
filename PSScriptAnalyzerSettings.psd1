# PSScriptAnalyzer settings for this repository's PowerShell (scripts/ and the modules under
# scripts/modules/).
#
# The consumer that matters is the VS Code PowerShell extension: it picks up a
# PSScriptAnalyzerSettings.psd1 at the repository root automatically, so the decisions below are what a
# developer actually sees in the editor. `Invoke-ScriptAnalyzer -Settings PSScriptAnalyzerSettings.psd1`
# honours the same file. The approved-verb gate in CI stays as it is: it runs
# `-IncludeRule PSUseApprovedVerbs`, and an include list makes exclusions moot.
#
# This is deliberately NOT a full-lint configuration. Running the complete default rule set over these
# scripts surfaces a body of pre-existing findings (output-stream usage, empty catch blocks, and so on)
# whose disposition is a separate piece of work; adopting them wholesale here would bury the two
# decisions this file exists to record.

@{
    # PSUseBOMForUnicodeEncodedFile fires "Missing BOM encoding for non-ASCII encoded file" on every
    # PowerShell file containing a non-ASCII character, which is most of them here — the scripts carry
    # German text and "Charité" throughout. The rule encodes a Windows PowerShell 5.1 assumption: 5.1
    # reads a BOM-less file as Windows-1252, so such a script needed a BOM to survive. This project
    # requires PowerShell 7 (every .ps1 and .psm1 declares #Requires -Version 7.0), and 7 defaults to
    # UTF-8, so the premise no longer holds.
    #
    # Two measured facts make adding BOMs actively wrong here rather than merely unnecessary:
    #   - A BOM before "#!" stops the kernel recognising an interpreter line, so the scripts that begin
    #     "#!/usr/bin/env pwsh" would cease to be directly executable on Linux and macOS. This
    #     repository is required to be cross-platform, and po4a already runs via WSL on Windows.
    #   - No PowerShell file here carries a BOM today and they all work, because everything runs on 7.
    #
    # If a genuine 5.1 consumer ever reappears, THIS is the decision to revisit — not the shebangs.
    ExcludeRules = @(
        'PSUseBOMForUnicodeEncodedFile'
    )

    Rules = @{
        # Matches the floor every .ps1/.psm1 declares via #Requires -Version 7.6, so the analyzer and
        # the engine check for the same thing.
        #
        # That floor is measured, not assumed. This repository's own syntax is satisfied at 7.0, but its
        # command usage is not: Get-Date -AsUTC in the Build-*.ps1 wrappers and
        # NeoIPC-Tools/Public/BuildReport.ps1, Resolve-Path -RelativeBasePath in
        # Build-PartnerCertificate.ps1 / Build-PartnerReport.ps1, and ConvertFrom-Json -DateKind in
        # NeoIPC-Tools/Private/Metadata.ps1 — none of which exist in 7.0. 7.6 is the single number that
        # covers all of it and agrees with both module manifests.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.6')
        }

        # PSUseCompatibleCommands, PSUseCompatibleCmdlets and PSUseCompatibleTypes are deliberately OFF.
        # Not for lack of trying — the measurement is what rules them out:
        #
        #   - They are driven by a bundled compatibility PROFILE (a file under the module's
        #     compatibility_profiles/ directory), not by a version string. The newest profile
        #     PSScriptAnalyzer 1.25.0 ships is 7.0.0.
        #   - This repository requires NEWER built-in parameters than 7.0: Get-Date -AsUTC (7.1) in the
        #     Build-*.ps1 wrappers and NeoIPC-Tools/Public/BuildReport.ps1, Resolve-Path
        #     -RelativeBasePath (7.4) in Build-PartnerCertificate.ps1 / Build-PartnerReport.ps1, and
        #     ConvertFrom-Json -DateKind (7.5) in NeoIPC-Tools/Private/Metadata.ps1, whose own comment
        #     calls it "the load-bearing flag". Every one of those is reported against a 7.0.0 profile —
        #     false positives by construction.
        #   - The rule also reports every command from a third-party module as unavailable, because a
        #     base OS profile contains none of them. Over this repository that is thousands of findings
        #     (Pester's Describe/It/Should, powershell-yaml's ConvertTo-Yaml), drowning anything real.
        #
        # Enable them if and when upstream ships a profile at or above this repository's floor.
        #
        # Naming a profile that does not exist does not degrade gracefully: Invoke-ScriptAnalyzer throws
        # "Could not find file ... compatibility_profiles\<name>" for every file analysed, and the whole
        # run fails. Worth knowing, because -ErrorAction SilentlyContinue turns that into a silent
        # zero-findings pass that looks like success.
    }
}
