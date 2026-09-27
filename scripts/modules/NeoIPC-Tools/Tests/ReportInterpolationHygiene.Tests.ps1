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
    because every report string with a placeholder is interpolated this way. A forgotten argument then
    degrades to variable disclosure rather than code execution.

    Two halves, deliberately:

    - The STRUCTURAL half bans the unsafe entry points outright and runs everywhere. It is the half that
      has to hold as call sites are added. It also keeps positional printf placeholders out of the
      strings and sprintf() away from them: a translator cannot tell what a %s stands for, and a
      translation that drops or reorders one fails nowhere but in the rendered text.
    - The BEHAVIOURAL half proves the helper actually refuses evaluation, and is skipped where R is
      absent. A ban nobody can execute is a spelling rule; this is what makes it a security property.

    On matching report code by regex, which this project otherwise forbids: there is no parser available
    here. R's own parser cannot read the corpus - a .qmd is markdown with embedded chunks, and parse() on
    one fails outright - and the CI job installs R only for the behavioural half. The pattern is lexically
    simple in exchange, and an aliased call (a bare `glue(` after library(glue)) is covered by the
    separate rule requiring non-base calls to be namespace-qualified. The string resources are YAML, and
    are read with powershell-yaml.

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

    # Every report source file as one text with each R comment line blanked, so a pattern can span a
    # call broken across lines and a line number can still be read off a match's offset.
    function Get-ReportCode {
        Get-ChildItem -LiteralPath $reportsDir -Recurse -File -Include '*.qmd', '*.Rmd', '*.R' |
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
                # a ```{r} fence are. A chunk option (`#|`) is kept: knitr evaluates an `!expr` value as R,
                # and the figure captions interpolate their translated templates there.
                $inChunk = $file.Extension -eq '.R'
                $code = foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                    if ($file.Extension -ne '.R') {
                        if ($line -match '^\s*```+\s*\{') { $inChunk = $true; ''; continue }
                        elseif ($line -match '^\s*```+\s*$') { $inChunk = $false; ''; continue }
                    }
                    if ($inChunk -and $line -match '^\s*#(?!\|)') { '' } else { $line }
                }
                [pscustomobject]@{ Path = [IO.Path]::GetRelativePath($repoRoot, $file.FullName); Text = $code -join "`n" }
            }
    }

    function Get-LineNumber {
        param([string]$Text, [int]$Offset)
        ($Text.Substring(0, $Offset) -split "`n").Count
    }

    # Returns `file:line` for every match of the pattern in report code, outside R comments.
    function Find-ReportCodeLine {
        param([string]$Pattern)
        foreach ($source in Get-ReportCode) {
            foreach ($match in [regex]::Matches($source.Text, $Pattern)) {
                '{0}:{1}' -f $source.Path, (Get-LineNumber $source.Text $match.Index)
            }
        }
    }

    # Returns `file:line` for every sprintf() or gettextf() call whose template names a string resource.
    # The template is the first argument, read up to the first comma or closing parenthesis at its own
    # depth, with quoted text skipped, so a template chosen by `if (x) sR$a else sR$b` or spread over
    # several lines is read whole, while `sprintf("%s", sR$x)` — a string resource as a value — is not.
    function Find-ReportFormatTemplate {
        foreach ($source in Get-ReportCode) {
            $text = $source.Text
            foreach ($match in [regex]::Matches($text, '\b(sprintf|gettextf)\s*\(')) {
                $start = $match.Index + $match.Length
                $depth = 0
                $quote = $null
                $end = $text.Length
                for ($i = $start; $i -lt $text.Length; $i++) {
                    $c = [string]$text[$i]
                    if ($quote) {
                        if ($c -eq '\') { $i++ } elseif ($c -eq $quote) { $quote = $null }
                        continue
                    }
                    if ($c -in '"', "'", '`') { $quote = $c }
                    elseif ($c -in '(', '[', '{') { $depth++ }
                    elseif ($c -in ')', ']', '}') {
                        if ($depth -eq 0) { $end = $i; break }
                        $depth--
                    } elseif ($c -eq ',' -and $depth -eq 0) { $end = $i; break }
                }
                if ($text.Substring($start, $end - $start) -match '\bsR\b') {
                    '{0}:{1}' -f $source.Path, (Get-LineNumber $text $match.Index)
                }
            }
        }
    }
}

Describe 'Report interpolation hygiene' {

    It 'no report file calls glue::glue or glue::glue_data on a translated template' {
        # `glue::glue(` and `glue::glue_data(` only — the trailing paren is what keeps glue_safe and
        # glue_data_safe out of the match.
        $offenders = Find-ReportCodeLine 'glue::glue(_data)?\s*\('

        ($offenders | Out-String).Trim() | Should -BeExactly '' -Because (
            'a translated template reaching glue::glue is evaluated as R at render time; ' +
            'use interpolate_translation() from reports/common/helpers.R')
    }

    It 'no report string resource carries a printf placeholder' {
        # The English sources of the string-resource cascade: the glossary, the shared strings and each
        # report's own. The translated copies are generated from these.
        $sources = @(
            Join-Path $repoRoot 'glossary.yaml'
            Join-Path $reportsDir 'common.yaml'
            Get-ChildItem -LiteralPath $reportsDir -Recurse -File -Filter '_sR.yaml' |
                Where-Object { $_.Directory.Name -eq 'content' } |
                ForEach-Object FullName
        )
        # A conversion with its position, flags, width and precision. A space is left out of the flags,
        # so that "10 % of" in prose is not read as the conversion `% o`.
        $printf = '%(\d+\$)?[-+0#]*\d*(\.\d+)?[sdifeEgGxXoc]'
        $offenders = foreach ($source in $sources) {
            $pending = [System.Collections.Generic.Stack[object]]::new()
            $pending.Push([pscustomobject]@{
                Path  = ''
                Value = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $source -Raw) -Ordered
            })
            while ($pending.Count -gt 0) {
                $node = $pending.Pop()
                if ($node.Value -is [System.Collections.IDictionary]) {
                    foreach ($key in $node.Value.Keys) {
                        $pending.Push([pscustomobject]@{ Path = "$($node.Path).$key"; Value = $node.Value[$key] })
                    }
                } elseif ($node.Value -is [System.Collections.IList]) {
                    for ($i = 0; $i -lt $node.Value.Count; $i++) {
                        $pending.Push([pscustomobject]@{ Path = "$($node.Path)[$i]"; Value = $node.Value[$i] })
                    }
                } elseif ($node.Value -is [string] -and $node.Value -match $printf) {
                    '{0}: {1}' -f [IO.Path]::GetRelativePath($repoRoot, $source), $node.Path.TrimStart('.')
                }
            }
        }

        ($offenders | Sort-Object | Out-String).Trim() | Should -BeExactly '' -Because (
            'a translator cannot tell what a positional placeholder stands for; ' +
            'write a {named} placeholder and fill it with interpolate_translation()')
    }

    It 'no report file formats a string resource with sprintf' {
        $offenders = Find-ReportFormatTemplate

        ($offenders | Out-String).Trim() | Should -BeExactly '' -Because (
            'a string resource used as a sprintf template hands translators positional placeholders; ' +
            'use interpolate_translation() with named values')
    }

    # These are what make this a security gate rather than a grep: the first test above proves nobody
    # CALLS the unsafe function, and only these prove the safe one refuses to evaluate. Skipping them locally is
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

        # A literal is the ONE shape that survives the defect these two exist to catch: glue evaluates
        # its arguments in .envir, and a constant needs no lookup there while a variable cannot be found
        # at all. So the assertion above passes against a helper that resolves nothing a real call site
        # passes, and did. No call site passes a constant as a data value — the six literals in the tree
        # are all .open/.close — so these are the shapes that actually ship.
        It 'resolves a value passed as a variable, not only as a literal' {
            Invoke-RSnippet 'sparse_threshold <- 5
                             cat(as.character(interpolate_translation("n = {threshold}",
                                                                      threshold = sparse_threshold)))' |
                Should -BeExactly 'n = 5' -Because (
                    'a variable must resolve; the literal case above passes even against a helper ' +
                    'that resolves nothing, because a constant needs no lookup')
        }

        It 'resolves a list-element lookup, the shape the outlier clauses use' {
            Invoke-RSnippet 'pairing <- list(metric_label = "pneumonia rate")
                             cat(as.character(interpolate_translation("The {metric_label}",
                                                                      metric_label = pairing$metric_label)))' |
                Should -BeExactly 'The pneumonia rate'
        }

        It 'refuses an unnamed value, which glue appends to the template' {
            Invoke-RSnippet 'cat(tryCatch(as.character(interpolate_translation("{v} ", quote(secret), v = 1)),
                                          error = function(e) "REFUSED"))' |
                Should -BeExactly 'REFUSED' -Because (
                    'an unnamed argument is template text rather than data, and is the one shape whose ' +
                    'value can still be evaluated outside the closed environment')
        }

        It 'refuses a zero-length value, which would collapse the whole string' {
            Invoke-RSnippet 'cat(tryCatch(as.character(interpolate_translation("in {d}.", d = NULL)),
                                          error = function(e) "REFUSED"))' |
                Should -BeExactly 'REFUSED' -Because 'a collapsed interpolation deletes the sentence silently'
        }

        It 'returns the same class glue::glue did' {
            # Thirteen call sites use the result where a glue object is expected; forcing character there
            # would be an unrelated behaviour change riding along with a security fix.
            Invoke-RSnippet 'cat(class(interpolate_translation("x")), sep = ",")' |
                Should -BeExactly 'glue,character'
        }
    }

    # No CI job renders a report, and a render is the only other place a mismatch between a template and
    # its call shows: a placeholder with no value aborts the render, and a value with no placeholder is
    # dropped from the sentence without a word.
    Context 'every interpolation of a string resource' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

        It 'passes exactly the placeholders of its English template' {
            $check = @'
# The R code of a report file: an .R file whole; of a .qmd or .Rmd its chunks, the `!expr` values of
# its chunk options and its inline spans. Read by hand rather than purled, since knitr evaluates chunk
# options when it purls.
code_of <- function(file) {
  lines <- readLines(file, warn = FALSE, encoding = "UTF-8")
  if (grepl("\\.R$", file)) return(lines)
  code <- character()
  in_chunk <- FALSE
  for (line in lines) {
    if (grepl("^\\s*```+\\s*\\{r", line)) { in_chunk <- TRUE; next }
    if (in_chunk && grepl("^\\s*```", line)) { in_chunk <- FALSE; next }
    if (in_chunk && !grepl("^\\s*#\\|", line)) code <- c(code, line)
  }
  c(code,
    unlist(regmatches(lines, gregexpr("(?<=!expr ').*(?='\\s*$)", lines, perl = TRUE))),
    unlist(regmatches(lines, gregexpr("(?<=`r ).*?(?=`)", lines, perl = TRUE))))
}

escape_regex <- function(x) gsub("([][{}()*+?.\\\\^$|])", "\\\\\\1", x)

placeholders <- function(text, open = "{", close = "}") {
  pattern <- paste0(escape_regex(open), "([A-Za-z_][A-Za-z0-9_]*)", escape_regex(close))
  unique(sub(pattern, "\\1", unlist(regmatches(text, gregexpr(pattern, text)))))
}

# The variables an expression reads. all.vars() would also count the name after `$`, which is a
# key, not a variable.
variables_of <- function(e) {
  if (is.name(e)) return(as.character(e))
  if (!is.call(e)) return(character())
  if (identical(e[[1]], as.name("$"))) return(variables_of(e[[2]]))
  unique(unlist(lapply(as.list(e)[-1], variables_of)))
}

# The templates an expression can yield: a string-resource path, or either branch of an if/else
# between two. Anything else (a template held in a variable, one looked up by a computed key) yields
# none and is left to the render.
templates_of <- function(e) {
  if (is.call(e) && identical(e[[1]], as.name("if")) && length(e) == 4L)
    return(c(templates_of(e[[3]]), templates_of(e[[4]])))
  if (identical(variables_of(e), "sR")) list(e) else list()
}

findings <- character()
checked <- 0L
walk <- function(e, file, sR) {
  if (!is.call(e)) return(invisible())
  if (identical(e[[1]], as.name("interpolate_translation"))) {
    arguments <- as.list(e)[-(1:2)]
    # A name starting with a dot is glue's own argument, such as the delimiters, not a value.
    values <- setdiff(names(arguments), "")
    values <- values[!startsWith(values, ".")]
    open <- if (is.character(arguments$.open)) arguments$.open else "{"
    close <- if (is.character(arguments$.close)) arguments$.close else "}"
    for (template in templates_of(e[[2]])) {
      source <- paste(deparse(template), collapse = "")
      text <- tryCatch(eval(template, list(sR = sR)), error = function(err) NULL)
      if (!is.character(text) || length(text) != 1L) {
        findings <<- c(findings, sprintf("%s: %s names no string", file, source))
      } else if (!setequal(placeholders(text, open, close), values)) {
        findings <<- c(findings, sprintf(
          "%s: %s has placeholders {%s} but the call passes {%s}", file, source,
          paste(sort(placeholders(text, open, close)), collapse = ", "),
          paste(sort(values), collapse = ", ")))
      }
      checked <<- checked + 1L
    }
  }
  for (argument in as.list(e)[-1]) if (!missing(argument)) walk(argument, file, sR)
}

for (report in list.dirs(reports, recursive = FALSE)) {
  if (!file.exists(file.path(report, "content", "_sR.yaml"))) next
  old <- setwd(report)
  localeObj <- list(language = "en", territory = NULL)
  sR <- get_string_resources(localeObj)
  files <- list.files(".", pattern = "\\.(qmd|Rmd|R)$", recursive = TRUE)
  # Generated translations: the content.<lang> copies, the per-language prose directories other than
  # the English sources, and the per-language wrappers.
  files <- files[!grepl("^content\\.", files) &
                 !grepl("^(?!en/)[a-z]{2}(-[A-Z]{2})?/", files, perl = TRUE) &
                 !grepl("\\.[a-z]{2}(-[A-Z]{2})?\\.qmd$", files)]
  for (file in files) {
    exprs <- tryCatch(parse(text = code_of(file), keep.source = FALSE),
                      error = function(err) {
                        findings <<- c(findings, sprintf("%s/%s does not parse: %s", basename(report),
                                                         file, conditionMessage(err)))
                        NULL
                      })
    for (e in exprs) walk(e, paste0(basename(report), "/", file), sR)
  }
  setwd(old)
}
cat(sprintf("CHECKED %d\n", checked))
cat(findings, sep = "\n")
'@
            $output = Invoke-RSnippet ("reports <- '$($reportsDir -replace '\\', '/')'`n" + $check)
            $output | Should -Match 'CHECKED [1-9]' -Because 'a check that reads no call proves nothing'
            ($output -replace 'CHECKED \d+', '').Trim() | Should -BeExactly '' -Because (
                'a placeholder without a value aborts the render, and a value without a placeholder ' +
                'drops out of the sentence silently')
        }
    }
}
