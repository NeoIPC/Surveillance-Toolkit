#Requires -Version 7.6

<#
.SYNOPSIS
    Root module for NeoIPC-Tools: dot-sources the private and public function files.

.DESCRIPTION
    The module's functions live in one file per subject under Private/ and Public/ rather than in this
    file, which dot-sources them all at import. That is the conventional layout for a module of this size,
    and the dot-sourcing is safe precisely because it happens here: the target is the module's own scope,
    which PowerShell isolates, so nothing leaks into the importer. The manifest's FunctionsToExport
    governs the visible surface independently of what was dot-sourced — Private/ functions are loaded but
    not exported.

    Order does not matter, because these files define functions rather than execute work; every function
    exists before any is called.

    NeoIPCRepoRoot is computed once here rather than in each consumer: this file sits two levels below
    scripts/, so the repository root is three levels up, and the completer script blocks parsed in
    Public/ are one level deeper still. Resolving it once spares them from unwinding that nesting.

.EXAMPLE
    Import-Module ./scripts/modules/NeoIPC-Tools -Force
#>

# Dot-source all private and public function files.

# Repo root anchor for cache paths. $PSScriptRoot here is
# .../scripts/modules/NeoIPC-Tools; the repo root is three levels up.
# Computed once at module load so completer scriptblocks (parsed in
# Public/*.ps1 where $PSScriptRoot is one level deeper) don't have to
# stack Split-Path calls to undo their nesting.
$script:NeoIPCRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

$privatePath = Join-Path $PSScriptRoot 'Private'
$publicPath  = Join-Path $PSScriptRoot 'Public'

# Private functions (not exported)
foreach ($file in (Get-ChildItem -Path $privatePath -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    . $file.FullName
}

# Public functions (exported via .psd1)
foreach ($file in (Get-ChildItem -Path $publicPath -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    . $file.FullName
}
