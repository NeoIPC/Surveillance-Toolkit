# Pester 5 tests for the NeoIPC data-dictionary generator (Private/DataDictionary.ps1 + Public/DataDictionary.ps1).
# Self-contained: every fixture is a synthetic in-memory package, so the suite runs against a standalone
# Surveillance-Toolkit checkout with no DHIS2 metadata.json and no package assembly. The XLSX case is skipped
# unless the DocumentFormat.OpenXml assembly has been provisioned.
#
# Run:  Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/DataDictionary.Tests.ps1
#
# Private helpers are exercised via InModuleScope. The Import-Module at file top runs during Pester's
# discovery phase, which InModuleScope requires.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {

    # Whether the optional DocumentFormat.OpenXml assembly is provisioned (decides the XLSX case). Evaluated
    # during Pester discovery so it can gate -Skip.
    $script:XlsxAvailable = Test-Path -LiteralPath (Join-Path (Get-NeoIPCDataDictionaryLibDir) 'DocumentFormat.OpenXml.dll')

    BeforeAll {
        function Ref([string]$Id) { @{ id = $Id } }

        # A synthetic package mirroring the assembled-package shape (type -> OrderedDictionary[], refs as
        # @{ id = '<uid>' }, nested-only children inlined). Deliberately out-of-order in places to prove the
        # ordinal sort. One small coded set, one free-text fallback element, one TRUE_ONLY, and a >limit set.
        function New-TestPackage {
            $pathOptions = @(for ($i = 1; $i -le 15; $i++) {
                    [ordered]@{ id = "p$i"; code = "$i"; name = "Organism $i"; sortOrder = $i; optionSet = (Ref 'osPath') }
                })
            [ordered]@{
                programs                  = @(
                    [ordered]@{
                        id = 'prog1'; code = 'TEST_PROG'; name = 'Test program'; version = 3
                        enrollmentDateLabel = 'Admission date'; incidentDateLabel = 'Enrolment date'; displayIncidentDate = $false
                        programStages = @((Ref 'stgAdm'), (Ref 'stgInf'))
                        programTrackedEntityAttributes = @(
                            [ordered]@{ id = 'pt2'; mandatory = $false; sortOrder = 2; trackedEntityAttribute = (Ref 'teaSex') },
                            [ordered]@{ id = 'pt1'; mandatory = $true; sortOrder = 1; trackedEntityAttribute = (Ref 'teaId') }
                        )
                    }
                )
                programStages             = @(
                    [ordered]@{
                        id = 'stgInf'; name = 'Infection'; description = 'Infection event.'; executionDateLabel = 'Infection date'
                        reportDateToUse = ''; sortOrder = 2; repeatable = $true; program = (Ref 'prog1')
                        programStageSections = @(Ref 'sec1')
                        programStageDataElements = @(
                            [ordered]@{ id = 'psde2'; compulsory = $false; sortOrder = 2; dataElement = (Ref 'deNote'); programStage = (Ref 'stgInf') },
                            [ordered]@{ id = 'psde3'; compulsory = $false; sortOrder = 1; dataElement = (Ref 'dePath'); programStage = (Ref 'stgInf') }
                        )
                    },
                    [ordered]@{
                        id = 'stgAdm'; name = 'Admission'; description = 'Admission event.'; executionDateLabel = 'Admission date'
                        reportDateToUse = 'enrollmentDate'; sortOrder = 1; repeatable = $false; program = (Ref 'prog1')
                        programStageSections = @()
                        programStageDataElements = @(
                            [ordered]@{ id = 'psde1'; compulsory = $true; sortOrder = 1; dataElement = (Ref 'deType'); programStage = (Ref 'stgAdm') }
                        )
                    }
                )
                trackedEntityAttributes   = @(
                    [ordered]@{ id = 'teaId'; code = 'TEST_PATIENT_ID'; name = 'Patient identifier'; formName = 'Patient ID'; shortName = 'Pat ID'; description = 'Unique, random id.'; valueType = 'TEXT' },
                    [ordered]@{ id = 'teaSex'; code = 'TEST_SEX'; name = 'Sex name'; formName = 'Sex'; shortName = 'Sx'; description = 'Phenotypic sex.'; valueType = 'LETTER'; optionSet = (Ref 'osSex') }
                )
                dataElements              = @(
                    [ordered]@{ id = 'deType'; code = 'TEST_ADM_TYPE'; name = 'Admission type name'; formName = 'Admission type'; shortName = 'Adm type'; description = 'Type.'; valueType = 'INTEGER_POSITIVE'; optionSet = (Ref 'osType') },
                    [ordered]@{ id = 'deNote'; code = 'TEST_ORG_NAME'; name = 'Organism name'; formName = 'Organism name'; shortName = 'Org name'; description = 'Use this option if the organism is not contained in the organism-list above.'; valueType = 'TEXT' },
                    [ordered]@{ id = 'dePath'; code = 'TEST_PATHOGEN_1'; name = 'Organism 1 name'; formName = 'Organism 1'; shortName = 'Org 1'; description = 'Detected organism.'; valueType = 'INTEGER_ZERO_OR_POSITIVE'; optionSet = (Ref 'osPath') }
                )
                optionSets                = @(
                    [ordered]@{ id = 'osPath'; code = 'NEOIPC_PATHOGENS'; name = 'Test pathogens'; valueType = 'INTEGER_ZERO_OR_POSITIVE'; options = @($pathOptions | ForEach-Object { Ref $_.id }) },
                    [ordered]@{ id = 'osSex'; code = 'TEST_SEX_VALUES'; name = 'Test sex values'; valueType = 'LETTER'; options = @((Ref 'oF'), (Ref 'oM'), (Ref 'oU')) },
                    [ordered]@{ id = 'osType'; code = 'TEST_ADM_TYPES'; name = 'Test admission types'; valueType = 'INTEGER_POSITIVE'; options = @((Ref 't1'), (Ref 't2')) }
                )
                options                   = @(
                    # Deliberately out of sortOrder to prove the resolver reorders.
                    [ordered]@{ id = 'oU'; code = 'u'; name = 'Undetermined'; sortOrder = 3; optionSet = (Ref 'osSex') },
                    [ordered]@{ id = 'oF'; code = 'f'; name = 'Female'; sortOrder = 1; optionSet = (Ref 'osSex') },
                    [ordered]@{ id = 'oM'; code = 'm'; name = 'Male'; sortOrder = 2; optionSet = (Ref 'osSex') },
                    [ordered]@{ id = 't1'; code = '1'; name = 'Born here'; sortOrder = 1; optionSet = (Ref 'osType') },
                    [ordered]@{ id = 't2'; code = '2'; name = 'Transferred'; sortOrder = 2; optionSet = (Ref 'osType') }
                ) + $pathOptions
                programStageSections      = @(
                    [ordered]@{ id = 'sec1'; name = 'Organisms'; sortOrder = 0; programStage = (Ref 'stgInf'); dataElements = @((Ref 'dePath'), (Ref 'deNote')) }
                )
            }
        }

        function Get-Sheet($Sheets, [string]$Name) { $Sheets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }

        $script:Pkg = New-TestPackage
        $script:Sheets = Get-NeoIPCDataDictionaryRow -Package $script:Pkg
        $script:Variables = (Get-Sheet $script:Sheets 'Variables').Rows
        $script:CodeLists = (Get-Sheet $script:Sheets 'Code lists').Rows
        $script:Forms = (Get-Sheet $script:Sheets 'Forms & dates').Rows
        $script:About = (Get-Sheet $script:Sheets 'About').Rows
    }

    Describe 'Sheet assembly' {
        It 'produces the four named sheets in order' {
            @($script:Sheets | ForEach-Object { $_.Name }) | Should -Be @('About', 'Variables', 'Code lists', 'Forms & dates')
        }
    }

    Describe 'Variable rows' {
        It 'orders patient attributes first, then stages by sortOrder, date row before its elements' {
            # Codes in document order: patient attrs (sortOrder 1,2), then Admission (date + 1 DE), then Infection (date + 2 DEs).
            $codes = @($script:Variables | ForEach-Object { $_['Code'] })
            $codes | Should -Be @(
                'TEST_PATIENT_ID', 'TEST_SEX',
                'NEOIPC_EVENTDATE_ADMISSION', 'TEST_ADM_TYPE',
                'NEOIPC_EVENTDATE_INFECTION', 'TEST_PATHOGEN_1', 'TEST_ORG_NAME')
        }

        It 'labels a known data element from formName, maps the data type, derives Required and Section, inlines a short code list' {
            $row = $script:Variables | Where-Object { $_['Code'] -eq 'TEST_PATHOGEN_1' } | Select-Object -First 1
            $row['Label'] | Should -BeExactly 'Organism 1'                 # formName
            $row['Data type'] | Should -BeExactly 'Whole number (>= 0)'    # INTEGER_ZERO_OR_POSITIVE
            $row['Required'] | Should -BeExactly 'No'                       # compulsory = false
            $row['Section'] | Should -BeExactly 'Organisms'
            $row['Repeatable'] | Should -BeExactly 'Yes'                    # stage repeatable
            $row['Level'] | Should -BeExactly 'Event'
        }

        It 'marks patient attributes Patient with blank Repeatable, and a coded attribute inlines its values' {
            $sex = $script:Variables | Where-Object { $_['Code'] -eq 'TEST_SEX' } | Select-Object -First 1
            $sex['Level'] | Should -BeExactly 'Patient'
            $sex['Module / form'] | Should -BeExactly 'Patient master data'
            $sex['Repeatable'] | Should -BeExactly ''
            $sex['Required'] | Should -BeExactly 'No'                       # mandatory = false
            $sex['Allowed values'] | Should -BeExactly 'f = Female; m = Male; u = Undetermined'
        }
    }

    Describe 'Event dates' {
        It 'emits exactly one event-date row per stage (user-entered Date, required) with unique codes' {
            $dateRows = @($script:Variables | Where-Object { $_['Field kind'] -eq 'Event date' })
            $dateRows.Count | Should -Be 2
            $codes = @($dateRows | ForEach-Object { $_['Code'] })
            ($codes | Select-Object -Unique).Count | Should -Be $codes.Count
            $dateRows | ForEach-Object { $_['Data type'] | Should -BeExactly 'Date'; $_['Required'] | Should -BeExactly 'Yes' }
        }

        It 'uses the program enrollmentDateLabel for the Admission stage date (reportDateToUse=enrollmentDate)' {
            $adm = $script:Variables | Where-Object { $_['Code'] -eq 'NEOIPC_EVENTDATE_ADMISSION' } | Select-Object -First 1
            $adm['Form date label'] | Should -BeExactly 'Admission date'
            $adm['Label'] | Should -BeExactly 'Admission date'
            $adm['Repeatable'] | Should -BeExactly 'No'
        }

        It 'uses the stage executionDateLabel for a non-Admission (Infection) event date' {
            $inf = $script:Variables | Where-Object { $_['Code'] -eq 'NEOIPC_EVENTDATE_INFECTION' } | Select-Object -First 1
            $inf['Form date label'] | Should -BeExactly 'Infection date'
            $inf['Label'] | Should -BeExactly 'Infection date'
            $inf['Repeatable'] | Should -BeExactly 'Yes'
        }
    }

    Describe 'Code lists' {
        It 'fully enumerates every option set, including the large one' {
            $setCodes = @($script:CodeLists | ForEach-Object { $_['Code list code'] } | Select-Object -Unique)
            $setCodes | Should -Contain 'NEOIPC_PATHOGENS'
            @($script:CodeLists | Where-Object { $_['Code list code'] -eq 'NEOIPC_PATHOGENS' }).Count | Should -Be 15
            @($script:CodeLists).Count | Should -Be (15 + 3 + 2)
        }

        It 'orders options by sortOrder and carries the value label' {
            $sex = @($script:CodeLists | Where-Object { $_['Code list code'] -eq 'TEST_SEX_VALUES' })
            @($sex | ForEach-Object { $_['Value code'] }) | Should -Be @('f', 'm', 'u')
            $sex[0]['Value label'] | Should -BeExactly 'Female'
        }
    }

    Describe 'Allowed values cell' {
        It 'inlines a short set but points to the Code lists sheet for a long one' {
            $type = $script:Variables | Where-Object { $_['Code'] -eq 'TEST_ADM_TYPE' } | Select-Object -First 1
            $type['Allowed values'] | Should -BeExactly '1 = Born here; 2 = Transferred'
            $path = $script:Variables | Where-Object { $_['Code'] -eq 'TEST_PATHOGEN_1' } | Select-Object -First 1
            $path['Allowed values'] | Should -BeExactly 'See code list: Test pathogens'
        }

        It 'inlines at the option limit and points just past it (pins the boundary)' {
            $mk = { param($n) @{ SetName = 'S'; Options = @(1..$n | ForEach-Object { [ordered]@{ code = "$_"; name = "v$_" } }) } }
            (Format-NeoIPCAllowedValues (& $mk 12)) | Should -Not -Match 'See code list'
            (Format-NeoIPCAllowedValues (& $mk 13)) | Should -BeExactly 'See code list: S'
        }
    }

    Describe 'Empty option set' {
        It 'does not crash and emits no code-list rows for an option set with zero options' {
            $pkg = [ordered]@{
                programs                = @([ordered]@{ id = 'p'; code = 'P'; name = 'P'; version = 1; programStages = @()
                        programTrackedEntityAttributes = @([ordered]@{ id = 'pt'; mandatory = $false; sortOrder = 1; trackedEntityAttribute = (Ref 'tea') }) })
                programStages           = @(); dataElements = @(); options = @(); programStageSections = @()
                trackedEntityAttributes = @([ordered]@{ id = 'tea'; code = 'C'; name = 'N'; valueType = 'TEXT'; optionSet = (Ref 'osE') })
                optionSets              = @([ordered]@{ id = 'osE'; code = 'EMPTY_SET'; name = 'Empty set'; valueType = 'TEXT'; options = @() })
            }
            { Get-NeoIPCDataDictionaryRow -Package $pkg } | Should -Not -Throw
            $cl = (Get-Sheet (Get-NeoIPCDataDictionaryRow -Package $pkg) 'Code lists').Rows
            @($cl | Where-Object { $_['Code list code'] -eq 'EMPTY_SET' }).Count | Should -Be 0
        }
    }

    Describe 'value-type mapping' {
        It 'maps known value types' {
            Get-NeoIPCFriendlyValueType 'TRUE_ONLY' | Should -BeExactly 'Checkbox (yes / blank)'
            Get-NeoIPCFriendlyValueType 'DATE' | Should -BeExactly 'Date'
        }
        It 'passes an unknown value type through verbatim and warns' {
            $w = $null
            $result = Get-NeoIPCFriendlyValueType -ValueType 'NO_SUCH_TYPE' -WarningVariable w -WarningAction SilentlyContinue
            $result | Should -BeExactly 'NO_SUCH_TYPE'
            $w | Should -Not -BeNullOrEmpty
        }
    }

    Describe 'Field kind' {
        It 'flags an uncoded free-text "not in the list" element as a free-text fallback' {
            $note = $script:Variables | Where-Object { $_['Code'] -eq 'TEST_ORG_NAME' } | Select-Object -First 1
            $note['Field kind'] | Should -BeExactly 'Free-text fallback'
        }
        It 'treats an ordinary element as an explicit field' {
            ($script:Variables | Where-Object { $_['Code'] -eq 'TEST_ADM_TYPE' } | Select-Object -First 1)['Field kind'] | Should -BeExactly 'Explicit field'
        }
    }

    Describe 'Label fallback' {
        It 'prefers formName, then name, then shortName' {
            (Get-NeoIPCDataDictionaryLabel ([ordered]@{ formName = 'F'; name = 'N'; shortName = 'S' })) | Should -BeExactly 'F'
            (Get-NeoIPCDataDictionaryLabel ([ordered]@{ formName = ''; name = 'N'; shortName = 'S' })) | Should -BeExactly 'N'
            (Get-NeoIPCDataDictionaryLabel ([ordered]@{ formName = ''; name = ''; shortName = 'S' })) | Should -BeExactly 'S'
        }
    }

    Describe 'About sheet' {
        It 'reports the program identity and counts' {
            $map = @{}; foreach ($r in $script:About) { $map[$r['Field']] = $r['Value'] }
            $map['Program'] | Should -BeExactly 'Test program (TEST_PROG)'
            $map['Variables'] | Should -BeExactly ([string]@($script:Variables).Count)
            $map['Code list values'] | Should -BeExactly ([string]@($script:CodeLists).Count)
            $map['Modules / forms'] | Should -BeExactly '2'
        }
    }

    Describe 'Determinism' {
        It 'produces a row order independent of the current culture' {
            $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('tr-TR')
                $a = @((Get-Sheet (Get-NeoIPCDataDictionaryRow -Package (New-TestPackage)) 'Variables').Rows | ForEach-Object { $_['Code'] })
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('en-US')
                $b = @((Get-Sheet (Get-NeoIPCDataDictionaryRow -Package (New-TestPackage)) 'Variables').Rows | ForEach-Object { $_['Code'] })
                $a | Should -Be $b
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
        }
    }

    Describe 'CSV writer' {
        It 'writes a UTF-8 BOM, LF line endings, the fixed header, and RFC-4180 quoting' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-dd-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                $paths = Write-NeoIPCDataDictionaryCsv -Sheet $script:Sheets -OutputDirectory $dir -BaseName 'DD'
                @($paths).Count | Should -Be 4
                $varPath = $paths | Where-Object { $_ -like '*-Variables.csv' }
                $bytes = [System.IO.File]::ReadAllBytes($varPath)
                $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)                      # UTF-8 BOM
                $text = [System.IO.File]::ReadAllText($varPath, [System.Text.UTF8Encoding]::new($true))
                $text | Should -Not -Match "`r`n"                                   # LF only
                $lines = $text -split "`n"
                $lines[0] | Should -BeExactly 'Level,Module / form,Form date label,Section,Code,Label,Data type,Required,Repeatable,Allowed values,Description,Field kind'
                # A field containing a comma is RFC-4180 quoted; one without is not.
                @($lines | Where-Object { $_ -match 'TEST_PATIENT_ID' })[0] | Should -Match '"Unique, random id\."'
            }
            finally { Remove-Item $dir -Recurse -Force }
        }

        It 'normalizes embedded CR/CRLF in cell text to LF (no CR byte in the output)' {
            $pkg = [ordered]@{
                programs                = @([ordered]@{ id = 'p'; code = 'P'; name = 'P'; version = 1; programStages = @()
                        programTrackedEntityAttributes = @([ordered]@{ id = 'pt'; mandatory = $false; sortOrder = 1; trackedEntityAttribute = (Ref 'tea') }) })
                programStages           = @(); dataElements = @(); optionSets = @(); options = @(); programStageSections = @()
                trackedEntityAttributes = @([ordered]@{ id = 'tea'; code = 'C'; name = 'N'; formName = 'N'; description = "line1`r`nline2`rline3"; valueType = 'TEXT' })
            }
            $sheets = Get-NeoIPCDataDictionaryRow -Package $pkg
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-dd-cr-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                $paths = Write-NeoIPCDataDictionaryCsv -Sheet $sheets -OutputDirectory $dir -BaseName 'DD'
                foreach ($p in $paths) { ([System.IO.File]::ReadAllBytes($p) -contains [byte]13) | Should -BeFalse }
            }
            finally { Remove-Item $dir -Recurse -Force }
        }
    }

    Describe 'XLSX writer' {
        It 'produces a schema-valid workbook with the expected sheet names' -Skip:(-not $script:XlsxAvailable) {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('neoipc-dd-xlsx-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                $paths = Export-NeoIPCDataDictionary -Package $script:Pkg -OutputDirectory $dir -Format Xlsx -BaseName 'DD'
                $xlsx = @($paths | Where-Object { $_ -like '*.xlsx' })[0]
                Test-Path -LiteralPath $xlsx | Should -BeTrue
                $doc = [DocumentFormat.OpenXml.Packaging.SpreadsheetDocument]::Open($xlsx, $false)
                try {
                    @([DocumentFormat.OpenXml.Validation.OpenXmlValidator]::new().Validate($doc)).Count | Should -Be 0
                    @($doc.WorkbookPart.Workbook.Sheets.ChildElements | ForEach-Object { $_.Name.Value }) |
                        Should -Be @('About', 'Variables', 'Code lists', 'Forms & dates')
                }
                finally { $doc.Dispose() }
            }
            finally { Remove-Item $dir -Recurse -Force }
        }
    }
}
