# NeoIPC data dictionary — flatten the assembled DHIS2 metadata package into a technology-agnostic
# "data dictionary" readable by epidemiologists AND technical implementers: patient attributes, per-stage
# data elements, the per-event dates, and the full code lists. Pure transforms over the
# in-memory package (an [ordered] dictionary `type -> OrderedDictionary[]`, references as `@{ id = '<uid>' }`);
# no DHIS2 API and no file I/O except the CSV writer. Consumed by Public/DataDictionary.ps1.

# DHIS2 valueType -> a friendly, technology-neutral "data type". An unmapped value type passes through
# verbatim and warns (fail-loud, never silently mislabel). ASCII-only on purpose so the source stays portable.
$script:NeoIPCDataTypeMap = [ordered]@{
    TEXT                     = 'Text'
    LONG_TEXT                = 'Text (long)'
    LETTER                   = 'Single letter'
    EMAIL                    = 'Email address'
    PHONE_NUMBER             = 'Phone number'
    URL                      = 'Web address'
    INTEGER                  = 'Whole number'
    INTEGER_POSITIVE         = 'Whole number (> 0)'
    INTEGER_ZERO_OR_POSITIVE = 'Whole number (>= 0)'
    INTEGER_NEGATIVE         = 'Whole number (< 0)'
    NUMBER                   = 'Number'
    UNIT_INTERVAL            = 'Fraction (0 to 1)'
    PERCENTAGE               = 'Percentage'
    BOOLEAN                  = 'Yes / No / blank'
    TRUE_ONLY                = 'Checkbox (yes / blank)'
    DATE                     = 'Date'
    DATETIME                 = 'Date and time'
    TIME                     = 'Time'
    AGE                      = 'Age'
    COORDINATE               = 'Coordinate'
}

# Above this many options a coded field's "Allowed values" cell points to the Code lists sheet instead of
# inlining every value; the Code lists sheet enumerates every set in full regardless.
$script:NeoIPCDataDictionaryInlineOptionLimit = 12

# Module / form label for the patient-level (tracked entity) attributes that are captured once per patient.
$script:NeoIPCDataDictionaryPatientModule = 'Patient master data'

function Get-NeoIPCFriendlyValueType {
    # Map a DHIS2 valueType to a friendly data-type label; pass unmapped types through verbatim and warn.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$ValueType)
    if ([string]::IsNullOrEmpty($ValueType)) { return '' }
    if ($script:NeoIPCDataTypeMap.Contains($ValueType)) { return $script:NeoIPCDataTypeMap[$ValueType] }
    Write-Warning "No friendly data-type mapping for valueType '$ValueType'; emitting it verbatim."
    return $ValueType
}

function Format-NeoIPCDataDictionaryBoolean {
    # Render a DHIS2 boolean cell (real [bool] in the package, but tolerate the string form) as Yes/No.
    [OutputType([string])]
    param([AllowNull()]$Value)
    if (($Value -is [bool] -and $Value) -or ("$Value" -ieq 'true')) { return 'Yes' }
    return 'No'
}

function Get-NeoIPCMetadataRefId {
    # Pull the UID out of a DHIS2 reference cell (`@{ id = '<uid>' }`); '' when the reference is absent.
    [OutputType([string])]
    param([AllowNull()]$Ref)
    if ($Ref -is [System.Collections.IDictionary] -and $Ref.Contains('id')) { return [string]$Ref['id'] }
    return ''
}

function Get-NeoIPCDataDictionarySorted {
    # Deterministic, locale-independent ordinal sort. $KeyOf returns a string sort key for an item; the
    # original index is appended so every key is unique, making the order stable and fully reproducible
    # regardless of input order. Returns with the `,` (non-enumerating) idiom so a single-element result is
    # not unrolled to a scalar by the caller.
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][scriptblock]$KeyOf
    )
    if ($Item.Count -le 1) { return , ([object[]]$Item) }
    $sorted = [System.Collections.Generic.SortedDictionary[string, object]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $Item.Count; $i++) {
        $sorted[((& $KeyOf $Item[$i]) + '|' + ('{0:D8}' -f $i))] = $Item[$i]
    }
    return , ([object[]]$sorted.Values)
}

function Get-NeoIPCDataDictionaryIntKey {
    # Zero-padded ordinal-sortable form of an integer-ish cell (absent/blank -> 0).
    [OutputType([string])]
    param([AllowNull()]$Value)
    $n = 0; [void][int]::TryParse([string]$Value, [ref]$n)
    return '{0:D8}' -f $n
}

function ConvertFrom-NeoIPCPackageIndex {
    # Build the id-keyed lookups the row builders need from an assembled package: data elements, option sets,
    # tracked-entity attributes and program stages by id; options grouped by their option-set id; and program-
    # stage sections grouped by their stage id (each keeping its ordered data-element id list for section
    # membership). Returns a hashtable of these indexes.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Package)

    $byId = { param($type)
        $h = @{}
        foreach ($o in @($Package[$type])) {
            if ($o -is [System.Collections.IDictionary] -and $o.Contains('id')) { $h[[string]$o['id']] = $o }
        }
        $h
    }

    $optionsBySet = @{}
    foreach ($opt in @($Package['options'])) {
        if ($opt -isnot [System.Collections.IDictionary]) { continue }
        $setId = Get-NeoIPCMetadataRefId $opt['optionSet']
        if (-not $setId) { continue }
        if (-not $optionsBySet.ContainsKey($setId)) { $optionsBySet[$setId] = [System.Collections.Generic.List[object]]::new() }
        $optionsBySet[$setId].Add($opt)
    }

    $sectionsByStage = @{}
    foreach ($sec in @($Package['programStageSections'])) {
        if ($sec -isnot [System.Collections.IDictionary]) { continue }
        $stageId = Get-NeoIPCMetadataRefId $sec['programStage']
        if (-not $stageId) { continue }
        if (-not $sectionsByStage.ContainsKey($stageId)) { $sectionsByStage[$stageId] = [System.Collections.Generic.List[object]]::new() }
        $sectionsByStage[$stageId].Add($sec)
    }

    return @{
        DataElementById  = & $byId 'dataElements'
        OptionSetById    = & $byId 'optionSets'
        AttributeById    = & $byId 'trackedEntityAttributes'
        StageById        = & $byId 'programStages'
        OptionsBySetId   = $optionsBySet
        SectionsByStageId = $sectionsByStage
    }
}

function Resolve-NeoIPCOptionList {
    # Resolve an option-set reference cell to its set details + ordered member options. $null when the field
    # has no option set. Options are ordered by sortOrder then code (ordinal), independent of package order.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$OptionSetRef, [Parameter(Mandatory)][hashtable]$Index)
    $setId = Get-NeoIPCMetadataRefId $OptionSetRef
    if (-not $setId) { return $null }
    $set = $Index.OptionSetById[$setId]
    if (-not $set) { return $null }
    # @( ... ) array-subexpression, not an if/else returning @(): PowerShell unwraps an if-branch empty array to
    # $null on assignment, and the downstream [object[]]$Item binder rejects $null (it allows EMPTY, not null).
    $opts = @(if ($Index.OptionsBySetId.ContainsKey($setId)) { $Index.OptionsBySetId[$setId] })
    $ordered = Get-NeoIPCDataDictionarySorted -Item $opts -KeyOf {
        param($o) (Get-NeoIPCDataDictionaryIntKey $o['sortOrder']) + '|' + [string]$o['code']
    }
    return @{
        SetCode   = [string]$set['code']
        SetName   = [string]$set['name']
        ValueType = [string]$set['valueType']
        Options   = $ordered
    }
}

function Format-NeoIPCAllowedValues {
    # The Variables "Allowed values" cell: '' when not coded; an inline "code = label; ..." list for short
    # sets; otherwise an in-workbook pointer to the named code list (which always carries every value).
    [OutputType([string])]
    param([AllowNull()][hashtable]$OptionInfo)
    if (-not $OptionInfo) { return '' }
    $opts = @($OptionInfo.Options)
    if ($opts.Count -eq 0) { return '' }
    if ($opts.Count -le $script:NeoIPCDataDictionaryInlineOptionLimit) {
        return (($opts | ForEach-Object { ('{0} = {1}' -f [string]$_['code'], [string]$_['name']).Trim() }) -join '; ')
    }
    return "See code list: $($OptionInfo.SetName)"
}

function Get-NeoIPCDataDictionaryLabel {
    # Epidemiologist-facing label: prefer formName, then name, then shortName.
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Object)
    foreach ($prop in 'formName', 'name', 'shortName') {
        $v = [string]$Object[$prop]
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
    }
    return ''
}

function Get-NeoIPCDataDictionaryFieldKind {
    # Classify a field for the "Field kind" column. Free-text-fallback is a narrow heuristic: an uncoded
    # TEXT/LONG_TEXT element whose description marks it as the "not in the list above" escape hatch.
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Element, [AllowNull()][hashtable]$OptionInfo)
    $vt = [string]$Element['valueType']
    if (-not $OptionInfo -and ($vt -eq 'TEXT' -or $vt -eq 'LONG_TEXT')) {
        if ([string]$Element['description'] -match 'not (contained )?in the .*\blist\b') { return 'Free-text fallback' }
    }
    return 'Explicit field'
}

function Get-NeoIPCStageDateLabel {
    # The human label for a stage's event date. The Admission stage reports on the enrolment date
    # (reportDateToUse = enrollmentDate; the program's incident date is hidden), so it takes the program's
    # enrollmentDateLabel; every other stage uses its own executionDateLabel.
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Stage, [AllowNull()][System.Collections.IDictionary]$Program)
    if ([string]$Stage['reportDateToUse'] -eq 'enrollmentDate' -and $Program) {
        $enr = [string]$Program['enrollmentDateLabel']
        if (-not [string]::IsNullOrWhiteSpace($enr)) { return $enr }
    }
    return [string]$Stage['executionDateLabel']
}

function Get-NeoIPCEventDateCode {
    # Deterministic synthetic code for a stage's event-date field (stages carry no code column of their own).
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Stage)
    $slug = ([string]$Stage['name']).ToUpperInvariant() -replace '[^A-Z0-9]+', '_'
    return 'NEOIPC_EVENTDATE_' + $slug.Trim('_')
}

function Get-NeoIPCSectionName {
    # The form section a data element sits in within a stage ('' when it belongs to none). Sections are
    # matched by stage; the first whose ordered dataElements list contains the element wins.
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StageId, [Parameter(Mandatory)][string]$DataElementId, [Parameter(Mandatory)][hashtable]$Index)
    if (-not $Index.SectionsByStageId.ContainsKey($StageId)) { return '' }
    foreach ($sec in $Index.SectionsByStageId[$StageId]) {
        foreach ($ref in @($sec['dataElements'])) {
            if ((Get-NeoIPCMetadataRefId $ref) -eq $DataElementId) { return [string]$sec['name'] }
        }
    }
    return ''
}

function New-NeoIPCVariableRow {
    # One Variables-sheet row (ordered to match $script:NeoIPCDataDictionaryVariableColumns).
    param(
        [string]$Level, [string]$Module, [string]$DateLabel, [string]$Section, [string]$Code, [string]$Label,
        [string]$DataType, [string]$Required, [string]$Repeatable, [string]$AllowedValues, [string]$Description,
        [string]$FieldKind
    )
    [ordered]@{
        'Level'           = $Level
        'Module / form'   = $Module
        'Form date label' = $DateLabel
        'Section'         = $Section
        'Code'            = $Code
        'Label'           = $Label
        'Data type'       = $DataType
        'Required'        = $Required
        'Repeatable'      = $Repeatable
        'Allowed values'  = $AllowedValues
        'Description'     = $Description
        'Field kind'      = $FieldKind
    }
}

# The DHIS2 UID is deliberately NOT a column — the dictionary is technology-agnostic; the project's variable
# CODE is the stable, platform-neutral identifier.
$script:NeoIPCDataDictionaryVariableColumns = @(
    'Level', 'Module / form', 'Form date label', 'Section', 'Code', 'Label', 'Data type', 'Required',
    'Repeatable', 'Allowed values', 'Description', 'Field kind')
$script:NeoIPCDataDictionaryCodeListColumns = @(
    'Code list', 'Code list code', 'Value code', 'Value label', 'Sort order', 'Data type')
$script:NeoIPCDataDictionaryFormsColumns = @(
    'Module / form', 'Date label', 'Repeatable', 'Description', 'Sort order')
$script:NeoIPCDataDictionaryAboutColumns = @('Field', 'Value')

function Get-NeoIPCPatientAttributeRow {
    # The patient-level (tracked entity) attribute rows, in program attribute order.
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Program, [Parameter(Mandatory)][hashtable]$Index)
    $rows = [System.Collections.Generic.List[object]]::new()
    $pteas = Get-NeoIPCDataDictionarySorted -Item @($Program['programTrackedEntityAttributes']) -KeyOf {
        param($p) (Get-NeoIPCDataDictionaryIntKey $p['sortOrder']) + '|' + (Get-NeoIPCMetadataRefId $p['trackedEntityAttribute'])
    }
    foreach ($ptea in $pteas) {
        if ($ptea -isnot [System.Collections.IDictionary]) { continue }
        $tea = $Index.AttributeById[(Get-NeoIPCMetadataRefId $ptea['trackedEntityAttribute'])]
        if (-not $tea) { continue }
        $optInfo = Resolve-NeoIPCOptionList -OptionSetRef $tea['optionSet'] -Index $Index
        $rows.Add((New-NeoIPCVariableRow `
            -Level 'Patient' -Module $script:NeoIPCDataDictionaryPatientModule -DateLabel '' -Section '' `
            -Code ([string]$tea['code']) -Label (Get-NeoIPCDataDictionaryLabel $tea) `
            -DataType (Get-NeoIPCFriendlyValueType ([string]$tea['valueType'])) `
            -Required (Format-NeoIPCDataDictionaryBoolean $ptea['mandatory']) -Repeatable '' `
            -AllowedValues (Format-NeoIPCAllowedValues $optInfo) -Description ([string]$tea['description']) `
            -FieldKind (Get-NeoIPCDataDictionaryFieldKind -Element $tea -OptionInfo $optInfo)))
    }
    return $rows.ToArray()
}

function Get-NeoIPCEventVariableRow {
    # For one stage: its event-date row first, then its data-element rows in form order (sortOrder).
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Stage,
        [AllowNull()][System.Collections.IDictionary]$Program,
        [Parameter(Mandatory)][hashtable]$Index
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $stageName = [string]$Stage['name']
    $stageId = [string]$Stage['id']
    $dateLabel = Get-NeoIPCStageDateLabel -Stage $Stage -Program $Program
    $repeatable = Format-NeoIPCDataDictionaryBoolean $Stage['repeatable']

    # The event's own date field — recorded explicitly by the user in the UI; it has no backing data element.
    $rows.Add((New-NeoIPCVariableRow `
        -Level 'Event' -Module $stageName -DateLabel $dateLabel -Section '' `
        -Code (Get-NeoIPCEventDateCode $Stage) -Label $dateLabel -DataType (Get-NeoIPCFriendlyValueType 'DATE') `
        -Required 'Yes' -Repeatable $repeatable -AllowedValues '' -Description ([string]$Stage['description']) `
        -FieldKind 'Event date'))

    $psdes = Get-NeoIPCDataDictionarySorted -Item @($Stage['programStageDataElements']) -KeyOf {
        param($p) (Get-NeoIPCDataDictionaryIntKey $p['sortOrder']) + '|' + (Get-NeoIPCMetadataRefId $p['dataElement'])
    }
    foreach ($psde in $psdes) {
        if ($psde -isnot [System.Collections.IDictionary]) { continue }
        $de = $Index.DataElementById[(Get-NeoIPCMetadataRefId $psde['dataElement'])]
        if (-not $de) { continue }
        $optInfo = Resolve-NeoIPCOptionList -OptionSetRef $de['optionSet'] -Index $Index
        $rows.Add((New-NeoIPCVariableRow `
            -Level 'Event' -Module $stageName -DateLabel $dateLabel `
            -Section (Get-NeoIPCSectionName -StageId $stageId -DataElementId ([string]$de['id']) -Index $Index) `
            -Code ([string]$de['code']) -Label (Get-NeoIPCDataDictionaryLabel $de) `
            -DataType (Get-NeoIPCFriendlyValueType ([string]$de['valueType'])) `
            -Required (Format-NeoIPCDataDictionaryBoolean $psde['compulsory']) -Repeatable $repeatable `
            -AllowedValues (Format-NeoIPCAllowedValues $optInfo) -Description ([string]$de['description']) `
            -FieldKind (Get-NeoIPCDataDictionaryFieldKind -Element $de -OptionInfo $optInfo)))
    }
    return $rows.ToArray()
}

function Get-NeoIPCDataDictionaryProgramStage {
    # The program's stages (resolved from the top-level stage list by program reference), in form order.
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Program, [Parameter(Mandatory)][hashtable]$Index)
    $programId = [string]$Program['id']
    $stages = @($Index.StageById.Values | Where-Object { (Get-NeoIPCMetadataRefId $_['program']) -eq $programId })
    return Get-NeoIPCDataDictionarySorted -Item $stages -KeyOf {
        param($s) (Get-NeoIPCDataDictionaryIntKey $s['sortOrder']) + '|' + [string]$s['name']
    }
}

function Get-NeoIPCFormsAndDatesRow {
    # One Forms & dates row per stage: the module/form and its event-date label.
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Stage, [AllowNull()][System.Collections.IDictionary]$Program)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $Stage) {
        $rows.Add([ordered]@{
            'Module / form'   = [string]$s['name']
            'Date label'      = Get-NeoIPCStageDateLabel -Stage $s -Program $Program
            'Repeatable'      = Format-NeoIPCDataDictionaryBoolean $s['repeatable']
            'Description'     = [string]$s['description']
            'Sort order'      = [string]$s['sortOrder']
        })
    }
    return $rows.ToArray()
}

function Get-NeoIPCCodeListRow {
    # Every option set fully enumerated — one row per (option set, option) — ordered by set code then the
    # option's sortOrder/code. Includes the large generated sets (pathogens, antimicrobials).
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Package, [Parameter(Mandatory)][hashtable]$Index)
    $rows = [System.Collections.Generic.List[object]]::new()
    $sets = Get-NeoIPCDataDictionarySorted -Item @($Package['optionSets']) -KeyOf { param($s) [string]$s['code'] }
    foreach ($set in $sets) {
        if ($set -isnot [System.Collections.IDictionary]) { continue }
        $info = Resolve-NeoIPCOptionList -OptionSetRef @{ id = [string]$set['id'] } -Index $Index
        if (-not $info) { continue }
        $dataType = Get-NeoIPCFriendlyValueType $info.ValueType
        foreach ($opt in $info.Options) {
            $rows.Add([ordered]@{
                'Code list'      = $info.SetName
                'Code list code' = $info.SetCode
                'Value code'     = [string]$opt['code']
                'Value label'    = [string]$opt['name']
                'Sort order'     = [string]$opt['sortOrder']
                'Data type'      = $dataType
            })
        }
    }
    return $rows.ToArray()
}

function Get-NeoIPCDataDictionaryAboutRow {
    # The About cover sheet: a flat list of Field/Value pairs (program identity, provenance, counts, a
    # do-not-hand-edit note).
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Program,
        [int]$VariableCount, [int]$CodeListCount, [int]$CodeListValueCount, [int]$FormCount
    )
    $pairs = [ordered]@{
        'Data dictionary'      = 'NeoIPC Core surveillance — collected variables and code lists'
        'Program'              = ('{0} ({1})' -f [string]$Program['name'], [string]$Program['code'])
        'Program version'      = [string]$Program['version']
        'Generated'            = 'Generated from the canonical NeoIPC metadata directory — do not hand-edit; regenerate with scripts/Build-NeoIPCDataDictionary.ps1.'
        'Variables'            = [string]$VariableCount
        'Code lists'           = [string]$CodeListCount
        'Code list values'     = [string]$CodeListValueCount
        'Modules / forms'      = [string]$FormCount
        'Pathogen code list'   = 'Generated from the NeoIPC infectious-agents ontology (metadata/common/infectious-agents).'
        'Antimicrobial list'   = 'Generated from the NeoIPC antibiotics curation (metadata/common/antibiotics).'
    }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $pairs.Keys) { $rows.Add([ordered]@{ 'Field' = $k; 'Value' = $pairs[$k] }) }
    return $rows.ToArray()
}

function Get-NeoIPCDataDictionaryRow {
    # Orchestrator: assemble the four data-dictionary sheets from a parsed package. Returns an ordered list
    # of sheet descriptors (@{ Name; FileSuffix; Columns; Rows }) for the CSV / XLSX writers.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Package)

    $programs = Get-NeoIPCDataDictionarySorted -Item @($Package['programs']) -KeyOf { param($p) [string]$p['code'] }
    if ($programs.Count -eq 0) { throw 'The metadata package contains no programs to document.' }
    # The dictionary documents ONE program (NEOIPC_CORE; the closure is single-program). The cover sheet and the
    # row sheets must describe the same one — fail loud rather than silently cover only the first of several.
    if ($programs.Count -gt 1) {
        throw ("The data dictionary documents a single program, but the package has $($programs.Count): " +
            ((@($programs | ForEach-Object { [string]$_['code'] })) -join ', ') + '.')
    }
    $program = $programs[0]
    $index = ConvertFrom-NeoIPCPackageIndex -Package $Package

    $variableRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (Get-NeoIPCPatientAttributeRow -Program $program -Index $index)) { $variableRows.Add($r) }
    $stages = Get-NeoIPCDataDictionaryProgramStage -Program $program -Index $index
    foreach ($stage in $stages) {
        foreach ($r in (Get-NeoIPCEventVariableRow -Stage $stage -Program $program -Index $index)) { $variableRows.Add($r) }
    }
    $formRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in (Get-NeoIPCFormsAndDatesRow -Stage $stages -Program $program)) { $formRows.Add($r) }

    # The Code column is the dictionary's stable identifier — fail loud if a synthesized event-date code ever
    # collides with another variable's code (e.g. two stage names that slugify the same), rather than emit two
    # rows sharing a supposedly-unique Code.
    $seenCode = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($r in $variableRows) {
        $code = [string]$r['Code']
        if ($code -and -not $seenCode.Add($code)) { throw "Duplicate variable code '$code' in the data dictionary." }
    }

    $codeListRows = Get-NeoIPCCodeListRow -Package $Package -Index $index
    $codeListCount = @($codeListRows | ForEach-Object { $_['Code list code'] } | Select-Object -Unique).Count
    $aboutRows = Get-NeoIPCDataDictionaryAboutRow -Program $program `
        -VariableCount $variableRows.Count -CodeListCount $codeListCount `
        -CodeListValueCount @($codeListRows).Count -FormCount $formRows.Count

    return @(
        [ordered]@{ Name = 'About';         FileSuffix = 'About';          Columns = $script:NeoIPCDataDictionaryAboutColumns;    Rows = $aboutRows }
        [ordered]@{ Name = 'Variables';     FileSuffix = 'Variables';      Columns = $script:NeoIPCDataDictionaryVariableColumns; Rows = $variableRows.ToArray() }
        [ordered]@{ Name = 'Code lists';    FileSuffix = 'Code-lists';     Columns = $script:NeoIPCDataDictionaryCodeListColumns; Rows = $codeListRows }
        [ordered]@{ Name = 'Forms & dates'; FileSuffix = 'Forms-and-dates'; Columns = $script:NeoIPCDataDictionaryFormsColumns;   Rows = $formRows.ToArray() }
    )
}

function Get-NeoIPCDataDictionaryLibDir {
    # The gitignored output dir the OpenXml assembly is published into (scripts/modules/NeoIPC-Tools/lib/bin).
    [OutputType([string])]
    param()
    Join-Path (Split-Path $PSScriptRoot -Parent) 'lib' 'bin'
}

function Assert-NeoIPCOpenXmlAvailable {
    # Ensure the DocumentFormat.OpenXml assembly is loaded, loading it from the provisioned lib dir if needed.
    # Throws an actionable message when it is not provisioned — the ordinary missing-dependency story.
    [CmdletBinding()]
    param()
    if ('DocumentFormat.OpenXml.Packaging.SpreadsheetDocument' -as [type]) { return }
    $libDir = Get-NeoIPCDataDictionaryLibDir
    $main = Join-Path $libDir 'DocumentFormat.OpenXml.dll'
    if (-not (Test-Path -LiteralPath $main)) {
        throw ("The DocumentFormat.OpenXml assembly required for .xlsx output is not provisioned (looked in '$libDir'). " +
            "Run 'Invoke-Workspace.ps1 -InstallDeps' to restore it (or, standalone, " +
            "'dotnet publish scripts/modules/NeoIPC-Tools/lib -o scripts/modules/NeoIPC-Tools/lib/bin'), " +
            'or pass -Format Csv to skip the workbook.')
    }
    # Load the runtime + framework dependencies first so the main assembly resolves them from this directory
    # (the default load context probes the host base dir, not lib/bin, so pre-load them explicitly).
    foreach ($dll in 'System.IO.Packaging.dll', 'DocumentFormat.OpenXml.Framework.dll', 'DocumentFormat.OpenXml.dll') {
        $path = Join-Path $libDir $dll
        if (Test-Path -LiteralPath $path) { Add-Type -LiteralPath $path }
    }
    if (-not ('DocumentFormat.OpenXml.Packaging.SpreadsheetDocument' -as [type])) {
        throw "Loaded DocumentFormat.OpenXml from '$libDir' but its SpreadsheetDocument type is still unavailable."
    }
}

function Get-NeoIPCXlsxColumnName {
    # 0-based column index -> spreadsheet column letters (0 -> A, 26 -> AA).
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Index)
    $n = $Index + 1
    $name = ''
    while ($n -gt 0) {
        $m = ($n - 1) % 26
        $name = [char](65 + $m) + $name
        $n = [int](($n - $m - 1) / 26)
    }
    return $name
}

function New-NeoIPCXlsxStylesheet {
    # Minimal stylesheet: font 0 = normal, font 1 = bold; cell format 0 = default, 1 = bold header.
    # NOTE: an OpenXmlElement is IEnumerable over its children, so it must be emitted with Write-Output
    # -NoEnumerate (a bare `return $styles` would unroll it into its child elements). The OpenXml type is
    # deliberately absent from [OutputType] — it is not loaded when the module is parsed.
    [OutputType([object])]
    param()
    $fonts = [DocumentFormat.OpenXml.Spreadsheet.Fonts]::new()
    [void]$fonts.Append([DocumentFormat.OpenXml.Spreadsheet.Font]::new())
    $bold = [DocumentFormat.OpenXml.Spreadsheet.Font]::new(); [void]$bold.Append([DocumentFormat.OpenXml.Spreadsheet.Bold]::new())
    [void]$fonts.Append($bold); $fonts.Count = [uint32]2

    $fills = [DocumentFormat.OpenXml.Spreadsheet.Fills]::new()
    foreach ($pt in [DocumentFormat.OpenXml.Spreadsheet.PatternValues]::None, [DocumentFormat.OpenXml.Spreadsheet.PatternValues]::Gray125) {
        $pf = [DocumentFormat.OpenXml.Spreadsheet.PatternFill]::new(); $pf.PatternType = $pt
        $fill = [DocumentFormat.OpenXml.Spreadsheet.Fill]::new(); [void]$fill.Append($pf); [void]$fills.Append($fill)
    }
    $fills.Count = [uint32]2

    $borders = [DocumentFormat.OpenXml.Spreadsheet.Borders]::new()
    [void]$borders.Append([DocumentFormat.OpenXml.Spreadsheet.Border]::new()); $borders.Count = [uint32]1

    $csf = [DocumentFormat.OpenXml.Spreadsheet.CellStyleFormats]::new()
    $base = [DocumentFormat.OpenXml.Spreadsheet.CellFormat]::new()
    $base.NumberFormatId = [uint32]0; $base.FontId = [uint32]0; $base.FillId = [uint32]0; $base.BorderId = [uint32]0
    [void]$csf.Append($base); $csf.Count = [uint32]1

    $cfs = [DocumentFormat.OpenXml.Spreadsheet.CellFormats]::new()
    $def = [DocumentFormat.OpenXml.Spreadsheet.CellFormat]::new()
    $def.NumberFormatId = [uint32]0; $def.FontId = [uint32]0; $def.FillId = [uint32]0; $def.BorderId = [uint32]0; $def.FormatId = [uint32]0
    $hdr = [DocumentFormat.OpenXml.Spreadsheet.CellFormat]::new()
    $hdr.NumberFormatId = [uint32]0; $hdr.FontId = [uint32]1; $hdr.FillId = [uint32]0; $hdr.BorderId = [uint32]0; $hdr.FormatId = [uint32]0; $hdr.ApplyFont = $true
    [void]$cfs.Append($def); [void]$cfs.Append($hdr); $cfs.Count = [uint32]2

    $styles = [DocumentFormat.OpenXml.Spreadsheet.Stylesheet]::new()
    [void]$styles.Append($fonts); [void]$styles.Append($fills); [void]$styles.Append($borders); [void]$styles.Append($csf); [void]$styles.Append($cfs)
    Write-Output -NoEnumerate $styles
}

function Write-NeoIPCDataDictionaryXlsx {
    # Write the sheets as one multi-tab .xlsx (bold + frozen header row, column widths, shared strings) via the
    # DocumentFormat.OpenXml SDK. Requires the provisioned assembly. Returns the written path. The CSVs remain
    # the diffable source; the workbook is the hand-out artifact (zip timestamps make it only best-effort
    # byte-stable, so it is not part of the determinism gate).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Sheet, [Parameter(Mandatory)][string]$Path)
    Assert-NeoIPCOpenXmlAvailable

    $ssDict = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    $ssList = [System.Collections.Generic.List[string]]::new()
    $sharedIndex = {
        param([string]$value)
        $i = 0
        if (-not $ssDict.TryGetValue($value, [ref]$i)) { $i = $ssList.Count; $ssDict[$value] = $i; $ssList.Add($value) }
        $i
    }
    # A Cell is built and appended inline (not returned from a helper): an OpenXmlElement is IEnumerable over
    # its children, so returning one through the pipeline would unroll it.
    $addCell = {
        param($Row, [string]$ColRef, [int]$RowNum, [string]$Value, [uint32]$Style)
        $cell = [DocumentFormat.OpenXml.Spreadsheet.Cell]::new()
        $cell.CellReference = $ColRef + $RowNum
        $cell.DataType = [DocumentFormat.OpenXml.Spreadsheet.CellValues]::SharedString
        $cell.CellValue = [DocumentFormat.OpenXml.Spreadsheet.CellValue]::new([string](& $sharedIndex $Value))
        if ($Style -gt 0) { $cell.StyleIndex = $Style }
        [void]$Row.AppendChild($cell)
    }

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $doc = [DocumentFormat.OpenXml.Packaging.SpreadsheetDocument]::Create($Path, [DocumentFormat.OpenXml.SpreadsheetDocumentType]::Workbook)
    try {
        $wbPart = $doc.AddWorkbookPart()
        $wbPart.Workbook = [DocumentFormat.OpenXml.Spreadsheet.Workbook]::new()
        $sheetsEl = $wbPart.Workbook.AppendChild([DocumentFormat.OpenXml.Spreadsheet.Sheets]::new())

        $stylesPart = $wbPart.AddNewPart[DocumentFormat.OpenXml.Packaging.WorkbookStylesPart]()
        $stylesPart.Stylesheet = New-NeoIPCXlsxStylesheet

        $sheetId = 1
        foreach ($sheet in $Sheet) {
            $cols = [string[]]$sheet.Columns
            $rows = @($sheet.Rows)

            $wsPart = $wbPart.AddNewPart[DocumentFormat.OpenXml.Packaging.WorksheetPart]()
            $worksheet = [DocumentFormat.OpenXml.Spreadsheet.Worksheet]::new()

            # Freeze the header row.
            $view = [DocumentFormat.OpenXml.Spreadsheet.SheetView]::new(); $view.WorkbookViewId = [uint32]0
            $pane = [DocumentFormat.OpenXml.Spreadsheet.Pane]::new()
            $pane.VerticalSplit = [double]1; $pane.TopLeftCell = 'A2'
            $pane.ActivePane = [DocumentFormat.OpenXml.Spreadsheet.PaneValues]::BottomLeft
            $pane.State = [DocumentFormat.OpenXml.Spreadsheet.PaneStateValues]::Frozen
            $sel = [DocumentFormat.OpenXml.Spreadsheet.Selection]::new(); $sel.Pane = [DocumentFormat.OpenXml.Spreadsheet.PaneValues]::BottomLeft
            [void]$view.Append($pane); [void]$view.Append($sel)
            $views = [DocumentFormat.OpenXml.Spreadsheet.SheetViews]::new(); [void]$views.Append($view)
            [void]$worksheet.Append($views)

            # Column widths from the longest cell (header included), capped.
            $colsEl = [DocumentFormat.OpenXml.Spreadsheet.Columns]::new()
            for ($c = 0; $c -lt $cols.Count; $c++) {
                $max = $cols[$c].Length
                foreach ($row in $rows) { $len = ([string]$row[$cols[$c]]).Length; if ($len -gt $max) { $max = $len } }
                if ($max -gt 80) { $max = 80 }
                $col = [DocumentFormat.OpenXml.Spreadsheet.Column]::new()
                $col.Min = [uint32]($c + 1); $col.Max = [uint32]($c + 1)
                $col.Width = [double]([math]::Round([math]::Max(8, $max * 1.1 + 2), 2)); $col.CustomWidth = $true
                [void]$colsEl.Append($col)
            }
            [void]$worksheet.Append($colsEl)

            $sheetData = [DocumentFormat.OpenXml.Spreadsheet.SheetData]::new()
            $headerRow = [DocumentFormat.OpenXml.Spreadsheet.Row]::new(); $headerRow.RowIndex = [uint32]1
            for ($c = 0; $c -lt $cols.Count; $c++) {
                & $addCell $headerRow (Get-NeoIPCXlsxColumnName $c) 1 $cols[$c] ([uint32]1)
            }
            [void]$sheetData.Append($headerRow)

            $r = 2
            foreach ($row in $rows) {
                $dataRow = [DocumentFormat.OpenXml.Spreadsheet.Row]::new(); $dataRow.RowIndex = [uint32]$r
                for ($c = 0; $c -lt $cols.Count; $c++) {
                    & $addCell $dataRow (Get-NeoIPCXlsxColumnName $c) $r ([string]$row[$cols[$c]]) ([uint32]0)
                }
                [void]$sheetData.Append($dataRow)
                $r++
            }
            [void]$worksheet.Append($sheetData)
            $wsPart.Worksheet = $worksheet

            $sheetEl = [DocumentFormat.OpenXml.Spreadsheet.Sheet]::new()
            $sheetEl.Id = $wbPart.GetIdOfPart($wsPart)
            $sheetEl.SheetId = [uint32]$sheetId
            $sheetEl.Name = $sheet.Name
            [void]$sheetsEl.Append($sheetEl)
            $sheetId++
        }

        # Shared string table (built while writing the cells).
        $sstPart = $wbPart.AddNewPart[DocumentFormat.OpenXml.Packaging.SharedStringTablePart]()
        $sst = [DocumentFormat.OpenXml.Spreadsheet.SharedStringTable]::new()
        foreach ($s in $ssList) {
            $item = [DocumentFormat.OpenXml.Spreadsheet.SharedStringItem]::new()
            $text = [DocumentFormat.OpenXml.Spreadsheet.Text]::new($s)
            # Preserve significant leading/trailing whitespace (some source labels carry it).
            if ($s.Length -ne $s.Trim().Length) { $text.Space = [DocumentFormat.OpenXml.SpaceProcessingModeValues]::Preserve }
            [void]$item.Append($text)
            [void]$sst.Append($item)
        }
        $sst.Count = [uint32]$ssList.Count; $sst.UniqueCount = [uint32]$ssList.Count
        $sstPart.SharedStringTable = $sst

        $wbPart.Workbook.Save()
    }
    finally { $doc.Dispose() }
    return $Path
}

function Write-NeoIPCDataDictionaryCsv {
    # Write the sheets as one UTF-8 (BOM, for Excel) / LF CSV per sheet, named <BaseName>-<FileSuffix>.csv.
    # BOM so spreadsheet apps detect UTF-8 (pathogen / antibiotic names carry diacritics); LF for git-stable,
    # byte-identical re-runs. Embedded CR/CRLF inside a cell (e.g. a CRLF-authored description) is normalized to
    # LF so the file carries no CR byte and is platform-independent (a multi-line cell stays RFC-4180-quoted).
    # Returns the written paths.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][object[]]$Sheet, [Parameter(Mandatory)][string]$OutputDirectory, [Parameter(Mandatory)][string]$BaseName)
    $written = [System.Collections.Generic.List[string]]::new()
    foreach ($sheet in $Sheet) {
        $path = Join-Path $OutputDirectory ('{0}-{1}.csv' -f $BaseName, $sheet.FileSuffix)
        $writer = [System.IO.StreamWriter]::new($path, $false, [System.Text.UTF8Encoding]::new($true))
        $writer.NewLine = "`n"
        try {
            $writer.WriteLine((($sheet.Columns | ForEach-Object { ConvertTo-NeoIPCCsvField $_ }) -join ','))
            foreach ($row in $sheet.Rows) {
                $writer.WriteLine((($sheet.Columns | ForEach-Object { ConvertTo-NeoIPCCsvField (([string]$row[$_]).Replace("`r`n", "`n").Replace("`r", "`n")) }) -join ','))
            }
        }
        finally { $writer.Dispose() }
        $written.Add($path)
    }
    return $written.ToArray()
}
