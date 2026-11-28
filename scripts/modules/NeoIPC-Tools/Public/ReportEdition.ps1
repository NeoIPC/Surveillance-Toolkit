#Requires -Version 7.6

<#
.SYNOPSIS
Read the parameters of one report preset from a presets.json file.

.DESCRIPTION
Reads the named preset's parameter set from a report's presets.json, the file the reporting
service also serves for its preset listing. The _comment key documents the file and is no
render parameter, so it is left out. Each call returns a fresh hashtable the caller may edit.
An unknown name ends the call with an error listing the names the file carries, and a file
without a presets object is refused rather than read as an empty one.

.PARAMETER PresetsFilePath
The presets.json to read, path of an existing file.

.PARAMETER Name
The preset to read, a key of the file's presets object.

.OUTPUTS
[hashtable] The preset's render parameters, camelCase keys as the document declares them.

.EXAMPLE
$preset = Get-NeoIPCReportPreset -PresetsFilePath reports/Reference-Report/presets.json -Name class-range-edition

Reads what a report of a class or range switches off, to seed the render parameters with.
#>
function Get-NeoIPCReportPreset {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$PresetsFilePath,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $PresetsFilePath)) {
        throw "The presets file '$PresetsFilePath' does not exist."
    }
    $document = (Get-Content -LiteralPath $PresetsFilePath -Raw) | ConvertFrom-Json
    $presets = $document.PSObject.Properties['presets']
    if ($null -eq $presets -or $null -eq $presets.Value) {
        throw "The presets file '$PresetsFilePath' carries no presets object."
    }

    $entry = $presets.Value.PSObject.Properties[$Name]
    if ($null -eq $entry) {
        $available = @($presets.Value.PSObject.Properties.Name) | Sort-Object
        throw "No preset named '$Name'. The file carries: $($available -join ', ')."
    }

    $parameters = @{}
    foreach ($property in $entry.Value.PSObject.Properties) {
        if ($property.Name -eq '_comment') {
            continue
        }
        $parameters[$property.Name] = $property.Value
    }
    return $parameters
}

<#
.SYNOPSIS
Read the number of departments a serialized reference dataset was built from.

.DESCRIPTION
Reads the n_departments field a serialized NeoIPC reference dataset carries: the number of
distinct departments its enrolments sit in, which is the count of departments whose patient
records ended their surveillance within the dataset's period. The count is decoded in R by
jsonlite::unserializeJSON, the reader of the format jsonlite::serializeJSON writes: the
serialized shape is jsonlite's own and differs across its package versions, and only R's
reader tracks its writer. A file that is no serialized dataset, or carries no
n_departments within it, is refused with an error naming the file, since a build gate cannot
decide on a count it cannot read. Rscript must be on PATH and its R must carry jsonlite.

.PARAMETER DatasetFilePath
The dataset's JSON file, path of an existing file.

.OUTPUTS
[System.Int32]

.EXAMPLE
$departments = Get-NeoIPCReferenceDatasetDepartmentCount -DatasetFilePath reference.json

Reads how many departments the dataset gives its figures to.
#>
function Get-NeoIPCReferenceDatasetDepartmentCount {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$DatasetFilePath
    )

    if (-not (Test-Path -LiteralPath $DatasetFilePath)) {
        throw "The dataset file '$DatasetFilePath' does not exist."
    }
    $rscript = Get-Command -Name Rscript -ErrorAction SilentlyContinue
    if (-not $rscript) {
        throw "Reading the department count of '$(Split-Path -Leaf $DatasetFilePath)' needs Rscript on PATH."
    }
    # R's $ matches a list's names partially, so only the exact [[ read can tell
    # n_departments from a field whose name merely starts with it. Status 5 separates an
    # R without jsonlite from a file that is no dataset, and status 4 a wrong-typed
    # count from a missing one. The decoder isolates every failure of its own read in the
    # handler h and prints the message on stdout under status 6, where the refusal can
    # quote it without the startup warnings R puts on stderr; matching stderr's "Error"
    # would quote nothing in a German R, which says "Fehler". The extraction is inside
    # the isolation because serialized content of no list (a scalar) unserializes
    # successfully and fails only when indexed.
    $decoder = 'p <- commandArgs(trailingOnly = TRUE)[[1]]; h <- function(e) { cat(conditionMessage(e)); quit(save = "no", status = 6) }; if (!requireNamespace("jsonlite", quietly = TRUE)) quit(save = "no", status = 5); dataset <- tryCatch(jsonlite::unserializeJSON(readLines(p, warn = FALSE)), error = h); count <- tryCatch(dataset[["n_departments", exact = TRUE]], error = h); if (is.null(count)) quit(save = "no", status = 3); if (!(is.numeric(count) && length(count) == 1L && !is.na(count))) quit(save = "no", status = 4); cat(format(count, scientific = FALSE))'
    # The exit codes are the diagnosis, so a global native-command error preference must
    # not throw over them; the assignment is local to this function's scope.
    $nativeUseErrorActionPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $reported = @(& $rscript.Source --vanilla -e $decoder $DatasetFilePath 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativeUseErrorActionPreference
    }
    # Merged stderr arrives as ErrorRecords; a warning R prints while succeeding must not
    # contaminate the count it printed on stdout.
    $printed = @($reported | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($exitCode -eq 5) {
        throw "Reading the department count of '$(Split-Path -Leaf $DatasetFilePath)' needs R's jsonlite package, which the R on this machine does not carry."
    }
    if ($exitCode -eq 3) {
        throw "The dataset file '$(Split-Path -Leaf $DatasetFilePath)' carries no n_departments field."
    }
    if ($exitCode -eq 4) {
        throw "The dataset file '$(Split-Path -Leaf $DatasetFilePath)' carries no single whole-number n_departments field."
    }
    if ($exitCode -eq 6) {
        # The decoder isolated its own failure and printed the message on stdout; stderr
        # may hold startup warnings before it.
        $cause = (@($printed | Where-Object { $_ }) -join ' ')
        if (-not $cause) {
            $cause = 'R isolated the failure but printed no message'
        }
        throw "The dataset file '$(Split-Path -Leaf $DatasetFilePath)' is not a serialized reference dataset (R reported: $cause)."
    }
    if ($exitCode -ne 0) {
        # R isolates its own read failures under status 6, so only a failure of the
        # Rscript call itself — R not starting, the expression never running — reaches
        # this last resort, and its stderr is all the report there is.
        $errorLines = @($reported | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" } | Where-Object { $_ })
        $cause = if ($errorLines) { $errorLines[0] } else { @($printed | Where-Object { $_ })[0] }
        throw "The dataset file '$(Split-Path -Leaf $DatasetFilePath)' is not a serialized reference dataset (R reported: $cause)."
    }
    $text = ($printed -join '').Trim()
    $count = 0L
    if ($text -notmatch '^\d+$' -or -not [long]::TryParse($text, [ref]$count) -or $count -lt [int]::MinValue -or $count -gt [int]::MaxValue) {
        throw "The dataset file '$(Split-Path -Leaf $DatasetFilePath)' gave no whole-number department count (R printed: '$text')."
    }
    return [int]$count
}
