#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Checks that the YAML readers the toolkit meets read every committed YAML file alike.

.DESCRIPTION
    The toolkit's YAML is YAML 1.2.2, and the reference reading is yaml12's, an R package built on a parser that
    passes the YAML test suite. This script reads every committed YAML file (git ls-files, so a submodule's files are
    left out) with yaml12, and with the readers the toolkit's own code uses: R's yaml package, with which the reports
    read their string resources; powershell-yaml; and ruamel.yaml in its safe and its round-trip mode. It compares each
    reading with yaml12's.

    Each file is read in three processes of its own, one each for R, Python, and PowerShell, and each writes its
    readings as JSON in one typed form: a mapping as {"map": [[key, value], ...]}, a sequence as {"seq": [...]}, and a
    scalar as [type, text], so that the comparison sees a reader's types: a string (compared ordinally, code point by
    code point), an integer (compared by value), a float (compared by value, NaN equal to NaN), a Boolean, null, R's
    NA, and any other type a reader makes, such as a date. Mapping keys are compared with their types, so an integer
    key and a string key differ. R's yaml reads a sequence of scalars into a vector, which cannot tell a one-item
    sequence from its item, or an empty mapping from an empty sequence, so against it those read alike.

    A difference means that a file reads one way in one tool and another way in the next, as 0x1A does: yaml12 reads
    the number 26, powershell-yaml the string "0x1A". Each one is named with its file and its place in the file.
    Before reading any file, the script checks its comparison on pairs that differ and pairs that agree, so that a
    comparison that finds nothing cannot pass for agreement.

    A file's three processes run side by side, and each has TimeoutSeconds to finish. One that does not is stopped,
    its own child processes with it, and each of its readers that has not written its reading by then counts as unable
    to read the file, so that a reader that does not finish is named rather than waited on: a plain 1e999999999 holds
    powershell-yaml's BigInteger.TryParse far longer than any check can wait. A reading is renamed into place once
    complete, so a stopped process leaves none half-written. Where yaml12 cannot read a file, there is nothing to
    compare the other readings with, and their processes are stopped at once.

    Exit codes: 0 when every reader agrees with yaml12 on every file; 1 when one does not, when a reader cannot read a
    file, or when the comparison fails its own check; 2 when an interpreter or a reader is missing, or there is no
    YAML file to read.

.PARAMETER RepositoryRoot
    The repository whose committed YAML files are read. Defaults to the repository that holds this script.

.PARAMETER Path
    Files to read instead of every committed YAML file, relative to the repository root or absolute.

.PARAMETER Python
    The Python interpreter, 3.11 or later, that has ruamel.yaml, as the name or path of a program: an alias or a
    function is not followed. Defaults to python.

.PARAMETER TimeoutSeconds
    How long each of a file's three reading processes may take before it is stopped. Defaults to 120.

.EXAMPLE
    ./scripts/Test-YamlReaderAgreement.ps1

.EXAMPLE
    ./scripts/Test-YamlReaderAgreement.ps1 -Python py -Path metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string[]]$Path,
    [string]$Python = 'python',
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Reads each file of a list with yaml12 and with R's yaml, and writes yaml12-<n>.json and r-yaml-<n>.json, or .error
# with the reason, beside it.
$rScript = @'
args <- commandArgs(trailingOnly = TRUE)
files <- readLines(args[[1]], encoding = "UTF-8", warn = FALSE)
out_dir <- args[[2]]

# A scalar as [type, text]: null, NA, NaN, and the infinities spelt out, and a double in 17 significant digits, so
# that every double reads back as itself.
scalar <- function(x) {
  if (is.null(x)) return(list("null", ""))
  if (inherits(x, "_yaml.merge_")) return(list("merge", "<<"))
  if (is.logical(x)) return(if (is.na(x)) list("NA", "logical") else list("bool", if (x) "true" else "false"))
  if (is.integer(x)) return(if (is.na(x)) list("NA", "integer") else list("int", as.character(x)))
  if (is.double(x)) {
    if (is.nan(x)) return(list("float", "nan"))
    if (is.na(x)) return(list("NA", "double"))
    if (is.infinite(x)) return(list("float", if (x > 0) "inf" else "-inf"))
    return(list("float", sprintf("%.17g", x)))
  }
  if (is.character(x)) return(if (is.na(x)) list("NA", "character") else list("str", enc2utf8(x)))
  list(class(x)[[1]], paste(format(x), collapse = " "))
}

# yaml12's reading, made with simplify = FALSE: a list with names, or with the yaml_keys attribute that holds a typed
# key, is a mapping; another list is a sequence.
canonical_yaml12 <- function(x) {
  if (!is.list(x)) return(scalar(x))
  keys <- attr(x, "yaml_keys", exact = TRUE)
  key_names <- names(x)
  if (is.null(keys) && is.null(key_names)) return(list(seq = unname(lapply(x, canonical_yaml12))))
  key_nodes <- if (is.null(keys)) lapply(key_names, function(k) list("str", enc2utf8(k))) else lapply(keys, canonical_yaml12)
  list(map = unname(Map(function(k, v) list(k, canonical_yaml12(v)), key_nodes, unname(x))))
}

# R's yaml's reading: a list with names is a mapping, whose keys R holds as names; another list is a sequence, and so
# is an atomic vector of more than one value, into which it reads a sequence of scalars.
canonical_r_yaml <- function(x) {
  if (is.null(x)) return(scalar(x))
  if (is.list(x)) {
    if (is.null(names(x))) return(list(seq = unname(lapply(x, canonical_r_yaml))))
    return(list(map = unname(Map(function(k, v) list(list("str", enc2utf8(k)), canonical_r_yaml(v)), names(x), x))))
  }
  if (length(x) == 1) return(scalar(x))
  list(seq = lapply(seq_along(x), function(i) scalar(x[i])))
}

# Written under another name and renamed once complete, so that a reading cut short by its process being stopped
# leaves no file to be taken for a reading.
write_text <- function(path, text) {
  partial <- paste0(path, ".partial")
  con <- file(partial, open = "wb")
  writeLines(enc2utf8(text), con, sep = "\n", useBytes = TRUE)
  close(con)
  if (!file.rename(partial, path)) stop("cannot rename ", partial, " to ", path)
}

# The JSON is made within the tryCatch too, since toJSON fails on a reading nested a few hundred levels deep: a file
# one reader cannot read is a difference, not the end of the run.
read_with <- function(i, prefix, reader) {
  result <- tryCatch(
    list(ok = TRUE, value = as.character(jsonlite::toJSON(reader(files[[i]]), auto_unbox = TRUE, null = "null"))),
    error = function(e) list(ok = FALSE, value = conditionMessage(e))
  )
  write_text(file.path(out_dir, paste0(prefix, "-", i, if (result$ok) ".json" else ".error")), result$value)
}

for (i in seq_along(files)) {
  read_with(i, "yaml12", function(f) canonical_yaml12(yaml12::read_yaml(f, simplify = FALSE)))
  read_with(i, "r-yaml", function(f) canonical_r_yaml(suppressWarnings(yaml::read_yaml(f))))
}
'@

# Reads each file of a list with ruamel.yaml in its safe and its round-trip mode, both in pure Python, and writes
# ruamel-<mode>-<n>.json, or .error with the reason. ruamel.yaml 0.19 makes its C loader an optional extra, which the
# toolkit's scripts do not install.
$pythonScript = @'
import json
import math
import sys
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.scalarbool import ScalarBoolean


def canonical(value):
    """The reading in the typed form the three languages share (see the script's help): a float as its repr, which
    reads back as the same double, and NaN and the infinities spelt out."""
    if isinstance(value, dict):
        return {"map": [[canonical(key), canonical(item)] for key, item in value.items()]}
    if isinstance(value, (list, tuple)):
        return {"seq": [canonical(item) for item in value]}
    if value is None:
        return ["null", ""]
    if isinstance(value, (bool, ScalarBoolean)):  # both are ints, so they come before the int
        return ["bool", "true" if value else "false"]
    if isinstance(value, int):
        return ["int", str(int(value))]
    if isinstance(value, float):
        if math.isnan(value):
            return ["float", "nan"]
        if math.isinf(value):
            return ["float", "inf" if value > 0 else "-inf"]
        return ["float", repr(float(value))]
    if isinstance(value, str):
        return ["str", str(value)]
    return [type(value).__name__, str(value)]  # a date, a timestamp, or another type of ruamel.yaml's own


def write_text(path: Path, text: str) -> None:
    """Writes under another name and renames once complete, so that a reading cut short by its process being stopped
    leaves no file to be taken for a reading."""
    partial = path.with_name(path.name + ".partial")
    partial.write_text(text, encoding="utf-8", errors="backslashreplace", newline="\n")
    partial.replace(path)


def main(list_file: str, out_dir: str) -> None:
    # Split on line feeds alone: str.splitlines() also splits on U+0085, U+2028, and U+2029, which a path may hold.
    files = [line for line in Path(list_file).read_text(encoding="utf-8").split("\n") if line]
    for index, path in enumerate(files, start=1):
        for mode in ("safe", "rt"):
            target = Path(out_dir) / f"ruamel-{mode}-{index}"
            try:
                with open(path, encoding="utf-8") as stream:
                    value = YAML(typ=mode, pure=True).load(stream)
                # ensure_ascii escapes every character beyond ASCII, a lone surrogate among them, which UTF-8 cannot
                # encode, and ConvertFrom-Json reads the escapes back.
                text = json.dumps(canonical(value), ensure_ascii=True)
                write_text(target.with_suffix(".json"), text + "\n")
            except Exception as error:  # a file one reader cannot read is a difference, not the end of the run
                write_text(target.with_suffix(".error"), f"{type(error).__name__}: {error}\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
'@

# Reads one file with powershell-yaml and writes <Target>.json, or <Target>.error with the reason. It runs in a process
# of its own, as the R and Python readings do, so that a reading that does not finish can be stopped.
$powershellYamlScript = @'
param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-TypedNode {
    # powershell-yaml's reading in the typed form every reader writes.
    param([AllowNull()]$Value)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -eq $Value) { return , @('null', '') }
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = [System.Collections.Generic.List[object]]::new()
        foreach ($key in $Value.Keys) { $pairs.Add(@(@('str', [string]$key), (ConvertTo-TypedNode $Value[$key]))) }
        return @{ map = $pairs }
    }
    if ($Value -is [System.Collections.IList]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-TypedNode $item)) }
        return @{ seq = $items }
    }
    if ($Value -is [bool]) { return , @('bool', $(if ($Value) { 'true' } else { 'false' })) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [System.Numerics.BigInteger]) { return , @('int', $Value.ToString($invariant)) }
    if ($Value -is [decimal]) { return , @('float', $Value.ToString($invariant)) }
    if ($Value -is [double]) {
        if ([double]::IsNaN($Value)) { return , @('float', 'nan') }
        if ([double]::IsInfinity($Value)) { return , @('float', $(if ($Value -gt 0) { 'inf' } else { '-inf' })) }
        return , @('float', $Value.ToString('R', $invariant))
    }
    if ($Value -is [datetime]) { return , @('datetime', $Value.ToString('o', $invariant)) }
    if ($Value -is [string]) { return , @('str', $Value) }
    , @($Value.GetType().Name, [string]$Value)
}

# What a JSON string escapes, and how, made once: a script-block literal inside a function is a new script block on
# every call, and PowerShell compiles a new delegate for each, which costs far more than the replacement.
$escaped = [regex]::new('[^\x20\x21\x23-\x5B\x5D-\x7E]')
$escape = [System.Text.RegularExpressions.MatchEvaluator] { param($character) '\u{0:x4}' -f [int]$character.Value[0] }

function ConvertTo-JsonText {
    # A string as a JSON string in ASCII alone, as the Python reading writes its own: the quotation mark, the backslash,
    # and every character outside printable ASCII as \uXXXX, by UTF-16 code unit, so that no encoding between this
    # process and the comparison can change a character.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    '"' + $script:escaped.Replace($Text, $script:escape) + '"'
}

function Add-TypedJson {
    # A typed node appended to a JSON text, written by hand, since ConvertTo-Json goes no deeper than 100 levels, and
    # the typed form takes three for each mapping and two for each sequence.
    param([AllowNull()]$Node, [Parameter(Mandatory)][System.Text.StringBuilder]$Json)
    if ($Node -is [System.Collections.IDictionary]) {
        $isMapping = $Node.Contains('map')
        # Indexed, not taken from an if statement, whose output would unroll a list of one pair into the pair.
        $items = $Node[$(if ($isMapping) { 'map' } else { 'seq' })]
        [void]$Json.Append($(if ($isMapping) { '{"map":[' } else { '{"seq":[' }))
        for ($index = 0; $index -lt $items.Count; $index++) {
            if ($index -gt 0) { [void]$Json.Append(',') }
            if ($isMapping) {
                [void]$Json.Append('[')
                Add-TypedJson -Node $items[$index][0] -Json $Json
                [void]$Json.Append(',')
                Add-TypedJson -Node $items[$index][1] -Json $Json
                [void]$Json.Append(']')
            }
            else {
                Add-TypedJson -Node $items[$index] -Json $Json
            }
        }
        [void]$Json.Append(']}')
        return
    }
    [void]$Json.Append('[').Append((ConvertTo-JsonText $Node[0])).Append(',').Append((ConvertTo-JsonText $Node[1])).Append(']')
}

function Write-Reading {
    # A reading written under another name and renamed once complete, so that one cut short by this process being
    # stopped leaves no file to be taken for a reading.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [System.IO.File]::WriteAllText("$Path.partial", $Text, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move("$Path.partial", $Path)
}

try {
    Import-Module powershell-yaml
    $json = [System.Text.StringBuilder]::new()
    Add-TypedJson -Node (ConvertTo-TypedNode ([System.IO.File]::ReadAllText($Source) | ConvertFrom-Yaml -Ordered)) -Json $json
    Write-Reading -Path "$Target.json" -Text ($json.ToString() + "`n")
}
catch {
    # A file one reader cannot read is a difference, not the end of the run.
    Write-Reading -Path "$Target.error" -Text ($_.Exception.Message + "`n")
}
'@

function ConvertFrom-TypedJson {
    # A reading's typed JSON parsed back, with every string left a string: ConvertFrom-Json would otherwise turn a
    # date-like string into a DateTime. Its default limit of 1,024 levels stands: the typed form takes three levels for
    # each mapping and two for each sequence, so the ontology, 15 mappings and 14 sequences deep, already needs 74.
    param([Parameter(Mandatory)][string]$Json)
    ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -DateKind String
}

function Get-NodeKind {
    # The kind of a typed node: mapping, sequence, or scalar.
    param([AllowNull()]$Node)
    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('map')) { return 'mapping' }
        if ($Node.Contains('seq')) { return 'sequence' }
    }
    'scalar'
}

function ConvertTo-Double {
    # A float's text as a double: nan, inf, and -inf spelt out, any other number in the invariant culture.
    param([Parameter(Mandatory)][string]$Text)
    switch -CaseSensitive ($Text) {
        'nan' { [double]::NaN }
        'inf' { [double]::PositiveInfinity }
        '-inf' { [double]::NegativeInfinity }
        default { [double]::Parse($Text, [System.Globalization.CultureInfo]::InvariantCulture) }
    }
}

function Test-ScalarAlike {
    # Whether two typed scalars are alike: the same type, and the same value, an integer or a float by its value, and
    # any other by its text, compared ordinally: -ceq compares linguistically, so a zero-width joiner, a soft hyphen,
    # or a NUL would count as nothing, and a precomposed letter as its decomposed form.
    param([Parameter(Mandatory)]$Reference, [Parameter(Mandatory)]$Other)
    if (-not [string]::Equals([string]$Reference[0], [string]$Other[0], [System.StringComparison]::Ordinal)) { return $false }
    switch -CaseSensitive ($Reference[0]) {
        'int' {
            $invariant = [System.Globalization.CultureInfo]::InvariantCulture
            return [System.Numerics.BigInteger]::Parse($Reference[1], $invariant) -eq [System.Numerics.BigInteger]::Parse($Other[1], $invariant)
        }
        'float' {
            $a = ConvertTo-Double $Reference[1]
            $b = ConvertTo-Double $Other[1]
            return ($a -eq $b) -or ([double]::IsNaN($a) -and [double]::IsNaN($b))
        }
        default { return [string]::Equals([string]$Reference[1], [string]$Other[1], [System.StringComparison]::Ordinal) }
    }
}

function Get-KeyText {
    # A mapping key as one text that two readers' alike keys share: its type with its value, or, for a key that is a
    # mapping or a sequence, its JSON.
    param([Parameter(Mandatory)]$Node)
    if ((Get-NodeKind $Node) -ne 'scalar') { return ConvertTo-Json -InputObject $Node -Depth 100 -Compress }
    $text = switch -CaseSensitive ($Node[0]) {
        'int' { [System.Numerics.BigInteger]::Parse($Node[1], [System.Globalization.CultureInfo]::InvariantCulture).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
        'float' { (ConvertTo-Double $Node[1]).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
        default { $Node[1] }
    }
    "$($Node[0])`t$text"
}

function Format-Text {
    # A text as a difference shows it: a control or format character, or a line or paragraph separator, which would
    # show as nothing or break the line, as its code point, such as <U+0085>, and so is a < that starts what would
    # read as such an escape, so that every escape is one.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $builder = [System.Text.StringBuilder]::new()
    $index = 0
    foreach ($rune in $Text.EnumerateRunes()) {
        if ([System.Text.Rune]::GetUnicodeCategory($rune) -in 'Control', 'Format', 'LineSeparator', 'ParagraphSeparator' -or
            ($rune.Value -eq 0x3C -and [string]::CompareOrdinal($Text, $index + 1, 'U+', 0, 2) -eq 0)) {
            [void]$builder.Append(('<U+{0:X4}>' -f $rune.Value))
        }
        else { [void]$builder.Append($rune.ToString()) }
        $index += $rune.Utf16SequenceLength
    }
    $builder.ToString()
}

function Format-Node {
    # A node as a difference names it: its kind, and a scalar's type and text. A text of more than 60 characters is cut
    # to 57, never inside a surrogate pair, from a little before From, where the two texts compared first differ, so
    # that the difference shows, and its length follows.
    param([AllowNull()]$Node, [int]$From = 0)
    switch (Get-NodeKind $Node) {
        'mapping' { return 'a mapping' }
        'sequence' { return 'a sequence' }
    }
    $type = [string]$Node[0]
    $full = [string]$Node[1]
    $text = $full
    $length = ''
    if ($full.Length -gt 60) {
        $start = [Math]::Max(0, [Math]::Min($From - 20, $full.Length - 57))
        if ($start -gt 0 -and [char]::IsLowSurrogate($full[$start])) { $start-- }
        $end = [Math]::Min($full.Length, $start + 57)
        if ($end -lt $full.Length -and [char]::IsHighSurrogate($full[$end - 1])) { $end-- }
        $text = $(if ($start -gt 0) { '...' }) + $full.Substring($start, $end - $start) + $(if ($end -lt $full.Length) { '...' })
        $length = " ($($full.Length) characters)"
    }
    $text = Format-Text $text
    switch -CaseSensitive ($type) {
        'str' { "the string '$text'$length" }
        'int' { "the integer $text$length" }
        'float' { "the float $text$length" }
        'bool' { "the Boolean $text" }
        'null' { 'null' }
        'NA' { "NA, R's missing $text" }
        default { "a $type ('$text')$length" }
    }
}

function Format-Key {
    # A key as a place names it: a string key as its text, any other as Format-Node names it.
    param([Parameter(Mandatory)]$Node)
    if ((Get-NodeKind $Node) -eq 'scalar' -and $Node[0] -ceq 'str') { return "'$(Format-Text $Node[1])'" }
    Format-Node $Node
}

function Compare-YamlReading {
    # One line per place where a reading differs from yaml12's. With Lenient, for R's yaml, a one-item sequence reads
    # like its item, and an empty mapping like an empty sequence (see the script's help).
    param([AllowNull()]$Reference, [AllowNull()]$Other, [Parameter(Mandatory)][AllowEmptyString()][string]$Place, [switch]$Lenient)
    $referenceKind = Get-NodeKind $Reference
    $otherKind = Get-NodeKind $Other
    if ($Lenient) {
        if ($referenceKind -eq 'sequence' -and $Reference.seq.Count -eq 1 -and $otherKind -eq 'scalar') {
            return Compare-YamlReading -Reference $Reference.seq[0] -Other $Other -Place "$($Place)[0]" -Lenient
        }
        $referenceCount = if ($referenceKind -eq 'mapping') { $Reference.map.Count } elseif ($referenceKind -eq 'sequence') { $Reference.seq.Count } else { -1 }
        $otherCount = if ($otherKind -eq 'mapping') { $Other.map.Count } elseif ($otherKind -eq 'sequence') { $Other.seq.Count } else { -1 }
        if ($referenceCount -eq 0 -and $otherCount -eq 0) { return }
    }
    if ($referenceKind -ne $otherKind) {
        "${Place}: yaml12 reads $(Format-Node $Reference), this reader $(Format-Node $Other)"
        return
    }
    switch ($referenceKind) {
        'mapping' {
            $otherByKey = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            foreach ($pair in $Other.map) {
                $key = Get-KeyText $pair[0]
                if (-not $otherByKey.ContainsKey($key)) { $otherByKey[$key] = $pair }
            }
            foreach ($pair in $Reference.map) {
                $key = Get-KeyText $pair[0]
                $shown = Format-Key $pair[0]
                if ($otherByKey.ContainsKey($key)) {
                    Compare-YamlReading -Reference $pair[1] -Other $otherByKey[$key][1] -Place "$Place/$shown" -Lenient:$Lenient
                    [void]$otherByKey.Remove($key)
                }
                else { "${Place}: this reader lacks the key $shown" }
            }
            foreach ($pair in $otherByKey.Values) { "${Place}: this reader adds the key $(Format-Key $pair[0])" }
        }
        'sequence' {
            if ($Reference.seq.Count -ne $Other.seq.Count) {
                "${Place}: yaml12 reads $($Reference.seq.Count) items, this reader $($Other.seq.Count)"
                return
            }
            for ($i = 0; $i -lt $Reference.seq.Count; $i++) { Compare-YamlReading -Reference $Reference.seq[$i] -Other $Other.seq[$i] -Place "$($Place)[$i]" -Lenient:$Lenient }
        }
        default {
            if (-not (Test-ScalarAlike -Reference $Reference -Other $Other)) {
                $referenceText = [string]$Reference[1]
                $otherText = [string]$Other[1]
                $from = 0
                $limit = [Math]::Min($referenceText.Length, $otherText.Length)
                while ($from -lt $limit -and $referenceText[$from] -ceq $otherText[$from]) { $from++ }
                "${Place}: yaml12 reads $(Format-Node $Reference -From $from), this reader $(Format-Node $Other -From $from)"
            }
        }
    }
}

function Read-ReaderOutput {
    # A reader's output for one file: its typed JSON parsed back, or the reason it could not read the file: its own,
    # or, where it wrote neither, its process's failure. A reader renames each file into place once complete, so a
    # reading its process wrote before it was stopped stands.
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Stem, [string]$Failure)
    $json = Join-Path $Directory "$Stem.json"
    if (Test-Path -LiteralPath $json) {
        return @{ Value = ConvertFrom-TypedJson -Json ([System.IO.File]::ReadAllText($json)); Error = $null }
    }
    $errorFile = Join-Path $Directory "$Stem.error"
    $reason = if (Test-Path -LiteralPath $errorFile) { [System.IO.File]::ReadAllText($errorFile).Trim() } elseif ($Failure) { $Failure } else { 'it wrote nothing' }
    @{ Value = $null; Error = $reason }
}

function Start-Reader {
    # Starts a reading process, its script given on standard input where it has one, and its temporary files kept in
    # TemporaryDirectory, so that a process stopped before it can remove them, such as R with its session directory,
    # leaves them where this run removes them.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The process it starts reads one file and writes its readings and its temporary files only to this run''s temporary directory.')]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$TemporaryDirectory,
        [string]$InputText
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($item in $ArgumentList) { $start.ArgumentList.Add($item) }
    foreach ($variable in 'TMPDIR', 'TMP', 'TEMP') { $start.Environment[$variable] = $TemporaryDirectory }
    $start.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')
    if ($start.RedirectStandardInput) { $start.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false) }
    $process = [System.Diagnostics.Process]::Start($start)
    if ($start.RedirectStandardInput) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }
    $process
}

function Wait-Reader {
    # Waits for a reading process until TimeoutSeconds have passed on Clock, which started with the file's processes,
    # and stops it, its own child processes with it, once they have. Returns why the process failed, or nothing when it
    # finished cleanly. Clock is a stopwatch, which no step of the system clock moves. The wait goes in slices of a
    # fifth of a second, since a stop of the script, as by Ctrl+C, takes effect only once a .NET call returns.
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Clock,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $limit = $TimeoutSeconds * 1000L
    while (-not $Process.WaitForExit([int][Math]::Min(200, [Math]::Max(0, $limit - $Clock.ElapsedMilliseconds)))) {
        if ($Clock.ElapsedMilliseconds -ge $limit) {
            $Process.Kill($true)
            $Process.WaitForExit()
            return "its $Name process did not finish within $TimeoutSeconds $(if ($TimeoutSeconds -eq 1) { 'second' } else { 'seconds' })"
        }
    }
    if ($Process.ExitCode -ne 0) { return "its $Name process exited $($Process.ExitCode)" }
}

function Stop-Reader {
    # Stops a reading process that is still running, its own child processes with it, and releases it: whether its
    # reading is no longer wanted or an error or an interrupt ends the file's work early.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'It stops only a reading process this run started.')]
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            $Process.WaitForExit()
        }
    }
    finally { $Process.Dispose() }
}

function Get-CommittedYamlFile {
    # The repository's committed YAML files, from git ls-files with NUL separators and unquoted paths, decoded as
    # UTF-8 whatever the console's code page, with which PowerShell would decode a native command's output. git runs
    # without the variables that tie it to one repository, as git itself lists them: it exports some of them, such as
    # GIT_DIR and GIT_INDEX_FILE, to its hooks, and they outrank -C.
    param([Parameter(Mandatory)][string]$Root)
    $localVariables = @(& git rev-parse --local-env-vars)
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse --local-env-vars failed (exit code $LASTEXITCODE)." }
    $start = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($item in '-C', $Root, '-c', 'core.quotePath=false', 'ls-files', '-z', '--', '*.yaml', '*.yml') { $start.ArgumentList.Add($item) }
    foreach ($name in $localVariables) { [void]$start.Environment.Remove($name) }
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git ls-files failed in '$Root': $($errorOutput.Result.Trim())" }
    }
    finally { $process.Dispose() }
    $output.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { Join-Path $Root $_ }
}

# The comparison's own check: each pair must differ, or agree, as it says.
$selfCheck = @(
    @{ Reference = '["int","26"]'; Other = '["str","0x1A"]'; Differs = $true; Lenient = $false }
    @{ Reference = '["int","1"]'; Other = '["float","1"]'; Differs = $true; Lenient = $false }
    @{ Reference = '["float","nan"]'; Other = '["float","nan"]'; Differs = $false; Lenient = $false }
    @{ Reference = '["float","1"]'; Other = '["float","1.0"]'; Differs = $false; Lenient = $false }
    @{ Reference = '["str","x"]'; Other = '["str","x​"]'; Differs = $true; Lenient = $false }
    @{ Reference = '{"map":[[["str","a"],["int","1"]]]}'; Other = '{"map":[]}'; Differs = $true; Lenient = $false }
    @{ Reference = '{"map":[[["bool","true"],["str","x"]]]}'; Other = '{"map":[[["str","true"],["str","x"]]]}'; Differs = $true; Lenient = $false }
    @{ Reference = '{"map":[[["str","a"],["int","1"]]]}'; Other = '{"map":[[["str","a"],["int","2"]]]}'; Differs = $true; Lenient = $false }
    @{ Reference = '{"seq":[["int","1"]]}'; Other = '{"seq":[["int","1"],["int","2"]]}'; Differs = $true; Lenient = $false }
    @{ Reference = '{"seq":[["str","a"]]}'; Other = '["str","a"]'; Differs = $true; Lenient = $false }
    @{ Reference = '{"seq":[["str","a"]]}'; Other = '["str","a"]'; Differs = $false; Lenient = $true }
)
foreach ($case in $selfCheck) {
    $found = @(Compare-YamlReading -Reference (ConvertFrom-TypedJson $case.Reference) -Other (ConvertFrom-TypedJson $case.Other) -Place '' -Lenient:$case.Lenient)
    if (($found.Count -gt 0) -ne $case.Differs) {
        Write-Host "The comparison fails its own check: $($case.Reference) against $($case.Other) should $(if ($case.Differs) { 'differ' } else { 'agree' })." -ForegroundColor Red
        exit 1
    }
}
# The display's own check: two long texts that differ only near their end, and a text holding an escape's spelling
# against one holding the character it names, must show apart.
$long = [string]::new([char]'x', 80)
$differences = @(Compare-YamlReading -Reference @('str', "$long`n") -Other @('str', $long) -Place '')
if ($differences.Count -ne 1 -or $differences[0] -notlike '*<U+000A>*') {
    Write-Host 'The display fails its own check: two long texts that differ at their end show alike.' -ForegroundColor Red
    exit 1
}
if ((Format-Text '<U+200B>') -ceq (Format-Text ([string][char]0x200B))) {
    Write-Host 'The display fails its own check: an escape and its spelling show alike.' -ForegroundColor Red
    exit 1
}

$root = (Resolve-Path -LiteralPath $RepositoryRoot).Path
# An if statement's output unrolls, so a single file would otherwise arrive as a bare string.
$files = @(
    if ($Path) {
        $Path | ForEach-Object { (Resolve-Path -LiteralPath $(if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $root $_ })).Path }
    }
    else {
        Get-CommittedYamlFile -Root $root
    }
)
if ($files.Count -eq 0) {
    Write-Host 'No YAML file to read.' -ForegroundColor Red
    exit 2
}

$missing = [System.Collections.Generic.List[string]]::new()
try { Import-Module powershell-yaml -ErrorAction Stop } catch { $missing.Add('powershell-yaml (Install-Module powershell-yaml)') }
# Each interpreter is resolved once, as PowerShell finds a program, and its check here and its readings start the
# program found: a process started by a name alone finds no alias, no function, no path relative to PowerShell's
# location, and on Windows nothing but an .exe.
$rscriptPath = Get-Command Rscript -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $rscriptPath) {
    $missing.Add('R (Rscript)')
}
else {
    & $rscriptPath -e 'quit(status = if (all(vapply(c("yaml12", "yaml", "jsonlite"), requireNamespace, logical(1), quietly = TRUE))) 0 else 1)' 2>$null
    if ($LASTEXITCODE -ne 0) { $missing.Add('yaml12, yaml, and jsonlite in R (install.packages(c("yaml12", "yaml", "jsonlite")))') }
}
$pythonPath = Get-Command $Python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $pythonPath) {
    $missing.Add("Python ($Python)")
}
else {
    & $pythonPath -P -c 'import ruamel.yaml' 2>$null
    if ($LASTEXITCODE -ne 0) { $missing.Add("ruamel.yaml for $Python, 3.11 or later (pip install ruamel.yaml)") }
}
if ($missing.Count -gt 0) {
    Write-Host "Missing YAML readers: $($missing -join '; ')." -ForegroundColor Red
    exit 2
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "yaml-reader-agreement-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $work
try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $powershellYamlFile = Join-Path $work 'Read-PowerShellYaml.ps1'
    [System.IO.File]::WriteAllText($powershellYamlFile, $powershellYamlScript, $utf8)
    # The pwsh that runs this script runs its powershell-yaml readings too.
    $pwsh = (Get-Process -Id $PID).Path

    $differences = [System.Collections.Generic.List[string]]::new()
    for ($n = 1; $n -le $files.Count; $n++) {
        $file = $files[$n - 1]
        $relative = [System.IO.Path]::GetRelativePath($root, $file).Replace('\', '/')
        # Each file's readings go to a directory of their own, as the readings of a list of one file: yaml12-1 and
        # r-yaml-1 from R, ruamel-safe-1 and ruamel-rt-1 from Python, and powershell-yaml-1.
        $directory = Join-Path $work $n
        $null = New-Item -ItemType Directory -Path $directory
        $listFile = Join-Path $directory 'files.txt'
        [System.IO.File]::WriteAllText($listFile, "$file`n", $utf8)
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        # Each process joins the dictionary as it starts, so that the finally stops every one already started, whether
        # its reading is not wanted, a later start fails, or an error or an interrupt ends the file's work.
        $processes = [ordered]@{}
        try {
            $processes['R'] = Start-Reader -FilePath $rscriptPath -ArgumentList '-', $listFile, $directory -TemporaryDirectory $directory -InputText $rScript
            # -P keeps the current directory off Python's module path, so that no file there shadows ruamel.yaml.
            $processes['Python'] = Start-Reader -FilePath $pythonPath -ArgumentList '-P', '-', $listFile, $directory -TemporaryDirectory $directory -InputText $pythonScript
            $processes['PowerShell'] = Start-Reader -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', $powershellYamlFile, '-Source', $file, '-Target', (Join-Path $directory 'powershell-yaml-1') -TemporaryDirectory $directory
            $failures = @{ R = Wait-Reader -Process $processes['R'] -Name 'R' -Clock $clock -TimeoutSeconds $TimeoutSeconds }

            $reference = Read-ReaderOutput -Directory $directory -Stem 'yaml12-1' -Failure $failures['R']
            if ($null -ne $reference.Error) {
                $differences.Add("${relative}: yaml12 cannot read it: $($reference.Error)")
                continue
            }
            foreach ($name in 'Python', 'PowerShell') {
                $failures[$name] = Wait-Reader -Process $processes[$name] -Name $name -Clock $clock -TimeoutSeconds $TimeoutSeconds
            }

            $readings = [ordered]@{
                'powershell-yaml'          = Read-ReaderOutput -Directory $directory -Stem 'powershell-yaml-1' -Failure $failures['PowerShell']
                "R's yaml"                 = Read-ReaderOutput -Directory $directory -Stem 'r-yaml-1' -Failure $failures['R']
                'ruamel.yaml (safe)'       = Read-ReaderOutput -Directory $directory -Stem 'ruamel-safe-1' -Failure $failures['Python']
                'ruamel.yaml (round-trip)' = Read-ReaderOutput -Directory $directory -Stem 'ruamel-rt-1' -Failure $failures['Python']
            }
            foreach ($reader in $readings.Keys) {
                $reading = $readings[$reader]
                if ($null -ne $reading.Error) {
                    $differences.Add("${relative}: $reader cannot read it: $($reading.Error)")
                    continue
                }
                $found = @(Compare-YamlReading -Reference $reference.Value -Other $reading.Value -Place '' -Lenient:($reader -ceq "R's yaml"))
                foreach ($line in ($found | Select-Object -First 10)) { $differences.Add("${relative} ($reader)$line") }
                if ($found.Count -gt 10) { $differences.Add("${relative} ($reader): and $($found.Count - 10) more differences") }
            }
        }
        finally {
            foreach ($process in $processes.Values) { Stop-Reader -Process $process }
        }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($differences.Count -gt 0) {
    Write-Host "The YAML readers disagree with yaml12 in $($differences.Count) place(s):" -ForegroundColor Red
    $differences | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "powershell-yaml, R's yaml, and ruamel.yaml (safe and round-trip) read all $($files.Count) YAML files as yaml12 does." -ForegroundColor Green
exit 0
