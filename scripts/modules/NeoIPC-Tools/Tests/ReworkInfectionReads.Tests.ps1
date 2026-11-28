#Requires -Version 7.6
#requires -Module Pester
#requires -Module powershell-yaml

<#
.SYNOPSIS
    Pester gate for the reworked infection reads of both reports.

.DESCRIPTION
    The December edition replaces three pooled figures in the Reference and Partner Reports with
    figures the reader can act on: the infection section opens with counts instead of a mean of
    infections per patient, which has no time base; the infectious-agent texts quote the share per
    infection type instead of the pooled detection rate, which depends on each department's mix of
    infection types; and the sepsis and NEC kinds, the exposed patients and their mean days, and the
    departments' follow-up enter where the pooled figure alone stood. Each substitution is a read
    removed as much as a read added, and a left-behind pooled read renders a figure the methods text
    no longer explains. The gate holds both halves of that substitution:

    - The STRUCTURAL half reads the report sources and the three English string layers as text and
      YAML, and runs everywhere. It names the dataset row keys of the kinds (bsi_recognized,
      bsi_commensal, bsi_clinical, nec_surgical, nec_medical) and the column carrying the count the
      recognized-pathogen footnote shows, so the reports and the package cannot drift from one
      another silently; a recoded key that the dataset never carries drops its row from the table
      without a word, which is the failure this half exists to catch. It matches only the reports'
      own literals, so a rename on the package side escapes it and surfaces only in a real render:
      the dataset names it holds stand agreed with the package change that computes them.
    - The BEHAVIOURAL half executes the shared helpers under R and is skipped where Rscript is
      absent, as the interpolation gate's half is; on CI its presence assertion makes an absent R
      a failure, not a silence.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/ReworkInfectionReads.Tests.ps1
#>

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $reportsDir = Join-Path $repoRoot 'reports'
    $helpers = Join-Path $reportsDir 'common' 'helpers.R'
    $rscript = (Get-Command Rscript -ErrorAction SilentlyContinue)?.Source

    # Runs an R snippet against a freshly sourced helpers.R and returns its stdout, so each
    # assertion is independent of the others' bindings, as in ReportInterpolationHygiene.Tests.ps1.
    # The existence guard is load-bearing: an ABSENT function also prints no PASS, and the guard
    # keeps that failure a refusal rather than an accident of the snippet.
    function Invoke-RSnippet {
        param([string]$Body, [string[]]$Guard)
        $guardLines = ($Guard | ForEach-Object {
            'stopifnot(exists("{0}"), is.function(get("{0}")))' -f $_
        }) -join "`n"
        $script = "source('$($helpers -replace '\\', '/')')`n$guardLines`n$Body"
        $file = New-TemporaryFile
        try {
            [System.IO.File]::WriteAllText($file.FullName, $script, [System.Text.UTF8Encoding]::new($false))
            (& $rscript --vanilla $file.FullName 2>&1) -join "`n"
        } finally {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    function Get-ReportSource {
        param([string]$RelativePath)
        (Get-Content -LiteralPath (Join-Path $reportsDir $RelativePath) -Raw)
    }

    # Every report source text (R, R Markdown, Quarto, YAML) outside the generated language layers,
    # as "file:text" pairs the pattern searches.
    function Get-AllReportSources {
        Get-ChildItem -LiteralPath $reportsDir -Recurse -File -Include '*.qmd', '*.Rmd', '*.R', '*.yaml' |
            Where-Object { $_.FullName -notmatch '[\\/]+content\.[a-z]' } |
            ForEach-Object {
                [pscustomobject]@{
                    Path = [IO.Path]::GetRelativePath($repoRoot, $_.FullName)
                    Text = Get-Content -LiteralPath $_.FullName -Raw
                }
            }
    }

    function Find-ReportSourceMatching {
        param([string]$Pattern)
        (Get-AllReportSources | Where-Object { $_.Text -match $Pattern }).Path
    }

    function Get-EnglishStringLayer {
        param([string]$RelativePath)
        ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $reportsDir $RelativePath) -Raw)
    }

    # The {named} placeholders of a translatable string, as the string resources define them.
    function Get-StringPlaceholders {
        param([string]$Value)
        @([regex]::Matches($Value, '\{([a-z_][a-z0-9_]*)\}') | ForEach-Object { $_.Groups[1].Value })
    }
}

Describe 'The infection section opens with counts, not a mean' {

    # The skip re-asks for Rscript at discovery, where Pester evaluates -Skip;
    # a BeforeAll variable is still unset at that moment, as in
    # ReportInterpolationHygiene.Tests.ps1.
    Context 'the dataset resources carry the counts' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

        It 'Rscript is present on CI because the behavioural half needs it' {
            $rscript | Should -Not -BeNullOrEmpty -Because 'the behavioural half of this gate needs Rscript'
        }

        It 'formats the patients with at least one severe infection and drops the mean' {
            $out = Invoke-RSnippet -Guard @('format_dataset_resources') -Body @'
counts <- list(n_departments = 7L, n_patients = 100L, n_enrollments = 120L,
               n_patient_days = 400L, n_severe_infections = 30L,
               n_patients_with_severe_infection = 25L)
sR <- list(headerList = list(allBirthweights = "all", allGestationalAges = "all"),
           not_available = "n/a", unit_separator = " ", percent_symbol = "%",
           digit_group_separator = " ")
out <- format_dataset_resources(list(), counts, sR)
without <- format_dataset_resources(
  list(), counts[names(counts) != "n_patients_with_severe_infection"], sR)
ok <- identical(out$numberOfPatientsWithSevereInfection, "25") &&
      is.null(out$averageSevereInfectionsPerPatient) &&
      is.null(without$numberOfPatientsWithSevereInfection)
cat(if (ok) "PASS" else "FAIL", "\n")
'@
            $out | Should -MatchExactly '\bPASS\b' -Because 'the opening gives counts, the mean of infections per patient has no time base, and a dataset without the slot leaves the field out'
        }
    }

    Context 'no read of the mean is left behind' {

        It 'no report source references averageSevereInfectionsPerPatient' {
            Find-ReportSourceMatching 'averageSevereInfectionsPerPatient' | Should -BeNullOrEmpty -Because 'the mean per patient leaves with the counts sentence that replaces it'
        }

        It 'both openings add the patients clause only when the dataset has the count' {
            foreach ($file in 'Reference-Report/content/_nosocomial_infections.Rmd',
                              'Partner-Report/content/_nosocomial_infections.Rmd') {
                $text = Get-ReportSource $file
                $text | Should -Match 'were recorded`r nosocomial_patients_clause`\.' -Because "$file ends the opening at the infections when the clause has no figure"
            }
            $common = Get-EnglishStringLayer 'common.yaml'
            $common.nosocomial_patients_clause | Should -Match 'had at least one' -Because 'the clause names what the slot counts'
            (Get-StringPlaceholders $common.nosocomial_patients_clause) |
                Sort-Object | Should -Be @('infected_count', 'patient_count') -Because 'the clause gives the patients and their denominator'
            foreach ($file in 'Reference-Report/_setup.qmd', 'Partner-Report/_setup.qmd') {
                $text = Get-ReportSource $file
                $text | Should -Match 'n_patients_with_severe_infection' -Because "$file reads the slot"
                # The marker beside the clause guard, not merely somewhere in
                # the file: an older marker for another read must not stand in
                # for the one this path needs.
                $text | Should -Match 'NEOIPC-PERMANENT\(dataset-format\)[\s\S]{0,700}?interpolate_translation\(\s*sR\$nosocomial_patients_clause' -Because "$file marks the stored-dataset path the clause guard walks, at the guard"
            }
        }

        It 'the reference comparison stands without the patients count' {
            $text = Get-ReportSource 'Partner-Report/_setup.qmd'
            # The reference infection figure and the patients clause stand on
            # their own guards: a stored reference dataset without the slot
            # still has the figure, and only the clause leaves.
            $text | Should -Match 'ref_counts\$n_severe_infections\) == 1L' -Because 'the reference sentence guards only the infection count'
            $text | Should -Match 'numberOfPatientsWithSevereInfection\) == 1L' -Because 'the patients clause guards the patients count on its own'
            $sR = Get-EnglishStringLayer 'Partner-Report/content/_sR.yaml'
            $sR.nosocomial_reference_infections | Should -Not -Match 'patient' -Because 'the reference sentence itself carries no patient figure'
            (Get-StringPlaceholders $sR.nosocomial_reference_infections) |
                Sort-Object | Should -Be @('infection_count') -Because 'the reference sentence gives only the infection count'
            $common = Get-EnglishStringLayer 'common.yaml'
            $common.nosocomial_patients_clause | Should -Match 'had at least one' -Because 'the shared clause the comparison reuses names the patients'
        }

        It 'the count-dependent clauses carry their singular forms' {
            $common = Get-EnglishStringLayer 'common.yaml'
            $common.nosocomial_patients_clause_one | Should -Match '\bpatient had\b' -Because 'one patient reads "1 of 1 patient"'
            $clauseBlock = $common.'agent-type-clauses'
            foreach ($base in 'bsi', 'hap', 'ssi', 'ssi_alone') {
                $clauseBlock.$base | Should -Not -BeNullOrEmpty
            }
            foreach ($key in 'bsi_total_one', 'hap_tested_one', 'hap_total_one',
                              'hap_not_tested', 'hap_total_one_not_tested',
                              'ssi_tested_one', 'ssi_total_one', 'ssi_not_tested',
                              'ssi_total_one_not_tested', 'ssi_alone_tested_one',
                              'ssi_alone_total_one', 'ssi_alone_not_tested',
                              'ssi_alone_total_one_not_tested') {
                $clauseBlock.$key | Should -Not -BeNullOrEmpty -Because "common.yaml carries the singular or untested form $key"
            }
            $sR = Get-EnglishStringLayer 'Partner-Report/content/_sR.yaml'
            $sR.nosocomial_reference_infections_one | Should -Match 'severe infection was recorded'
        }
    }
}

Describe 'The sepsis and NEC kinds are rows of the incidence-density table' {

    Context 'the table files carry the kinds' {

        It 'both table files recode the five kinds and the unclassified count' {
            $countColumns = @{
                'Reference-Report/tables/_tbl-incidence-density-rates.qmd' = '"n_agent_unclassified"'
                'Partner-Report/tables/_tbl-incidence-density-rates.qmd' = '"n_agent_unclassified_own"'
            }
            $dropPatterns = @{
                'Reference-Report/tables/_tbl-incidence-density-rates.qmd' = 'any_of\("n_agent_unclassified"\)'
                'Partner-Report/tables/_tbl-incidence-density-rates.qmd' = 'any_of\(\s*c\("n_ref", "n_agent_unclassified_own", "n_agent_unclassified_ref"\)\)'
            }
            foreach ($file in $countColumns.Keys | Sort-Object) {
                $text = Get-ReportSource $file
                foreach ($key in 'bsi_recognized', 'bsi_commensal', 'bsi_clinical',
                                 'nec_surgical', 'nec_medical') {
                    # The recode arm, not the bare string: a guard mentioning the key
                    # without mapping it to its label would drop the row silently.
                    $text | Should -Match ('"' + $key + '"\s*~') -Because "$file recodes the $key row to its label"
                }
                $text | Should -Match $countColumns[$file] -Because "$file reads the count column the dataset carries"
                $text | Should -Match $dropPatterns[$file] -Because "$file keeps the footnote's count out of the printed columns"
            }
        }
    }

    Context 'the strings carry the kinds' {

        It 'the labels and the kinds footnotes exist' {
            $common = Get-EnglishStringLayer 'common.yaml'
            $block = $common.'tbl-incidence-density-rates'
            foreach ($key in 'bsi_recognized', 'bsi_commensal', 'bsi_clinical',
                             'nec_surgical', 'nec_medical', 'bsi_kinds_footnote', 'nec_kinds_footnote') {
                $block.$key | Should -Not -BeNullOrEmpty -Because "common.yaml labels the $key row or footnotes the kinds"
            }
        }

        It 'the recognized-pathogen footnote carries the count of unclassified BSIs' {
            $common = Get-EnglishStringLayer 'common.yaml'
            $common.'tbl-incidence-density-rates'.bsi_kinds_footnote |
                Should -Match '\{count\}' -Because 'the footnote names how many BSIs carried an infectious agent the list cannot classify'
        }
    }
}

Describe 'The exposed patients and their days are a table of their own' {

    Context 'both reports carry it' {

        It 'the table files exist in both reports' {
            Join-Path $reportsDir 'Reference-Report/tables/_tbl-patients-exposed.qmd' |
                Should -Exist -Because 'the table of exposed patients and their mean days joins both reports'
            Join-Path $reportsDir 'Partner-Report/tables/_tbl-patients-exposed.qmd' |
                Should -Exist
        }

        It 'both content files include the table' {
            Get-ReportSource 'Reference-Report/_content.qmd' | Should -Match '_tbl-patients-exposed'
            Get-ReportSource 'Partner-Report/_content.qmd' | Should -Match '_tbl-patients-exposed'
        }
    }

    Context 'the strings carry it' {

        It 'the caption and the two measures are strings' {
            $common = Get-EnglishStringLayer 'common.yaml'
            $block = $common.'tbl-patients-exposed'
            $block.'tbl-cap' | Should -Be 'Patients Exposed to Risk and Protective Factors and Their Days of Exposure'
            $block.patients_exposed | Should -Not -BeNullOrEmpty
            $block.mean_days | Should -Not -BeNullOrEmpty
            $block.no_data | Should -Not -BeNullOrEmpty
            $block.abbreviations_footnote | Should -Not -BeNullOrEmpty
            $block.percent | Should -Not -BeNullOrEmpty -Because 'the share columns are headed for the percentage they hold'
            $block.mean | Should -Not -BeNullOrEmpty -Because 'the mean days column is headed for the mean it holds'
            $block.total_days | Should -Not -BeNullOrEmpty -Because 'the days count column is headed for the days it sums'
        }

        It 'the mean days print without intervals the dataset does not carry' {
            foreach ($file in 'Reference-Report/tables/_tbl-patients-exposed.qmd',
                              'Partner-Report/tables/_tbl-patients-exposed.qmd') {
                $text = Get-ReportSource $file
                # The intervals may be named only to be dropped: no rename may
                # give one a column of the table, and no merge may sit one
                # beside a mean.
                $text | Should -Not -Match '=\s*"[a-z0-9_]*ci_[a-z_]*mean_days"' -Because "$file carries no mean-days interval into the table"
                $text | Should -Not -Match 'c\((rate|pooled|q[1-3])_days, [^)\r\n]*ci_' -Because "$file merges no interval beside a mean"
                $text | Should -Not -Match 'ci_lower_rate_days|ci_lower_pooled_days' -Because "$file leaves the means no interval columns"
            }
        }

        It 'both table files print their no-data note when the dataset lacks the table' {
            $text = Get-ReportSource 'Reference-Report/tables/_tbl-patients-exposed.qmd'
            $text | Should -Match 'tryCatch' -Because 'a dataset saved before the table aborts the getter, and the note must stand where the table cannot'
            # Both files read a stored dataset that may predate the table slot,
            # and both must carry that path under the dataset-format marker.
            foreach ($file in 'Reference-Report/tables/_tbl-patients-exposed.qmd',
                              'Partner-Report/tables/_tbl-patients-exposed.qmd') {
                $text = Get-ReportSource $file
                $text | Should -Match 'NEOIPC-PERMANENT\(dataset-format\)' -Because "$($file): a stored dataset outlives every release"
                $text | Should -Match 'no_data_table\(sR\$`tbl-patients-exposed`\$no_data\)'
            }
        }

        It 'the Partner labels stand only for columns the table has' {
            $text = Get-ReportSource 'Partner-Report/tables/_tbl-patients-exposed.qmd'
            $text | Should -Match 'names\(labels\) %in% names\(tbl_data\)' -Because 'without reference data the reference columns are absent, and gt refuses to label one'
            $text | Should -Match 'cols_label\(!!!labels\)'
        }

        It 'both table files head the columns for what they hold' {
            foreach ($file in 'Reference-Report/tables/_tbl-patients-exposed.qmd',
                              'Partner-Report/tables/_tbl-patients-exposed.qmd') {
                $text = Get-ReportSource $file
                $text | Should -Match 'tbl-patients-exposed`\$total_days' -Because "$file heads the days-count column for the days it sums"
            }
            $partner = Get-ReportSource 'Partner-Report/tables/_tbl-patients-exposed.qmd'
            $partner | Should -Match 'tbl-patients-exposed`\$percent' -Because 'the share column is headed for the percentage it holds, not a rate'
            $partner | Should -Match 'tbl-patients-exposed`\$mean' -Because 'the mean days column is headed for the mean it holds, not a rate'
        }

        It 'the interval bounds are formatted before the merges splice them' {
            foreach ($file in 'Reference-Report/tables/_tbl-patients-exposed.qmd',
                              'Partner-Report/tables/_tbl-patients-exposed.qmd') {
                $text = Get-ReportSource $file
                # The cols_merge calls splice what fmt_number printed, so the
                # format must cover every value column but the counts: an
                # enumerated whitelist drops a bound column and the raw value
                # reaches the cell. Negation is what keeps the coverage total.
                $text | Should -Match '(?s)fmt_number\(\s*columns\s*=\s*!\s*tidyselect::any_of\(' -Because "$file formats every value column but the counts, so no merged interval bound reaches the cell unformatted"
            }
        }

        It 'both table files label all eight factors' {
            # The labels themselves are the shared glossary terms and derived
            # sentence-case variants, not a second copy in the table's block;
            # what the file must show is each dataset key bound to an sR lookup
            # on its recode arm.
            foreach ($file in 'Reference-Report/tables/_tbl-patients-exposed.qmd',
                              'Partner-Report/tables/_tbl-patients-exposed.qmd') {
                $text = Get-ReportSource $file
                foreach ($key in 'cvc', 'pvc', 'inv', 'niv', 'ab',
                                 'human_milk', 'probiotic', 'kangaroo_care') {
                    $text | Should -Match ('"' + $key + '"\s*~\s*sR\$') -Because "$file binds the $key factor to its label"
                }
            }
        }
    }
}

Describe 'The infectious-agent texts quote the types, not the pooled share' {

    Context 'the pooled read is gone' -Skip:(-not $env:CI -and -not (Get-Command Rscript -ErrorAction SilentlyContinue)) {

        It 'Rscript is present on CI because the behavioural half needs it' {
            $rscript | Should -Not -BeNullOrEmpty -Because 'the behavioural half of this gate needs Rscript'
        }

        It 'the pooled detection rate leaves the dataset resources' {
            $out = Invoke-RSnippet -Guard @('format_dataset_resources') -Body @'
counts <- list(n_departments = 7L, n_patients = 100L, n_enrollments = 120L,
               n_patient_days = 400L, n_severe_infections = 30L,
               n_infectious_agents = 40L, n_infections_with_agent = 20L,
               n_infections_overall = 60L)
sR <- list(headerList = list(allBirthweights = "all", allGestationalAges = "all"),
           not_available = "n/a", unit_separator = " ", percent_symbol = "%",
           digit_group_separator = " ")
out <- format_dataset_resources(list(), counts, sR)
cat(if (is.null(out$infectiousAgentDetectionRate)) "PASS" else "FAIL", "\n")
'@
            $out | Should -MatchExactly '\bPASS\b' -Because 'the pooled share depends on each department''s mix of infection types'
        }

        It 'the per-type fields give both shares and drop what has no infections' {
            $out = Invoke-RSnippet -Guard @('format_agent_type_fields') -Body @'
sR <- list(digit_group_separator = " ", percent_symbol = "%",
           unit_separator = " ", not_available = "n/a")
fields <- format_agent_type_fields(
  with_agent = list(bsi = 10L, hap = 8L, ssi = 0L),
  tested = list(bsi = 50L, hap = 20L, ssi = 0L),
  totals = list(bsi = 50L, hap = 40L, ssi = 5L), sR = sR)
dropped <- format_agent_type_fields(
  with_agent = list(bsi = 10L, hap = NULL, ssi = 1L),
  tested = list(bsi = 50L, hap = 20L, ssi = 1L),
  totals = list(bsi = 50L, hap = 40L, ssi = 0L), sR = sR)
comma <- modifyList(sR, list(decimal_mark = ","))
commaFields <- format_agent_type_fields(
  with_agent = list(bsi = 10L), tested = list(bsi = 50L),
  totals = list(bsi = 50L), sR = comma)
ok <- identical(fields$bsi$share, "20.0 %") &&
      identical(commaFields$bsi$share, "20,0 %") &&
      identical(fields$hap$tested_share, "50.0 %") &&
      identical(fields$hap$share, "40.0 %") &&
      identical(fields$ssi$share, "n/a") &&
      is.null(dropped$hap) && is.null(dropped$ssi)
cat(if (ok) "PASS" else "FAIL", "\n")
'@
            $out | Should -MatchExactly '\bPASS\b' -Because 'the text gives the share of the tested and the share tested with the resources'' separator before the sign, a type without infections its total no clause, and a type never tested no share among the tested'
        }

        It 'the clauses join as the template has them and leave out absent types' {
            $out = Invoke-RSnippet -Guard @('format_agent_type_fields', 'agent_type_clauses') -Body @'
sR <- list(percent_symbol = "%", unit_separator = "", not_available = "n/a",
           digit_group_separator = " ",
           `agent-type-clauses` = list(
             bsi = "Of the {total} episodes of primary sepsis/BSI, {count} ({share}) had an infectious agent recorded",
             bsi_total_one = "Of the {total} episode of primary sepsis/BSI, {count} ({share}) was recorded",
             hap = "Of the {total} pneumonias, {tested} ({tested_share}) were tested microbiologically, and the test recorded an infectious agent in {count} ({share}) of them",
             hap_total_one_tested_one = "Of the {total} pneumonia, {tested} ({tested_share}) was tested microbiologically, and the test recorded an infectious agent in {count} ({share}) of it",
             hap_not_tested = "Of the {total} pneumonias, none was tested microbiologically",
             ssi = "of the {total} SSIs, {tested} ({tested_share}) were tested, and the test recorded one in {count} ({share})",
             ssi_total_one_tested_one = "of the {total} SSI, {tested} ({tested_share}) was tested, and the test recorded one in {count} ({share})",
             ssi_not_tested = "of the {total} SSIs, none was tested",
             ssi_alone = "Of the {total} SSIs, {tested} ({tested_share}) were tested, and the test recorded one in {count} ({share})",
             ssi_alone_total_one_tested_one = "Of the {total} SSI, {tested} ({tested_share}) was tested, and the test recorded one in {count} ({share})",
             ssi_alone_not_tested = "Of the {total} SSIs, none was tested"))
fields <- format_agent_type_fields(
  with_agent = list(hap = 8L, ssi = 1L),
  tested = list(hap = 20L, ssi = 2L),
  totals = list(hap = 40L, ssi = 5L), sR = sR)
joined <- agent_type_clauses(fields, sR)
tailed <- agent_type_clauses(fields, sR, tail = " (@tbl-agent-per-infection-rate)")
alone <- agent_type_clauses(list(ssi = fields$ssi), sR)
none <- agent_type_clauses(list(), sR)
tailOnly <- agent_type_clauses(list(), sR, tail = " (@tbl-agent-per-infection-rate)")
untested <- agent_type_clauses(format_agent_type_fields(
  with_agent = list(hap = 0L, ssi = 0L),
  tested = list(hap = 0L, ssi = 0L),
  totals = list(hap = 40L, ssi = 5L), sR = sR), sR)
singular <- agent_type_clauses(format_agent_type_fields(
  with_agent = list(bsi = 1L, hap = 1L, ssi = 1L),
  tested = list(bsi = 1L, hap = 1L, ssi = 1L),
  totals = list(bsi = 1L, hap = 1L, ssi = 1L), sR = sR), sR)
ok <- startsWith(joined, "Of the 40 pneumonias") &&
      grepl("; of the 5 SSIs", joined, fixed = TRUE) &&
      grepl("\\.$", joined) && !grepl(";;", joined) &&
      grepl("\\(@tbl-agent-per-infection-rate\\)\\.$", tailed) &&
      startsWith(alone, "Of the 5 SSIs") &&
      identical(none, "") &&
      identical(tailOnly, "(@tbl-agent-per-infection-rate).") &&
      identical(untested, paste0("Of the 40 pneumonias, none was tested microbiologically",
                                 "; of the 5 SSIs, none was tested.")) &&
      grepl("episode of primary sepsis/BSI, 1 (100.0%) was recorded", singular, fixed = TRUE) &&
      grepl("Of the 1 pneumonia, 1 (100.0%) was tested", singular, fixed = TRUE) &&
      grepl("; of the 1 SSI, 1 (100.0%) was tested", singular, fixed = TRUE)
cat(if (ok) "PASS" else "FAIL", "\n")
'@
            $out | Should -MatchExactly '\bPASS\b' -Because 'pneumonia and SSI join one sentence over a semicolon, the SSI clause opens its own sentence alone, the table reference closes the text even without any clause, none tested takes the form naming no figure, one infection takes the singular, and absent types leave no sentence'
        }
    }

    Context 'no pooled read is left behind' {

        It 'no report source reads the pooled rate field' {
            Find-ReportSourceMatching '\$(infectiousAgentDetectionRate|overallNumberOfInfections)\b' | Should -BeNullOrEmpty -Because 'the section quotes the types once the pooled rate is gone; the include parameter of the detection table keeps its name'
        }

        It 'both setups read the tested counts of the per-infection-type table' {
            Get-ReportSource 'Reference-Report/_setup.qmd' |
                Should -Match '_list\("tested"\)' -Because 'the reference gives the share of the tested from the table that counts them'
            Get-ReportSource 'Partner-Report/_setup.qmd' |
                Should -Match '_list\("tested"\)' -Because 'the department gives the share of the tested from the table that counts them'
        }

        It 'the outlier registry has no all metric for the per-type table' {
            $setup = Get-ReportSource 'Partner-Report/_setup.qmd'
            $setup | Should -Not -Match 'metrics\s*=\s*c\("all"'
            $setup | Should -Not -Match 'total_metric\s*=\s*"all"'
        }

        It 'the outlier strings dropped the all metric and do not name pathogens' {
            $sR = Get-EnglishStringLayer 'Partner-Report/content/_sR.yaml'
            $sR.outlier.agent_detection_per_inf_type_all_zero | Should -BeNullOrEmpty
            $sR.outlier.agent_detection_per_inf_type_interpretation_all_above | Should -BeNullOrEmpty
            $sR.outlier.agent_detection_per_inf_type_interpretation_all_below | Should -BeNullOrEmpty
            $sR.outlier.agent_detection_per_inf_type_interpretation_some_above | Should -Not -Match 'athogen'
            $sR.outlier.agent_detection_per_inf_type_interpretation_some_below | Should -Not -Match 'athogen'
        }

        It 'the clause strings carry the template figures' {
            $common = Get-EnglishStringLayer 'common.yaml'
            $block = $common.'agent-type-clauses'
            foreach ($key in 'bsi', 'hap', 'ssi', 'ssi_alone') {
                $block.$key | Should -Not -BeNullOrEmpty -Because "common.yaml carries the $key clause"
            }
            $block.bsi | Should -Match 'had an infectious agent recorded'
            $block.hap | Should -Match 'were tested microbiologically'
            $block.hap | Should -Match '\{tested_share\}' -Because 'the text gives the share tested beside the share of the tested'
        }

        It 'both infectious-agent texts quote the types through the assembled clauses' {
            foreach ($file in 'Reference-Report/content/_infectious_agents.Rmd',
                              'Partner-Report/content/_infectious-agents.Rmd') {
                $text = Get-ReportSource $file
                $text | Should -Match 'agentTypeClauses' -Because "$file quotes the types through the assembled clauses"
                $text | Should -Not -Match '\$infectiousAgentDetectionRate\b'
            }
        }
    }
}

Describe 'The Partner Report shows the secondary-BSI and antibiotic tables by default' {

    It 'the two include parameters default to true in every language front end' {
        $files = Get-ChildItem -LiteralPath (Join-Path $reportsDir 'Partner-Report') -File -Filter 'Partner-Report*.qmd'
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $qmd = Get-Content -LiteralPath $file.FullName -Raw
            $qmd | Should -Match '(?m)^\s*includeSecondaryBsiRateTable:\s*true\s*$' -Because "$($file.Name) defaults the secondary-BSI table on"
            $qmd | Should -Match '(?m)^\s*includeAntibioticUtilisationTable:\s*true\s*$' -Because "$($file.Name) defaults the antibiotic table on"
        }
    }
}
