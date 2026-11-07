#Requires -Version 7.6

<#
.SYNOPSIS
    Tests of the YAML portability check (Private/YamlPortability.ps1), on fixtures and on every committed YAML file.

.DESCRIPTION
    The toolkit's YAML is YAML 1.2.2 in its portable subset, which the YAML versions and the readers the toolkit meets
    read alike. The check models six readings of a plain scalar, and each model of a reader is held here to the reader
    itself on scalars chosen to tell them apart: powershell-yaml in this process, R's yaml and yaml12 through Rscript,
    and ruamel.yaml through Python, each failing rather than skipping where its reader is missing. Each form outside
    the subset is shown reported, in keys and values, in block and flow collections, and at depth, and each form inside
    it, accepted. The last block applies the check to every committed YAML file.

    Internals are reached through InModuleScope; the Import-Module at file top runs during Pester's discovery phase,
    which InModuleScope requires.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/YamlPortability.Tests.ps1
#>

Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop

        # Scalars that the readings type apart: the YAML 1.1 and 1.2.2 forms, powershell-yaml's TryParse, R's yaml's,
        # yaml12's, and ruamel.yaml's own, at their edges (letter case, signs, radixes, underscores, commas, the 32-
        # and 64-bit ranges, digits Python refuses to convert, decimals, subnormal floats, infinities, NaN, timestamps,
        # and NA), and plain text.
        $script:Scalars = @(
            'yes', 'Yes', 'YES', 'no', 'No', 'NO', 'y', 'Y', 'n', 'N', 'on', 'On', 'ON', 'off', 'Off', 'OFF',
            'true', 'True', 'TRUE', 'tRuE', 'false', 'False', 'FALSE', 'fAlSe', 'null', 'Null', 'NULL', 'nULL', '~', '',
            '0', '00', '012', '08', '09', '-012', '+012', '0o17', '-0o17', '+0o17', '0o1_7', '0o_7', '0o_', '0x1A',
            '-0x1A', '+0x1A', '0x1a', '0b101', '-0b101', '0b012', '0b_', '0x_', '0_', '0_7', '_', '_1', '1_', '1__2', '-_',
            '+_', '1', '-1', '+1', '10', '1_000', '1,000', '1,5', '12345678901',
            '2147483647', '2147483648', '-2147483647', '-2147483648', '3000000000', '0x7FFFFFFF', '0x80000000',
            '017777777777', '020000000000', '+-1', '++1', '-+1', '+-0', '+-1.5', '+-9223372036854775808',
            '+-9223372036854775809', '++9223372036854775808', '0x-1', '0x+E', '0o+10', '0o-7', '0x-8000000000000000',
            '0x-8000000000000001', '0x+', '0o-8', '123456789012345678',
            '9223372036854775807', '-9223372036854775809', '0x7FFFFFFFFFFFFFFF', '0x8000000000000000',
            '0o777777777777777777777', '0o1000000000000000000000', ('1' * 400), ('9' * 4300), ('9' * 4301),
            ('0' * 4300 + '1'),
            '1.0', '10.0', '6.0', '1.5', '.5', '-.5', '+.5', '5.', '-5.', '1.5e3', '1.5e+3', '1.0e+5', '1e5', '1E5',
            '1E+5', '-1e5', '1.e5', '.5e5', '.5e+5', '1e-5', '1.5e-3', '1.2.3', '.', '._', '1.2.3e+4', '1e400',
            '1.0e+400', '1.0e-400', '1e1000000000', '1e-30', '1.0e-310', '4.9e-324', '2.2250738585072011e-308',
            '2.2250738585072014e-308', '-0.0', '-0e1', '-.0', '-0_.0', '-0.0e0',
            '0.1', '0.30000000000000004', '3.141592653589793', '1234567890123456789', '0.1234567890123456789', '1.5_0',
            '-1.5_0', '1._5', '._5', '1_0e5',
            '.inf', '-.inf', '+.inf', '.Inf', '.INF', '-.Inf', '.nan', '.NaN', '.NAN', '-.nan', '+.nan', 'Infinity',
            '-Infinity', 'infinity', 'NaN', 'nan', 'INF', '1:20', '1:20:30', '-1:20', '190:20:30.15', '1:20.5',
            '2026-11-02', '2026-11-02T10:00:00Z', '2026-11-02 10:00:00', '2026-11-02T10:00:00',
            '2001-12-14t21:59:43.10-05:00', '2001-12-14 21:59:43.10 -5', '<<', '=', '.na', '.na.integer', '.na.real',
            '.na.character', '.NA', 'abc', 'the text', 'Staphylococcus aureus', '3GCR', '1st', '0x', '0o', '0b', '+',
            '1-2', 'a:b', '1 2'
        )
        # The scalars as values of one mapping, k0 to kN, in a file every reader reads.
        $script:ScalarFile = Join-Path $TestDrive 'scalars.yaml'
        $lines = for ($i = 0; $i -lt $script:Scalars.Count; $i++) { "k${i}: $($script:Scalars[$i])".TrimEnd() }
        [System.IO.File]::WriteAllText($script:ScalarFile, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))

        function Get-Reading {
            # The readings of one scalar, in the order of $script:NeoIPCYamlReaders.
            param([AllowEmptyString()][string]$Text, [switch]$Key)
            @($script:NeoIPCYamlReaders | ForEach-Object { Get-NeoIPCYamlScalarReading -Text $Text -Reader $_ -Key:$Key })
        }

        function Get-Rule {
            # The rules of the findings for a text.
            param([AllowEmptyString()][string]$Text, [switch]$StringsOnly)
            @(Get-NeoIPCYamlPortabilityFinding -Text $Text -StringsOnly:$StringsOnly | ForEach-Object { $_.Rule })
        }

        function Compare-RReading {
            # The scalars, read through Rscript by an R reader's expression over the file args[[1]], against the
            # model's reading for that reader: one line per scalar they read apart.
            param([Parameter(Mandatory)][string]$Reader, [Parameter(Mandatory)][string]$Read)
            $rScript = Join-Path $TestDrive "$($Reader -replace '\W', '-').R"
            $output = Join-Path $TestDrive "$($Reader -replace '\W', '-').tsv"
            $rCode = @'
args <- commandArgs(trailingOnly = TRUE)
reading <- function(v) {
  if (is.null(v)) return("Null")
  if (inherits(v, "_yaml.merge_")) return("Merge")
  if (is.list(v)) return("a list")
  if (is.logical(v)) return(if (is.na(v)) "NA" else paste("Boolean", if (v) "true" else "false"))
  if (is.integer(v)) return(if (is.na(v)) "NA" else paste("Integer", as.character(v)))
  if (is.double(v)) {
    if (is.nan(v)) return("Float NaN")
    if (is.na(v)) return("NA")
    if (is.infinite(v)) return(if (v > 0) "Float Infinity" else "Float -Infinity")
    return(paste("Number", sprintf("%.17g", v)))
  }
  if (is.character(v)) return(if (is.na(v)) "NA" else "String")
  paste("a", class(v)[[1]])
}
read <- READ
rows <- vapply(names(read), function(k) paste(k, reading(read[[k]]), sep = "\t"), character(1))
con <- file(args[[2]], open = "wb")
writeLines(rows, con, sep = "\n", useBytes = TRUE)
close(con)
'@
            [System.IO.File]::WriteAllText($rScript, $rCode.Replace('READ', $Read), [System.Text.UTF8Encoding]::new($false))
            & Rscript $rScript $script:ScalarFile $output
            $LASTEXITCODE | Should -Be 0 -Because "Rscript reads the scalars with $Reader, which must be installed"
            $actual = @{}
            foreach ($row in [System.IO.File]::ReadAllLines($output)) {
                $cells = $row.Split("`t")
                $actual[$cells[0]] = if ($cells[1] -cmatch '\ANumber (?<value>.+)\z') {
                    Format-NeoIPCYamlFloatReading -Value ([double]::Parse($Matches.value, [System.Globalization.CultureInfo]::InvariantCulture))
                }
                else { $cells[1] }
            }
            for ($i = 0; $i -lt $script:Scalars.Count; $i++) {
                $modelled = Get-NeoIPCYamlScalarReading -Text $script:Scalars[$i] -Reader $Reader
                # A subnormal float is NA where strtod reports its underflow, as glibc's does, and itself where it
                # does not, as Windows' does not, so the model names both and the platform decides.
                $expected = if ($modelled -cmatch '\A(?<float>Float .+) or NA\z') { if ($IsWindows) { $Matches.float } else { 'NA' } } else { $modelled }
                if ($expected -cne $actual["k$i"]) { "'$($script:Scalars[$i])': modelled $modelled, read $($actual["k$i"])" }
            }
        }

        function Compare-RuamelReading {
            # The scalars, each read through Python by ruamel.yaml 0.19 in its safe and its round-trip mode, against
            # the model's reading: one line per scalar they read apart. Each is read alone, as the value of one key,
            # since a scalar ruamel.yaml cannot construct fails the whole file it is in; and the reading names the
            # tag its resolver gave, as the model does, with the value its constructors made of it.
            $list = Join-Path $TestDrive 'scalars.json'
            $output = Join-Path $TestDrive 'ruamel.tsv'
            [System.IO.File]::WriteAllText($list, (ConvertTo-Json -InputObject $script:Scalars -Depth 100), [System.Text.UTF8Encoding]::new($false))
            $pythonCode = @'
import json
import math
import sys

from ruamel.yaml import YAML


def reading(text, mode):
    yaml = YAML(typ=mode, pure=True)
    tag = str(yaml.compose("k: " + text + "\n").value[0][1].tag).rsplit(":", 1)[-1]
    if tag in ("str", "null", "merge", "value", "timestamp"):
        return {"str": "String", "null": "Null", "merge": "Merge", "value": "Value", "timestamp": "Timestamp"}[tag]
    try:
        value = yaml.load("k: " + text + "\n")["k"]
    except ValueError as error:
        if tag == "int":
            return "Integer too long to convert" if "Exceeds the limit" in str(error) else "Integer without digits"
        return "Float without a value"
    except IndexError:
        return "Integer without digits"
    if tag == "bool":
        return "Boolean " + ("true" if value else "false")
    if tag == "int":
        return "Integer " + str(int(value))
    if tag == "float":
        if math.isnan(value):
            return "Float NaN"
        if math.isinf(value):
            return "Float Infinity" if value > 0 else "Float -Infinity"
        return "Number " + repr(float(value))
    return "a " + tag


scalars = json.loads(open(sys.argv[1], encoding="utf-8").read())
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as out:
    for index, text in enumerate(scalars):
        safe, round_trip = reading(text, "safe"), reading(text, "rt")
        out.write(f"k{index}\t{safe if safe == round_trip else 'safe ' + safe + ', round-trip ' + round_trip}\n")
'@
            # -P keeps the current directory off Python's module path, so that no file there shadows ruamel.yaml.
            $pythonCode | & python -P - $list $output
            $LASTEXITCODE | Should -Be 0 -Because 'Python reads the scalars with ruamel.yaml, which must be installed'
            $actual = @{}
            foreach ($row in [System.IO.File]::ReadAllLines($output)) {
                $cells = $row.Split("`t")
                $actual[$cells[0]] = if ($cells[1] -cmatch '\ANumber (?<value>.+)\z') {
                    Format-NeoIPCYamlFloatReading -Value ([double]::Parse($Matches.value, [System.Globalization.CultureInfo]::InvariantCulture))
                }
                else { $cells[1] }
            }
            for ($i = 0; $i -lt $script:Scalars.Count; $i++) {
                $modelled = Get-NeoIPCYamlScalarReading -Text $script:Scalars[$i] -Reader 'ruamel.yaml'
                if ($modelled -cne $actual["k$i"]) { "'$($script:Scalars[$i])': modelled $modelled, read $($actual["k$i"])" }
            }
        }
    }

    Describe 'Get-NeoIPCYamlScalarReading' {
        # The readings in order: YAML 1.1, YAML 1.2.2, powershell-yaml, R's yaml, yaml12, ruamel.yaml.
        It 'reads <Text> as <Expected>' -ForEach @(
            @{ Text = 'yes'; Expected = 'Boolean true', 'String', 'String', 'Boolean true', 'String', 'String' }
            @{ Text = '012'; Expected = 'Integer 10', 'Integer 12', 'Integer 12', 'Integer 10', 'Integer 12', 'Integer 12' }
            @{ Text = '0x1A'; Expected = 'Integer 26', 'Integer 26', 'String', 'Integer 26', 'Integer 26', 'Integer 26' }
            @{ Text = '10.0'; Expected = 'Float 10', 'Float 10', 'Integer 10', 'Float 10', 'Float 10', 'Float 10' }
            @{ Text = 'NaN'; Expected = 'String', 'String', 'Float NaN', 'String', 'String', 'String' }
            @{ Text = 'tRuE'; Expected = 'String', 'String', 'Boolean true', 'String', 'String', 'String' }
            @{ Text = 'nULL'; Expected = 'String', 'String', 'Null', 'String', 'String', 'String' }
            @{ Text = '1,000'; Expected = 'String', 'String', 'String', 'NA', 'String', 'String' }
            @{ Text = '.na'; Expected = 'String', 'String', 'String', 'NA', 'String', 'String' }
            @{ Text = '3000000000'; Expected = 'Integer 3000000000', 'Integer 3000000000', 'Integer 3000000000', 'NA', 'Float 3000000000', 'Integer 3000000000' }
            @{ Text = '-2147483648'; Expected = 'Integer -2147483648', 'Integer -2147483648', 'Integer -2147483648', 'NA', 'NA', 'Integer -2147483648' }
            @{ Text = '123456789012345678'; Expected = 'Integer 123456789012345678', 'Integer 123456789012345678', 'Integer 123456789012345678', 'NA', 'Float 1.2345678901234568E+17', 'Integer 123456789012345678' }
            @{ Text = '0x8000000000000000'; Expected = 'Integer 9223372036854775808', 'Integer 9223372036854775808', 'String', 'NA', 'String', 'Integer 9223372036854775808' }
            @{ Text = '+-1'; Expected = 'String', 'String', 'String', 'String', 'Integer -1', 'String' }
            @{ Text = '+-9223372036854775809'; Expected = 'String', 'String', 'String', 'String', 'String', 'String' }
            @{ Text = '0x-1'; Expected = 'String', 'String', 'String', 'String', 'Integer -1', 'String' }
            @{ Text = '0o+10'; Expected = 'String', 'String', 'String', 'String', 'Integer 8', 'String' }
            @{ Text = '-0.0'; Expected = 'Float -0', 'Float -0', 'Integer 0', 'Float -0', 'Float -0', 'Float -0' }
            @{ Text = '-0_.0'; Expected = 'Float -0', 'String', 'String', 'String', 'String', 'Float -0' }
            @{ Text = '1:20'; Expected = 'Integer 80', 'String', 'String', 'String', 'String', 'String' }
            @{ Text = '2026-11-02'; Expected = 'Timestamp', 'String', 'String', 'String', 'String', 'Timestamp' }
            @{ Text = '0b_'; Expected = 'Integer without digits', 'String', 'String', 'String', 'String', 'Integer without digits' }
            @{ Text = '1.5_0'; Expected = 'String', 'String', 'String', 'String', 'String', 'Float 1.5' }
            @{ Text = '-0o17'; Expected = 'String', 'String', 'String', 'String', 'String', 'Integer -15' }
            @{ Text = '.5e5'; Expected = 'String', 'Float 50000', 'Integer 50000', 'String', 'Float 50000', 'String' }
            @{ Text = '._'; Expected = 'String', 'String', 'String', 'String', 'String', 'Float without a value' }
            @{ Text = '1.0e-310'; Expected = 'Float 1E-310', 'Float 1E-310', 'Float 0', 'Float 1E-310 or NA', 'Float 1E-310', 'Float 1E-310' }
            @{ Text = '1.5'; Expected = 'Float 1.5', 'Float 1.5', 'Float 1.5', 'Float 1.5', 'Float 1.5', 'Float 1.5' }
            @{ Text = 'the text'; Expected = 'String', 'String', 'String', 'String', 'String', 'String' }
        ) {
            Get-Reading -Text $Text | Should -Be $Expected
        }

        It 'reads a key as text under powershell-yaml, which keeps keys as text' {
            (Get-Reading -Text 'true' -Key)[2] | Should -Be 'String'
        }

        It 'reads the key = as a string under ruamel.yaml, and the value = as a value key' {
            Get-NeoIPCYamlScalarReading -Text '=' -Reader 'ruamel.yaml' -Key | Should -Be 'String'
            Get-NeoIPCYamlScalarReading -Text '=' -Reader 'ruamel.yaml' | Should -Be 'Value'
        }

        It 'reads an integer of any length under <Reader> without overflowing' -ForEach @(
            @{ Reader = 'YAML 1.1'; Text = '0b' + ('1' * 70); Expected = 'Integer ' + ([System.Numerics.BigInteger]::Pow(2, 70) - 1) }
            @{ Reader = 'YAML 1.1'; Text = '0' + ('7' * 30); Expected = 'Integer ' + ([System.Numerics.BigInteger]::Pow(8, 30) - 1) }
            @{ Reader = 'YAML 1.2.2'; Text = '0o' + ('7' * 30); Expected = 'Integer ' + ([System.Numerics.BigInteger]::Pow(8, 30) - 1) }
            @{ Reader = 'ruamel.yaml'; Text = '0b' + ('1' * 70); Expected = 'Integer ' + ([System.Numerics.BigInteger]::Pow(2, 70) - 1) }
        ) {
            Get-NeoIPCYamlScalarReading -Text $Text -Reader $Reader | Should -Be $Expected
        }

        It 'names a number whose exponent would hold TryParse for seconds instead of reading it under powershell-yaml' {
            $elapsed = Measure-Command { $script:Reading = Get-NeoIPCYamlScalarReading -Text '1e999999999' -Reader 'powershell-yaml' }
            $script:Reading | Should -Be 'Number too large to read'
            $elapsed.TotalSeconds | Should -BeLessThan 1
            Get-NeoIPCYamlScalarReading -Text '1e1000000' -Reader 'powershell-yaml' | Should -BeLike 'Integer 1000000*'
            # From an exponent of 1,000,000,000 on, TryParse refuses at once, and powershell-yaml reads Infinity.
            $elapsed = Measure-Command { $script:Reading = Get-NeoIPCYamlScalarReading -Text '1e1000000000' -Reader 'powershell-yaml' }
            $script:Reading | Should -Be 'Float Infinity'
            $elapsed.TotalSeconds | Should -BeLessThan 1
            Get-NeoIPCYamlScalarReading -Text '1e2147483648' -Reader 'powershell-yaml' | Should -Be 'Float Infinity'
        }
    }

    Describe 'The readings and their readers' {
        It 'models powershell-yaml as powershell-yaml reads' {
            $read = [System.IO.File]::ReadAllText($script:ScalarFile) | ConvertFrom-Yaml
            $invariant = [System.Globalization.CultureInfo]::InvariantCulture
            $differences = for ($i = 0; $i -lt $script:Scalars.Count; $i++) {
                $value = $read["k$i"]
                $actual = if ($null -eq $value) { 'Null' }
                elseif ($value -is [bool]) { "Boolean $($value.ToString().ToLowerInvariant())" }
                elseif ($value -is [int] -or $value -is [long] -or $value -is [System.Numerics.BigInteger]) { "Integer $($value.ToString($invariant))" }
                elseif ($value -is [decimal]) { Format-NeoIPCYamlFloatReading -Value ([double]::Parse($value.ToString($invariant), $invariant)) }
                elseif ($value -is [double]) { Format-NeoIPCYamlFloatReading -Value $value }
                elseif ($value -is [string]) { 'String' }
                else { "a $($value.GetType().Name)" }
                $modelled = Get-NeoIPCYamlScalarReading -Text $script:Scalars[$i] -Reader 'powershell-yaml'
                if ($modelled -cne $actual) { "'$($script:Scalars[$i])': modelled $modelled, read $actual" }
            }
            @($differences) | Should -BeNullOrEmpty -Because (@($differences) -join "`n")
        }

        It "models R's yaml as R's yaml reads" {
            $differences = Compare-RReading -Reader "R's yaml" -Read 'suppressWarnings(yaml::read_yaml(args[[1]]))'
            @($differences) | Should -BeNullOrEmpty -Because (@($differences) -join "`n")
        }

        # build-metadata, which runs the whole directory, leaves these two tests out by their tags: yaml12 is built from
        # source, and ruamel.yaml is pinned to the version modelled, which the yaml-reader-agreement job does, and that
        # job runs them.
        It 'models yaml12 as yaml12 reads' -Tag 'yaml12' {
            $differences = Compare-RReading -Reader 'yaml12' -Read 'yaml12::read_yaml(args[[1]], simplify = FALSE)'
            @($differences) | Should -BeNullOrEmpty -Because (@($differences) -join "`n")
        }

        It 'models ruamel.yaml as ruamel.yaml reads' -Tag 'ruamel' {
            $differences = Compare-RuamelReading
            @($differences) | Should -BeNullOrEmpty -Because (@($differences) -join "`n")
        }
    }

    Describe 'Get-NeoIPCYamlPortabilityFinding' {
        It 'reports <_>, which the readings read apart' -ForEach @(
            'yes', 'Off', 'Y', 'n', 'NO', '012', '08', '1e5', '1.5e+3', '1:20', '1_000', '0o17', '0b101', '2026-11-02',
            '2026-11-02T10:00:00Z', '<<', '=', '0x1A', '10.0', 'NaN', 'Infinity', 'tRuE', 'nULL', '.inf', '1,000', '.na',
            '3000000000', '-2147483648', '+-1', '1.5_0', '-0o17', '+0o17', '0o1_7', '._5', '.5e5', '0x8000000000000000',
            '123456789012345678', '1.0e-310', '1e999999999', '0x-1', '0o+10', '-0.0'
        ) {
            Get-Rule -Text "key: $_`n" | Should -Be @('yaml-portability')
        }

        It 'names the readings that read a scalar apart' {
            (Get-NeoIPCYamlPortabilityFinding -Text "key: yes`n").Message |
                Should -BeExactly "The plain scalar 'yes' reads as the Boolean true under YAML 1.1 and R's yaml, but as a string under YAML 1.2.2, powershell-yaml, yaml12, and ruamel.yaml; quote it."
        }

        It 'accepts <_>, which every reading reads alike' -ForEach @(
            'true', 'False', '12', '0', '-7', '+5', '2147483647', '1.5', '.5', '-.5', '0.1', 'null', '~', 'the text',
            "'yes'", '"012"', "'0x1A'", '+-9223372036854775809'
        ) {
            @(Get-NeoIPCYamlPortabilityFinding -Text "key: $_`n") | Should -BeNullOrEmpty
        }

        It 'reports a plain key that a reading takes for anything but a string: <_>' -ForEach @('true', '1', '~', 'null', 'yes', '1.5') {
            Get-Rule -Text "${_}: value`n" | Should -Be @('yaml-portability')
        }

        It 'reports a scalar in a flow collection and at depth: <Name>' -ForEach @(
            @{ Name = 'a flow sequence'; Text = "key: [a, yes]`n" }
            @{ Name = 'a key of a flow mapping'; Text = "key: {on: 1}`n" }
            @{ Name = 'a nested mapping'; Text = "a:`n  b:`n    c:`n      d: Off`n" }
            @{ Name = 'nested sequences'; Text = "- - - 012`n" }
        ) {
            Get-Rule -Text $Text | Should -Be @('yaml-portability')
        }

        It 'reads a multi-line plain scalar as its folded value' {
            # Folded, the two lines are 2026-11-02 10:00:00, a timestamp under YAML 1.1 alone.
            Get-Rule -Text "key: 2026-11-02`n  10:00:00`n" | Should -Be @('yaml-portability')
            @(Get-NeoIPCYamlPortabilityFinding -Text "key: first`n  yes`n") | Should -BeNullOrEmpty
        }

        It 'leaves a block scalar of several lines, comments, and quoted scalars alone' {
            @(Get-NeoIPCYamlPortabilityFinding -Text "key: |`n  yes`n  012`n# yes`nother: 'Off'`nlast: '0x1A'`n") | Should -BeNullOrEmpty
        }

        It "reports a block scalar that R's yaml types: <Name>" -ForEach @(
            @{ Name = 'stripped'; Text = "a: |-`n  yes`nb: x`n" }
            @{ Name = 'folded and stripped'; Text = "a: >-`n  0x1A`nb: x`n" }
            @{ Name = 'empty'; Text = "a: |-`nb: x`n" }
            @{ Name = 'stripped, at the end of the text'; Text = "a: |-`n  yes`n" }
        ) {
            Get-Rule -Text $Text | Should -Be @('yaml-portability')
        }

        It 'names the reading of a block scalar that R''s yaml types' {
            (Get-NeoIPCYamlPortabilityFinding -Text "a: |-`n  yes`nb: x`n").Message |
                Should -BeExactly "The block scalar 'yes' reads as the Boolean true under R's yaml, which types a block scalar as it types a plain one, but as a string under YAML 1.1, YAML 1.2.2, powershell-yaml, yaml12, and ruamel.yaml; quote it."
        }

        It "reports a clipped block scalar at the end of the text twice where R's yaml, reading it without its final line break, types it: <Name>" -ForEach @(
            @{ Name = 'its content on the last line'; Text = "a: |`n  012`n"; Seen = "'012'" }
            @{ Name = 'in a text without a final line break'; Text = "a: |`n  yes"; Seen = "'yes'" }
        ) {
            $messages = @(Get-NeoIPCYamlPortabilityFinding -Text $Text | ForEach-Object { $_.Message })
            $messages.Count | Should -Be 2
            $messages[0] | Should -BeLike 'The block scalar runs to the end of the text and clips its final line break*'
            $messages[1] | Should -BeLike "The block scalar $Seen reads as * under R's yaml*"
        }

        It 'reports a block scalar at the end of the text that clips or keeps its final line break: <Name>' -ForEach @(
            @{ Name = 'literal'; Text = "a: |`n  x`n" }
            @{ Name = 'folded'; Text = "a: >`n  x`n  y`n" }
            @{ Name = 'kept'; Text = "a: |+`n  x`n" }
            @{ Name = 'kept, with a blank line'; Text = "a: |+`n  x`n`n" }
            @{ Name = 'nested'; Text = "a:`n  b: |`n    x`n" }
            @{ Name = 'in a sequence'; Text = "- |`n  x`n     `n" }
            @{ Name = 'clipped, in a text without a final line break'; Text = "a: |`n  x" }
            @{ Name = 'clipped, before a last line of spaces without a line break'; Text = "a: |`n  x`n  " }
            @{ Name = 'clipped, before a last line of spaces deeper than its content'; Text = "a: |`n  x`n     `n" }
            @{ Name = 'clipped, before a last line of spaces and a tab'; Text = "a: |`n  x`n  `t`n" }
            @{ Name = 'clipped, with an indentation indicator'; Text = "a: |2`n  x`n   `n" }
            @{ Name = 'clipped, with carriage returns for line breaks'; Text = "a: |`r  x`r     `r" }
            @{ Name = 'clipped, before a blank line'; Text = "a: |`n  x`n`n" }
            @{ Name = 'clipped, before a line of spaces no deeper than its content'; Text = "a: |`n  x`n  `n" }
            @{ Name = 'kept, in a text without a final line break'; Text = "a: |+`n  x" }
        ) {
            Get-Rule -Text $Text | Should -Be @('yaml-portability')
        }

        It 'accepts a block scalar that strips its final line break, or does not end the text: <Name>' -ForEach @(
            @{ Name = 'stripped'; Text = "a: |-`n  x`n" }
            @{ Name = 'stripped, in a text without a final line break'; Text = "a: |-`n  x" }
            @{ Name = 'stripped, before a last line of spaces deeper than its content'; Text = "a: |-`n  x`n     `n" }
            @{ Name = 'folded and stripped, before a last line of spaces'; Text = "a: >-`n  x`n   " }
            @{ Name = 'a key after it'; Text = "a: |`n  x`nb: 1`n" }
            @{ Name = 'a comment after it'; Text = "a: |`n  x`n# note`n" }
        ) {
            @(Get-NeoIPCYamlPortabilityFinding -Text $Text) | Should -BeNullOrEmpty
        }

        It 'with StringsOnly, reports a plain scalar that every reading reads as a number' {
            Get-Rule -Text "a: 12`n" -StringsOnly | Should -Be @('yaml-portability')
            Get-Rule -Text "a: 12`n" | Should -BeNullOrEmpty
            Get-Rule -Text "a: text`n" -StringsOnly | Should -BeNullOrEmpty
        }

        It 'reports <Rule> for <Defect>' -ForEach @(
            @{ Defect = 'a key repeated in one mapping'; Rule = 'yaml-duplicate-key'; Text = "name: a`nname: b`n" }
            @{ Defect = 'a key repeated in another letter case'; Rule = 'yaml-case-variant-key'; Text = "name: a`nName: b`n" }
            @{ Defect = 'a key repeated in a flow mapping'; Rule = 'yaml-duplicate-key'; Text = "a: {b: 1, b: 2}`n" }
            @{ Defect = 'an anchor'; Rule = 'yaml-anchor'; Text = "a: &one 1`n" }
            @{ Defect = 'an alias'; Rule = 'yaml-alias'; Text = "a: *one`n" }
            @{ Defect = 'a tag of the core schema'; Rule = 'yaml-tag'; Text = "a: !!str yes`n" }
            @{ Defect = 'a local tag'; Rule = 'yaml-tag'; Text = "a: !local yes`n" }
            @{ Defect = 'the non-specific tag'; Rule = 'yaml-tag'; Text = "a: ! yes`n" }
            @{ Defect = 'a %YAML directive'; Rule = 'yaml-directive'; Text = "%YAML 1.2`n---`na: 1`n" }
            @{ Defect = 'a %TAG directive'; Rule = 'yaml-directive'; Text = "%TAG !e! tag:example.com,2000:`n---`na: 1`n" }
            @{ Defect = 'a %TAG directive restating the default handle'; Rule = 'yaml-directive'; Text = "%TAG ! !`n---`na: 1`n" }
            @{ Defect = 'a directive of another name'; Rule = 'yaml-directive'; Text = "%FOO bar`n---`na: 1`n" }
            @{ Defect = 'a directive of another name before an implicit document'; Rule = 'yaml-directive'; Text = "%FOO bar`na: 1`n" }
            @{ Defect = "a directive of another name after a document's content"; Rule = 'yaml-directive'; Text = "a: 1`n%FOO`n" }
            @{ Defect = 'a second document'; Rule = 'yaml-documents'; Text = "a: 1`n---`nb: 2`n" }
            @{ Defect = 'a sequence as a key'; Rule = 'yaml-complex-key'; Text = "? [a, b]`n: c`n" }
            @{ Defect = 'a mapping as a key'; Rule = 'yaml-complex-key'; Text = "? {a: 1}`n: c`n" }
        ) {
            Get-Rule -Text $Text | Should -Be @($Rule)
        }

        It 'names a tag as the text spells it' {
            (Get-NeoIPCYamlPortabilityFinding -Text "a: !!str yes`n").Message | Should -BeLike '*explicit tag !!str,*'
        }

        It 'advises quoting only a tagged scalar' {
            (Get-NeoIPCYamlPortabilityFinding -Text "a: !!str yes`n").Message | Should -BeLike '*quote the scalar if it should be a string.'
            (Get-NeoIPCYamlPortabilityFinding -Text "a: !!map {b: c}`n").Message | Should -BeLike '*has none: leave it out.'
        }

        It 'counts lines across every kind of line break when it names a directive''s' {
            (Get-NeoIPCYamlPortabilityFinding -Text "a: 1`r%FOO`r").Location | Should -Be 'line 2'
        }

        It 'reads a text that starts with a byte order mark as its readers do, who skip the mark' {
            Get-Rule -Text "$([char]0xFEFF)%YAML 1.2`n---`na: 1`n" | Should -Be @('yaml-directive')
            Get-Rule -Text "$([char]0xFEFF)a: yes`n" | Should -Be @('yaml-portability')
        }

        It 'shows a long value in part, with its length' {
            $message = (Get-NeoIPCYamlPortabilityFinding -Text "a: $('1' * 5000)`n").Message
            $message.Length | Should -BeLessThan 1000
            $message | Should -BeLike "*'$('1' * 57)...' (5000 characters)*"
        }

        It 'checks keys per mapping, so one key in two mappings is no repeat' {
            @(Get-NeoIPCYamlPortabilityFinding -Text "a:`n  name: one`nb:`n  name: two`nc:`n- name: three`n- name: four`n") | Should -BeNullOrEmpty
        }

        It 'reports text that is not YAML instead of throwing' {
            Get-Rule -Text "key: [`n" | Should -Be @('yaml-syntax')
        }

        It 'reports text that is not YAML instead of hanging, where the scanner repeats an error without moving on' {
            # In a child process with a time limit, so that a hang fails the test instead of stalling the run.
            $script = Join-Path $TestDrive 'malformed.ps1'
            $module = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
            $code = @'
Import-Module 'MODULE'
foreach ($text in "label: Note: see below`n", "a: b: c`n", "a`nb: c`n", "key: [a, b]: c`n", "a: 'b': c`n") {
    (& (Get-Module NeoIPC-Tools) { param($t) @(Get-NeoIPCYamlPortabilityFinding -Text $t) } $text).Rule -join ','
}
'@
            [System.IO.File]::WriteAllText($script, $code.Replace('MODULE', $module), [System.Text.UTF8Encoding]::new($false))
            $start = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
            foreach ($item in '-NoProfile', '-NonInteractive', '-File', $script) { $start.ArgumentList.Add($item) }
            $start.RedirectStandardOutput = $true
            $process = [System.Diagnostics.Process]::Start($start)
            try {
                $output = $process.StandardOutput.ReadToEndAsync()
                $finished = $process.WaitForExit(120000)
                if (-not $finished) { $process.Kill($true) }
                $finished | Should -BeTrue -Because 'the check must return on malformed YAML'
                @($output.Result.Split("`n", [System.StringSplitOptions]::RemoveEmptyEntries).Trim()) | Should -Be @('yaml-syntax', 'yaml-syntax', 'yaml-syntax', 'yaml-syntax', 'yaml-syntax')
            }
            finally { $process.Dispose() }
        }

        It 'reports an integer too long for 64 bits, or one without digits, instead of throwing: <_>' -ForEach @(
            ('0b' + ('1' * 70)), ('0' + ('7' * 30)), ('0o' + ('7' * 30)), '0b_', '0x_'
        ) {
            Get-Rule -Text "key: $_`n" | Should -Be @('yaml-portability')
        }

        It 'reports powershell-yaml missing instead of throwing' {
            # A child process whose module path lacks powershell-yaml, as a machine without it has.
            $empty = Join-Path $TestDrive 'no-modules'
            $null = New-Item -ItemType Directory -Path $empty -Force
            $module = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
            $command = "`$env:PSModulePath = '$empty' + [System.IO.Path]::PathSeparator + (Join-Path `$PSHOME 'Modules'); " +
                "Import-Module '$module'; & (Get-Module NeoIPC-Tools) { (Get-NeoIPCYamlPortabilityFinding -Text 'a: 1').Rule }"
            $rules = @(& (Join-Path $PSHOME 'pwsh') -NoProfile -NonInteractive -Command $command)
            $LASTEXITCODE | Should -Be 0
            $rules | Should -Be @('yaml-reader')
        }
    }

    Describe "The toolkit's YAML files" {
        It 'keeps every committed YAML file to the portable subset' {
            $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
            # NUL-separated and decoded as UTF-8, so that a path outside ASCII arrives whatever the console's code page.
            $listing = Invoke-NeoIPCGitText -RepositoryRoot $root -Argument '-c', 'core.quotePath=false', 'ls-files', '-z', '--', '*.yaml', '*.yml'
            $files = @($listing.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
            $files | Should -Contain 'reports/common.yaml' -Because 'the reports read their common strings with a YAML 1.1 reader'
            $files | Should -Contain 'metadata/common/infectious-agents/NeoIPC-Infectious-Agents.yaml'
            $files | Should -Contain 'metadata/common/infectious-agents/NeoIPC-Infectious-Agent-Reporting-Groups.yaml'
            $findings = foreach ($file in $files) {
                foreach ($f in @(Get-NeoIPCYamlPortabilityFinding -Text ([System.IO.File]::ReadAllText((Join-Path $root $file))))) {
                    "${file} $($f.Location): $($f.Message)"
                }
            }
            @($findings) | Should -BeNullOrEmpty -Because (@($findings) -join "`n")
        }
    }
}
