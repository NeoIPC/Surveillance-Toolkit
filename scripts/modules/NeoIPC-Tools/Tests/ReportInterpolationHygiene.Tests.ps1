#Requires -Version 7.6
#requires -Module Pester

<#
.SYNOPSIS
    Pester gate keeping translated strings out of R's evaluator.

.DESCRIPTION
    glue resolves each brace as an R EXPRESSION, in the environment given by .envir, which defaults to the
    caller's frame. Report templates come from gettext catalogues that any signed-in Weblate account may
    write, so a translated string reaching glue::glue() is arbitrary R evaluated at render time with every
    local binding in scope, inside the container that renders clinical reports. Measured rather than
    argued: a template of "{nchar(secret)}" returned 23.

    glue_safe() and glue_data_safe() look each brace up as a NAME and never evaluate, so the property
    lives in the primitive instead of in an argument every future author has to remember - which matters
    because the source-string migration is about to add roughly 123 more interpolations. A forgotten
    argument then degrades to variable disclosure rather than code execution.

    Two halves, deliberately:

    - The STRUCTURAL half bans the unsafe entry points outright and runs everywhere. It is the half that
      has to hold as the migration adds call sites.
    - The BEHAVIOURAL half proves the helper actually refuses evaluation, and is skipped where R is
      absent. A ban nobody can execute is a spelling rule; this is what makes it a security property.

    On matching by regex, which this project otherwise forbids: there is no parser available here. R's own
    parser cannot read the corpus - a .qmd is markdown with embedded chunks, and parse() on one fails
    outright - and CI installs no R at all, because rendering happens in the container repository. The
    pattern is lexically simple in exchange, and an aliased call (a bare `glue(` after library(glue)) is
    covered by the separate rule requiring non-base calls to be namespace-qualified.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReportInterpolationHygiene.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $reportsDir = Join-Path $repoRoot 'reports'
    $helpers = Join-Path $reportsDir 'common' 'helpers.R'
    $rscript = (Get-Command Rscript -ErrorAction SilentlyContinue)?.Source

    # Runs an R snippet against a freshly sourced helpers.R and returns its stdout, so each assertion is
    # independent of the others' bindings.
    #
    # The stopifnot guard is load-bearing rather than defensive. The refusal assertions below catch an
    # error and report "REFUSED" — and an ABSENT helper raises an error too, so without this they pass
    # while proving nothing. That is not hypothetical: both of them went green on the first run of this
    # file, before the helper existed. Asserting the function is there first means a refusal can only be
    # the refusal being tested for. The check cannot be an error-message match instead: R localises those,
    # and this machine reports them in German.
    function Invoke-RSnippet {
        param([string]$Body)
        $guard = 'stopifnot(exists("interpolate_translation"), is.function(interpolate_translation))'
        $script = "source('$($helpers -replace '\\', '/')')`n$guard`n$Body"
        $file = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($file.FullName, $script, [System.Text.UTF8Encoding]::new($false))
            (& $rscript --vanilla $file.FullName 2>&1) -join "`n"
        } finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Report interpolation hygiene' {

    It 'no report file calls glue::glue or glue::glue_data on a translated template' {
        # `glue::glue(` and `glue::glue_data(` only — the trailing paren is what keeps glue_safe and
        # glue_data_safe out of the match.
        $pattern = 'glue::glue(_data)?\s*\('
        $offenders = Get-ChildItem -LiteralPath $reportsDir -Recurse -File -Include '*.qmd', '*.Rmd', '*.R' |
            ForEach-Object {
                $file = $_
                # An R COMMENT is skipped, because this project writes about glue in prose constantly and
                # a sentence naming it is not a call. A markdown HEADING is not, and the earlier form
                # treated the two as one case: a Quarto heading opens with '#' too, headings here carry
                # inline R routinely, and `# Results for `r glue::glue(...)`` was therefore excluded from
                # the one gate that would have caught it.
                #
                # Which one a '#' line is cannot be read off the line — `# text` is a valid heading AND a
                # valid R comment, and an ATX rule alone reports every comment in every .R file. It takes
                # the file and the chunk: in .R every '#' is a comment, and in .qmd/.Rmd only those inside
                # a ```{r} fence are.
                $inChunk = $file.Extension -eq '.R'
                $lineNumber = 0
                foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                    $lineNumber++
                    if ($file.Extension -ne '.R') {
                        if ($line -match '^\s*```+\s*\{') { $inChunk = $true; continue }
                        elseif ($line -match '^\s*```+\s*$') { $inChunk = $false; continue }
                    }
                    if ($inChunk -and $line -match '^\s*#') { continue }
                    if ($line -match $pattern) {
                        '{0}:{1}' -f [IO.Path]::GetRelativePath($repoRoot, $file.FullName), $lineNumber
                    }
                }
            }

        ($offenders | Out-String).Trim() | Should -BeExactly '' -Because (
            'a translated template reaching glue::glue is evaluated as R at render time; ' +
            'use interpolate_translation() from reports/common/helpers.R')
    }

    # These four are what make this a security gate rather than a grep: the one above proves nobody CALLS
    # the unsafe function, and only these prove the safe one refuses to evaluate. Skipping them locally is
    # a convenience for a machine without R; skipping them on a runner means the property is asserted by
    # nothing at all, and reads in the log exactly like proving it. So CI is required to have R.
    Context 'the helper refuses evaluation' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

        It 'has R available, because a runner without it would silently prove nothing' -Skip:(-not $env:CI) {
            Get-Command Rscript -ErrorAction SilentlyContinue |
                Should -Not -BeNullOrEmpty -Because 'the behavioural half of this gate needs Rscript'
        }

        It 'refuses to execute a function call written into a translated string' {
            Invoke-RSnippet 'cat(tryCatch(as.character(interpolate_translation("{Sys.time()}")),
                                          error = function(e) "REFUSED"))' |
                Should -BeExactly 'REFUSED' -Because 'a catalogue is writable by anyone signed in to Weblate'
        }

        It 'refuses to read a variable from the calling frame' {
            Invoke-RSnippet 'secret <- "LEAKED"
                             cat(tryCatch(as.character(interpolate_translation("{secret}")),
                                          error = function(e) "REFUSED"))' |
                Should -BeExactly 'REFUSED' -Because 'the environment is closed, not merely non-evaluating'
        }

        It 'still resolves the values the call site supplies' {
            Invoke-RSnippet 'cat(as.character(interpolate_translation("n = {threshold}", threshold = 5)))' |
                Should -BeExactly 'n = 5' -Because 'every converted call site passes its values by name'
        }

        It 'returns the same class glue::glue did' {
            # Thirteen call sites use the result where a glue object is expected; forcing character there
            # would be an unrelated behaviour change riding along with a security fix.
            Invoke-RSnippet 'cat(class(interpolate_translation("x")), sep = ",")' |
                Should -BeExactly 'glue,character'
        }
    }
}
