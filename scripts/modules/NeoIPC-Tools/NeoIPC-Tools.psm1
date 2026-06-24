# NeoIPC-Tools module root
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
