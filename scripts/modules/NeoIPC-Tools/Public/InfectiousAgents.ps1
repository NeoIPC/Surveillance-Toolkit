<#
.SYNOPSIS
Return the next unused integer Id in the infectious-agent ontology YAML.

.DESCRIPTION
Walks NeoIPC-Infectious-Agents.yaml depth-first across Hierarchies, Children,
and Synonyms lists, collecting every Id: value, and returns max + 1.

Gaps left by retired entries are not refilled — append-after-max only. Use
this when adding a new concept or synonym to the ontology.

.PARAMETER Path
Path to the YAML file. Defaults to the canonical ontology file in the
repository so the cmdlet works without arguments from anywhere inside the
repo. Relative paths are resolved against the current working directory.

.OUTPUTS
[int] The next unused Id value (max existing Id + 1).

.EXAMPLE
PS> Find-NextFreeInfectiousAgentId
3561
#>
function Find-NextFreeInfectiousAgentId {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' '..' '..' 'metadata' 'common' 'infectious-agents' 'NeoIPC-Infectious-Agents.yaml')
    )

    function Get-IdsFromNode {
        param($Node)
        if ($Node -is [System.Collections.IList]) {
            foreach ($item in $Node) { Get-IdsFromNode $item }
            return
        }
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains('Id')) { [int]$Node['Id'] }
            foreach ($key in 'Hierarchies', 'Children', 'Synonyms') {
                if ($Node.Contains($key)) { Get-IdsFromNode $Node[$key] }
            }
        }
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $tree = Get-Content -LiteralPath $resolved | ConvertFrom-Yaml
    $ids = Get-IdsFromNode $tree
    [int](($ids | Measure-Object -Maximum).Maximum + 1)
}
