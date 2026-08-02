#!/usr/bin/env pwsh
#Requires -Version 7.6

<#
.SYNOPSIS
    Fail if any committed text file has the wrong line endings or encoding, or if a PowerShell file's
    header is malformed.

.DESCRIPTION
    The mechanical half of the text-file contract: LF line endings, UTF-8 without a BOM, and a canonical
    PowerShell header. Runs over this repository.

    This repository's only submodule is the pinned po4a tool, which is third-party upstream and not ours
    to hold to this contract — it is excluded automatically, because SubmodulePrefix defaults to 'repos/'
    and no submodule here matches. So the file needs no adaptation to run standalone.

    Equivalent copies of this check live in the other NeoIPC repositories. The duplication is deliberate:
    each repository has to enforce its own contract when cloned on its own, so none of them can reach
    outside itself for the script. Only the help text differs between copies — keep the logic in step when
    changing any of it.

    Three checks, each of which caught a real defect in this repository:

    1. LINE ENDINGS, from the WORKING-TREE column of `git ls-files --eol`, not the index column. This
        distinction is the whole point. With `* text=auto` declared, git normalizes on commit, so a tool
        that writes CRLF into the working tree still produces an LF blob and a clean `git status` — the
        index column can therefore never report crlf for a text file, and a gate that reads it passes on
        exactly the defect it exists to catch. Seven CRLF catalogues sat in this repository undetected
        that way. The index column is still checked as a cheap fallback — but not, as this help previously
        claimed, because a declared-binary file bypasses normalization: such a file is exempt before either
        column is read, so it can never reach the check. It guards against a crlf/mixed blob arriving by a
        route that skips the clean filter instead.

    2. ENCODING, by reading bytes: no UTF-8 BOM, and the content must decode as strict UTF-8. Files git
        classifies as binary are skipped — they are not text and the rule does not apply to them.

    3. POWERSHELL HEADERS, by parsing each file: a #Requires -Version at or above the floor, a shebang on
        line 1 for anything executed directly, and — where the file carries a top-of-file help block —
        that block actually resolving. That last one is not cosmetic: three separate layout mistakes
        silently discard comment-based help while `Get-Help` still prints a synthesized syntax line, so
        the script looks documented when it is not. Sixteen files were in that state.

    Exit code is 0 when clean, 1 when any check fails. Nothing is modified.

    The scope is all-or-nothing: every repository the run puts in scope must be a checked-out working tree,
    and the run fails naming the ones that are not. A green result therefore always means the whole declared
    scope was inspected, never that part of it was quietly skipped.

.PARAMETER Path
    Repository root to check. Defaults to this repository's root (this script's parent directory).

.PARAMETER NoSubmodules
    Check only the given repository, not its submodules. Used when each repository runs the check itself
    in its own CI, where the submodules are not present.

.PARAMETER SubmodulePrefix
    Only submodules whose path starts with this are checked. Defaults to 'repos/', which no submodule of
    this repository matches — so the sweep stays inside this repository unless told otherwise.

    Third-party upstream checkouts are deliberately out of scope wherever they appear: their line endings
    and encodings are not ours to set, gating on them would report failures nobody here could act on, and
    they are large enough to turn a seconds-long check into a minutes-long one.

.PARAMETER RequiredPowerShellVersion
    The #Requires floor every .ps1/.psm1 must declare at least. Defaults to 7.6, which is what this
    codebase actually needs — Resolve-Path -RelativeBasePath and ConvertFrom-Json -DateKind do not exist
    below it.

.EXAMPLE
    ./scripts/Test-TextFileHygiene.ps1

    Check this repository. This is what its CI runs on every push and pull request.

.EXAMPLE
    ./scripts/Test-TextFileHygiene.ps1 -Path . -NoSubmodules

    Check one repository on its own, as a repository's own CI does.
#>

[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot),
    [switch]$NoSubmodules,
    [string]$SubmodulePrefix = 'repos/',
    [string]$RequiredPowerShellVersion = '7.6'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$floor = [version]$RequiredPowerShellVersion
$failures = [System.Collections.Generic.List[string]]::new()
$checkedFiles = 0
$checkedRepos = 0
# Why a tracked path was not inspected, kept apart so the empty-root guard can name the actual cause.
$skippedBinary = 0
$skippedAbsent = 0

function Get-RepoList {
    param([string]$Root)

    $roots = @($Root)
    if (-not $NoSubmodules) {
        # Read the declared submodule paths rather than shelling into each one: `submodule foreach` would
        # also descend into refs/, and those upstream checkouts are both out of scope and enormous.
        foreach ($line in @(& git -C $Root config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>$null)) {
            if (-not $line) { continue }
            $declared = ($line -split '\s+', 2)[1]
            if ($declared -and $declared.StartsWith($SubmodulePrefix)) {
                $roots += (Join-Path $Root $declared)
            }
        }
    }
    # Every declared root is returned, checked out or not. This used to drop the ones that are not working
    # trees, which is what made a narrowed sweep look like a clean one — see the scope check at the call site.
    $roots
}

function Get-EolRow {
    param([string]$Repo)

    # `git ls-files --eol` emits: i/<idx>  w/<worktree>  attr/<attrs><TAB><path>
    # Split the path off on the TAB first, then the columns on whitespace, so an attr value containing a
    # space (attr/text=auto eol=lf) cannot shift the column indices — and so "eol=crlf" appearing inside
    # the attr text can never be mistaken for a finding.
    foreach ($line in (& git -C $Repo ls-files --eol)) {
        if (-not $line) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) { continue }
        $cols = @($parts[0] -split '\s+' | Where-Object { $_ })
        if ($cols.Count -lt 2) { continue }

        # The third column is the literal string "attr/" with the attributes glued directly on, e.g.
        # "attr/-text" or "attr/text=auto eol=lf" — so the prefix has to come off before matching, or
        # "-text" is preceded by "/" rather than whitespace and no word-boundary pattern will find it.
        $attr = if ($cols.Count -gt 2) { ($cols[2..($cols.Count - 1)] -join ' ') } else { '' }
        $attr = $attr -replace '^attr/', ''

        # Whether to treat the path as binary, and so exempt from the text rules. The ATTRIBUTE is
        # authoritative, not the detected content: `*.pdf binary` expands to -text, but git still reports
        # the i/ and w/ columns from what it DETECTED in the bytes. A PDF whose first 8000 bytes contain
        # no NUL is detected as "lf" while being declared binary — so keying the skip on the i/ column
        # alone reports it as invalid UTF-8, which is how the first run of this script failed.
        # Only the DECLARATION exempts a path. Folding the detected columns into this instead opens a
        # hole big enough to drive the original defect through: a single NUL byte in the first 8000 bytes
        # makes git report -text, which would then skip the line-ending check, the BOM check AND the
        # strict-UTF-8 check at once — so a UTF-16 CRLF catalogue commits silently, which is exactly the
        # class of corruption this script exists to catch. A genuinely binary file must therefore say so
        # in .gitattributes; there are only ever a handful, and naming them is the point.
        $declaredBinary = $attr -match '(^|\s)-text(\s|$)' -or $attr -match '(^|\s)binary(\s|$)'
        $detectedBinary = $cols[0] -eq 'i/-text' -or $cols[1] -eq 'w/-text'

        [pscustomobject]@{
            Index       = $cols[0]
            Worktree    = $cols[1]
            Attr        = $attr
            File        = $parts[1]
            IsBinary    = $declaredBinary
            LooksBinary = $detectedBinary
        }
    }
}

function Test-LineEnding {
    param([string]$Repo, [string]$Label)

    foreach ($row in (Get-EolRow -Repo $Repo)) {
        if ($row.IsBinary) { continue }

        # Declared text, but git found a NUL in the first 8000 bytes and so reports -text. This has to be
        # its own finding rather than a skip, because it is the one state in which NONE of the other checks
        # can see anything wrong: git reports -text instead of crlf so the line-ending columns are empty of
        # evidence, a NUL is perfectly valid UTF-8 so strict decoding passes, and a UTF-16 file carries no
        # UTF-8 BOM. A CRLF UTF-16 catalogue therefore sailed through every check while being exactly the
        # corruption this script exists to catch. Either the file is mis-encoded, or it is binary and the
        # attribute should say so.
        if ($row.LooksBinary) {
            $failures.Add("$Label`: $($row.File) is declared text but git detects binary content (a NUL byte). " +
                "That usually means it is UTF-16 or otherwise mis-encoded — git cannot report its real line " +
                "endings while it looks binary. If it genuinely is binary, declare it '-text' in .gitattributes.")
            continue
        }

        if ($row.Worktree -in @('w/crlf', 'w/mixed')) {
            $failures.Add("$Label`: $($row.File) has $($row.Worktree.Substring(2)) line endings in the working tree (expected lf)")
        }
        elseif ($row.Index -in @('i/crlf', 'i/mixed')) {
            $failures.Add("$Label`: $($row.File) has $($row.Index.Substring(2)) line endings in the index (expected lf)")
        }
    }
}

function Test-Encoding {
    param([string]$Repo, [string]$Label)

    # Paths exempt as binary — by declared attribute only. Same determination as the line-ending check,
    # so the two cannot disagree about what counts as text. `$looksBinary` is kept separately to make the
    # failure actionable rather than to excuse the file.
    $binary = [System.Collections.Generic.HashSet[string]]::new()
    $looksBinary = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($row in (Get-EolRow -Repo $Repo)) {
        if ($row.IsBinary) { [void]$binary.Add($row.File) }
        elseif ($row.LooksBinary) { [void]$looksBinary.Add($row.File) }
    }

    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    foreach ($file in (& git -C $Repo ls-files)) {
        if (-not $file) { continue }
        # Two different reasons a tracked path is not inspected, counted apart. They are
        # indistinguishable in `$checkedFiles`, and the empty-root guard reports which one emptied a
        # root — so folding them together lets that message name `.gitattributes` for a checkout fault
        # and send the reader to the wrong file, which is worse than saying nothing.
        if ($binary.Contains($file)) { $script:skippedBinary++; continue }
        $full = Join-Path $Repo $file
        # Tracked but not on disk: deleted from the working tree, excluded by a sparse checkout, or an
        # uninitialised submodule — a directory rather than a Leaf either way.
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $script:skippedAbsent++; continue }

        # Absolute path: [System.IO.File] resolves a relative path against the PROCESS working
        # directory, not PowerShell's location, so a relative one here silently reads the wrong file.
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $script:checkedFiles++

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $failures.Add("$Label`: $file starts with a UTF-8 BOM")
            continue
        }

        # A UTF-16 or UTF-32 BOM means the file is not UTF-8 at all. Strict decoding below rejects it
        # anyway — 0xFF and 0xFE never appear in valid UTF-8 — but naming the actual encoding is what
        # makes the failure actionable; "is not valid UTF-8" leaves the reader guessing which of a dozen
        # things went wrong. Test UTF-32 first: its little-endian BOM (FF FE 00 00) opens with the
        # UTF-16LE one, so the shorter pattern would otherwise shadow it and misreport the encoding.
        $wideBom =
            if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) { 'UTF-32LE' }
            elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) { 'UTF-32BE' }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { 'UTF-16LE' }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { 'UTF-16BE' }
            else { $null }
        if ($wideBom) {
            $failures.Add("$Label`: $file starts with a $wideBom BOM — it is not UTF-8. Re-encode it as UTF-8 without a BOM.")
            continue
        }
        try { [void]$strict.GetString($bytes) }
        catch {
            $hint = if ($looksBinary.Contains($file)) {
                " (git detects it as binary — if it genuinely is, declare it '-text' in .gitattributes" +
                " so it is exempt by declaration rather than by accident)"
            } else { '' }
            $failures.Add("$Label`: $file is not valid UTF-8$hint")
        }
    }
}

function Test-PowerShellHeader {
    param([string]$Repo, [string]$Label)

    foreach ($file in (& git -C $Repo ls-files '*.ps1' '*.psm1')) {
        if (-not $file) { continue }
        $full = Join-Path $Repo $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

        # A module source file is dot-sourced by its module root, never executed, and its help belongs to
        # the functions it defines — so it takes the version floor but neither a shebang nor script help.
        $isModuleSource = $file -match 'modules/.+/(Private|Public)/'

        # "Executed directly" is decided from a POSITIVE signal — living outside any modules/ tree —
        # rather than by failing three negative patterns. Anything under modules/ is dot-sourced or
        # imported by a module root, whether it sits in Private/, Public/, or directly in modules/
        # (the shared Pester helper does). Inferring this by exclusion let that helper fall through and
        # be told to carry a shebang, which is precisely what the header rule forbids on a file that is
        # never executed.
        $isModuleFile = $file -match '(^|/)modules/'
        $isDirectlyRun = -not $isModuleFile -and
                         $file -notmatch '\.psm1$' -and
                         $file -notmatch '\.Tests\.ps1$'

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
        if ($errors.Count) {
            $failures.Add("$Label`: $file does not parse ($($errors.Count) error(s))")
            continue
        }

        $declared = if ($ast.ScriptRequirements) { $ast.ScriptRequirements.RequiredPSVersion } else { $null }
        if (-not $declared) {
            $failures.Add("$Label`: $file has no '#Requires -Version' (expected at least $floor)")
        }
        elseif ([version]$declared -lt $floor) {
            $failures.Add("$Label`: $file declares '#Requires -Version $declared', below the $floor floor")
        }

        $text = [System.IO.File]::ReadAllText($full)
        $firstLine = ($text -split "`r?`n", 2)[0]
        if ($isDirectlyRun -and -not $firstLine.TrimStart().StartsWith('#!')) {
            $failures.Add("$Label`: $file is executed directly but has no '#!' on line 1")
        }

        # Only assert help RESOLVES where the file plainly means to have script-level help: a <# … #>
        # block containing .SYNOPSIS before the first statement. Testing the outcome rather than the
        # layout catches all three ways the block can be silently discarded, without encoding any of them:
        #   - a comment line (shebang or #Requires) directly above <#, with no blank line between;
        #   - a function fewer than two blank lines after #>, which takes the help for itself;
        #   - a line inside the block starting with '.' plus a word that is not a help keyword,
        #     which discards the entire block. ".po" and ".pot" do this, and this project writes about
        #     those files constantly.
        if (-not $isModuleSource) {
            $firstStatement = if ($ast.EndBlock -and $ast.EndBlock.Statements.Count) {
                $ast.EndBlock.Statements[0].Extent.StartOffset
            } elseif ($ast.ParamBlock) {
                $ast.ParamBlock.Extent.StartOffset
            } else { [int]::MaxValue }

            $intendsHelp = $tokens | Where-Object {
                $_.Kind -eq 'Comment' -and $_.Text.StartsWith('<#') -and
                $_.Text -match '\.SYNOPSIS' -and $_.Extent.StartOffset -lt $firstStatement
            } | Select-Object -First 1

            if ($intendsHelp) {
                $help = $ast.GetHelpContent()
                if (-not ($help -and $help.Synopsis)) {
                    $failures.Add(("$Label`: $file has a top-of-file help block that PowerShell does not " +
                        'resolve — check for a missing blank line after the last leading comment, a ' +
                        'function fewer than two blank lines after #>, or a line starting with a dot-token'))
                }
            }
        }
    }
}

function Test-ConvertToJsonDepth {
    param([string]$Repo, [string]$Label)

    # ConvertTo-Json defaults to -Depth 2 and drops everything below it. The default is wrong here in the
    # way that costs most: the object still serialises, the output still looks like JSON, and the only
    # signal is a warning on a stream nobody reads in CI. A workspace poll script put a nested GraphQL
    # error into a job log as `@{line=1; column=9}` — a PowerShell hashtable stringified where JSON was
    # meant — and that string was the diagnostic for an outage, so the one place it degraded was the one
    # place someone was reading. Nothing here is defended against depth, so there is no case for a
    # shallower cap and the rule is simply the maximum the parameter accepts (its range is 0..100).
    #
    # Matched on the AST, not by grepping the command name: many textual hits are the phrase appearing
    # inside explanatory comments, and a regex cannot tell those from a call.
    foreach ($file in (& git -C $Repo ls-files '*.ps1' '*.psm1')) {
        if (-not $file) { continue }
        $full = Join-Path $Repo $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
        # A file that does not parse is already reported by the header check; saying so twice is noise.
        if ($errors.Count) { continue }

        $calls = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'ConvertTo-Json'
            }, $true)

        foreach ($call in $calls) {
            # PowerShell binds any unambiguous prefix, so -Dep and -D reach -Depth exactly as -Depth does.
            $hasDepth = $call.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                $_.ParameterName -and
                'Depth'.StartsWith($_.ParameterName, [System.StringComparison]::OrdinalIgnoreCase)
            }
            # A splatted call carries its parameters in a hashtable this check cannot read, so it is left
            # alone rather than failed on a construct the check does not understand.
            $isSplatted = $call.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            }
            if (-not $hasDepth -and -not $isSplatted) {
                $failures.Add("$Label`: $file line $($call.Extent.StartLineNumber) calls ConvertTo-Json " +
                    'without -Depth — the default of 2 truncates silently; pass -Depth 100')
            }
        }
    }
}

# Everything in scope is swept in full or the run fails; the scope never quietly shrinks. Passing over a root
# is indistinguishable in the output from having checked it, and that is not hypothetical: two uninitialized
# submodules took a superproject sweep from eight repositories to six and it still printed OK, and a source
# tree with no repository at all printed "OK: 0 file(s) across 0 repository/ies" and exited 0. A gate that
# inspected nothing while reporting success is the one outcome this whole contract exists to make impossible.
#
# The test is that each root ENUMERATES, not that a `.git` entry exists beside it, and the difference is the
# whole point. A `.git` gitlink file whose target gitdir is gone — what copying or archiving a superproject
# without its .git/modules produces — is a perfectly ordinary file, so a presence test passes it; every
# `git -C <root> ls-files` then exits 128 with no output, which none of the three checks below inspects
# (they read $LASTEXITCODE nowhere, and on this PowerShell a failing native command does not throw), so the
# root contributes zero findings and zero files while still counting as checked. Since only the TOTAL file
# count is reported, that zero is invisible. Measured, not reasoned: a superproject with one healthy and one
# gitlink-broken submodule printed "Text-file hygiene OK: 5 file(s) across 3 repository/ies" with a planted
# CRLF file in the broken one never seen — and its process exit code was whatever git happened to set last,
# so whether that green message also counted as a passing run depended on which repository came last in
# .gitmodules. So ask git to list the files, and require an answer.
#
# `exit 1` rather than `throw`: a regression harness invokes this script with `&` and scores $LASTEXITCODE,
# so a terminating error would propagate into that caller instead of counting as a failed run.
$rootPath = (Resolve-Path -LiteralPath $Path).Path
$repoList = @(Get-RepoList -Root $rootPath)

$unusable = foreach ($repo in $repoList) {
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
        [pscustomobject]@{ Repo = $repo; Reason = 'the directory does not exist' }
        continue
    }
    # `--eol`, not a bare `ls-files`: this preflight exists to establish that the sweep below can enumerate,
    # and the sweep runs `git ls-files --eol` (see Get-EolRow), which inspects no exit code of its own. Prove
    # the guarantee with the command that will actually be used, so the two are about the same thing by
    # construction rather than by coincidence — a git old enough to lack `--eol`, or any failure specific to
    # that option, would otherwise pass the preflight and then sweep nothing.
    $listed = @(& git -C $repo ls-files --eol 2>$null)
    if ($LASTEXITCODE -ne 0) {
        [pscustomobject]@{ Repo = $repo; Reason = "git cannot enumerate it (ls-files --eol exit $LASTEXITCODE) — not checked out, or a .git pointing at a gitdir that is gone" }
    } elseif ($listed.Count -eq 0) {
        [pscustomobject]@{ Repo = $repo; Reason = 'it has no tracked files, so a sweep of it would prove nothing' }
    }
}
$unusable = @($unusable)
if ($unusable) {
    Write-Host ("Cannot check text-file hygiene: {0} of {1} repository/ies in scope cannot be swept:" -f $unusable.Count, $repoList.Count) -ForegroundColor Red
    $unusable | ForEach-Object { Write-Host ("  {0}`n      {1}" -f $_.Repo, $_.Reason) -ForegroundColor Red }
    Write-Host ''
    if ($unusable.Repo -contains $rootPath) {
        Write-Host "'$rootPath' is not a usable git working tree, so it has no tracked files to check." -ForegroundColor DarkGray
    } else {
        Write-Host "Check the submodules out first: git submodule update --init -- $SubmodulePrefix" -ForegroundColor DarkGray
    }
    exit 1
}

$inspectedNothing = [System.Collections.Generic.List[object]]::new()
foreach ($repo in $repoList) {
    $label = Split-Path $repo -Leaf
    $checkedRepos++
    # Sampled per root rather than over the run — see the guard below for why that distinction is the
    # whole point. The skip counters are sampled the same way so the cause reported for a root is that
    # root's, not the run's running total.
    $filesBefore = $checkedFiles
    $binaryBefore = $skippedBinary
    $absentBefore = $skippedAbsent
    Test-LineEnding      -Repo $repo -Label $label
    Test-Encoding        -Repo $repo -Label $label
    Test-PowerShellHeader -Repo $repo -Label $label
    Test-ConvertToJsonDepth -Repo $repo -Label $label
    if ($checkedFiles -eq $filesBefore) {
        $inspectedNothing.Add([pscustomobject]@{
            Repo   = $repo
            Binary = $skippedBinary - $binaryBefore
            Absent = $skippedAbsent - $absentBefore
        })
    }
}

# A root that inspected NOTHING must not count as checked. The preflight above proves each root can
# ENUMERATE; it does not prove that any file survived the declared-binary filter, and those are different
# claims. A .gitattributes regression declaring the whole tree binary (`* -text`) satisfies the preflight —
# `ls-files --eol` returns rows for every path — and then every row is skipped, so the root contributes zero
# findings and zero inspected files while still counting as swept. Measured, not reasoned: a repository
# holding `* -text`, one CRLF file and one file with a UTF-8 BOM printed "Text-file hygiene OK: 0 file(s)"
# and exited 0, seeing neither planted defect.
#
# Per ROOT, because only the TOTAL is reported: in a multi-root scope a healthy root's files keep that total
# non-zero, so one root dropping to zero is invisible in the green line. Same blindness the enumeration
# preflight above closes for a different cause; a run-level count cannot see this one.
#
# The declared-binary case is the one that looks most normal — the checkout is complete, git is healthy,
# every command succeeds — and this is the repository where seven CRLF catalogues did sit undetected, so the
# check whose .DESCRIPTION promises the whole declared scope was inspected has to be able to keep it.
#
# It is NOT the only way a root empties, which is why the cause is reported rather than assumed. A tracked
# path that is absent from the working tree — deleted, excluded by a sparse checkout, or an uninitialised
# submodule — is skipped by the same counter. Naming `.gitattributes` there would point at the one file that
# is fine and steer the reader away from the checkout, which is the actual fault: a message that
# under-specifies costs a minute, one that misdirects costs however long it takes to stop believing it.
if ($inspectedNothing.Count) {
    Write-Host ("Cannot check text-file hygiene: {0} of {1} repository/ies in scope enumerated tracked files but left none to inspect:" -f $inspectedNothing.Count, $repoList.Count) -ForegroundColor Red
    foreach ($root in $inspectedNothing) {
        $why =
            if ($root.Binary -and $root.Absent) {
                "$($root.Binary) declared binary, $($root.Absent) absent from the working tree"
            } elseif ($root.Binary) {
                "all $($root.Binary) declared binary — check .gitattributes for a stray '* -text' or '* binary'"
            } elseif ($root.Absent) {
                "all $($root.Absent) tracked but absent from the working tree — an incomplete or sparse checkout, not .gitattributes"
            } else {
                'no tracked path reached the encoding check at all'
            }
        Write-Host ("  {0}`n      {1}" -f $root.Repo, $why) -ForegroundColor Red
    }
    Write-Host ''
    Write-Host 'Nothing there was checked for line endings, a BOM or valid UTF-8. The cause named above decides' -ForegroundColor DarkGray
    Write-Host 'the fix: a whole-tree binary declaration exempts a tree from every check in this script, while' -ForegroundColor DarkGray
    Write-Host 'absent files were never there to check in the first place.' -ForegroundColor DarkGray
    Write-Host ''
}

if ($failures.Count) {
    Write-Host ("Text-file hygiene: {0} problem(s) across {1} repository/ies." -f $failures.Count, $checkedRepos) -ForegroundColor Red
    $failures | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Expected: LF line endings, UTF-8 without a BOM, and the canonical PowerShell header' -ForegroundColor DarkGray
    Write-Host "(#!/usr/bin/env pwsh where run directly, #Requires -Version $floor, blank line, help block)." -ForegroundColor DarkGray
}

# Both conditions are terminal, and the exit is deliberately here rather than inside either block: a root that
# inspected nothing is a failed run whether or not the roots that DID inspect something came back clean, and
# an `exit 1` inside the block above would have reported findings while returning before this one was scored.
if ($failures.Count -or $inspectedNothing.Count) { exit 1 }

Write-Host ("Text-file hygiene OK: {0} file(s) across {1} repository/ies." -f $checkedFiles, $checkedRepos) -ForegroundColor Green
# Declare the verdict explicitly. Falling off the end leaves $LASTEXITCODE holding whatever the last internal
# `git` call set — or, when the scope was empty so no `git` ran at all, whatever the CALLER had there already.
# A caller reading that is scoring this run off residue, and a regression harness did exactly that.
exit 0
