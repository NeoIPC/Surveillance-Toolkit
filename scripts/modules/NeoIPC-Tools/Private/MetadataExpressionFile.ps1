# NeoIPC metadata pipeline — per-expression text-file externalisation.
#
# The expression-heavy fields live in one text file per expression under <directory>/expressions/, rather than packed
# into a CSV cell, so the author edits them with editor support (multi-line, no CSV quoting, highlighting). A field is
# externalised CONSISTENTLY (always a file, even when a given value is short) where a multi-line expression is
# *possible* in it; for programRuleActions.data that capability is action-type-specific (see below).
#
# Layout (subdirectories as the structuring unit): a program rule and its actions are one unit, so they co-locate in
# a per-rule folder named by the rule — expressions/programRules/<rule>/condition.dhis2 and
# expressions/programRules/<rule>/<actionId>.data.dhis2. Program indicators and validation rules (few) stay flat per
# type — expressions/<type>/<id>.<column>.dhis2. The CSV cell stores the relative path, so the tree is free to change.
#
# Like the sharing.yaml redirect, this is a DIRECTORY concern: the in-memory package <-> rows converters keep the
# expressions inline, so the pure converters and the round-trip comparator stay untouched. Only the on-disk directory
# form splits them out — Write-... runs in ConvertFrom-NeoIPCMetadataJson (emit), Read-... in
# ConvertTo-NeoIPCMetadataJson (read). The round-trip therefore reconstructs the inline value via the read path.

# Externalised expression COLUMNS per type — CSV column names (a nested expression uses its flattened
# "<parent>_<field>" column, e.g. leftSide_expression). programRuleActions.data is gated on the action type.
$script:NeoIPCMetadataExpressionColumns = [ordered]@{
    programRules       = @('condition')
    programRuleActions = @('data')
    programIndicators  = @('expression', 'filter')
    validationRules    = @('leftSide_expression', 'rightSide_expression')
}

# programRuleActionType values whose `data` is an authored, potentially-multi-line expression (the value/message
# producers). The field/section/option togglers (HIDEFIELD/HIDESECTION/HIDEPROGRAMSTAGE/SETMANDATORYFIELD/HIDEOPTION/
# SHOWOPTIONGROUP/HIDEOPTIONGROUP) and the template-driven notification types (SENDMESSAGE/SCHEDULEMESSAGE) keep their
# rare/short data inline. Verified against ProgramRuleActionType + RuleAction.dataExpression in refs/.
$script:NeoIPCExpressionBearingActionTypes = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]('ASSIGN', 'DISPLAYTEXT', 'DISPLAYKEYVALUEPAIR', 'SHOWWARNING', 'WARNINGONCOMPLETE', 'SHOWERROR', 'ERRORONCOMPLETE'),
    [System.StringComparer]::Ordinal)

# Cell pattern that marks an externalised reference (vs an inline expression): expressions/<...>.dhis2.
$script:NeoIPCMetadataExpressionRefPattern = [regex]'^expressions/.+\.dhis2$'

function Test-NeoIPCMetadataExpressionColumn {
    # True when (Type, Column) should be EMITTED to its own file. For programRuleActions.data the action type must be
    # expression-bearing (the togglers / notification types keep data inline); ActionType is ignored otherwise.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Column,
        [AllowNull()][AllowEmptyString()][string]$ActionType
    )
    $cols = $script:NeoIPCMetadataExpressionColumns[$Type]
    if (-not $cols -or $cols -notcontains $Column) { return $false }
    if ($Type -eq 'programRuleActions' -and $Column -eq 'data') {
        return $script:NeoIPCExpressionBearingActionTypes.Contains([string]$ActionType)
    }
    $true
}

function Get-NeoIPCMetadataExpressionRuleSegmentMap {
    # programRule id -> subdirectory segment: the rule CODE (or the id for a rule with no code). A program rule and its
    # actions' expressions share this subdirectory. Rule codes match ^[A-Z][A-Z0-9_]*$ and UIDs are alphanumeric, so
    # both are path-safe without sanitisation and unique per type, so no name-sanitiser and no collision check are
    # needed — a defensive path-safety assertion is the only guard (against a malformed code slipping through).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$RuleRows)
    $byId = @{}
    foreach ($r in @($RuleRows)) {
        if ($null -eq $r) { continue }   # @($null) is a 1-element null array, so a missing programRules key lands here
        $rid = [string]$r['id']
        if ($rid -eq '') { continue }
        $code = [string]$r['code']
        $seg = if ($code -ne '') { $code } else { $rid }
        if ($seg -notmatch '^[A-Za-z0-9_]+$') { throw "Program rule '$rid' has a path-unsafe expression-folder segment '$seg' — a rule code must match ^[A-Z][A-Z0-9_]*`$." }
        $byId[$rid] = $seg
    }
    $byId
}

function Get-NeoIPCMetadataExpressionFilePath {
    # The directory-relative path (forward slashes) of a field's expression file. A program rule's condition and its
    # actions' data co-locate under one per-rule subdirectory named by the rule CODE
    # (expressions/programRules/<RULE_CODE>/...); the action's file keeps its own UID inside that folder (actions
    # carry no code). Program indicators and validation rules stay flat per-type, keyed by CODE (or the UID for a
    # code-less object, e.g. the placeholder validation rule). $RuleSegment is the rule id -> segment map.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Row,
        [Parameter(Mandatory)][string]$Column,
        [Parameter(Mandatory)][hashtable]$RuleSegment
    )
    $id = [string]$Row['id']
    switch ($Type) {
        'programRules' { 'expressions/programRules/{0}/{1}.dhis2' -f $RuleSegment[$id], $Column }
        'programRuleActions' {
            $rid = [string]$Row['programRule']
            $seg = if ($RuleSegment.ContainsKey($rid)) { $RuleSegment[$rid] } elseif ($rid -ne '') { $rid } else { $id }
            'expressions/programRules/{0}/{1}.{2}.dhis2' -f $seg, $id, $Column
        }
        default {
            $code = [string]$Row['code']
            $key = if ($code -ne '') { $code } else { $id }
            'expressions/{0}/{1}.{2}.dhis2' -f $Type, $key, $Column
        }
    }
}

function Write-NeoIPCMetadataExpressionFiles {
    # Emit side (directory): for every externalised expression column with a non-empty value, write the value verbatim
    # to <Directory>/expressions/<type>/<id>.<column>.dhis2 and REPLACE the row cell with the relative file path.
    # Mutates $Rows in place. Verbatim bytes (no added newline) so the read-back round-trips with zero diff.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string]$Directory)
    $ruleSeg = Get-NeoIPCMetadataExpressionRuleSegmentMap -RuleRows $Rows['programRules']
    foreach ($type in @($Rows.Keys)) {
        if (-not $script:NeoIPCMetadataExpressionColumns[$type]) { continue }
        $cols = $script:NeoIPCMetadataExpressionColumns[$type]
        foreach ($row in @($Rows[$type])) {
            $actionType = [string]$row['programRuleActionType']
            foreach ($col in $cols) {
                if (-not $row.Contains($col)) { continue }
                $val = [string]$row[$col]
                if ($val -eq '') { continue }
                if (-not (Test-NeoIPCMetadataExpressionColumn -Type $type -Column $col -ActionType $actionType)) { continue }
                if ([string]$row['id'] -eq '') { throw "Cannot externalise the '$col' expression of a $type row with no id." }
                $rel = Get-NeoIPCMetadataExpressionFilePath -Type $type -Row $row -Column $col -RuleSegment $ruleSeg
                $abs = Join-Path $Directory ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                $sub = Split-Path -Parent $abs
                if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
                [System.IO.File]::WriteAllText($abs, $val, [System.Text.UTF8Encoding]::new($false))
                $row[$col] = $rel
            }
        }
    }
}

function Read-NeoIPCMetadataExpressionFiles {
    # Read side (directory): the inverse — for every externalised expression column whose cell is a file reference
    # (matches the expressions/...dhis2 pattern), read the file content verbatim back into the cell. Mutates $Rows in
    # place. An inline value (no reference pattern) is left untouched, so an un-migrated or hand-authored inline
    # expression still reads. Fails loud on a referenced-but-missing file (a broken reference).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string]$Directory)
    foreach ($type in @($Rows.Keys)) {
        if (-not $script:NeoIPCMetadataExpressionColumns[$type]) { continue }
        $cols = $script:NeoIPCMetadataExpressionColumns[$type]
        foreach ($row in @($Rows[$type])) {
            foreach ($col in $cols) {
                if (-not $row.Contains($col)) { continue }
                $val = [string]$row[$col]
                if (-not $script:NeoIPCMetadataExpressionRefPattern.IsMatch($val)) { continue }
                $abs = Join-Path $Directory ($val -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $abs)) { throw "Expression file referenced by $type '$([string]$row['id'])' column '$col' not found: '$val'." }
                $row[$col] = [System.IO.File]::ReadAllText($abs)
            }
        }
    }
}
