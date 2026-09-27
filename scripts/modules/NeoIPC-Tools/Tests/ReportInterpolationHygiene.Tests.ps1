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
      Beside it, and on the same R, every interpolation of a string resource is held to the
      placeholders of its English template, read from the report code with R's own parser.

    The structural half matches report code by regex, which this project otherwise forbids, because it
    has to run where R is absent, and R's parser cannot read a .qmd whole: it is markdown with embedded
    chunks, and parse() on one fails outright. The pattern is lexically simple in exchange, and an
    aliased call (a bare `glue(` after library(glue)) is covered by the separate rule requiring non-base
    calls to be namespace-qualified. The R-backed check first reads a report file's chunks, the options
    written into its chunk headers, and its `!expr` values and inline spans where each fits on one
    line, and parses what it read. The string resources are YAML, and are read with powershell-yaml.

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
# The R code of a report file, in the order it runs: an .R file whole; of a .qmd or .Rmd its chunks,
# the options written into a chunk's header, the `!expr` values of its chunk options and of the
# front matter, and its inline spans in knitr's `r …` form and Quarto's `{r} …` form. An `!expr`
# value and an inline span are read when they fit on one line; a mention the reading misses is caught
# by the count in check_file(). Read by hand rather than purled, since knitr evaluates chunk options
# when it purls.
code_of <- function(file) {
  lines <- readLines(file, warn = FALSE, encoding = "UTF-8")
  if (grepl("\\.R$", file)) return(lines)
  spans <- function(line, patterns)
    unlist(lapply(patterns, function(p) regmatches(line, gregexpr(p, line, perl = TRUE))[[1]]))
  option_values <- c("(?<=!expr ').*(?='\\s*(?:#.*)?$)", "(?<=!expr \").*(?=\"\\s*(?:#.*)?$)",
                     "(?<=!expr )(?!['\"]).*?(?=\\s+#|\\s*$)")
  inline_spans <- c("(?<=`r ).*?(?=`)", "(?<=`\\{r\\} ).*?(?=`)")
  code <- character()
  in_chunk <- FALSE
  for (line in lines) {
    if (!in_chunk && grepl("^\\s*```+\\s*\\{r", line)) {
      in_chunk <- TRUE
      header <- sub("\\}\\s*$", "", sub("^\\s*```+\\s*\\{r\\s*,?\\s*", "", line))
      # knitr takes a first element without `=` as the chunk's label.
      if (!grepl("=", sub(",.*$", "", header))) header <- sub("^[^,]*,?", "", header)
      if (grepl("=", header)) code <- c(code, paste0("list(", header, ")"))
    } else if (in_chunk && grepl("^\\s*```", line)) {
      in_chunk <- FALSE
    } else if (in_chunk && !grepl("^\\s*#\\|", line)) {
      code <- c(code, line)
    } else {
      code <- c(code, spans(line, if (in_chunk) option_values else c(option_values, inline_spans)))
    }
  }
  code
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

# What an expression can hold as a template: the string-resource paths it can yield, and whether any
# part of it could not be followed.
unknown <- list(templates = list(), unresolved = TRUE)
nothing <- list(templates = list(), unresolved = FALSE)
join <- function(...) {
  parts <- list(...)
  list(templates = Reduce(c, lapply(parts, `[[`, "templates"), list()),
       unresolved = any(vapply(parts, `[[`, logical(1), "unresolved")))
}

# The templates an expression can yield: a string-resource path, or a literal; a variable, through the
# values its bindings hold at this point; an if/else, a switch or a braced block, through each value it
# can yield; a fixed key looked up on any of these. Anything else leaves the expression unresolved: a
# key computed at render time, a function's parameter, a function's result. An empty literal yields
# nothing, since it stands for "no sentence" rather than a template.
resolve <- function(e, b) {
  if (is.null(e)) return(nothing)
  if (is.character(e))
    return(if (length(e) == 1L && nzchar(e)) list(templates = list(e), unresolved = FALSE) else nothing)
  if (is.name(e)) {
    name <- as.character(e)
    if (!nzchar(name)) return(nothing)
    if (name == "sR") return(list(templates = list(e), unresolved = FALSE))
    if (name %in% names(b))
      return(if (name %in% rebound) join(b[[name]], unknown) else b[[name]])
    return(unknown)
  }
  if (!is.call(e)) return(unknown)
  head <- e[[1]]
  if (identical(head, as.name("if")))
    return(if (length(e) == 4L) join(resolve(e[[3]], b), resolve(e[[4]], b)) else resolve(e[[3]], b))
  if (identical(head, as.name("switch"))) {
    parts <- list()
    for (alternative in as.list(e)[-(1:2)])
      if (!missing(alternative)) parts <- c(parts, list(resolve(alternative, b)))
    return(do.call(join, parts))
  }
  if (identical(head, as.name("{"))) return(if (length(e) > 1L) resolve(e[[length(e)]], b) else nothing)
  if (identical(head, as.name("("))) return(resolve(e[[2]], b))
  if (identical(head, as.name("$")) ||
      (identical(head, as.name("[[")) && length(e) == 3L && is.character(e[[3]]))) {
    inner <- resolve(e[[2]], b)
    return(list(templates = lapply(inner$templates, function(t) { e[[2]] <- t; e }),
                unresolved = inner$unresolved))
  }
  if (identical(variables_of(e), "sR")) return(list(templates = list(e), unresolved = FALSE))
  unknown
}

# The bindings after two paths that may each have been taken, such as the branches of an if/else.
merge_bindings <- function(b1, b2) {
  for (name in names(b2))
    if (!identical(b1[[name]], b2[[name]]))
      b1[[name]] <- if (name %in% names(b1)) join(b1[[name]], b2[[name]]) else b2[[name]]
  b1
}

# The interpolations whose template no static reading can follow, keyed by file, function and
# template expression, each with what stands in for the reading. `templates` lists, under sR, every
# template the expression can hold, and they are checked like any other; a template the check can see
# the expression hold must be among them. `rule = "subset"` lets the call pass values a template does
# not use, for a composer that fills whichever template it picked from one set of values. `unchecked`
# says why nothing is checked here. An entry no call reaches is itself a finding, so the list cannot
# outlive the code it describes.
declared <- list(
  "Partner-Report/_setup.qmd in select_clause(): clause_template" = list(
    rule = "subset",
    templates = paste0("outlier$composed$clause_", c(
      "concordant_high", "concordant_low", "concordant_high_pooled", "concordant_low_pooled",
      "discordant_high", "discordant_low", "discordant_high_pooled", "discordant_low_pooled",
      "within_iqr", "no_quartiles"))),
  "common/helpers.R in labels_for(): template" = list(
    unchecked = "labels_for() hands its template and values on unchanged, and its calls are checked"),
  "Validation-Report/_problem_text.qmd in problem_text(): interpolate_translation passed as a value" = list(
    unchecked = paste("do.call() fills a rule's sentence from its finding's context fields, and the",
                      "report's setup holds every template to neoipcr's context fields before it renders")))
# Functions that hand a template and its values to interpolate_translation() unchanged, whose calls are
# checked as interpolations.
wrappers <- "labels_for"

findings <- character()
reached <- character()
calls_seen <- character()
templates_seen <- character()
# Per file: the variables bound somewhere this walk does not follow in order (through assign(), or
# `<<-` inside a function), and how many mentions of interpolate_translation the checking walk reached.
rebound <- character()
mentions_read <- 0L
# The report whose strings the shared code is being checked against, "" for a report's own code, and
# for each template the shared code names, the reports whose strings lack it.
cascade <- ""
missing_in <- list()
# Off while a pass only gathers bindings: the first pass over a loop body, over a function body and
# over a file. Such a pass also keeps every value a variable is ever assigned rather than the last.
checking <- TRUE
quietly <- function(expr) {
  previous <- checking
  checking <<- FALSE
  on.exit(checking <<- previous)
  expr
}
finding <- function(...) findings <<- c(findings, sprintf(...))
key_of <- function(file, scope, what)
  paste0(file, if (nzchar(scope)) paste0(" in ", scope, "()"), ": ", what)
sources_of <- function(templates)
  vapply(templates, function(t) paste(deparse(t), collapse = ""), character(1))

check_call <- function(e, file, scope, sR, b) {
  if (!checking) return(invisible())
  call_text <- paste(deparse(e, width.cutoff = 500L), collapse = " ")
  calls_seen <<- union(calls_seen, paste(file, call_text))
  if (length(e) < 2L) return(finding("%s: %s names no template", file, call_text))
  expression <- e[[2]]
  arguments <- as.list(e)[-(1:2)]
  argument_names <- names(arguments)
  if (is.null(argument_names)) argument_names <- rep("", length(arguments))
  forwarded <- vapply(arguments, identical, logical(1), as.name("..."))
  if (any(!nzchar(argument_names) & !forwarded))
    finding("%s: %s passes a value without a name, which glue would append to the sentence",
            file, call_text)
  # A name starting with a dot is glue's own argument, such as the delimiters, not a value.
  values <- argument_names[nzchar(argument_names) & !startsWith(argument_names, ".")]
  delimiters <- arguments[intersect(c(".open", ".close"), argument_names)]
  if (!all(vapply(delimiters, is.character, logical(1))))
    return(finding("%s: %s sets a delimiter this reading cannot see", file, call_text))
  open <- if (is.character(arguments[[".open"]])) arguments[[".open"]] else "{"
  close <- if (is.character(arguments[[".close"]])) arguments[[".close"]] else "}"
  key <- key_of(file, scope, paste(deparse(expression), collapse = " "))
  r <- resolve(expression, b)
  rule <- "exact"
  if (key %in% names(declared)) {
    reached <<- union(reached, key)
    if (!is.null(declared[[key]]$unchecked)) return(invisible())
  }
  if (any(forwarded))
    return(finding(paste("%s: %s forwards `...`, whose values this reading cannot see;",
                         "declare it with the reason"), file, call_text))
  if (key %in% names(declared)) {
    candidates <- lapply(declared[[key]]$templates, function(path) str2lang(paste0("sR$", path)))
    unlisted <- setdiff(sources_of(r$templates), sources_of(candidates))
    if (length(unlisted))
      finding("%s: %s can hold %s, which its declaration does not list", file,
              paste(deparse(expression), collapse = " "), paste(unlisted, collapse = ", "))
    rule <- declared[[key]]$rule
  } else {
    if (r$unresolved || length(r$templates) == 0L)
      return(finding(paste("%s: the template of %s cannot be followed to a string resource here;",
                           "write it as a path under sR, or declare it with the reason"), file, call_text))
    candidates <- r$templates
  }
  sources <- sources_of(candidates)
  where <- if (nzchar(cascade)) sprintf("%s with %s's strings", file, cascade) else file
  for (i in which(!duplicated(sources))) {
    templates_seen <<- union(templates_seen, paste(file, sources[[i]]))
    text <- tryCatch(eval(candidates[[i]], list(sR = sR)), error = function(err) NULL)
    if (!is.character(text) || length(text) != 1L) {
      if (nzchar(cascade)) {
        missing_key <- sprintf("%s: %s", file, sources[[i]])
        missing_in[[missing_key]] <<- union(missing_in[[missing_key]], cascade)
      } else {
        finding("%s: %s names no string", file, sources[[i]])
      }
      next
    }
    expected <- placeholders(text, open, close)
    fits <- if (identical(rule, "subset")) all(expected %in% values) else setequal(expected, values)
    if (!fits)
      finding("%s: %s has placeholders {%s} but the call passes {%s}", where, sources[[i]],
              paste(sort(expected), collapse = ", "), paste(sort(values), collapse = ", "))
  }
}

# Walks an expression in evaluation order, checking every interpolation against the bindings made so
# far, and returns the bindings after it. `scope` names the function the code is in, "" at the top
# level, and `final` holds every value the code around a function body ever assigns, which is what the
# function reads its free variables from when it is called.
walk <- function(e, file, scope, sR, b, final) {
  if (is.name(e) || (is.character(e) && length(e) == 1L)) {
    if (checking && identical(as.character(e), "interpolate_translation")) {
      mentions_read <<- mentions_read + 1L
      key <- key_of(file, scope, "interpolate_translation passed as a value")
      if (key %in% names(declared)) reached <<- union(reached, key)
      else finding("%s: interpolate_translation is passed as a value, so its template cannot be read", file)
    }
    return(b)
  }
  if (!is.call(e)) return(b)
  head <- e[[1]]
  if (length(e) == 3L && (identical(head, as.name("<-")) || identical(head, as.name("=")) ||
                          identical(head, as.name("<<-")))) {
    target <- e[[2]]
    value <- e[[3]]
    if (identical(target, as.name("interpolate_translation")) && checking)
      mentions_read <<- mentions_read + 1L
    if (is.name(target) && is.call(value) && identical(value[[1]], as.name("function"))) {
      walk(value, file, as.character(target), sR, b, final)
      b[[as.character(target)]] <- unknown
      return(b)
    }
    b <- walk(value, file, scope, sR, b, final)
    # An assignment into part of a variable (x$a <-, x[["a"]] <-, names(x) <-) leaves it holding
    # something this reading does not follow.
    if (is.call(target)) {
      b <- walk(target, file, scope, sR, b, final)
      root <- target
      while (is.call(root) && length(root) >= 2L) root <- root[[2]]
      if (is.name(root) && !identical(root, as.name("sR")) && as.character(root) %in% names(b))
        b[[as.character(root)]] <- join(b[[as.character(root)]], unknown)
      return(b)
    }
    # `<<-` inside a function binds a variable of the code around it, at a time this walk does not
    # know.
    if (is.name(target) && identical(head, as.name("<<-")) && nzchar(scope))
      rebound <<- union(rebound, as.character(target))
    # sR is the string resources whatever builds it: the cascade, or a layer merged onto it.
    if (is.name(target) && !identical(target, as.name("sR"))) {
      name <- as.character(target)
      b[[name]] <- if (!checking && name %in% names(b)) join(b[[name]], resolve(value, b))
                   else resolve(value, b)
    }
    return(b)
  }
  if ((identical(head, as.name("assign")) || identical(head, quote(base::assign))) &&
      length(e) >= 3L && is.character(e[[2]]))
    rebound <<- union(rebound, e[[2]])
  if (identical(head, as.name("function"))) {
    inner <- merge_bindings(b, final)
    for (parameter in setdiff(names(e[[2]]), "sR")) inner[[parameter]] <- unknown
    for (default in as.list(e[[2]])) if (!missing(default)) walk(default, file, scope, sR, inner, final)
    body_final <- quietly(walk(e[[3]], file, scope, sR, inner, inner))
    walk(e[[3]], file, scope, sR, inner, body_final)
    return(b)
  }
  if (identical(head, as.name("if"))) {
    b <- walk(e[[2]], file, scope, sR, b, final)
    taken <- walk(e[[3]], file, scope, sR, b, final)
    other <- if (length(e) == 4L) walk(e[[4]], file, scope, sR, b, final) else b
    return(merge_bindings(taken, other))
  }
  if (identical(head, as.name("switch"))) {
    b <- walk(e[[2]], file, scope, sR, b, final)
    after <- b
    for (alternative in as.list(e)[-(1:2)])
      if (!missing(alternative)) after <- merge_bindings(after, walk(alternative, file, scope, sR, b, final))
    return(after)
  }
  # A loop's later passes see what its earlier ones assigned, so the body is walked again from the
  # bindings a first pass leaves.
  if (identical(head, as.name("for"))) {
    b <- walk(e[[3]], file, scope, sR, b, final)
    b[[as.character(e[[2]])]] <- unknown
    looped <- merge_bindings(b, quietly(walk(e[[4]], file, scope, sR, b, final)))
    return(merge_bindings(b, walk(e[[4]], file, scope, sR, looped, final)))
  }
  if (identical(head, as.name("while"))) {
    looped <- merge_bindings(b, quietly(
      walk(e[[3]], file, scope, sR, walk(e[[2]], file, scope, sR, b, final), final)))
    return(merge_bindings(b, walk(e[[3]], file, scope, sR,
                                  walk(e[[2]], file, scope, sR, looped, final), final)))
  }
  if (identical(head, as.name("repeat"))) {
    looped <- merge_bindings(b, quietly(walk(e[[2]], file, scope, sR, b, final)))
    return(merge_bindings(b, walk(e[[2]], file, scope, sR, looped, final)))
  }
  if (identical(head, as.name("interpolate_translation")) && checking)
    mentions_read <<- mentions_read + 1L
  if (identical(head, as.name("interpolate_translation")) ||
      (is.name(head) && as.character(head) %in% wrappers))
    check_call(e, file, scope, sR, b)
  # A function looked up by a call, as in get("…")(…), is code too.
  if (is.call(head)) b <- walk(head, file, scope, sR, b, final)
  for (argument in as.list(e)[-1]) if (!missing(argument)) b <- walk(argument, file, scope, sR, b, final)
  b
}

# The mentions of interpolate_translation in a file outside R comments, counted in its text rather
# than in what code_of() read, so that code the reading misses shows as a difference.
mentions_in <- function(file) {
  lines <- readLines(file, warn = FALSE, encoding = "UTF-8")
  comment <- grepl("^\\s*#(?!\\|)", lines, perl = TRUE)
  if (!grepl("\\.R$", file)) {
    fence <- grepl("^\\s*```", lines)
    in_chunk <- (cumsum(fence) %% 2L == 1L) & !fence
    comment <- comment & in_chunk
  }
  code <- lines[!comment]
  sum(lengths(regmatches(code, gregexpr("\\binterpolate_translation\\b", code, perl = TRUE))))
}

# A file is walked twice: once to gather every value its top level ever assigns, which a function
# defined in it may read when it is called, and once to check it. Every mention of the helper in its
# text must be one the checking walk reached.
check_file <- function(file, label, sR) {
  exprs <- tryCatch(parse(text = code_of(file), keep.source = FALSE),
                    error = function(err) {
                      finding("%s does not parse: %s", label, conditionMessage(err))
                      NULL
                    })
  walk_all <- function(final) {
    b <- list()
    for (e in exprs) b <- walk(e, label, "", sR, b, final)
    b
  }
  rebound <<- character()
  mentions_read <<- 0L
  walk_all(quietly(walk_all(list())))
  mentions <- mentions_in(file)
  if (mentions != mentions_read)
    finding("%s mentions interpolate_translation %d times, but this reading reached %d of them",
            label, mentions, mentions_read)
}

cascades <- list()
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
  for (file in files) check_file(file, paste0(basename(report), "/", file), sR)
  cascades[[basename(report)]] <- sR
  setwd(old)
}

# The shared code every report sources, against each report's strings, since a report may override a
# shared template. A template one report lacks matters only if that report calls the code, so a
# missing template is a finding when no report has it.
for (file in list.files(file.path(reports, "common"), pattern = "\\.(qmd|Rmd|R)$")) {
  for (name in names(cascades)) {
    cascade <- name
    check_file(file.path(reports, "common", file), paste0("common/", file), cascades[[name]])
  }
}
cascade <- ""
for (key in names(missing_in))
  if (length(missing_in[[key]]) == length(cascades)) finding("%s names no string", key)

for (key in setdiff(names(declared), reached))
  finding("the declaration for %s is reached by no call", key)
cat(sprintf("CHECKED %d calls, %d templates\n", length(calls_seen), length(templates_seen)))
cat(unique(findings), sep = "\n")
'@
            $output = Invoke-RSnippet ("reports <- '$($reportsDir -replace '\\', '/')'`n" + $check)
            $output | Should -Match 'CHECKED [1-9]' -Because 'a check that reads no call proves nothing'
            ($output -replace '(?m)^CHECKED .*$', '').Trim() | Should -BeExactly '' -Because (
                'a placeholder without a value aborts the render, a value without a placeholder ' +
                'drops out of the sentence silently, and a call the check cannot read is one it ' +
                'would not notice breaking')
        }
    }
}
