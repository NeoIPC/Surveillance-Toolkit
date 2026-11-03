#Requires -Version 7.6

# The toolkit's YAML is YAML 1.2.2 in its portable subset, the form that the YAML versions and readers the toolkit meets
# read alike:
#   1. every plain scalar has one type and one value under each of the six readings below, and every plain key reads
#      as a string under each;
#   2. every block scalar reads as a string under R's yaml, which types it as it types a plain one, and none that runs
#      to the end of the text clips or keeps its final line break, which readers gain or lose there (below);
#   3. there are no anchors, aliases, tags, directives, second documents, keys that are collections, or keys repeated,
#      in the same or another letter case.
# YamlPortability.Tests.ps1 holds every committed YAML file to it, and the toolkit's own YAML writers emit it:
# Export-NeoIPCSharingProfile checks its output here, and update-glossary-po.py quotes every string it writes. The
# readings model their readers, so scripts/Test-YamlReaderAgreement.ps1 also runs the readers themselves over every
# committed file.
#
# The six readings of a plain scalar's text, which YamlDotNet's event parser hands over with its style:
#   1. YAML 1.1's type repository (bool, null, int, float, timestamp, merge, and value), in the specification's
#      patterns, except that a timestamp's numeric zone may follow whitespace, as PyYAML and ruamel.yaml read it.
#   2. YAML 1.2.2's core schema (section 10.3.2).
#   3. powershell-yaml 0.4.12 (its Convert-ValueToProperType), the toolkit's own reader: .NET's TryParse in the
#      invariant culture tries a Boolean in any letter case, then an integer, which takes 10.0 and 1e5 too, then a
#      decimal and a double, which takes NaN and Infinity; null follows in any letter case, skipping the characters
#      the invariant culture's comparison ignores, and a mapping key stays text.
#   4. R's yaml package 2.3 (src/implicit.re and src/r_parse.c), with which the reports read their string resources:
#      YAML 1.1's patterns with commas allowed among digits, .na and its typed forms, and integers of 32 bits. It keeps
#      sexagesimal numbers, binary integers, underscored digits, and timestamps as strings, and reads NA for an integer
#      beyond 32 bits, for digits it cannot convert, such as 1,000, and for a float that strtod reports out of range:
#      one beyond a double's range or one that underflows to zero, and a subnormal one where the C library reports its
#      underflow, as glibc's does and Windows' does not. It types a block scalar as it types a plain one.
#   5. The R package yaml12 0.2.0, the reference reader of scripts/Test-YamlReaderAgreement.ps1: YAML 1.2.2's core
#      schema, except that a sign may follow 0x, 0o, or a leading plus sign (0x-1 and +-1 are the integer -1), such a
#      form beyond a signed 64-bit integer reading as a string, and that an R integer has 32 bits, so -2147483648, R's
#      integer NA, reads as NA, and a larger integer as the double nearest it.
#   6. ruamel.yaml 0.19 (resolver.py and constructor.py), with which the toolkit's Python scripts read YAML: its
#      default YAML 1.2 resolver tries the patterns listed for a scalar's first character, and its safe and round-trip
#      constructors make the same value of each, but for the merge and value scalars << and =, which safe mode cannot
#      construct and round-trip mode keeps as tagged scalars. It widens YAML 1.2.2's core schema to underscores among digits,
#      binary integers, signs before 0o and 0x, timestamps, and YAML 1.1's merge and value keys, and narrows it where a
#      float that starts with its point has an exponent without a sign, as .5e5 has, which it reads as a string. It
#      cannot construct an integer prefix without digits, such as 0b_, or a decimal integer of more than 4,300 digits,
#      Python's limit, and it reads the key = as a string.
#
# A block scalar that runs to the end of the text, followed by nothing but whitespace, gains or loses a final line
# break by reader unless it strips its trailing line breaks (|- or >-): R's yaml reads a file's lines joined without
# the last line break, which the block loses where the text's last line belongs to it; powershell-yaml's
# ConvertFrom-Yaml reads the text with a line break added, which a block that keeps its trailing line breaks (|+ or
# >+), or whose content reaches the unterminated last line, takes as one more; and yaml12 ends such a value with a line
# break where the text ends without one, which YamlDotNet itself, libyaml under R's yaml, and ruamel.yaml do not. Whether
# the text's last line belongs to a block that clips them (| or >) turns on its spaces against the block's content
# indentation, so the portable subset ends a text with no block scalar but one that strips them, which every reader
# reads alike.
$script:NeoIPCYaml11Resolution = [ordered]@{
    Boolean   = '\A(?:y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)\z'
    Null      = '\A(?:~|null|Null|NULL|)\z'
    Integer   = '\A[-+]?(?:0b[0-1_]+|0[0-7_]+|(?:0|[1-9][0-9_]*)|0x[0-9a-fA-F_]+|[1-9][0-9_]*(?::[0-5]?[0-9])+)\z'
    Float     = '\A(?:[-+]?(?:[0-9][0-9_]*)?\.[0-9.]*(?:[eE][-+][0-9]+)?|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z'
    Timestamp = '\A(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9]{1,2}(?::[0-9]{2})?))?)\z'
    Merge     = '\A<<\z'
    Value     = '\A=\z'
}
$script:NeoIPCYaml12Resolution = [ordered]@{
    Null    = '\A(?:null|Null|NULL|~|)\z'
    Boolean = '\A(?:true|True|TRUE|false|False|FALSE)\z'
    Integer = '\A(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)\z'
    Float   = '\A(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z'
}
# R's yaml package's implicit tags (src/implicit.re) for the forms it reads as other than a string, in its order: the
# first pattern that matches the whole text decides. Its sexagesimal, timestamp, and value forms it leaves strings.
$script:NeoIPCRYamlResolution = [ordered]@{
    Null        = '\A(?:~|null|Null|NULL)?\z'
    BoolYes     = '\A(?:y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON)\z'
    BoolNo      = '\A(?:n|N|no|No|NO|false|False|FALSE|off|Off|OFF)\z'
    BoolNA      = '\A\.na\z'
    IntHex      = '\A[-+]?0x[0-9a-fA-F,]+\z'
    IntOct      = '\A[-+]?0[0-7,]+\z'
    IntNA       = '\A\.na\.integer\z'
    IntCanon    = '\A[-+]?(?:0|[1-9][0-9,]*)\z'
    FloatFix    = '\A[-+]?(?:[0-9][0-9,]*)?\.[0-9,]*\z'
    FloatExp    = '\A[-+]?(?:[0-9][0-9,]*)?\.[0-9.]*[eE][-+][0-9]+\z'
    FloatInf    = '\A\+?\.(?:inf|Inf|INF)\z'
    FloatNegInf = '\A-\.(?:inf|Inf|INF)\z'
    FloatNaN    = '\A\.(?:nan|NaN|NAN)\z'
    FloatNA     = '\A\.na\.real\z'
    StrNA       = '\A\.na\.character\z'
    Merge       = '\A<<\z'
}
# ruamel.yaml's YAML 1.2 implicit resolvers (resolver.py), in its order, each tried only for a scalar whose first
# character is among its First: the first that matches the whole text decides, and an empty text is null.
$script:NeoIPCRuamelYamlResolution = @(
    @{ Reading = 'Boolean'; First = 'tTfF'; Pattern = '\A(?:true|True|TRUE|false|False|FALSE)\z' }
    @{ Reading = 'Float'; First = '-+0123456789.'; Pattern = '\A(?:[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+]?[0-9]+)?|[-+]?[0-9][0-9_]*[eE][-+]?[0-9]+|[-+]?\.[0-9_]+(?:[eE][-+][0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z' }
    @{ Reading = 'Integer'; First = '-+0123456789'; Pattern = '\A(?:[-+]?0b[0-1_]+|[-+]?0o?[0-7_]+|[-+]?[0-9_]+|[-+]?0x[0-9a-fA-F_]+)\z' }
    @{ Reading = 'Merge'; First = '<'; Pattern = '\A<<\z' }
    @{ Reading = 'Null'; First = '~nN'; Pattern = '\A(?:~|null|Null|NULL)\z' }
    @{ Reading = 'Timestamp'; First = '0123456789'; Pattern = $script:NeoIPCYaml11Resolution.Timestamp }
    @{ Reading = 'Value'; First = '='; Pattern = '\A=\z' }
)
$script:NeoIPCYamlReaders = @('YAML 1.1', 'YAML 1.2.2', 'powershell-yaml', "R's yaml", 'yaml12', 'ruamel.yaml')


function Format-NeoIPCYamlFloatReading {
    # A float reading: the value in .NET's round-trip form, so that equal values read alike whatever their spelling
    # (1.50 and 1.5), or Infinity, -Infinity, or NaN.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][double]$Value)
    if ([double]::IsNaN($Value)) { 'Float NaN' }
    elseif ([double]::IsPositiveInfinity($Value)) { 'Float Infinity' }
    elseif ([double]::IsNegativeInfinity($Value)) { 'Float -Infinity' }
    else { 'Float ' + $Value.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) }
}


function Get-NeoIPCYamlDigitValue {
    # The value of a run of digits in a base, accumulated as a BigInteger, so that no length overflows; $null for an
    # empty run, such as the digits of 0b_ once its underscores are dropped. The caller has matched the digits.
    [CmdletBinding()]
    [OutputType([System.Numerics.BigInteger])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Digits, [Parameter(Mandatory)][ValidateSet(2, 8, 10, 16)][int]$Base)
    if ($Digits.Length -eq 0) { return $null }
    $value = [System.Numerics.BigInteger]::Zero
    foreach ($digit in $Digits.ToCharArray()) { $value = $value * $Base + [System.Convert]::ToInt32([string]$digit, 16) }
    $value
}


function Get-NeoIPCYamlSpec11ScalarReading {
    # Reading 1: YAML 1.1's type repository.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $table = $script:NeoIPCYaml11Resolution
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Text -cmatch $table.Boolean) {
        return "Boolean $(if ($Text -cmatch '\A(?:y|Y|yes|Yes|YES|true|True|TRUE|on|On|ON)\z') { 'true' } else { 'false' })"
    }
    if ($Text -cmatch $table.Null) { return 'Null' }
    if ($Text -cmatch $table.Integer) {
        $digits = $Text.Replace('_', '')
        $negative = $digits.StartsWith('-')
        $digits = $digits.TrimStart('+', '-')
        $value = if ($digits.Contains(':')) {
            $total = [System.Numerics.BigInteger]::Zero
            foreach ($part in $digits.Split(':')) { $total = $total * 60 + (Get-NeoIPCYamlDigitValue -Digits $part -Base 10) }
            $total
        }
        elseif ($digits.StartsWith('0x')) { Get-NeoIPCYamlDigitValue -Digits $digits.Substring(2) -Base 16 }
        elseif ($digits.StartsWith('0b')) { Get-NeoIPCYamlDigitValue -Digits $digits.Substring(2) -Base 2 }
        elseif ($digits.Length -gt 1 -and $digits.StartsWith('0')) { Get-NeoIPCYamlDigitValue -Digits $digits.Substring(1) -Base 8 }
        else { Get-NeoIPCYamlDigitValue -Digits $digits -Base 10 }
        if ($null -eq $value) { return 'Integer without digits' }
        if ($negative) { $value = -$value }
        return "Integer $($value.ToString($invariant))"
    }
    if ($Text -cmatch $table.Float) {
        if ($Text -cmatch '\A[-+]?\.(?:inf|Inf|INF)\z') {
            return Format-NeoIPCYamlFloatReading -Value $(if ($Text.StartsWith('-')) { [double]::NegativeInfinity } else { [double]::PositiveInfinity })
        }
        if ($Text -cmatch '\A\.(?:nan|NaN|NAN)\z') { return 'Float NaN' }
        $digits = $Text.Replace('_', '')
        $value = [double]0
        if ($digits.Contains(':')) {
            # A sexagesimal float: base-60 places, the last of which carries the fraction.
            $negative = $digits.StartsWith('-')
            foreach ($part in $digits.TrimStart('+', '-').Split(':')) { $value = $value * 60 + [double]::Parse($part, $invariant) }
            # Multiplied rather than negated, which would make +0 of a zero.
            if ($negative) { $value = -1.0 * $value }
            return Format-NeoIPCYamlFloatReading -Value $value
        }
        # The pattern takes more than one point, and a point alone, which name no number.
        if ([double]::TryParse($digits, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$value)) {
            return Format-NeoIPCYamlFloatReading -Value $value
        }
        return 'Float without a value'
    }
    if ($Text -cmatch $table.Timestamp) { return 'Timestamp' }
    if ($Text -cmatch $table.Merge) { return 'Merge' }
    if ($Text -cmatch $table.Value) { return 'Value' }
    'String'
}


function Get-NeoIPCYamlSpec122ScalarReading {
    # Reading 2: YAML 1.2.2's core schema.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $table = $script:NeoIPCYaml12Resolution
    if ($Text -cmatch $table.Null) { return 'Null' }
    if ($Text -cmatch $table.Boolean) { return "Boolean $($Text.ToLowerInvariant())" }
    if ($Text -cmatch $table.Integer) {
        if ($Text.StartsWith('0o')) { $value = Get-NeoIPCYamlDigitValue -Digits $Text.Substring(2) -Base 8 }
        elseif ($Text.StartsWith('0x')) { $value = Get-NeoIPCYamlDigitValue -Digits $Text.Substring(2) -Base 16 }
        else {
            $value = Get-NeoIPCYamlDigitValue -Digits $Text.TrimStart('+', '-') -Base 10
            if ($Text.StartsWith('-')) { $value = -$value }
        }
        return "Integer $($value.ToString([System.Globalization.CultureInfo]::InvariantCulture))"
    }
    if ($Text -cmatch $table.Float) {
        if ($Text -cmatch '\A[-+]?\.(?:inf|Inf|INF)\z') {
            return Format-NeoIPCYamlFloatReading -Value $(if ($Text.StartsWith('-')) { [double]::NegativeInfinity } else { [double]::PositiveInfinity })
        }
        if ($Text -cmatch '\A\.(?:nan|NaN|NAN)\z') { return 'Float NaN' }
        return Format-NeoIPCYamlFloatReading -Value ([double]::Parse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    'String'
}


function Get-NeoIPCPowerShellYamlScalarReading {
    # Reading 3: powershell-yaml 0.4.12's typing of a plain, untagged scalar (Convert-ValueToProperType), in its order,
    # with the TryParse calls it makes. A mapping key it keeps as text.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Key)
    if ($Key) { return 'String' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $float = [System.Globalization.NumberStyles]::Float
    $boolean = $false
    if ([bool]::TryParse($Text, [ref]$boolean)) { return "Boolean $(if ($boolean) { 'true' } else { 'false' })" }
    # BigInteger's TryParse builds the power of ten an exponent names, which takes a tenth of a second at a million,
    # seconds at ten million, and longer than any check can wait beyond, up to 999,999,999; an exponent of
    # 1,000,000,000 or more it refuses at once, as measured on .NET 10, and powershell-yaml then reads Infinity. A
    # number in that range is named here instead of read, which no other reading reads it as.
    if ($Text -cmatch '\A[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)[eE]\+?(?<exponent>[0-9]+)\z') {
        $exponent = [System.Numerics.BigInteger]::Parse($Matches.exponent, $invariant)
        if ($exponent -gt 1000000 -and $exponent -lt 1000000000) { return 'Number too large to read' }
    }
    $integer = [System.Numerics.BigInteger]::Zero
    if ([System.Numerics.BigInteger]::TryParse($Text, $float, $invariant, [ref]$integer)) { return "Integer $($integer.ToString($invariant))" }
    $number = [decimal]0
    if ([decimal]::TryParse($Text, $float, $invariant, [ref]$number)) {
        # The decimal as the double nearest it: the same number, as far as a double, which the other readers read, can
        # tell. A decimal rounds what it cannot hold, so 1e-30 reads as 0 here.
        return Format-NeoIPCYamlFloatReading -Value ([double]::Parse($number.ToString($invariant), $float, $invariant))
    }
    $double = [double]0
    if ([double]::TryParse($Text, $float, $invariant, [ref]$double)) { return Format-NeoIPCYamlFloatReading -Value $double }
    # PowerShell's -in compares as powershell-yaml's own test does: without regard to letter case, and skipping the
    # characters the invariant culture's comparison ignores, such as a soft hyphen or a zero-width space.
    if ($Text -in '', '~', 'null', 'Null', 'NULL') { return 'Null' }
    'String'
}


function Get-NeoIPCRYamlScalarReading {
    # Reading 4: the implicit tag R's yaml package gives a plain scalar, and the value its default handler makes of it
    # (src/r_parse.c, handle_scalar).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $rule = $null
    foreach ($entry in $script:NeoIPCRYamlResolution.GetEnumerator()) {
        if ($Text -cmatch $entry.Value) { $rule = $entry.Key; break }
    }
    if ($null -eq $rule) { return 'String' }
    if ($rule -ceq 'Null') { return 'Null' }
    if ($rule -ceq 'BoolYes') { return 'Boolean true' }
    if ($rule -ceq 'BoolNo') { return 'Boolean false' }
    if ($rule -cin 'BoolNA', 'IntNA', 'FloatNA', 'StrNA') { return 'NA' }
    if ($rule -ceq 'FloatInf') { return 'Float Infinity' }
    if ($rule -ceq 'FloatNegInf') { return 'Float -Infinity' }
    if ($rule -ceq 'FloatNaN') { return 'Float NaN' }
    if ($rule -ceq 'Merge') { return 'Merge' }
    if ($rule -cin 'IntHex', 'IntOct', 'IntCanon') {
        # strtol must read the whole text, so a comma among the digits makes NA, and an R integer has 32 bits, with
        # its smallest value standing for NA.
        $body = $Text.TrimStart('+', '-')
        if ($body.Contains(',')) { return 'NA' }
        $value = if ($rule -ceq 'IntHex') { Get-NeoIPCYamlDigitValue -Digits $body.Substring(2) -Base 16 }
        elseif ($rule -ceq 'IntOct') { Get-NeoIPCYamlDigitValue -Digits $body.Substring(1) -Base 8 }
        else { Get-NeoIPCYamlDigitValue -Digits $body -Base 10 }
        if ($Text.StartsWith('-')) { $value = -$value }
        if ($value -le -2147483648 -or $value -gt 2147483647) { return 'NA' }
        return "Integer $($value.ToString([System.Globalization.CultureInfo]::InvariantCulture))"
    }
    # A float (FloatFix, FloatExp): strtod must read the whole text, which a comma, a second point, or a point without
    # digits cuts short, and it sets ERANGE for a value beyond a double's range and for one that underflows to zero;
    # each of these reads as NA. For a subnormal value, glibc's strtod sets ERANGE too, and Windows' does not, so such
    # a value reads as NA or as itself by the C library.
    if ($Text -cnotmatch '\A[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?\z') { return 'NA' }
    $value = [double]::Parse($Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture)
    if ([double]::IsInfinity($value)) { return 'NA' }
    if (($Text -split '[eE]')[0] -cmatch '[1-9]') {
        if ($value -eq 0) { return 'NA' }
        if ([Math]::Abs($value) -lt 2.2250738585072014E-308) { return "$(Format-NeoIPCYamlFloatReading -Value $value) or NA" }
    }
    Format-NeoIPCYamlFloatReading -Value $value
}


function Get-NeoIPCYaml12ScalarReading {
    # Reading 5: the yaml12 package's reading. Its parser, saphyr (Scalar::parse_from_cow), reads YAML 1.2.2's core
    # schema in 64 bits but for signs: it hands the digits after 0x or 0o to Rust's from_str_radix, and those after a
    # leading plus sign to Rust's integer parser, and each takes a sign of its own. Such a form that fits no 64 bits
    # matches none of its other forms and reads as a string, while a plain decimal integer beyond 64 bits reads as the
    # double nearest it. R's integer has 32 bits, so -2147483648, R's integer NA, reads as NA, and a larger integer as
    # the double nearest it.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $value = $null
    if ($Text -cmatch '\A0x(?<sign>[-+]?)(?<digits>[0-9a-fA-F]+)\z' -or $Text -cmatch '\A0o(?<sign>[-+]?)(?<digits>[0-7]+)\z') {
        $value = Get-NeoIPCYamlDigitValue -Digits $Matches.digits -Base $(if ($Text[1] -ceq 'x') { 16 } else { 8 })
        if ($Matches.sign -ceq '-') { $value = -$value }
    }
    elseif ($Text -cmatch '\A\+(?<sign>[-+])(?<digits>[0-9]+)\z') {
        $value = Get-NeoIPCYamlDigitValue -Digits $Matches.digits -Base 10
        if ($Matches.sign -ceq '-') { $value = -$value }
    }
    if ($null -ne $value) {
        if ($value -lt [long]::MinValue -or $value -gt [long]::MaxValue) { return 'String' }
        $reading = "Integer $($value.ToString($invariant))"
    }
    else { $reading = Get-NeoIPCYamlSpec122ScalarReading -Text $Text }
    if ($reading -cmatch '\AInteger (?<value>-?[0-9]+)\z') {
        $integer = [System.Numerics.BigInteger]::Parse($Matches.value, $invariant)
        if ($integer -eq -2147483648) { return 'NA' }
        if ($integer -lt -2147483648 -or $integer -gt 2147483647) {
            # Parsed from the digits, which rounds to the nearest double, as R does, where a cast would truncate.
            return Format-NeoIPCYamlFloatReading -Value ([double]::Parse($integer.ToString($invariant), $invariant))
        }
    }
    $reading
}


function Get-NeoIPCRuamelYamlScalarReading {
    # Reading 6: the tag ruamel.yaml 0.19's YAML 1.2 resolver gives a plain scalar, and the value its constructors make
    # of it: underscores dropped, a sign, then 0b, 0x, or 0o for the base, and decimal otherwise, leading zeros and all.
    # A key it types as a value, but for =, which it makes a string.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Key)
    if ($Text.Length -eq 0) { return 'Null' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $resolved = $null
    foreach ($resolver in $script:NeoIPCRuamelYamlResolution) {
        if ($resolver.First.Contains($Text[0]) -and $Text -cmatch $resolver.Pattern) { $resolved = $resolver.Reading; break }
    }
    if ($null -eq $resolved) { return 'String' }
    if ($resolved -ceq 'Boolean') { return "Boolean $($Text.ToLowerInvariant())" }
    if ($resolved -ceq 'Value' -and $Key) { return 'String' }
    if ($resolved -cin 'Null', 'Merge', 'Timestamp', 'Value') { return $resolved }
    $digits = $Text.Replace('_', '')
    $negative = $digits.StartsWith('-')
    $digits = $digits.TrimStart('+', '-')
    if ($resolved -ceq 'Float') {
        $digits = $digits.ToLowerInvariant()
        if ($digits -ceq '.inf') { return Format-NeoIPCYamlFloatReading -Value $(if ($negative) { [double]::NegativeInfinity } else { [double]::PositiveInfinity }) }
        if ($digits -ceq '.nan') { return 'Float NaN' }
        # Python's float() reads every form the pattern lets through but a point alone, which ._ leaves.
        $value = [double]0
        if (-not [double]::TryParse($digits, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$value)) { return 'Float without a value' }
        # Multiplied rather than negated: PowerShell's unary minus makes +0 of a zero, where Python's makes -0.
        return Format-NeoIPCYamlFloatReading -Value $(if ($negative) { -1.0 * $value } else { $value })
    }
    $base = 10
    if ($digits.StartsWith('0b')) { $base = 2; $digits = $digits.Substring(2) }
    elseif ($digits.StartsWith('0x')) { $base = 16; $digits = $digits.Substring(2) }
    elseif ($digits.StartsWith('0o')) { $base = 8; $digits = $digits.Substring(2) }
    # Python's int() refuses a decimal of more than 4,300 digits, its default limit, and leaves the other bases alone.
    elseif ($digits.Length -gt 4300) { return 'Integer too long to convert' }
    $value = Get-NeoIPCYamlDigitValue -Digits $digits -Base $base
    if ($null -eq $value) { return 'Integer without digits' }
    if ($negative) { $value = -$value }
    "Integer $($value.ToString($invariant))"
}


function Get-NeoIPCYamlScalarReading {
    # How one of the six readings (see the top of this file) reads a plain scalar: its type, and for a Boolean or a
    # number its value, as one text, so that two readings compare as text: 012 reads as "Integer 10" under YAML 1.1 and
    # as "Integer 12" under YAML 1.2.2. A key reads as "String" under powershell-yaml, which keeps keys as text.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('YAML 1.1', 'YAML 1.2.2', 'powershell-yaml', "R's yaml", 'yaml12', 'ruamel.yaml')][string]$Reader,
        [switch]$Key
    )
    switch ($Reader) {
        'YAML 1.1' { Get-NeoIPCYamlSpec11ScalarReading -Text $Text }
        'YAML 1.2.2' { Get-NeoIPCYamlSpec122ScalarReading -Text $Text }
        'powershell-yaml' { Get-NeoIPCPowerShellYamlScalarReading -Text $Text -Key:$Key }
        "R's yaml" { Get-NeoIPCRYamlScalarReading -Text $Text }
        'yaml12' { Get-NeoIPCYaml12ScalarReading -Text $Text }
        'ruamel.yaml' { Get-NeoIPCRuamelYamlScalarReading -Text $Text -Key:$Key }
    }
}


function Format-NeoIPCYamlReading {
    # A reading as a finding's message names it.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Reading)
    switch -Regex -CaseSensitive ($Reading) {
        '\AString\z' { 'a string'; break }
        '\ANull\z' { 'null'; break }
        '\ANA\z' { 'NA'; break }
        '\ABoolean (?<value>.+)\z' { "the Boolean $($Matches.value)"; break }
        '\AInteger without digits\z' { 'an integer without digits'; break }
        '\AInteger too long to convert\z' { 'an integer too long for Python to convert'; break }
        '\AInteger (?<value>-?[0-9]{1,40})\z' { "the integer $($Matches.value)"; break }
        '\AInteger (?<value>-?[0-9]+)\z' { "the integer $($Matches.value.Substring(0, 20))... ($($Matches.value.TrimStart('-').Length) digits)"; break }
        '\ANumber too large to read\z' { 'a number too large for this check to read'; break }
        '\AFloat without a value\z' { 'a float without a value'; break }
        '\AFloat (?<value>.+) or NA\z' { "the float $($Matches.value) (NA where the C library reports its underflow, as glibc does)"; break }
        '\AFloat (?<value>.+)\z' { "the float $($Matches.value)"; break }
        '\ATimestamp\z' { 'a timestamp'; break }
        '\AMerge\z' { 'a merge key'; break }
        '\AValue\z' { 'a value key'; break }
        default { $Reading }
    }
}


function Format-NeoIPCYamlExcerpt {
    # A value quoted as a message shows it: whole up to 60 characters, else its first 57 and its length, never cutting
    # a surrogate pair apart.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text.Length -le 60) { return "'$Text'" }
    $cut = if ([char]::IsHighSurrogate($Text[56])) { 56 } else { 57 }
    "'$($Text.Substring(0, $cut))...' ($($Text.Length) characters)"
}


function Get-NeoIPCYamlLastBlockValue {
    # The value of the last block scalar of a YAML text as YamlDotNet reads it, or $null where the text holds none or
    # cannot be read. YamlDotNet's parser, unlike its scanner, throws on a syntax error rather than repeat it.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $value = $null
    try {
        $parser = [YamlDotNet.Core.Parser]::new([System.IO.StringReader]::new($Text))
        while ($parser.MoveNext()) {
            $parsingEvent = $parser.Current
            if ($parsingEvent -is [YamlDotNet.Core.Events.Scalar] -and
                $parsingEvent.Style -in [YamlDotNet.Core.ScalarStyle]::Literal, [YamlDotNet.Core.ScalarStyle]::Folded) {
                $value = $parsingEvent.Value
            }
        }
    }
    catch { return $null }
    $value
}


function Join-NeoIPCPhrase {
    # Phrases joined as an English list, with a serial comma: "a", "a and b", "a, b, and c".
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Phrase)
    if ($Phrase.Count -eq 1) { return $Phrase[0] }
    if ($Phrase.Count -eq 2) { return "$($Phrase[0]) and $($Phrase[1])" }
    ($Phrase[0..($Phrase.Count - 2)] -join ', ') + ", and $($Phrase[-1])"
}


function Get-NeoIPCYamlPortabilityFinding {
    # Checks that a YAML text keeps to the portable subset of YAML 1.2.2 (see the top of this file). It reports:
    #   1. a plain scalar that the six readings read as different types or values, such as yes (a Boolean only under
    #      YAML 1.1 and R's yaml), 012 (octal 10 under YAML 1.1), 0x1A (a string only to powershell-yaml), or
    #      3000000000 (NA to R's yaml); quoting makes it a string under each;
    #   2. a plain key that a reading takes for anything but a string, such as true or 1, since powershell-yaml keeps
    #      every key as its text, and R's yaml would name it TRUE or 1, and a key that is a mapping or a sequence;
    #   3. with StringsOnly, for the output of a writer whose values are all strings, a plain scalar that reads as
    #      anything but a string, though all six agree;
    #   4. a block scalar that R's yaml types, such as |- holding yes, and one that runs to the end of the text and clips
    #      or keeps its final line break;
    #   5. an anchor, an alias, or an explicit tag, which readers resolve differently or not at all;
    #   6. a directive, which YAML 1.1 readers reject or misread, and a second document;
    #   7. a key repeated in one mapping, which readers settle differently, and a key repeated in another letter case,
    #      which powershell-yaml merges into one.
    # Returns findings in the shape of New-NeoIPCCheckFinding, and never throws.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$StringsOnly)

    try { Import-Module powershell-yaml -ErrorAction Stop }
    catch {
        New-NeoIPCCheckFinding -Rule 'yaml-reader' -Location '' -Message "powershell-yaml, which carries YamlDotNet, cannot be loaded: $($_.Exception.Message)"
        return
    }
    # A byte order mark, which a reader of a file skips, would start a plain scalar for YamlDotNet, handed a text.
    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    $directive = 'The text holds a directive, a line that starts with %, which readers reject, misread, or skip; the portable subset has none.'
    # Each explicit tag as the text spells it, in the order of the nodes it belongs to: an event carries the tag
    # resolved, tag:yaml.org,2002:str for !!str. The chomping indicator of the last block scalar, which the events do
    # not carry, decides whether its final line break is one readers disagree on.
    $tagSpellings = [System.Collections.Generic.Queue[string]]::new()
    $lastBlock = $null
    try {
        # YamlDotNet's scanner turns %YAML and %TAG into tokens, %TAG ! ! among them, which a parsed document's default
        # tags would hide, but it skips a directive of another name, which R's yaml rejects, before a document or in
        # one; so a line starting with % in the text between two tokens is one too.
        $scanner = [YamlDotNet.Core.Scanner]::new([System.IO.StringReader]::new($Text))
        $from = 0
        $reported = $false
        while ($scanner.MoveNext()) {
            $token = $scanner.Current
            if ($token -is [YamlDotNet.Core.Tokens.Error]) {
                # The scanner reports some errors, such as a second ': ' in a plain scalar, as a token without moving on,
                # so every later token would be the same error.
                New-NeoIPCCheckFinding -Rule 'yaml-syntax' -Location "line $($token.Start.Line)" -Message "The file is not valid YAML: $($token.Value)"
                return
            }
            if (-not $reported -and $token.Start.Index -gt $from) {
                $index = $Text.IndexOf([char]'%', $from, $token.Start.Index - $from)
                while ($index -ge 0) {
                    if ($index -eq 0 -or $Text[$index - 1] -in [char]"`n", [char]"`r") {
                        $line = [regex]::Matches($Text.Substring(0, $index), '\r\n|\r|\n').Count + 1
                        New-NeoIPCCheckFinding -Rule 'yaml-directive' -Location "line $line" -Message $directive
                        $reported = $true
                        break
                    }
                    $index = if ($index + 1 -lt $token.Start.Index) { $Text.IndexOf([char]'%', $index + 1, $token.Start.Index - $index - 1) } else { -1 }
                }
            }
            if ($token -is [YamlDotNet.Core.Tokens.VersionDirective] -or $token -is [YamlDotNet.Core.Tokens.TagDirective]) {
                if (-not $reported) { New-NeoIPCCheckFinding -Rule 'yaml-directive' -Location "line $($token.Start.Line)" -Message $directive }
                $reported = $true
            }
            elseif ($token -is [YamlDotNet.Core.Tokens.DocumentStart]) { $reported = $false }
            elseif ($token -is [YamlDotNet.Core.Tokens.Tag]) { $tagSpellings.Enqueue($Text.Substring($token.Start.Index, $token.End.Index - $token.Start.Index)) }
            elseif ($token -is [YamlDotNet.Core.Tokens.Scalar] -and
                $token.Style -in [YamlDotNet.Core.ScalarStyle]::Literal, [YamlDotNet.Core.ScalarStyle]::Folded) {
                # The header follows the | or > the token starts with: an indentation digit and a chomping sign, in
                # either order.
                $header = $Text.Substring($token.Start.Index + 1, [Math]::Min(2, $Text.Length - $token.Start.Index - 1))
                $header = $header -creplace '(?s)[^-+1-9].*\z', ''
                $lastBlock = @{
                    End      = $token.End.Index
                    Chomping = if ($header.Contains('-')) { 'strip' } elseif ($header.Contains('+')) { 'keep' } else { 'clip' }
                }
            }
            $from = [Math]::Max($from, $token.End.Index)
        }
    }
    catch [YamlDotNet.Core.YamlException] {
        New-NeoIPCCheckFinding -Rule 'yaml-syntax' -Location "line $($_.Exception.Start.Line)" -Message "The file is not valid YAML: $($_.Exception.Message)"
        return
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'yaml-reader' -Location '' -Message "The check could not read the text: $($_.Exception.Message)"
        return
    }

    # One frame per open collection. A mapping alternates key and value; Keys holds each key's letter-case-folded form
    # against its spelling.
    $frames = [System.Collections.Generic.Stack[hashtable]]::new()
    $verdicts = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $documents = 0
    $parser = [YamlDotNet.Core.Parser]::new([System.IO.StringReader]::new($Text))
    try {
        while ($parser.MoveNext()) {
            $parsingEvent = $parser.Current
            $line = "line $($parsingEvent.Start.Line)"
            if ($parsingEvent -is [YamlDotNet.Core.Events.DocumentStart]) {
                $documents++
                if ($documents -eq 2) {
                    New-NeoIPCCheckFinding -Rule 'yaml-documents' -Location $line -Message 'The file holds more than one document; some readers read only the first.'
                }
                continue
            }
            if ($parsingEvent -is [YamlDotNet.Core.Events.MappingEnd] -or $parsingEvent -is [YamlDotNet.Core.Events.SequenceEnd]) {
                [void]$frames.Pop()
                continue
            }
            $isAlias = $parsingEvent -is [YamlDotNet.Core.Events.AnchorAlias]
            if (-not $isAlias -and $parsingEvent -isnot [YamlDotNet.Core.Events.NodeEvent]) { continue }

            if ($isAlias) {
                New-NeoIPCCheckFinding -Rule 'yaml-alias' -Location $line -Message "An alias (*$($parsingEvent.Value)) stands for an anchored node; the portable subset uses neither anchors nor aliases."
            }
            else {
                if (-not $parsingEvent.Anchor.IsEmpty) {
                    New-NeoIPCCheckFinding -Rule 'yaml-anchor' -Location $line -Message "A node carries the anchor &$($parsingEvent.Anchor); the portable subset uses neither anchors nor aliases."
                }
                if (-not $parsingEvent.Tag.IsEmpty) {
                    $tag = if ($tagSpellings.Count -gt 0) { $tagSpellings.Dequeue() } else { "$($parsingEvent.Tag)" }
                    $advice = if ($parsingEvent -is [YamlDotNet.Core.Events.Scalar]) { 'leave it out, and quote the scalar if it should be a string' } else { 'leave it out' }
                    New-NeoIPCCheckFinding -Rule 'yaml-tag' -Location $line -Message "A node carries the explicit tag $tag, and the portable subset has none: $advice."
                }
            }

            # A key of the innermost open mapping: check it against the mapping's other keys.
            $isKey = $false
            if ($frames.Count -gt 0 -and $frames.Peek().Kind -eq 'map') {
                $frame = $frames.Peek()
                $isKey = $frame.ExpectKey
                if ($isKey -and -not $isAlias -and $parsingEvent -isnot [YamlDotNet.Core.Events.Scalar]) {
                    # powershell-yaml keeps such a key as an array or a raw node, R's yaml names the entry after the
                    # key's items, and yaml12 keeps the key typed.
                    $kind = if ($parsingEvent -is [YamlDotNet.Core.Events.MappingStart]) { 'mapping' } else { 'sequence' }
                    New-NeoIPCCheckFinding -Rule 'yaml-complex-key' -Location $line -Message "A mapping key is itself a $kind, which each reader turns into something else; the portable subset's keys are strings."
                }
                elseif ($isKey -and $parsingEvent -is [YamlDotNet.Core.Events.Scalar]) {
                    $key = $parsingEvent.Value
                    $folded = $key.ToUpperInvariant()
                    if ($frame.Keys.ContainsKey($folded)) {
                        $first = $frame.Keys[$folded]
                        if ($first -ceq $key) {
                            New-NeoIPCCheckFinding -Rule 'yaml-duplicate-key' -Location $line -Message "The key '$key' appears twice in one mapping, which readers settle differently."
                        }
                        else {
                            New-NeoIPCCheckFinding -Rule 'yaml-case-variant-key' -Location $line -Message "The key '$key' repeats '$first' in another letter case, which powershell-yaml merges into one."
                        }
                    }
                    else {
                        $frame.Keys[$folded] = $key
                    }
                }
                $frame.ExpectKey = -not $frame.ExpectKey
            }
            if ($parsingEvent -is [YamlDotNet.Core.Events.MappingStart]) { $frames.Push(@{ Kind = 'map'; ExpectKey = $true; Keys = @{} }) }
            elseif ($parsingEvent -is [YamlDotNet.Core.Events.SequenceStart]) { $frames.Push(@{ Kind = 'seq' }) }

            if ($parsingEvent -is [YamlDotNet.Core.Events.Scalar] -and
                $parsingEvent.Style -in [YamlDotNet.Core.ScalarStyle]::Literal, [YamlDotNet.Core.ScalarStyle]::Folded) {
                # A block scalar that runs to the end of the text, nothing but whitespace after its end mark, and clips or
                # keeps its final line break (see the top of this file); R's yaml reads it from the text without its last
                # line break, as YamlDotNet reads that text here.
                $seen = $parsingEvent.Value
                if ($Text.Substring([Math]::Min([int]$parsingEvent.End.Index, $Text.Length)).Trim(' ', "`t", "`r", "`n").Length -eq 0) {
                    $chomping = if ($null -ne $lastBlock -and $lastBlock.End -eq $parsingEvent.End.Index) { $lastBlock.Chomping } else { 'clip' }
                    if ($chomping -cne 'strip') {
                        New-NeoIPCCheckFinding -Rule 'yaml-portability' -Location $line `
                            -Message "The block scalar runs to the end of the text and $(if ($chomping -ceq 'keep') { 'keeps' } else { 'clips' }) its final line break, which readers gain or lose there: R's yaml reads a file's lines joined without the last one, powershell-yaml reads the text with one added, and yaml12 ends such a value with one even where the text does not; strip its trailing line breaks (|- or >-), or end the text with another node."
                    }
                    if ($Text -cmatch '(?:\r\n|\r|\n)\z') {
                        $lastValue = Get-NeoIPCYamlLastBlockValue -Text ($Text -creplace '(?:\r\n|\r|\n)\z', '')
                        if ($null -ne $lastValue) { $seen = $lastValue }
                    }
                }
                $reading = Get-NeoIPCYamlScalarReading -Text $seen -Reader "R's yaml"
                if ($reading -cne 'String') {
                    $others = Join-NeoIPCPhrase ([string[]]@($script:NeoIPCYamlReaders | Where-Object { $_ -cne "R's yaml" }))
                    New-NeoIPCCheckFinding -Rule 'yaml-portability' -Location $line `
                        -Message "The block scalar $(Format-NeoIPCYamlExcerpt $seen) reads as $(Format-NeoIPCYamlReading $reading) under R's yaml, which types a block scalar as it types a plain one, but as a string under $others; quote it."
                }
            }

            if ($parsingEvent -is [YamlDotNet.Core.Events.Scalar] -and $parsingEvent.Style -eq [YamlDotNet.Core.ScalarStyle]::Plain -and
                $parsingEvent.Tag.IsEmpty) {
                $value = $parsingEvent.Value
                # A file repeats most of its values, so each is read once per call, as a key and as a value apart.
                $verdictKey = $(if ($isKey) { 'key:' } else { 'value:' }) + $value
                $message = $null
                if (-not $verdicts.TryGetValue($verdictKey, [ref]$message)) {
                    $message = ''
                    $order = [System.Collections.Generic.List[string]]::new()
                    $readersOf = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
                    foreach ($reader in $script:NeoIPCYamlReaders) {
                        $reading = Get-NeoIPCYamlScalarReading -Text $value -Reader $reader -Key:$isKey
                        if (-not $readersOf.ContainsKey($reading)) {
                            $readersOf[$reading] = [System.Collections.Generic.List[string]]::new()
                            $order.Add($reading)
                        }
                        $readersOf[$reading].Add($reader)
                    }
                    $what = if ($isKey) { 'key' } else { 'scalar' }
                    if ($order.Count -gt 1) {
                        $phrases = @($order | ForEach-Object { "as $(Format-NeoIPCYamlReading $_) under $(Join-NeoIPCPhrase ([string[]]$readersOf[$_]))" })
                        $how = if ($phrases.Count -eq 2) { "$($phrases[0]), but $($phrases[1])" } else { Join-NeoIPCPhrase $phrases }
                        $message = "The plain $what $(Format-NeoIPCYamlExcerpt $value) reads $how; quote it."
                    }
                    elseif ($StringsOnly -and $order[0] -cne 'String') {
                        $message = "The plain $what $(Format-NeoIPCYamlExcerpt $value) reads as $(Format-NeoIPCYamlReading $order[0]) under every reader, but the text holds only strings; quote it."
                    }
                    $verdicts[$verdictKey] = $message
                }
                if ($message) { New-NeoIPCCheckFinding -Rule 'yaml-portability' -Location $line -Message $message }
            }
        }
    }
    catch [YamlDotNet.Core.YamlException] {
        New-NeoIPCCheckFinding -Rule 'yaml-syntax' -Location "line $($_.Exception.Start.Line)" -Message "The file is not valid YAML: $($_.Exception.Message)"
    }
    catch {
        New-NeoIPCCheckFinding -Rule 'yaml-reader' -Location '' -Message "The check could not read the text: $($_.Exception.Message)"
    }
}
