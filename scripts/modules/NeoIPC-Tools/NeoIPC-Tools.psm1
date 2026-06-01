# NeoIPC-Tools module root
# Dot-source all private and public function files.

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
