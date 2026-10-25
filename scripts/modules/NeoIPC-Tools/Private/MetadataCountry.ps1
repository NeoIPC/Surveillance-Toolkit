#Requires -Version 7.6
# Adding a country to the org-unit scaffold, for Add-NeoIPCMetadataCountry and for Add-NeoIPCPartnerSite, which adds a
# country that both the instance and the scaffold lack: the plan of the rows, their writing, and what the plan reads
# from outside the directory, the World Bank's classification of economies by income, whose API holds an economy's
# current class and whose "historical classification by income" workbook holds the class of every fiscal year. Both are
# World Bank data under the Creative Commons Attribution 4.0 licence (the workbook is a resource of the World
# Development Indicators dataset), which asks for the World Bank to be credited as the source.

$script:NeoIPCWorldBankCountryApi = 'https://api.worldbank.org/v2/country'
$script:NeoIPCWorldBankIncomeHistoryUri = 'https://ddh-openapi.worldbank.org/resources/DR0095334/download'
$script:NeoIPCWorldBankIncomeHistorySheet = 'Country Analytical History'

function Get-NeoIPCWorldBankEconomy {
    # The World Bank's record of the economy with the ISO 3166-1 alpha-2 code -Code: its own three-letter code, which is
    # the ISO alpha-3 code for most economies but not for all (Kosovo: XKX), its name, and its current income class (HIC,
    # UMC, LMC, LIC, or INX for not classified). Nothing for a code the API does not serve, which its workbook may still
    # classify (TW: the workbook's TWN); a code that names an aggregate of economies, such as EU, ends the call.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Code)

    $ErrorActionPreference = 'Stop'
    $uri = "$script:NeoIPCWorldBankCountryApi/$Code`?format=json"
    try { $response = Invoke-WebRequest -Uri $uri -SkipHttpErrorCheck -ErrorAction Stop }
    catch { throw "The World Bank's API did not answer for '$Code' ($uri): $($_.Exception.Message)" }
    $content = $response.Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
    $status = [int]$response.StatusCode
    if ($status -lt 200 -or $status -ge 300) { throw "The World Bank's API answered HTTP $status for '$Code' ($uri)." }
    try { $body = ConvertFrom-Json -InputObject $content -AsHashtable -NoEnumerate -ErrorAction Stop }
    catch { throw "The World Bank's API answered for '$Code' with a body that is not JSON ($uri)." }

    # The API answers a known code with [paging, [economy]] and an unknown one with [{message: [...]}], both as HTTP 200.
    $page = @(if ($body -is [System.Collections.IList] -and $body.Count -eq 2 -and $body[1] -is [System.Collections.IList]) { $body[1] })
    if ($page.Count -ne 1 -or $page[0] -isnot [System.Collections.IDictionary]) { return }
    $economy = $page[0]
    if ([string]$economy['region']?['id'] -ceq 'NA') {
        throw [System.ArgumentException]::new("The code '$Code' names an aggregate of economies to the World Bank, $($economy['name']), not a country.", 'Code')
    }
    [pscustomobject]@{
        Code        = [string]$economy['id']
        Name        = [string]$economy['name']
        IncomeLevel = [string]$economy['incomeLevel']?['id']
    }
}

function Read-NeoIPCWorldBankIncomeHistory {
    # The income class the World Bank gave the economy with its three-letter code -Code in each fiscal year, from the
    # "historical classification by income" workbook, as fiscal year -> class: L, LM, UM, or H, '..' for an economy it did
    # not classify, and '' for a blank cell. The sheet "Country Analytical History" holds the fiscal years in one row
    # (FY89, FY90, ...) and an economy in each row below, its code in column A; the two-digit years are read with the
    # invariant calendar's two-digit-year window. The years key a SortedDictionary, since an ordered dictionary indexed
    # with an int takes it for a position. The workbook is read with the OpenXml SDK, which the module also writes its own
    # workbooks with.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.SortedDictionary[int, string]])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Code
    )

    $ErrorActionPreference = 'Stop'
    Assert-NeoIPCOpenXmlAvailable
    $resolved = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    # A download that is no workbook, such as an error page, or a copy another program holds, fails here.
    try { $doc = [DocumentFormat.OpenXml.Packaging.SpreadsheetDocument]::Open($resolved, $false) }
    catch { throw [System.IO.InvalidDataException]::new("'$Path' could not be read as the World Bank's classification history: $($_.Exception.Message)", $_.Exception) }
    try {
        $workbookPart = $doc.WorkbookPart
        $sheet = $null
        foreach ($candidate in $workbookPart.Workbook.Sheets.ChildElements) {
            if ($candidate -is [DocumentFormat.OpenXml.Spreadsheet.Sheet] -and $candidate.Name.Value -ceq $script:NeoIPCWorldBankIncomeHistorySheet) { $sheet = $candidate }
        }
        if (-not $sheet) { throw "The workbook '$Path' has no sheet '$script:NeoIPCWorldBankIncomeHistorySheet', so it is not the World Bank's classification history in the layout this reads." }

        # A shared string is the text of its runs, without the phonetic guides some locales add.
        $strings = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($workbookPart.SharedStringTablePart?.SharedStringTable?.ChildElements)) {
            if ($item -isnot [DocumentFormat.OpenXml.Spreadsheet.SharedStringItem]) { continue }
            $parts = foreach ($child in $item.ChildElements) {
                if ($child -is [DocumentFormat.OpenXml.Spreadsheet.Text]) { $child.Text }
                elseif ($child -is [DocumentFormat.OpenXml.Spreadsheet.Run]) { $child.Text?.Text }
            }
            $strings.Add(($parts -join ''))
        }
        $cellText = {
            param($Cell)
            $type = $Cell.DataType?.Value
            if ($null -ne $type -and $type.Equals([DocumentFormat.OpenXml.Spreadsheet.CellValues]::SharedString)) { return $strings[[int]$Cell.CellValue.Text] }
            if ($null -ne $type -and $type.Equals([DocumentFormat.OpenXml.Spreadsheet.CellValues]::InlineString)) { return [string]$Cell.InlineString.InnerText }
            if ($Cell.CellValue) { return [string]$Cell.CellValue.Text }
            ''
        }

        $years = [ordered]@{}
        $classes = $null
        $sheetData = $workbookPart.GetPartById($sheet.Id.Value).Worksheet.GetFirstChild[DocumentFormat.OpenXml.Spreadsheet.SheetData]()
        foreach ($row in $sheetData.ChildElements) {
            if ($row -isnot [DocumentFormat.OpenXml.Spreadsheet.Row]) { continue }
            $cells = [ordered]@{}
            foreach ($cell in $row.ChildElements) {
                if ($cell -isnot [DocumentFormat.OpenXml.Spreadsheet.Cell]) { continue }
                if ([string]$cell.CellReference?.Value -cnotmatch '^(?<column>[A-Z]+)[0-9]+$') { throw "The workbook '$Path' has a cell without a cell reference, which this reader needs." }
                $cells[$Matches['column']] = & $cellText $cell
            }
            if ($years.Count -eq 0) {
                foreach ($column in $cells.Keys) {
                    if ($cells[$column] -cmatch '^FY(?<year>[0-9]{2})$') {
                        $years[$column] = [cultureinfo]::InvariantCulture.Calendar.ToFourDigitYear([int]$Matches['year'])
                    }
                }
                continue
            }
            if ($cells['A'] -ceq $Code) {
                $classes = [System.Collections.Generic.SortedDictionary[int, string]]::new()
                foreach ($column in $years.Keys) { $classes[$years[$column]] = $cells.Contains($column) ? ([string]$cells[$column]).Trim() : '' }
                break
            }
        }
        if ($years.Count -eq 0) { throw "The sheet '$script:NeoIPCWorldBankIncomeHistorySheet' of '$Path' has no row of fiscal years (FY89, FY90, ...)." }
        if ($null -eq $classes) { throw "The World Bank's classification history '$Path' has no economy with the code '$Code'." }
        $classes
    }
    finally { $doc.Dispose() }
}

function Get-NeoIPCMetadataCountryPlan {
    # What adding the country with the ISO 3166-1 alpha-2 code -Code to the org-unit scaffold of -MetadataDirectory
    # writes, read and checked without writing anything (Add-NeoIPCMetadataCountry's help says from where): the rows of
    # the three files with the country's rows inserted, under Files, and the values they give the country: its random
    # Id, Name, ShortName, OpeningDate, the Id and Code of its Parent, its IncomeClass and the Groups it joins, its
    # TestHospital and TestDepartment, the resolved Directory, and Summary, the addition in words; and under Read what
    # each file of the scaffold held when it was read, path -> bytes. Write-NeoIPCMetadataCountryPlan writes the files.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Code,
        [string]$Name,
        [string]$ShortName,
        [Parameter(Mandatory)][string]$MetadataDirectory,
        [string]$ClassificationHistoryPath
    )

    $ErrorActionPreference = 'Stop'
    $directory = [System.IO.Path]::GetFullPath($PSCmdlet.GetUnresolvedProviderPathFromPSPath($MetadataDirectory))
    $paths = [ordered]@{
        OrgUnits    = Join-Path $directory 'common' 'organisationUnits.csv'
        Groups      = Join-Path $directory 'common' 'organisationUnitGroups.csv'
        Memberships = Join-Path $directory 'common' 'organisationUnitGroupMemberships.csv'
        PlayUnits   = Join-Path $directory 'play' 'organisationUnits.csv'
    }
    foreach ($path in $paths.Values) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw [System.IO.FileNotFoundException]::new("The metadata directory '$directory' has no file '$path'.", $path) }
    }

    $region = try { [System.Globalization.RegionInfo]::new($Code) } catch { $null }
    if (-not $region -or $region.TwoLetterISORegionName -cne $Code) {
        throw [System.ArgumentException]::new("'$Code' is not a country code that .NET knows from ISO 3166-1.", 'Code')
    }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $region.EnglishName }
    if ([string]::IsNullOrWhiteSpace($ShortName)) { $ShortName = $Name }
    if ($ShortName.Length -gt 50) {
        throw [System.ArgumentException]::new("The short name '$ShortName' is $($ShortName.Length) characters long, and DHIS2 allows 50: give a short name.", 'ShortName')
    }
    # DHIS2 keeps a name to 230 characters, the names of the test units too, which are built from the country's.
    $testHospitalName = "Test Hospital - $Name"
    $testDepartmentName = "Test Department - $Name"
    foreach ($unitName in $Name, $testHospitalName, $testDepartmentName) {
        if ($unitName.Length -gt 230) {
            throw [System.ArgumentException]::new("The name '$unitName' is $($unitName.Length) characters long, and DHIS2 allows 230: give a shorter name for the country.", 'Name')
        }
    }

    # What each file held, which the writer checks before it writes, read before the rows, so that a change in between
    # fails that check rather than passes it.
    $read = @{}
    foreach ($path in $paths.Values) { $read[$path] = [System.IO.File]::ReadAllBytes($path) }
    # Lists, so that the rows are inserted in place.
    $orgUnits = [System.Collections.Generic.List[object]]::new([object[]]@(Read-NeoIPCMetadataCsv -Path $paths.OrgUnits))
    $memberships = [System.Collections.Generic.List[object]]::new([object[]]@(Read-NeoIPCMetadataCsv -Path $paths.Memberships))
    $playUnits = [System.Collections.Generic.List[object]]::new([object[]]@(Read-NeoIPCMetadataCsv -Path $paths.PlayUnits))
    $groupCodes = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Read-NeoIPCMetadataCsv -Path $paths.Groups | ForEach-Object { [string]$_['code'] }), [System.StringComparer]::Ordinal)

    $testHospitalCode = "${Code}_TEST"
    $testDepartmentCode = "${Code}_TEST_TEST"
    if (@($orgUnits | Where-Object { [string]$_['code'] -ceq $Code }).Count -gt 0) {
        throw [System.InvalidOperationException]::new("The scaffold '$($paths.OrgUnits)' has the country '$Code' already.")
    }
    $playTaken = @($playUnits | Where-Object { [string]$_['code'] -cin $testHospitalCode, $testDepartmentCode } | ForEach-Object { [string]$_['code'] })
    if ($playTaken.Count -gt 0) {
        throw [System.InvalidOperationException]::new("The play package '$($paths.PlayUnits)' has $($playTaken -join ' and ') already, for a country the scaffold lacks.")
    }
    $roots = @($orgUnits | Where-Object { [string]$_['level'] -ceq '1' })
    if ($roots.Count -ne 1) {
        throw [System.InvalidOperationException]::new("The scaffold '$($paths.OrgUnits)' has $($roots.Count) org units at level 1, and a country is added below its one root.")
    }
    $root = $roots[0]
    $columns = @($orgUnits[0].Keys)
    foreach ($column in 'id', 'code', 'name', 'shortName', 'openingDate', 'level', 'parent') {
        if ($columns -cnotcontains $column) { throw [System.InvalidOperationException]::new("The scaffold '$($paths.OrgUnits)' has no column '$column'.") }
    }
    $playColumns = $playUnits.Count -gt 0 ? @($playUnits[0].Keys) : $columns

    # The fiscal years for which the scaffold has income-class groups, each of which the country gets a membership for.
    $years = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($groupCode in $groupCodes) {
        if ($groupCode -cmatch '^WORLD_BANK_CLASS_(?:H|UM|LM|L)_FY_(?<year>[0-9]{4})$') { [void]$years.Add([int]$Matches['year']) }
    }
    $incomeClass = [System.Collections.Generic.SortedDictionary[int, string]]::new()
    $joins = [System.Collections.Generic.List[string]]::new()
    if ($years.Count -eq 0) {
        Write-Warning "The scaffold has no World Bank income-class groups, so '$Code' joins none."
    }
    else {
        # The API gives the World Bank's own code for the economy. The workbook is read by the ISO alpha-3 code for a code
        # the API does not serve, and its newest year is then taken without the API's check.
        $economy = Get-NeoIPCWorldBankEconomy -Code $Code
        $economyCode = $economy ? $economy.Code : $region.ThreeLetterISORegionName
        if (-not $economy) {
            Write-Warning "The World Bank's API does not serve '$Code', so the classes its workbook gives '$economyCode' are taken without the API's check of the newest year."
        }
        $download = $null
        try {
            $historyPath = $ClassificationHistoryPath
            if ([string]::IsNullOrWhiteSpace($historyPath)) {
                # A downloaded file goes into a directory of its own, which is removed with it.
                $download = Join-Path ([System.IO.Path]::GetTempPath()) "neoipc-world-bank-$([guid]::NewGuid().ToString('N'))"
                [void][System.IO.Directory]::CreateDirectory($download)
                $historyPath = Join-Path $download 'OGHIST.xlsx'
                try { Invoke-WebRequest -Uri $script:NeoIPCWorldBankIncomeHistoryUri -OutFile $historyPath -ErrorAction Stop }
                catch { throw "The World Bank's classification history could not be downloaded ($script:NeoIPCWorldBankIncomeHistoryUri): $($_.Exception.Message)" }
            }
            $history = Read-NeoIPCWorldBankIncomeHistory -Path $historyPath -Code $economyCode
        }
        finally {
            if ($download -and (Test-Path -LiteralPath $download)) { [System.IO.Directory]::Delete($download, $true) }
        }

        # The workbook lists every economy for each of its fiscal years, so a year it lacks is one it ends before, never
        # an economy it left unclassified, which its cell says ('' or '..'): such a copy is older than the scaffold, and
        # the country would miss that year's membership, which every country has.
        $uncovered = @($years | Where-Object { -not $history.ContainsKey($_) })
        if ($uncovered.Count -gt 0) {
            $source = [string]::IsNullOrWhiteSpace($ClassificationHistoryPath) ? 'The World Bank''s classification history' : "The classification history '$ClassificationHistoryPath'"
            throw [System.InvalidOperationException]::new("$source has no fiscal year $($uncovered -join ' or '), which the scaffold's income-class groups cover, so it is older than the scaffold and nothing is written: give a newer copy, or leave out -ClassificationHistoryPath to download it.")
        }
        # The API's current class and the workbook's newest year are the same classification, unless the workbook is
        # older than the API's; INX is the API's word for a year the workbook leaves blank or marks '..'.
        if ($economy) {
            $apiClass = @{ HIC = 'H'; UMC = 'UM'; LMC = 'LM'; LIC = 'L'; INX = '' }
            if (-not $apiClass.ContainsKey($economy.IncomeLevel)) {
                throw [System.InvalidOperationException]::new("The World Bank's API gives '$Code' the income level '$($economy.IncomeLevel)', which this does not know.")
            }
            $newestYear = $history.Keys | Select-Object -Last 1
            $newest = $history[$newestYear] -ceq '..' ? '' : $history[$newestYear]
            if ($apiClass[$economy.IncomeLevel] -cne $newest) {
                throw [System.InvalidOperationException]::new("The World Bank's API classifies '$Code' as $($economy.IncomeLevel), but its classification history gives '$($history[$newestYear])' for fiscal year $newestYear, its newest: the history is older than the API's classification, or the two disagree, so nothing is written.")
            }
        }

        foreach ($year in $years) {
            $class = $history[$year]
            if ($class -cin '', '..') {
                Write-Warning "The World Bank did not classify '$Code' in its fiscal year $year, so it joins no income-class group for that year."
                continue
            }
            if ($class -cnotin 'L', 'LM', 'UM', 'H') {
                throw [System.InvalidOperationException]::new("The World Bank's classification history gives '$Code' the class '$class' for fiscal year $year, which this does not know.")
            }
            $groupCode = "WORLD_BANK_CLASS_${class}_FY_$year"
            if (-not $groupCodes.Contains($groupCode)) {
                throw [System.InvalidOperationException]::new("The scaffold has no group $groupCode for the class the World Bank gives '$Code' in fiscal year $year.")
            }
            $incomeClass[$year] = $class
            $joins.Add($groupCode)
        }
    }

    $taken = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@($orgUnits) + @($playUnits) | ForEach-Object { [string]$_['id'] }), [System.StringComparer]::Ordinal)
    $newId = {
        do { $id = New-NeoIPCRandomUid } until ($taken.Add($id))
        $id
    }
    $newRow = {
        param([string[]]$Columns, [hashtable]$Values)
        $row = [ordered]@{}
        foreach ($column in $Columns) { $row[$column] = $Values.ContainsKey($column) ? [string]$Values[$column] : '' }
        $row
    }
    $level = [int]$root['level']
    $countryId = & $newId
    $hospitalId = & $newId
    $departmentId = & $newId
    $openingDate = [string]$root['openingDate']
    Add-NeoIPCOrderedRow -Rows $orgUnits -Key { $args[0]['code'] } -Row (& $newRow $columns @{
            id = $countryId; code = $Code; name = $Name; shortName = $ShortName; openingDate = $openingDate; level = $level + 1; parent = [string]$root['id']
        })
    foreach ($groupCode in $joins) {
        Add-NeoIPCOrderedRow -Rows $memberships -Key { "$($args[0]['organisationUnit'])`0$($args[0]['organisationUnitGroup'])" } -Row ([ordered]@{ organisationUnitGroup = $groupCode; organisationUnit = $Code })
    }
    Add-NeoIPCOrderedRow -Rows $playUnits -Key { $args[0]['code'] } -Row (& $newRow $playColumns @{
            id = $hospitalId; code = $testHospitalCode; name = $testHospitalName; shortName = "Test Hospital $Code"; openingDate = $openingDate; level = $level + 2; parent = $countryId
        })
    Add-NeoIPCOrderedRow -Rows $playUnits -Key { $args[0]['code'] } -Row (& $newRow $playColumns @{
            id = $departmentId; code = $testDepartmentCode; name = $testDepartmentName; shortName = "Test Department $Code"; openingDate = $openingDate; level = $level + 3; parent = $hospitalId
        })

    $groupText = $joins.Count -gt 0 ? "the groups $($joins -join ', ')" : 'no income-class group'
    [pscustomobject]@{
        Code           = $Code
        Id             = $countryId
        Name           = $Name
        ShortName      = $ShortName
        OpeningDate    = $openingDate
        ParentId       = [string]$root['id']
        ParentCode     = [string]$root['code']
        IncomeClass    = $incomeClass
        Groups         = [string[]]$joins.ToArray()
        TestHospital   = $testHospitalCode
        TestDepartment = $testDepartmentCode
        Directory      = $directory
        Summary        = "the country $Code '$Name' with the id $countryId, $groupText, and the test units $testHospitalCode and $testDepartmentCode"
        Read           = $read
        Files          = @(
            [pscustomobject]@{ Path = $paths.OrgUnits; Columns = $columns; Rows = $orgUnits }
            [pscustomobject]@{ Path = $paths.Memberships; Columns = @($memberships.Count -gt 0 ? $memberships[0].Keys : @('organisationUnitGroup', 'organisationUnit')); Rows = $memberships }
            [pscustomobject]@{ Path = $paths.PlayUnits; Columns = $playColumns; Rows = $playUnits }
        )
    }
}

function Write-NeoIPCMetadataCountryPlan {
    # Write the files of a plan from Get-NeoIPCMetadataCountryPlan, all or none: when a write fails, the files written
    # so far are put back and the call ends, naming any file it could not put back. A file of the scaffold that no longer
    # holds what the plan read, changed since by another run, an editor, or git, ends the call before anything is
    # written, since the plan's rows would discard that change. Returns what the files held before (Before) and what the
    # call wrote (Written), each path -> bytes, for a caller that has to put them back later.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][pscustomobject]$Plan)

    $ErrorActionPreference = 'Stop'
    $changed = @($Plan.Read.Keys | Sort-Object | Where-Object {
            # The comma keeps the bytes one array through the try's output, an empty file's too, so that $null means
            # only a file that could not be read.
            $now = try { , [System.IO.File]::ReadAllBytes($_) } catch { $null }
            $null -eq $now -or -not [System.Linq.Enumerable]::SequenceEqual([byte[]]$now, [byte[]]$Plan.Read[$_])
        })
    if ($changed.Count -gt 0) {
        throw [System.IO.IOException]::new("$($changed -join ' and ') changed since the call read the scaffold, so nothing is written: run the call again, which reads the scaffold anew.")
    }
    $before = @{}
    foreach ($file in $Plan.Files) { $before[$file.Path] = [System.IO.File]::ReadAllBytes($file.Path) }
    $touched = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($file in $Plan.Files) {
            $touched.Add($file.Path)
            Write-NeoIPCMetadataCsv -Path $file.Path -Columns $file.Columns -Rows $file.Rows
        }
    }
    catch {
        $failure = $_
        $unrestored = @(Restore-NeoIPCFileBackup -Backup $before -Path $touched.ToArray() | ForEach-Object { $_.Path })
        $state = $unrestored.Count -gt 0 ? "and $($unrestored -join ' and ') could not be put back" : 'so the files are as they were'
        throw [System.IO.IOException]::new("Writing the country to the scaffold failed, $($state): $($failure.Exception.Message)", $failure.Exception)
    }
    $written = @{}
    foreach ($file in $Plan.Files) { $written[$file.Path] = [System.IO.File]::ReadAllBytes($file.Path) }
    [pscustomobject]@{ Before = $before; Written = $written }
}

function Restore-NeoIPCFileBackup {
    # Put files back as a backup holds them, path -> bytes, each on its own, so that one that cannot be written leaves the
    # others put back. A file that still holds its backup, such as one whose write failed before it was opened because
    # another program holds it, is left as it is. With -Written, what the call to be undone wrote, path -> bytes, a file
    # is put back only while it holds that: one changed since, by another run say, keeps the change, which putting it
    # back would discard, and so does one that cannot be read to tell. Returns each file that is not put back, with its
    # Path and the Reason: Changed, Unreadable, or Unwritable.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Backup,
        [string[]]$Path = @($Backup.Keys),
        [hashtable]$Written
    )
    $same = { param($One, $Other) $null -ne $One -and $null -ne $Other -and [System.Linq.Enumerable]::SequenceEqual([byte[]]$One, [byte[]]$Other) }
    foreach ($file in $Path) {
        # The comma keeps an empty file's bytes an array, so that $null means only a file that could not be read.
        $now = try { , [System.IO.File]::ReadAllBytes($file) } catch { $null }
        if (& $same $now $Backup[$file]) { continue }
        if ($Written -and -not (& $same $now $Written[$file])) {
            [pscustomobject]@{ Path = $file; Reason = ($null -eq $now) ? 'Unreadable' : 'Changed' }
            continue
        }
        try { [System.IO.File]::WriteAllBytes($file, $Backup[$file]) }
        catch { [pscustomobject]@{ Path = $file; Reason = 'Unwritable' } }
    }
}

function Add-NeoIPCOrderedRow {
    # Insert -Row into -Rows before the first row whose key sorts after its own, ordinally, as the authored CSV files are
    # ordered: in a file sorted by that key the row lands in its place, and every other row stays where it is.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Rows,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Row,
        [Parameter(Mandatory)][scriptblock]$Key
    )
    $own = [string](& $Key $Row)
    $index = 0
    while ($index -lt $Rows.Count -and [string]::CompareOrdinal([string](& $Key $Rows[$index]), $own) -le 0) { $index++ }
    $Rows.Insert($index, $Row)
}
