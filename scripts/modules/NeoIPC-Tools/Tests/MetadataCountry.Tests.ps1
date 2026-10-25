#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for Add-NeoIPCMetadataCountry and the World Bank readers behind it.

.DESCRIPTION
    Covers Public/MetadataCountry.ps1 and Private/MetadataCountry.ps1 against a metadata directory of the tests' own and
    a classification-history workbook the tests build with the OpenXml SDK in the World Bank's layout: title rows above
    the row of fiscal years, which begins in column C, then an economy per row with its code in column A, its classes as
    shared strings, and blank, absent, numeric, inline, and rich-text cells among them. The World Bank's API and the
    workbook's download are mocked at Invoke-WebRequest, the module's way out to the network. The cases that run the
    cmdlet as a console runs it, with no try above the call, which Pester puts around each test, do so in a runspace of
    their own, where a stand-in takes Invoke-WebRequest's place, since Pester's mocks reach no other runspace. The
    workbook is built here rather than with the module's own writer, so that the reader is checked against the layout
    and not against a writer that agrees with it.

    The cases of Add-NeoIPCMetadataCountry and of the workbook reader read the workbook, so they are skipped unless the
    DocumentFormat.OpenXml assembly is provisioned, as the module's other workbook tests are; those of
    Restore-NeoIPCFileBackup and Write-NeoIPCMetadataCountryPlan read none and always run.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/MetadataCountry.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

# Decided during discovery, so that it can gate -Skip.
$script:XlsxAvailable = InModuleScope NeoIPC-Tools { Test-Path -LiteralPath (Join-Path (Get-NeoIPCDataDictionaryLibDir) 'DocumentFormat.OpenXml.dll') }

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'TestFileHelpers.ps1')
    # The workbook serves both Describe blocks, and each removes its TestDrive when it ends, so it lives here.
    $script:fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) "neoipc-country-$([guid]::NewGuid().ToString('N'))"
    if (InModuleScope NeoIPC-Tools { Test-Path -LiteralPath (Join-Path (Get-NeoIPCDataDictionaryLibDir) 'DocumentFormat.OpenXml.dll') }) {
        InModuleScope NeoIPC-Tools { Assert-NeoIPCOpenXmlAvailable }
        New-Item -ItemType Directory -Path $script:fixtureDir | Out-Null

        # A workbook with one sheet of the given rows. A cell is a string (a shared string), or @{ Number = n },
        # @{ Inline = 'text' }, @{ Runs = 'a', 'b' } (a shared string of rich-text runs), or @{ Empty = $true } (a cell
        # without a value); a column left out of a row is a cell that does not exist.
        function Build-TestHistoryWorkbook {
            param([string]$Path, [string]$SheetName, [object[]]$Rows)
            $doc = [DocumentFormat.OpenXml.Packaging.SpreadsheetDocument]::Create($Path, [DocumentFormat.OpenXml.SpreadsheetDocumentType]::Workbook)
            try {
                $workbookPart = $doc.AddWorkbookPart()
                $workbookPart.Workbook = [DocumentFormat.OpenXml.Spreadsheet.Workbook]::new()
                $sheets = $workbookPart.Workbook.AppendChild([DocumentFormat.OpenXml.Spreadsheet.Sheets]::new())
                $worksheetPart = $workbookPart.AddNewPart[DocumentFormat.OpenXml.Packaging.WorksheetPart]()
                $sheetData = [DocumentFormat.OpenXml.Spreadsheet.SheetData]::new()
                $table = [DocumentFormat.OpenXml.Spreadsheet.SharedStringTable]::new()
                $count = 0
                foreach ($spec in $Rows) {
                    $row = [DocumentFormat.OpenXml.Spreadsheet.Row]::new()
                    $row.RowIndex = [uint32]$spec.Index
                    foreach ($column in $spec.Cells.Keys) {
                        $value = $spec.Cells[$column]
                        $cell = [DocumentFormat.OpenXml.Spreadsheet.Cell]::new()
                        $cell.CellReference = "$column$($spec.Index)"
                        if ($value -is [string] -or $value.Runs) {
                            $item = [DocumentFormat.OpenXml.Spreadsheet.SharedStringItem]::new()
                            if ($value -is [string]) { [void]$item.AppendChild([DocumentFormat.OpenXml.Spreadsheet.Text]::new($value)) }
                            else {
                                foreach ($part in $value.Runs) {
                                    $run = [DocumentFormat.OpenXml.Spreadsheet.Run]::new()
                                    [void]$run.AppendChild([DocumentFormat.OpenXml.Spreadsheet.Text]::new($part))
                                    [void]$item.AppendChild($run)
                                }
                            }
                            [void]$table.AppendChild($item)
                            $cell.DataType = [DocumentFormat.OpenXml.Spreadsheet.CellValues]::SharedString
                            $cell.CellValue = [DocumentFormat.OpenXml.Spreadsheet.CellValue]::new([string]$count)
                            $count++
                        }
                        elseif ($null -ne $value.Number) { $cell.CellValue = [DocumentFormat.OpenXml.Spreadsheet.CellValue]::new([string]$value.Number) }
                        elseif ($value.Inline) {
                            $cell.DataType = [DocumentFormat.OpenXml.Spreadsheet.CellValues]::InlineString
                            $inline = [DocumentFormat.OpenXml.Spreadsheet.InlineString]::new()
                            [void]$inline.AppendChild([DocumentFormat.OpenXml.Spreadsheet.Text]::new($value.Inline))
                            $cell.InlineString = $inline
                        }
                        [void]$row.AppendChild($cell)
                    }
                    [void]$sheetData.AppendChild($row)
                }
                $worksheet = [DocumentFormat.OpenXml.Spreadsheet.Worksheet]::new()
                [void]$worksheet.AppendChild($sheetData)
                $worksheetPart.Worksheet = $worksheet
                $sheet = [DocumentFormat.OpenXml.Spreadsheet.Sheet]::new()
                $sheet.Id = $workbookPart.GetIdOfPart($worksheetPart)
                $sheet.SheetId = [uint32]1
                $sheet.Name = $SheetName
                [void]$sheets.AppendChild($sheet)
                $workbookPart.AddNewPart[DocumentFormat.OpenXml.Packaging.SharedStringTablePart]().SharedStringTable = $table
                $workbookPart.Workbook.Save()
            }
            finally { $doc.Dispose() }
        }

        # The World Bank's layout. VEN has a cell without a value for FY24, none for FY25, and '..' for FY26; YEM gives
        # FY25 a footnoted class; NPL's FY25 is an inline string and its FY26 a shared string of two runs; KEN's newest
        # year disagrees with what the API gives it.
        $header = [ordered]@{ B = "Bank's fiscal year:"; C = 'FY99'; D = 'FY00'; E = 'FY24'; F = 'FY25'; G = 'FY26'; H = 'FY27' }
        $years = [ordered]@{ B = 'Data for calendar year :'; C = @{ Number = 1997 }; D = @{ Number = 1998 }; E = @{ Number = 2022 }; F = @{ Number = 2023 }; G = @{ Number = 2024 }; H = @{ Number = 2025 } }
        $script:historyRows = @(
            @{ Index = 1; Cells = [ordered]@{ B = 'World Bank Analytical Classifications' } }
            @{ Index = 5; Cells = $header }
            @{ Index = 6; Cells = $years }
            @{ Index = 7; Cells = [ordered]@{ A = 'ARG'; B = 'Argentina'; C = 'LM'; D = 'UM'; E = 'UM'; F = 'UM'; G = 'UM'; H = 'UM' } }
            @{ Index = 8; Cells = [ordered]@{ A = 'KEN'; B = 'Kenya'; C = 'L'; D = 'L'; E = 'LM'; F = 'LM'; G = 'LM'; H = 'LM' } }
            @{ Index = 9; Cells = [ordered]@{ A = 'NPL'; B = 'Nepal'; C = 'L'; D = 'L'; E = 'LM'; F = @{ Inline = 'LM' }; G = @{ Runs = 'L', 'M' }; H = 'LM' } }
            @{ Index = 10; Cells = [ordered]@{ A = 'VEN'; B = 'Venezuela, RB'; C = 'UM'; D = 'UM'; E = @{ Empty = $true }; G = '..'; H = 'LM' } }
            @{ Index = 11; Cells = [ordered]@{ A = 'XKX'; B = 'Kosovo'; C = '..'; D = '..'; E = 'UM'; F = 'UM'; G = 'UM'; H = 'UM' } }
            @{ Index = 12; Cells = [ordered]@{ A = 'YEM'; B = 'Yemen, Rep.'; C = 'L'; D = 'L'; E = 'L'; F = 'LM*'; G = 'L'; H = 'L' } }
            @{ Index = 13; Cells = [ordered]@{ A = 'TWN'; B = 'Taiwan, China'; C = 'H'; D = 'H'; E = 'H'; F = 'H'; G = 'H'; H = 'H' } }
        )
        $script:history = Join-Path $script:fixtureDir 'OGHIST.xlsx'
        Build-TestHistoryWorkbook -Path $script:history -SheetName 'Country Analytical History' -Rows $script:historyRows

        $economies = @{
            AR = @{ id = 'ARG'; name = 'Argentina'; region = 'LCN'; income = 'UMC' }
            BV = @{ id = 'BVX'; name = 'An aggregate'; region = 'NA'; income = 'NA' }
            FJ = @{ id = 'FJI'; name = 'Fiji'; region = 'EAS'; income = 'UMC' }
            KE = @{ id = 'KEN'; name = 'Kenya'; region = 'SSF'; income = 'LIC' }
            NP = @{ id = 'NPL'; name = 'Nepal'; region = 'SAS'; income = 'LMC' }
            VE = @{ id = 'VEN'; name = 'Venezuela, RB'; region = 'LCN'; income = 'LMC' }
            XK = @{ id = 'XKX'; name = 'Kosovo'; region = 'ECS'; income = 'UMC' }
            YE = @{ id = 'YEM'; name = 'Yemen, Rep.'; region = 'MEA'; income = 'LIC' }
        }
        $responses = @{}
        foreach ($code in $economies.Keys) {
            $e = $economies[$code]
            $responses[$code] = ConvertTo-Json -Depth 100 -Compress -InputObject @(
                [ordered]@{ page = 1; pages = 1; per_page = '50'; total = 1 }
                , @([ordered]@{ id = $e.id; iso2Code = $code; name = $e.name; region = [ordered]@{ id = $e.region; value = 'Region' }; incomeLevel = [ordered]@{ id = $e.income; value = 'Income' } })
            )
        }
        # The API serves neither, and the workbook classifies TW as TWN.
        foreach ($code in 'AQ', 'TW') { $responses[$code] = '[{"message":[{"id":"120","key":"Invalid value","value":"The provided parameter value is not valid"}]}]' }

        InModuleScope NeoIPC-Tools -Parameters @{ Responses = $responses; History = $script:history } {
            $script:CountryTestResponses = $Responses
            $script:CountryTestHistory = $History
            $script:CountryTestDownloads = [System.Collections.Generic.List[string]]::new()
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:fixtureDir) { Remove-Item -LiteralPath $script:fixtureDir -Recurse -Force }
}

Describe 'Add-NeoIPCMetadataCountry' -Skip:(-not $script:XlsxAvailable) {
    BeforeEach {
        $script:dir = Join-Path $TestDrive 'metadata'
        $common = Join-Path $script:dir 'common'
        $play = Join-Path $script:dir 'play'
        New-Item -ItemType Directory -Path $common, $play -Force | Out-Null
        @(
            'id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing'
            'AlbaniaUid1,AL,Albania,Albania,2023-01-01,,2,RootUid0001,,'
            'AustriaUid1,AT,Austria,Austria,2023-01-01,,2,RootUid0001,,'
            'RootUid0001,NEOIPC,NeoIPC,NeoIPC,2022-07-01,,1,,,'
            'TestUnits01,TEST_UNITS,Test Units,Test Units,2023-01-01,,2,RootUid0001,,'
            'TurkiyeUid1,TR,Türkiye,Türkiye,2023-01-01,,2,RootUid0001,,'
        ) | Set-TestFileContent -LiteralPath (Join-Path $common 'organisationUnits.csv')
        $groups = @('id,code,name,shortName,description,symbol,color,sharing', 'CountryGrp1,COUNTRY,Country,Country,,,,NEOIPC_READ')
        $n = 0
        foreach ($year in 2025, 2026) {
            foreach ($class in 'H', 'L', 'LM', 'UM') {
                $groups += "WbGroup$(($n++).ToString('0000')),WORLD_BANK_CLASS_${class}_FY_$year,World Bank $class $year,World Bank $class $year,,,,NEOIPC_READ"
            }
        }
        $groups | Set-TestFileContent -LiteralPath (Join-Path $common 'organisationUnitGroups.csv')
        @(
            'organisationUnitGroup,organisationUnit'
            'WORLD_BANK_CLASS_UM_FY_2025,AL'
            'WORLD_BANK_CLASS_UM_FY_2026,AL'
            'WORLD_BANK_CLASS_H_FY_2025,AT'
            'WORLD_BANK_CLASS_H_FY_2026,AT'
            'REFERENCE_CENTRE,NEOIPC'
        ) | Set-TestFileContent -LiteralPath (Join-Path $common 'organisationUnitGroupMemberships.csv')
        @(
            'id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing'
            'AlbaniaHos1,AL_TEST,Test Hospital - Albania,Test Hospital AL,2023-01-01,,3,AlbaniaUid1,,'
            'AlbaniaDep1,AL_TEST_TEST,Test Department - Albania,Test Department AL,2023-01-01,,4,AlbaniaHos1,,'
            'AustriaHos1,AT_TEST,Test Hospital - Austria,Test Hospital AT,2023-01-01,,3,AustriaUid1,,'
            'AustriaDep1,AT_TEST_TEST,Test Department - Austria,Test Department AT,2023-01-01,,4,AustriaHos1,,'
        ) | Set-TestFileContent -LiteralPath (Join-Path $play 'organisationUnits.csv')
        $script:files = @('common/organisationUnits.csv', 'common/organisationUnitGroupMemberships.csv', 'play/organisationUnits.csv') |
            ForEach-Object { Join-Path $script:dir $_ }
        $script:before = @{}
        foreach ($file in $script:files) { $script:before[$file] = [System.IO.File]::ReadAllBytes($file) }

        InModuleScope NeoIPC-Tools {
            $script:CountryTestDownloads.Clear()
            $script:CountryTestChange = $null
            # The API answers as the World Bank's does, HTTP 200 for a code it does not know too; TO gets a server error.
            # The download writes the test workbook where it is asked to.
            Mock Invoke-WebRequest {
                if ([string]$Uri -cmatch '^https://api\.worldbank\.org/v2/country/(?<code>[A-Z]{2})\?format=json$') {
                    $code = $Matches['code']
                    # Another run that writes the scaffold while this one waits for the World Bank.
                    if ($script:CountryTestChange) { [System.IO.File]::AppendAllText($script:CountryTestChange.Path, $script:CountryTestChange.Text) }
                    if ($code -ceq 'TO') { return [pscustomobject]@{ StatusCode = 503; Content = 'Service Unavailable' } }
                    return [pscustomobject]@{ StatusCode = 200; Content = $script:CountryTestResponses[$code] }
                }
                if ([string]$Uri -ceq 'https://ddh-openapi.worldbank.org/resources/DR0095334/download') {
                    $script:CountryTestDownloads.Add($OutFile)
                    Copy-Item -LiteralPath $script:CountryTestHistory -Destination $OutFile
                    return
                }
                throw "unexpected request to $Uri"
            }
        }
        $script:params = @{ MetadataDirectory = $script:dir; ClassificationHistoryPath = $script:history; Confirm = $false }
        $script:rows = { param($Relative) @(Import-Csv -LiteralPath (Join-Path $script:dir $Relative)) }
        $script:unchanged = {
            foreach ($file in $script:files) {
                [System.Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes($file), $script:before[$file]) | Should -BeTrue -Because "$file is left as it was"
            }
        }
    }

    It 'adds the country below the root, with a random UID, the root''s opening date, and the English name .NET gives the region' {
        $result = Add-NeoIPCMetadataCountry -Code AR @script:params

        $units = & $script:rows 'common/organisationUnits.csv'
        $units.code | Should -Be @('AL', 'AR', 'AT', 'NEOIPC', 'TEST_UNITS', 'TR')
        $country = $units[1]
        $country.id | Should -MatchExactly '^[A-Za-z][A-Za-z0-9]{10}$'
        $country.id | Should -Not -BeIn @('AlbaniaUid1', 'AustriaUid1', 'RootUid0001', 'TestUnits01', 'TurkiyeUid1')
        $country.name | Should -BeExactly 'Argentina'
        $country.shortName | Should -BeExactly 'Argentina'
        $country.openingDate | Should -BeExactly '2022-07-01'
        $country.level | Should -BeExactly '2'
        $country.parent | Should -BeExactly 'RootUid0001'
        $result.Id | Should -BeExactly $country.id
        $result.Added | Should -BeTrue
        # Every other line stays as it was.
        $lines = @(Get-Content -LiteralPath (Join-Path $script:dir 'common/organisationUnits.csv'))
        @($lines | Where-Object { $_ -notlike "*,AR,*" }) | Should -Be @([System.Text.Encoding]::UTF8.GetString($script:before[$script:files[0]]).TrimEnd("`n") -split "`n")
    }

    It 'joins the income-class group of each fiscal year the groups cover, with the class the history gives' {
        $result = Add-NeoIPCMetadataCountry -Code AR @script:params

        $members = & $script:rows 'common/organisationUnitGroupMemberships.csv'
        @($members | ForEach-Object { "$($_.organisationUnitGroup),$($_.organisationUnit)" }) | Should -Be @(
            'WORLD_BANK_CLASS_UM_FY_2025,AL', 'WORLD_BANK_CLASS_UM_FY_2026,AL', 'WORLD_BANK_CLASS_UM_FY_2025,AR', 'WORLD_BANK_CLASS_UM_FY_2026,AR'
            'WORLD_BANK_CLASS_H_FY_2025,AT', 'WORLD_BANK_CLASS_H_FY_2026,AT', 'REFERENCE_CENTRE,NEOIPC')
        $result.Groups | Should -Be @('WORLD_BANK_CLASS_UM_FY_2025', 'WORLD_BANK_CLASS_UM_FY_2026')
        @($result.IncomeClass.Keys) | Should -Be @(2025, 2026)
        $result.IncomeClass[2025] | Should -BeExactly 'UM'
    }

    It 'gives the play package the country''s test hospital and test department' {
        $result = Add-NeoIPCMetadataCountry -Code AR @script:params

        $units = & $script:rows 'play/organisationUnits.csv'
        $units.code | Should -Be @('AL_TEST', 'AL_TEST_TEST', 'AR_TEST', 'AR_TEST_TEST', 'AT_TEST', 'AT_TEST_TEST')
        $hospital = $units[2]
        $department = $units[3]
        $hospital.name | Should -BeExactly 'Test Hospital - Argentina'
        $hospital.shortName | Should -BeExactly 'Test Hospital AR'
        $hospital.level | Should -BeExactly '3'
        $hospital.parent | Should -BeExactly $result.Id
        $department.name | Should -BeExactly 'Test Department - Argentina'
        $department.shortName | Should -BeExactly 'Test Department AR'
        $department.level | Should -BeExactly '4'
        $department.parent | Should -BeExactly $hospital.id
        $hospital.openingDate | Should -BeExactly '2022-07-01'
        @($hospital.id, $department.id, $result.Id | Sort-Object -Unique).Count | Should -Be 3
    }

    It 'keeps the files LF and UTF-8 without a BOM, the rows it does not add included' {
        [void](Add-NeoIPCMetadataCountry -Code AR @script:params)

        foreach ($file in $script:files) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $bytes -contains 13 | Should -BeFalse -Because "$file has no CR"
            ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse -Because "$file has no BOM"
        }
        # A decoder that refuses anything but UTF-8 still reads the row of Türkiye, which the call rewrote.
        $strict = [System.Text.UTF8Encoding]::new($false, $true)
        $strict.GetString([System.IO.File]::ReadAllBytes($script:files[0])) | Should -Match 'TurkiyeUid1,TR,Türkiye,Türkiye,'
    }

    It 'writes the three files all or none' {
        # Pester 6 throws for a call that no filter matches, so the unfiltered mock hands it to the function itself,
        # taken from the module before it is mocked, since a mock's body sees none of its functions.
        $write = & (Get-Module -Name NeoIPC-Tools) { ${function:Write-NeoIPCMetadataCsv} }
        Mock -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCsv { & $write @PesterBoundParameters }
        Mock -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCsv { throw 'The disk is full.' } -ParameterFilter { $Path -like '*play*organisationUnits.csv' }

        { Add-NeoIPCMetadataCountry -Code AR @script:params } | Should -Throw '*failed, so the files are as they were*disk is full*'

        & $script:unchanged
    }

    It 'puts back a file whose own write failed partway' {
        # Write-NeoIPCMetadataCsv opens a file emptied, so a write that fails partway leaves part of the new text in it.
        $write = & (Get-Module -Name NeoIPC-Tools) { ${function:Write-NeoIPCMetadataCsv} }
        Mock -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCsv { & $write @PesterBoundParameters }
        Mock -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCsv { [System.IO.File]::WriteAllText($Path, 'id,co'); throw 'The disk is full.' } -ParameterFilter { $Path -like '*play*organisationUnits.csv' }

        { Add-NeoIPCMetadataCountry -Code AR @script:params } | Should -Throw '*failed, so the files are as they were*disk is full*'

        & $script:unchanged
    }

    It 'names a file it could not put back when a later write fails, and puts back the others' {
        # A file the call wrote that is a directory by the time it is put back cannot be written on any platform, as root
        # neither.
        $orgUnits = $script:files[0]
        $write = & (Get-Module -Name NeoIPC-Tools) { ${function:Write-NeoIPCMetadataCsv} }
        Mock -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCsv { & $write @PesterBoundParameters }
        Mock -ModuleName NeoIPC-Tools Write-NeoIPCMetadataCsv {
            Remove-Item -LiteralPath $orgUnits
            [void](New-Item -ItemType Directory -Path $orgUnits)
            throw 'The disk is full.'
        } -ParameterFilter { $Path -like '*play*organisationUnits.csv' }
        try {
            { Add-NeoIPCMetadataCountry -Code AR @script:params } | Should -Throw "*failed, and $orgUnits could not be put back*disk is full*"

            foreach ($file in $script:files[1], $script:files[2]) {
                [System.Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes($file), $script:before[$file]) | Should -BeTrue -Because "$file is as it was"
            }
        }
        finally {
            Remove-Item -LiteralPath $orgUnits -Recurse -Force
        }
    }

    It 'writes nothing when a file of the scaffold changes after the call read it, and keeps that change' {
        $other = "WORLD_BANK_CLASS_H_FY_2026,ZZ`n"
        InModuleScope NeoIPC-Tools -Parameters @{ Path = $script:files[1]; Text = $other } { $script:CountryTestChange = @{ Path = $Path; Text = $Text } }

        { Add-NeoIPCMetadataCountry -Code AR @script:params } | Should -Throw "*$($script:files[1]) changed since the call read the scaffold, so nothing is written*"

        $kept = [byte[]]($script:before[$script:files[1]] + [System.Text.Encoding]::UTF8.GetBytes($other))
        [System.Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes($script:files[1]), $kept) | Should -BeTrue -Because 'the other run''s change is kept'
        foreach ($file in $script:files[0], $script:files[2]) {
            [System.Linq.Enumerable]::SequenceEqual([System.IO.File]::ReadAllBytes($file), $script:before[$file]) | Should -BeTrue -Because "$file is left as it was"
        }
    }

    It 'writes nothing when a file of the scaffold changes between the reads of its bytes and its rows, and keeps that change' {
        # The bytes the writer compares are read before the rows, so that a change in between fails that check.
        $read = & (Get-Module -Name NeoIPC-Tools) { ${function:Read-NeoIPCMetadataCsv} }
        Mock -ModuleName NeoIPC-Tools Read-NeoIPCMetadataCsv {
            & $read @PesterBoundParameters
            if ($Path -like '*common*organisationUnits.csv') { [System.IO.File]::AppendAllText($Path, "OtherRunUid,XX,Other,Other,2023-01-01,,2,RootUid0001,,`n") }
        }

        { Add-NeoIPCMetadataCountry -Code AR @script:params } | Should -Throw '*changed since the call read the scaffold*'

        [System.IO.File]::ReadAllText($script:files[0]) | Should -BeLike '*OtherRunUid,XX,Other*'
    }

    It 'refuses a downloaded history that ends before the newest fiscal year the scaffold''s groups cover, naming what serves instead, and writes nothing' {
        $groupFile = Join-Path $script:dir 'common/organisationUnitGroups.csv'
        @(Get-Content -LiteralPath $groupFile) + 'WbGroup9999,WORLD_BANK_CLASS_UM_FY_2028,World Bank UM 2028,World Bank UM 2028,,,,NEOIPC_READ' | Set-TestFileContent -LiteralPath $groupFile

        { Add-NeoIPCMetadataCountry -Code AR -MetadataDirectory $script:dir -Confirm:$false } | Should -Throw "The World Bank's classification history has no fiscal year 2028*: once the World Bank has published that year, run the call again, or add the country with Add-NeoIPCMetadataCountry -ClassificationHistoryPath and a copy that covers it."

        & $script:unchanged
    }

    It 'adds the rows to files that hold only their header' {
        foreach ($pair in @(@($script:files[1], 'organisationUnitGroup,organisationUnit'), @($script:files[2], 'id,code,name,shortName,openingDate,closedDate,level,parent,image,sharing'))) {
            Set-TestFileContent -LiteralPath $pair[0] -Value $pair[1]
        }

        [void](Add-NeoIPCMetadataCountry -Code AR @script:params)

        @(& $script:rows 'common/organisationUnitGroupMemberships.csv' | ForEach-Object { "$($_.organisationUnitGroup),$($_.organisationUnit)" }) | Should -Be @('WORLD_BANK_CLASS_UM_FY_2025,AR', 'WORLD_BANK_CLASS_UM_FY_2026,AR')
        (& $script:rows 'play/organisationUnits.csv').code | Should -Be @('AR_TEST', 'AR_TEST_TEST')
    }

    It 'reads the workbook of an economy the API does not serve by its ISO alpha-3 code, and says so' {
        $output = @(Add-NeoIPCMetadataCountry -Code TW @script:params 3>&1)

        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Message | Should -BeLike '*API does not serve ''TW''*''TWN''*'
        @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0].Groups | Should -Be @('WORLD_BANK_CLASS_H_FY_2025', 'WORLD_BANK_CLASS_H_FY_2026')
    }

    It 'names a workbook it cannot read, and writes nothing' {
        $notWorkbook = Join-Path $TestDrive 'error-page.xlsx'
        Set-TestFileContent -LiteralPath $notWorkbook -Value '<html><body>Service Unavailable</body></html>'
        $params = $script:params.Clone()
        $params.ClassificationHistoryPath = $notWorkbook

        { Add-NeoIPCMetadataCountry -Code AR @params } | Should -Throw '*error-page.xlsx'' could not be read as the World Bank''s classification history*'

        & $script:unchanged
    }

    It 'takes the name and the short name it is given' {
        $result = Add-NeoIPCMetadataCountry -Code AR -Name 'Argentine Republic' -ShortName 'Argentina' @script:params

        $country = (& $script:rows 'common/organisationUnits.csv')[1]
        $country.name | Should -BeExactly 'Argentine Republic'
        $country.shortName | Should -BeExactly 'Argentina'
        (& $script:rows 'play/organisationUnits.csv')[2].name | Should -BeExactly 'Test Hospital - Argentine Republic'
        $result.Name | Should -BeExactly 'Argentine Republic'
    }

    It 'reads an economy by the World Bank''s own code, which is not always the ISO one' {
        $result = Add-NeoIPCMetadataCountry -Code XK @script:params

        $result.Groups | Should -Be @('WORLD_BANK_CLASS_UM_FY_2025', 'WORLD_BANK_CLASS_UM_FY_2026')
    }

    It 'reads inline and rich-text classes as their text' {
        $result = Add-NeoIPCMetadataCountry -Code NP @script:params

        $result.Groups | Should -Be @('WORLD_BANK_CLASS_LM_FY_2025', 'WORLD_BANK_CLASS_LM_FY_2026')
    }

    It 'warns for each fiscal year the World Bank left the economy unclassified, and joins no group for it' {
        $output = @(Add-NeoIPCMetadataCountry -Code VE @script:params 3>&1)

        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $warnings.Message | Should -Be @(
            "The World Bank did not classify 'VE' in its fiscal year 2025, so it joins no income-class group for that year."
            "The World Bank did not classify 'VE' in its fiscal year 2026, so it joins no income-class group for that year.")
        $result = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
        $result.Groups.Count | Should -Be 0
        $result.Added | Should -BeTrue
        @(& $script:rows 'common/organisationUnitGroupMemberships.csv' | Where-Object organisationUnit -CEQ 'VE').Count | Should -Be 0
        # The name is the one .NET gives, not the World Bank's 'Venezuela, RB'.
        @(& $script:rows 'common/organisationUnits.csv' | Where-Object code -CEQ 'VE')[0].name | Should -BeExactly 'Venezuela'
    }

    It 'downloads the history when no copy is given, and removes the download' {
        $params = $script:params.Clone()
        $params.Remove('ClassificationHistoryPath')

        $result = Add-NeoIPCMetadataCountry -Code AR @params

        $result.Groups.Count | Should -Be 2
        $downloads = InModuleScope NeoIPC-Tools { , $script:CountryTestDownloads.ToArray() }
        $downloads.Count | Should -Be 1
        Test-Path -LiteralPath (Split-Path -Path $downloads[0] -Parent) | Should -BeFalse
    }

    It 'plans, without writing, what Add-NeoIPCPartnerSite reads of a country it adds to the list' {
        $plan = InModuleScope NeoIPC-Tools -Parameters @{ Dir = $script:dir; History = $script:history } {
            Get-NeoIPCMetadataCountryPlan -Code AR -MetadataDirectory $Dir -ClassificationHistoryPath $History
        }

        & $script:unchanged
        $plan.Code | Should -BeExactly 'AR'
        $plan.Id | Should -MatchExactly '^[A-Za-z][A-Za-z0-9]{10}$'
        $plan.Name | Should -BeExactly 'Argentina'
        $plan.ShortName | Should -BeExactly 'Argentina'
        $plan.OpeningDate | Should -BeExactly '2022-07-01'
        $plan.ParentId | Should -BeExactly 'RootUid0001'
        $plan.ParentCode | Should -BeExactly 'NEOIPC'
        $plan.Groups | Should -Be @('WORLD_BANK_CLASS_UM_FY_2025', 'WORLD_BANK_CLASS_UM_FY_2026')
        $plan.Directory | Should -BeExactly ([System.IO.Path]::GetFullPath($script:dir))
        $plan.Summary | Should -BeLike "the country AR 'Argentina' with the id $($plan.Id), *"
        @($plan.Files.Path) | Should -Be $script:files
    }

    It 'writes nothing under -WhatIf and says so in its result' {
        $result = Add-NeoIPCMetadataCountry -Code AR @script:params -WhatIf

        & $script:unchanged
        $result.Added | Should -BeFalse
        $result.Groups.Count | Should -Be 2
    }

    It 'refuses <Name> before it asks the World Bank' -ForEach @(
        @{ Name = 'a country the scaffold has'; Code = 'AL'; Message = '*has the country ''AL'' already*' }
        @{ Name = 'a code .NET does not know'; Code = 'ZZ'; Message = '*''ZZ'' is not a country code that .NET knows*' }
        @{ Name = 'a code of the wrong shape'; Code = 'ar'; Message = '*not two upper-case letters*' }
        @{ Name = 'a code that ends in a line feed'; Code = "AR`n"; Message = '*not two upper-case letters*' }
        @{ Name = 'a short name longer than DHIS2 allows'; Code = 'AR'; Extra = @{ Name = 'A' * 51 }; Message = '*country''s short name*is 51 characters long, and DHIS2 allows 50: give a shorter one.' }
        @{ Name = 'a name that makes a test unit''s name longer than DHIS2 allows'; Code = 'AR'; Extra = @{ Name = 'A' * 213; ShortName = 'Argentina' }; Message = '*''Test Department - A*is 231 characters long, and DHIS2 allows 230: give the country a name of at most 212 characters*' }
        @{ Name = 'test units the play package has for a country the scaffold lacks'; Code = 'AR'; Setup = {
                $playFile = $script:files[2]
                @(Get-Content -LiteralPath $playFile) + 'StrayHosp01,AR_TEST,Stray,Stray,2023-01-01,,3,AlbaniaUid1,,' | Set-TestFileContent -LiteralPath $playFile
                $script:before[$playFile] = [System.IO.File]::ReadAllBytes($playFile)
            }; Message = '*has AR_TEST already*'
        }
    ) {
        if ($Setup) { & $Setup }
        $extra = $Extra ?? @{}

        { Add-NeoIPCMetadataCountry -Code $Code @script:params @extra } | Should -Throw $Message

        Should -Invoke -ModuleName NeoIPC-Tools Invoke-WebRequest -Times 0 -Exactly
        & $script:unchanged
    }

    It 'refuses <Name>, and writes nothing' -ForEach @(
        @{ Name = 'a code neither the World Bank''s API nor its workbook knows'; Code = 'AQ'; Message = '*has no economy with the code ''ATA''*' }
        @{ Name = 'a code that names an aggregate of economies'; Code = 'BV'; Message = '*''BV'' names an aggregate of economies*' }
        @{ Name = 'an API that fails'; Code = 'TO'; Message = '*answered HTTP 503*' }
        @{ Name = 'an economy the history lacks'; Code = 'FJ'; Message = '*has no economy with the code ''FJI''*' }
        @{ Name = 'a history whose newest year disagrees with the API'; Code = 'KE'; Message = '*classifies ''KE'' as LIC, but its classification history gives ''LM'' for fiscal year 2027*nothing is written*' }
        @{ Name = 'a class the history gives that this does not know'; Code = 'YE'; Message = '*gives ''YE'' the class ''LM`**'' for fiscal year 2025*' }
        @{ Name = 'a class whose group the scaffold lacks'; Code = 'AR'; Setup = {
                $groupFile = Join-Path $script:dir 'common/organisationUnitGroups.csv'
                @(Get-Content -LiteralPath $groupFile | Where-Object { $_ -notlike '*WORLD_BANK_CLASS_UM_FY_2026*' }) | Set-TestFileContent -LiteralPath $groupFile
            }; Message = '*has no group WORLD_BANK_CLASS_UM_FY_2026*'
        }
        # The workbook's newest year matches the API, so only the scaffold's groups can tell that it is too old.
        @{ Name = 'a history that ends before the newest fiscal year the scaffold''s groups cover'; Code = 'AR'; Setup = {
                $groupFile = Join-Path $script:dir 'common/organisationUnitGroups.csv'
                @(Get-Content -LiteralPath $groupFile) + 'WbGroup9999,WORLD_BANK_CLASS_UM_FY_2028,World Bank UM 2028,World Bank UM 2028,,,,NEOIPC_READ' | Set-TestFileContent -LiteralPath $groupFile
            }; Message = '*has no fiscal year 2028, which the scaffold''s income-class groups cover, so it is older than the scaffold and nothing is written*'
        }
    ) {
        if ($Setup) { & $Setup }

        { Add-NeoIPCMetadataCountry -Code $Code @script:params } | Should -Throw $Message

        & $script:unchanged
    }

    Context 'as a console runs it' {
        BeforeAll {
            # Runs the cmdlet with -Arguments as a console runs a line, in a runspace of its own with nothing around it:
            # a try anywhere above a call, Pester's own included, makes an error that ends a statement unwind to it, where
            # without one the next statement runs, and does the same to a throw under -ErrorAction SilentlyContinue, which
            # PowerShell drops where no try is. Pester's mocks reach no other runspace, so a stand-in there records each
            # request and answers it with -Response, or fails it when none is given. The runspace's host cannot ask a
            # question. Returns the output, the error that ended the call, and the requests.
            $script:atConsole = {
                param([string]$Arguments, [string]$Response = '')
                $manifest = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
                $runspace = [runspacefactory]::CreateRunspace()
                $runspace.Open()
                $ps = [powershell]::Create()
                try {
                    $ps.Runspace = $runspace
                    $runspace.SessionStateProxy.SetVariable('Response', $Response)
                    [void]$ps.AddScript(@"
Import-Module '$($manifest.Replace("'", "''"))' -Force
`$global:Requests = [System.Collections.Generic.List[string]]::new()
function global:Invoke-WebRequest {
    `$global:Requests.Add("`$args")
    if (-not `$global:Response) { throw 'A test made an HTTP call.' }
    [pscustomobject]@{ StatusCode = 200; Content = `$global:Response }
}
Add-NeoIPCMetadataCountry -MetadataDirectory '$($script:dir.Replace("'", "''"))' -ClassificationHistoryPath '$($script:history.Replace("'", "''"))' $Arguments
"@)
                    $thrown = $null
                    $output = try { @($ps.Invoke()) } catch { $thrown = $_; @() }
                    [pscustomobject]@{
                        Output   = $output
                        # Thrown out of the runspace's pipeline, which a throw that ends the call is there, or written to
                        # its error stream, where an error that ends only the line's statement goes.
                        Errors   = @(@($ps.Streams.Error | ForEach-Object { $_.Exception }) + @(if ($thrown) { $thrown.Exception.InnerException }))
                        Requests = @($runspace.SessionStateProxy.GetVariable('Requests'))
                    }
                }
                finally {
                    $ps.Dispose()
                    $runspace.Dispose()
                }
            }
        }

        It 'ends at a refusal with an error, asking and writing nothing, although the caller passes -ErrorAction SilentlyContinue' {
            $run = & $script:atConsole -Arguments '-Code AL -Confirm:$false -ErrorAction SilentlyContinue'

            $run.Output.Count | Should -Be 0
            $run.Requests.Count | Should -Be 0
            $run.Errors | Should -HaveCount 1
            $run.Errors[0].Message | Should -BeLike '*has the country ''AL'' already*'
            & $script:unchanged
        }

        It 'ends with an error where -Confirm asks and nobody can answer, writing nothing, although the caller passes -ErrorAction SilentlyContinue' {
            $argentina = '[{"page":1,"pages":1,"per_page":"50","total":1},[{"id":"ARG","iso2Code":"AR","name":"Argentina","region":{"id":"LCN","value":"Region"},"incomeLevel":{"id":"UMC","value":"Income"}}]]'

            $run = & $script:atConsole -Arguments '-Code AR -Confirm -ErrorAction SilentlyContinue' -Response $argentina

            $run.Requests.Count | Should -Be 1 -Because 'the call reads the World Bank before it asks'
            $run.Output.Count | Should -Be 0
            # The question's failure, whose text is in the session's language.
            $run.Errors | Should -HaveCount 1
            $run.Errors[0] | Should -BeOfType ([System.Management.Automation.MethodInvocationException])
            $run.Errors[0].InnerException | Should -BeOfType ([System.Management.Automation.Host.HostException])
            & $script:unchanged
        }
    }
}

Describe 'Read-NeoIPCWorldBankIncomeHistory' -Skip:(-not $script:XlsxAvailable) {
    It 'reads the two-digit fiscal years of the header row as four-digit years, in order' {
        $classes = InModuleScope NeoIPC-Tools -Parameters @{ Path = $script:history } { Read-NeoIPCWorldBankIncomeHistory -Path $Path -Code 'ARG' }

        @($classes.Keys) | Should -Be @(1999, 2000, 2024, 2025, 2026, 2027)
        $classes[1999] | Should -BeExactly 'LM'
        $classes[2027] | Should -BeExactly 'UM'
    }

    It 'reads a cell without a value and a missing cell as blank' {
        $classes = InModuleScope NeoIPC-Tools -Parameters @{ Path = $script:history } { Read-NeoIPCWorldBankIncomeHistory -Path $Path -Code 'VEN' }

        $classes[2024] | Should -BeExactly ''
        $classes[2025] | Should -BeExactly ''
        $classes[2026] | Should -BeExactly '..'
    }

    It 'refuses a workbook <Name>' -ForEach @(
        @{ Name = 'without the sheet'; Sheet = 'Another sheet'; Rows = 'history'; Message = '*has no sheet ''Country Analytical History''*' }
        @{ Name = 'without a row of fiscal years'; Sheet = 'Country Analytical History'; Rows = 'no header'; Message = '*has no row of fiscal years*' }
    ) {
        $path = Join-Path $TestDrive "broken-$([guid]::NewGuid().ToString('N')).xlsx"
        $rows = $Rows -ceq 'history' ? $script:historyRows : @($script:historyRows | Where-Object { $_.Index -ne 5 })
        Build-TestHistoryWorkbook -Path $path -SheetName $Sheet -Rows $rows

        { InModuleScope NeoIPC-Tools -Parameters @{ Path = $path } { Read-NeoIPCWorldBankIncomeHistory -Path $Path -Code 'ARG' } } | Should -Throw $Message
    }
}

Describe 'Restore-NeoIPCFileBackup' {
    It 'puts back each file that changed, leaves one that did not, and returns one it cannot put back' {
        $changed = Join-Path $TestDrive 'changed.csv'
        $kept = Join-Path $TestDrive 'kept.csv'
        $blocked = Join-Path $TestDrive 'blocked.csv'
        [System.IO.File]::WriteAllText($changed, 'after')
        [System.IO.File]::WriteAllText($kept, 'same')
        $keptTime = [datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc($kept, $keptTime)
        # A path that is a directory when the files are put back cannot be written.
        [void](New-Item -ItemType Directory -Path $blocked)
        $backup = @{ $changed = [System.Text.Encoding]::UTF8.GetBytes('before'); $kept = [System.Text.Encoding]::UTF8.GetBytes('same'); $blocked = [System.Text.Encoding]::UTF8.GetBytes('before') }

        $unrestored = @(InModuleScope NeoIPC-Tools -Parameters @{ Backup = $backup } { Restore-NeoIPCFileBackup -Backup $Backup })

        $unrestored.Count | Should -Be 1
        $unrestored[0].Path | Should -BeExactly $blocked
        $unrestored[0].Reason | Should -BeExactly 'Unwritable'
        [System.IO.File]::ReadAllText($changed) | Should -BeExactly 'before'
        [System.IO.File]::GetLastWriteTimeUtc($kept) | Should -Be $keptTime
    }

    It 'puts back only a file that still holds what the call wrote, and returns one changed since or unreadable, keeping it' {
        $ours = Join-Path $TestDrive 'ours.csv'
        $theirs = Join-Path $TestDrive 'theirs.csv'
        $gone = Join-Path $TestDrive 'gone.csv'
        [System.IO.File]::WriteAllText($ours, 'after')
        [System.IO.File]::WriteAllText($theirs, 'after and another run')
        # A path that is a directory by the time the call reads it cannot be read to tell whether it changed.
        [void](New-Item -ItemType Directory -Path $gone)
        $backup = @{ $ours = [System.Text.Encoding]::UTF8.GetBytes('before'); $theirs = [System.Text.Encoding]::UTF8.GetBytes('before'); $gone = [System.Text.Encoding]::UTF8.GetBytes('before') }
        $written = @{ $ours = [System.Text.Encoding]::UTF8.GetBytes('after'); $theirs = [System.Text.Encoding]::UTF8.GetBytes('after'); $gone = [System.Text.Encoding]::UTF8.GetBytes('after') }

        $unrestored = @(InModuleScope NeoIPC-Tools -Parameters @{ Backup = $backup; Written = $written; Paths = @($ours, $theirs, $gone) } { Restore-NeoIPCFileBackup -Backup $Backup -Written $Written -Path $Paths })

        @($unrestored | ForEach-Object { "$($_.Reason) $($_.Path)" }) | Should -Be @("Changed $theirs", "Unreadable $gone")
        [System.IO.File]::ReadAllText($ours) | Should -BeExactly 'before'
        [System.IO.File]::ReadAllText($theirs) | Should -BeExactly 'after and another run'
        Test-Path -LiteralPath $gone -PathType Container | Should -BeTrue
    }

    It 'takes a file emptied since the call wrote it for one that changed, not one it cannot read' {
        $emptied = Join-Path $TestDrive 'emptied.csv'
        [System.IO.File]::WriteAllBytes($emptied, [byte[]]@())
        $backup = @{ $emptied = [System.Text.Encoding]::UTF8.GetBytes('before') }
        $written = @{ $emptied = [System.Text.Encoding]::UTF8.GetBytes('after') }

        $unrestored = @(InModuleScope NeoIPC-Tools -Parameters @{ Backup = $backup; Written = $written } { Restore-NeoIPCFileBackup -Backup $Backup -Written $Written })

        @($unrestored | ForEach-Object { "$($_.Reason) $($_.Path)" }) | Should -Be @("Changed $emptied")
    }
}

Describe 'Write-NeoIPCMetadataCountryPlan' {
    It 'takes a file of the scaffold that was empty when it was read, and still is, for one that did not change' {
        $empty = Join-Path $TestDrive 'empty.csv'
        [System.IO.File]::WriteAllBytes($empty, [byte[]]@())

        { InModuleScope NeoIPC-Tools -Parameters @{ Path = $empty } { Write-NeoIPCMetadataCountryPlan -Plan ([pscustomobject]@{ Read = @{ $Path = [byte[]]@() }; Files = @() }) } } | Should -Not -Throw
    }

    It 'names a file of the scaffold it cannot read, and one gone since, apart' {
        # A path that is a directory by the time the call reads it cannot be read, on any platform.
        $blocked = Join-Path $TestDrive 'blocked.csv'
        [void](New-Item -ItemType Directory -Path $blocked)
        $gone = Join-Path $TestDrive 'gone.csv'
        $before = [System.Text.Encoding]::UTF8.GetBytes('before')

        { InModuleScope NeoIPC-Tools -Parameters @{ Path = $blocked; Bytes = $before } { Write-NeoIPCMetadataCountryPlan -Plan ([pscustomobject]@{ Read = @{ $Path = $Bytes }; Files = @() }) } } | Should -Throw "$blocked (*) could not be read, so nothing is written."
        { InModuleScope NeoIPC-Tools -Parameters @{ Path = $gone; Bytes = $before } { Write-NeoIPCMetadataCountryPlan -Plan ([pscustomobject]@{ Read = @{ $Path = $Bytes }; Files = @() }) } } | Should -Throw "$gone changed since the call read the scaffold*"
    }
}
