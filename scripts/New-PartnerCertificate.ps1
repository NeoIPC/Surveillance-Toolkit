[CmdletBinding(DefaultParameterSetName = 'Acquire')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Signatory,
    [Parameter(Mandatory, Position = 1)]
    [System.IO.DirectoryInfo]$SignatureImagePath,
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'Acquire')]
    [string]$DepartmentCode,
    [Parameter(Position = 3, ParameterSetName = 'Acquire')]
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'Pass')]
    [int]$StartYear,
    [Parameter(Position = 4, ParameterSetName = 'Acquire')]
    [Parameter(Mandatory, Position = 3, ParameterSetName = 'Pass')]
    [int]$EndYear,
    [Parameter(Position = 5, ParameterSetName = 'Acquire')]
    [Parameter(Mandatory, Position = 4, ParameterSetName = 'Pass')]
    [int]$NumberOfPatients,
    [Parameter(Position = 6, ParameterSetName = 'Acquire')]
    [Parameter(Mandatory, Position = 5, ParameterSetName = 'Pass')]
    [string]$HospitalName,
    # [ArgumentCompleter({
    #     param($commandName, $parameterName, $wordToComplete, $commandAst,$fakeBoundParameters)
    #     [CultureInfo]::GetCultures([System.Globalization.CultureTypes]::AllCultures) | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object { $_.Name }
    # })]
    [Parameter(Position = 7, ParameterSetName = 'Acquire')]
    [Parameter(Position = 6, ParameterSetName = 'Pass')]
    [string]$Language,
    [Parameter(Position = 8, ParameterSetName = 'Acquire')]
    [Parameter(Position = 7, ParameterSetName = 'Pass')]
    [Parameter(Mandatory, Position = 2, ParameterSetName = 'DataFileOnly')]
    [System.IO.DirectoryInfo]$DataFilePath
    )