#Requires -Version 7.6

<#
.SYNOPSIS
    Pester tests for the personal access token cmdlets.

.DESCRIPTION
    Covers Read-DHIS2PersonalAccessToken, Remove-DHIS2PersonalAccessToken, and Clear-DHIS2PersonalAccessTokens
    (Public/PAT.ps1). The requests go to a small in-memory DHIS2 behind Invoke-WebRequest, so that the real GET and DELETE
    helpers build each request and read each answer. It models what the source of DHIS2 2.40.12, 2.41.10, 2.42.6 and
    2.43.2 says of api/apiToken, which no release changed in what is modelled: a token is a sharing object, private by
    default, so an account sees the tokens it created and those shared with it, while a superuser (authority ALL) sees
    every token; DHIS2 never serializes a token's key; an `in` filter needs brackets (without them DHIS2 answers 400
    "Collection size must be integer"); a token the account cannot see is not found (404); a token shared with an
    account for reading only is not deletable by it (403), since a deletion needs write sharing; and a request
    authenticated with a token that is gone or expired is refused with 401, which a deletion of that token brings about
    at once from DHIS2 2.41 on. Fields are not applied: a test checks the fields a request names instead.

    The confirmation tests run the cmdlets in a runspace whose host answers each prompt from a script, so that they are
    asked exactly as a person would be, and records every request for input, such as Read-Host's for a username, which
    it refuses. That runspace imports the module afresh and reaches the same fake DHIS2 through a global
    Invoke-WebRequest, which module code finds before the cmdlet.

    Self-contained: no instance is needed and no request leaves the process.

.EXAMPLE
    Invoke-Pester -Path scripts/modules/NeoIPC-Tools/Tests/PAT.Tests.ps1
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..') -Force

InModuleScope 'NeoIPC-Tools' {
    Describe 'The personal access token cmdlets' {
        BeforeAll {
            $script:Host1 = 'dhis2.example.org'
            # Without -Auth the cmdlets would read a token from this variable rather than ask for a password.
            $script:SavedTokenVariable = [Environment]::GetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', 'Process')
            [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', [NullString]::Value, 'Process')

            # A DHIS2 instance with three accounts: admin, a superuser, and alice and bob, who are not.
            function New-FakeDhis2 {
                $script:Fake = @{
                    Users    = [ordered]@{
                        'UsrAdmin001' = @{ Id = 'UsrAdmin001'; Username = 'admin'; Authorities = @('ALL') }
                        'UsrAlice001' = @{ Id = 'UsrAlice001'; Username = 'alice'; Authorities = @('F_METADATA_IMPORT') }
                        'UsrBobby001' = @{ Id = 'UsrBobby001'; Username = 'bob'; Authorities = @() }
                    }
                    Tokens   = [System.Collections.Generic.List[hashtable]]::new()
                    Requests = [System.Collections.Generic.List[object]]::new()
                }
            }
            # A token of -Owner; -Expire is epoch milliseconds, $null leaves the field out of DHIS2's answer.
            function Add-FakeToken([string]$Id, [string]$Owner, $Expire = 4102444800000, [string[]]$SharedWith = @(), [string[]]$Methods = @()) {
                $token = @{
                    Id = $Id; Owner = $Owner; Expire = $Expire; SharedWith = $SharedWith; Methods = $Methods
                    Created = '2026-01-02T03:04:05.000'; Plaintext = 'd2p_' + ($Id * 4).Substring(0, 44) + '000000'
                }
                $script:Fake.Tokens.Add($token)
                $token
            }
            function Get-FakeAuth([string]$TokenId) { @{ AuthType = 'Token'; Token = @($script:Fake.Tokens | Where-Object { $_.Id -ceq $TokenId })[0].Plaintext } }
            # The fake takes any password.
            function Get-BasicAuth([string]$Username) { @{ AuthType = 'Basic'; Username = $Username; Password = [System.Net.NetworkCredential]::new('', 'made-up').SecurePassword } }
            function Get-FakeRequest([string]$Method, [string]$Path) {
                @($script:Fake.Requests | Where-Object { $_.Method -eq $Method -and (-not $Path -or $_.Path -ceq $Path) })
            }
            function Get-DeletedId { @(Get-FakeRequest 'DELETE' | ForEach-Object { $_.Path.Split('/')[-1] }) }

            # The answer of the fake DHIS2 to one request, shaped as Invoke-WebRequest returns it with -SkipHttpErrorCheck.
            # Self-contained, so that the confirmation runspace can define it from its text.
            function Invoke-FakeDhis2 {
                param($State, [string]$Method, [uri]$Uri, $Headers, [System.Management.Automation.PSCredential]$Credential)
                function Send([int]$Code, $Body) {
                    [pscustomobject]@{ StatusCode = $Code; Content = $(if ($null -eq $Body) { '' } else { $Body | ConvertTo-Json -Depth 100 -Compress }) }
                }
                function Deny([int]$Code, [string]$Message) {
                    Send $Code ([ordered]@{ httpStatus = 'Refused'; httpStatusCode = $Code; status = 'ERROR'; message = $Message })
                }
                function ConvertTo-FakeJson($Token) {
                    $o = [ordered]@{ id = $Token.Id; created = $Token.Created
                        createdBy = [ordered]@{ id = $Token.Owner; username = $State.Users[$Token.Owner].Username }
                        attributes = @(if (@($Token.Methods).Count -gt 0) { [ordered]@{ type = 'MethodAllowedList'; allowedMethods = @($Token.Methods) } })
                    }
                    if ($null -ne $Token.Expire) { $o['expire'] = $Token.Expire }
                    $o
                }

                $path = $Uri.AbsolutePath.TrimStart('/')
                $query = @{}
                foreach ($pair in $Uri.Query.TrimStart('?').Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
                    $key, $value = $pair.Split('=', 2)
                    if (-not $query.ContainsKey($key)) { $query[$key] = [System.Collections.Generic.List[string]]::new() }
                    $query[$key].Add([System.Net.WebUtility]::UrlDecode($value))
                }
                $State.Requests.Add([pscustomobject]@{ Method = ([string]$Method).ToUpperInvariant(); Path = $path; Query = $query })

                # Authentication as ApiTokenAuthManager does it: a token that is gone or expired is refused.
                $user = $null
                $authorization = if ($Headers) { [string]$Headers['Authorization'] } else { '' }
                if ($authorization.StartsWith('ApiToken ', [System.StringComparison]::Ordinal)) {
                    $plaintext = $authorization.Substring(9)
                    $used = @($State.Tokens | Where-Object { $_.Plaintext -ceq $plaintext })[0]
                    if (-not $used) { return Deny 401 'The API token does not exists' }
                    if ($null -ne $used.Expire -and $used.Expire -le [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
                        return Deny 401 'Failed to authenticate API token, token has expired.'
                    }
                    $user = $State.Users[$used.Owner]
                }
                elseif ($Credential) { $user = @($State.Users.Values | Where-Object { $_.Username -ceq $Credential.UserName })[0] }
                if (-not $user) { return Deny 401 'Unauthorized' }

                # Sharing: a superuser bypasses it; anyone else sees their own tokens and those shared with them, here for
                # reading only, and may delete only their own.
                $isSuper = @($user.Authorities) -ccontains 'ALL'
                $visible = @($State.Tokens | Where-Object { $isSuper -or $_.Owner -ceq $user.Id -or @($_.SharedWith) -ccontains $user.Id })

                if ($Method -eq 'Get' -and $path -ceq 'api/me') {
                    return Send 200 ([ordered]@{ id = $user.Id; authorities = @($user.Authorities) })
                }
                if ($Method -eq 'Get' -and $path -ceq 'api/apiToken') {
                    $rows = $visible
                    foreach ($filter in @($query['filter'] | Where-Object { $_ })) {
                        $property, $operator, $value = $filter.Split(':', 3)
                        if ($property -cne 'id') { throw "The fake DHIS2 does not read the filter '$filter'." }
                        switch ($operator) {
                            'in' {
                                if (-not ($value.StartsWith('[') -and $value.EndsWith(']'))) { return Deny 400 'Collection size must be integer' }
                                $ids = $value.Substring(1, $value.Length - 2).Split(',')
                                $rows = @($rows | Where-Object { $ids -ccontains $_.Id })
                            }
                            'eq' { $rows = @($rows | Where-Object { $_.Id -ceq $value }) }
                            default { throw "The fake DHIS2 does not read the filter '$filter'." }
                        }
                    }
                    return Send 200 ([ordered]@{ apiToken = @($rows | ForEach-Object { ConvertTo-FakeJson $_ }) })
                }
                if ($path -cmatch '^api/apiToken/([^/]+)$') {
                    $id = $Matches[1]
                    $token = @($visible | Where-Object { $_.Id -ceq $id })[0]
                    if (-not $token) { return Deny 404 "ApiToken with id $id could not be found." }
                    if ($Method -eq 'Get') { return Send 200 (ConvertTo-FakeJson $token) }
                    if ($Method -eq 'Delete') {
                        if (-not ($isSuper -or $token.Owner -ceq $user.Id)) { return Deny 403 'You don''t have the proper permissions to delete this object.' }
                        [void]$State.Tokens.Remove($token)
                        return Send 200 ([ordered]@{ httpStatus = 'OK'; httpStatusCode = 200; status = 'OK'; response = [ordered]@{ uid = $id } })
                    }
                }
                throw "The fake DHIS2 does not answer $Method $path."
            }

            # The runspace for the confirmation tests, whose host answers prompts from a queue and records them.
            . (Join-Path $PSScriptRoot 'ScriptedHost.ps1')
            $script:ScriptedHost = [NeoIPCTests.ScriptedHost]::new()
            $script:Runspace = [runspacefactory]::CreateRunspace($script:ScriptedHost)
            $script:Runspace.Open()
            $setup = [powershell]::Create()
            try {
                $setup.Runspace = $script:Runspace
                $manifest = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'NeoIPC-Tools.psd1'
                $null = $setup.AddScript(@"
Import-Module '$($manifest.Replace("'", "''"))' -Force
function global:Invoke-FakeDhis2 {
$((Get-Command Invoke-FakeDhis2).Definition)
}
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(`$Method, `$Uri, `$Headers, `$Authentication, `$Credential, [switch]`$SkipHttpErrorCheck, [switch]`$AllowUnencryptedAuthentication)
    Invoke-FakeDhis2 -State `$global:Fake -Method `$Method -Uri `$Uri -Headers `$Headers -Credential `$Credential
}
function global:Invoke-RestMethod { throw 'A test made an HTTP call.' }
"@)
                $null = $setup.Invoke()
                if ($setup.Streams.Error.Count -gt 0) { throw "Preparing the confirmation runspace failed: $($setup.Streams.Error[0])" }
            }
            finally { $setup.Dispose() }

            # Runs -Command in the scripted runspace against the current fake DHIS2, answering the prompts with -Answers.
            # Returns the output, the errors, the terminating error, and the prompts, requests for input, and warnings the
            # host was shown. -NoTry runs it as a console runs a line, with no try above it: a try anywhere above a call
            # makes every terminating error unwind to it, while without one an error that ends a statement lets the next
            # one run.
            function Invoke-Scripted([string[]]$Answers = @(), [hashtable]$Variables = @{}, [Parameter(Mandatory)][string]$Command, [switch]$NoTry) {
                $ui = $script:ScriptedHost.ScriptedUI
                $ui.Answers.Clear(); $ui.Prompts.Clear(); $ui.Inputs.Clear(); $ui.Warnings.Clear()
                foreach ($a in $Answers) { $ui.Answers.Enqueue($a) }
                $script:Runspace.SessionStateProxy.SetVariable('Fake', $script:Fake)
                $script:Runspace.SessionStateProxy.SetVariable('Stop', $null)
                foreach ($k in $Variables.Keys) { $script:Runspace.SessionStateProxy.SetVariable($k, $Variables[$k]) }
                $ps = [powershell]::Create()
                try {
                    $ps.Runspace = $script:Runspace
                    $null = $ps.AddScript($(if ($NoTry) { $Command } else { "try { $Command } catch { `$global:Stop = `$_ }" }))
                    $uncaught = $null
                    $output = try { $ps.Invoke() } catch { $uncaught = $_; @() }
                    [pscustomobject]@{
                        Output   = @($output)
                        Errors   = @($ps.Streams.Error)
                        Stop     = $(if ($uncaught) { $uncaught } else { $script:Runspace.SessionStateProxy.GetVariable('Stop') })
                        Prompts  = @($ui.Prompts)
                        Inputs   = @($ui.Inputs)
                        Warnings = @($ui.Warnings)
                    }
                }
                finally { $ps.Dispose() }
            }
        }
        AfterAll {
            if ($script:Runspace) { $script:Runspace.Dispose() }
            # [NullString]::Value removes the variable; $null would bind as '' and leave it present but empty.
            $restore = if ($null -eq $script:SavedTokenVariable) { [NullString]::Value } else { $script:SavedTokenVariable }
            [Environment]::SetEnvironmentVariable('NEOIPC_DHIS2_TOKEN', $restore, 'Process')
        }

        BeforeEach {
            New-FakeDhis2
            Mock Invoke-WebRequest { Invoke-FakeDhis2 -State $script:Fake -Method $Method -Uri $Uri -Headers $Headers -Credential $Credential }
            Mock Invoke-RestMethod { throw 'A test made an HTTP call.' }
            Mock Read-Host { throw 'A cmdlet asked for credentials.' }
        }

        Describe 'Read-DHIS2PersonalAccessToken' {
            BeforeEach {
                $null = Add-FakeToken 'TokAdmin001' 'UsrAdmin001'
                $null = Add-FakeToken 'TokAlice001' 'UsrAlice001'
                $null = Add-FakeToken 'TokAlice002' 'UsrAlice001'
                $null = Add-FakeToken 'TokBobby001' 'UsrBobby001' -SharedWith 'UsrAlice001'
                $null = Add-FakeToken 'TokBobby002' 'UsrBobby001'
            }

            It 'lists only the caller''s own tokens by default, for <Who>' -ForEach @(
                @{ Who = 'a superuser, to whom DHIS2 lists every token'; As = 'TokAdmin001'; Expected = @('TokAdmin001') }
                @{ Who = 'an account another user shared a token with'; As = 'TokAlice001'; Expected = @('TokAlice001', 'TokAlice002') }
            ) {
                $read = @(Read-DHIS2PersonalAccessToken -Auth (Get-FakeAuth $As) -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue)
                @($read.Id) | Should -Be $Expected
                $warnings.Count | Should -Be 0
            }
            It 'lists with -AllUsers every token DHIS2 returns to <Who>, <Warning>' -ForEach @(
                @{ Who = 'a superuser'; Warning = 'silently'; As = 'TokAdmin001'; Expected = @('TokAdmin001', 'TokAlice001', 'TokAlice002', 'TokBobby001', 'TokBobby002'); Warns = $false }
                @{ Who = 'an account without ALL'; Warning = 'warning that DHIS2 lists only those shared with it'; As = 'TokAlice001'; Expected = @('TokAlice001', 'TokAlice002', 'TokBobby001'); Warns = $true }
            ) {
                $read = @(Read-DHIS2PersonalAccessToken -AllUsers -Auth (Get-FakeAuth $As) -Hostname $script:Host1 -WarningVariable warnings -WarningAction SilentlyContinue)
                @($read.Id) | Should -Be $Expected
                if ($Warns) { "$warnings" | Should -BeLike '*authority ALL*shared with it*' } else { $warnings.Count | Should -Be 0 }
            }
            It 'applies a -Filter in DHIS2 and still keeps only the caller''s own tokens' {
                $read = @(Read-DHIS2PersonalAccessToken -Filter 'id:eq:TokBobby001' -Auth (Get-FakeAuth 'TokAlice001') -Hostname $script:Host1)
                $read.Count | Should -Be 0
                @((Get-FakeRequest 'GET' 'api/apiToken')[0].Query['filter']) | Should -Be @('id:eq:TokBobby001')
            }
            It 'reads one -Id through its own path, whoever created it' {
                $read = @(Read-DHIS2PersonalAccessToken -Id 'TokBobby002' -Auth (Get-FakeAuth 'TokAdmin001') -Hostname $script:Host1)
                $read.Id | Should -Be @('TokBobby002')
                $read[0].CreatedBy | Should -BeExactly 'bob'
                @(Get-FakeRequest 'GET' 'api/apiToken/TokBobby002').Count | Should -Be 1
                @(Get-FakeRequest 'GET' 'api/me').Count | Should -Be 0
            }
            It 'reads several -Id with one bracketed id:in filter, in the order given' {
                $read = @(Read-DHIS2PersonalAccessToken -Id 'TokBobby002', 'TokAlice001', 'TokBobby002' -Auth (Get-FakeAuth 'TokAdmin001') -Hostname $script:Host1)
                @($read.Id) | Should -Be @('TokBobby002', 'TokAlice001')
                $reads = Get-FakeRequest 'GET' 'api/apiToken'
                $reads.Count | Should -Be 1
                @($reads[0].Query['filter']) | Should -Be @('id:in:[TokBobby002,TokAlice001]')
            }
            It 'reads 250 ids in three requests' {
                $ids = @(1..250 | ForEach-Object { 'TokMany{0:D4}' -f $_ })
                foreach ($i in $ids) { $null = Add-FakeToken $i 'UsrBobby001' }
                $read = @(Read-DHIS2PersonalAccessToken -Id $ids -Auth (Get-FakeAuth 'TokAdmin001') -Hostname $script:Host1)
                $read.Count | Should -Be 250
                $reads = Get-FakeRequest 'GET' 'api/apiToken'
                $reads.Count | Should -Be 3
                foreach ($r in $reads) { $r.Query['filter'][0].Split(',').Count | Should -BeLessOrEqual 100 }
            }
            It 'reports an id DHIS2 does not return as an error that names it, <Case>' -ForEach @(
                @{ Case = 'read alone'; Ids = @('TokBobby002'); Expected = @() }
                @{ Case = 'read with others'; Ids = @('TokAlice001', 'TokBobby002'); Expected = @('TokAlice001') }
            ) {
                $read = @(Read-DHIS2PersonalAccessToken -Id $Ids -Auth (Get-FakeAuth 'TokAlice001') -Hostname $script:Host1 -ErrorVariable failures -ErrorAction SilentlyContinue)
                ($read.Id -join ',') | Should -BeExactly ($Expected -join ',')
                # The error variable also holds the 404 of the single read, which the cmdlet handles.
                $records = @($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -like 'NeoIPCPersonalAccessTokenNotFound*' })
                $records.Count | Should -Be 1
                $records[0].Exception.Message | Should -BeLike "*'TokBobby002'*"
                $records[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
            }
            It 'refuses an id that is no UID before any request, and sends nothing when no id is left' {
                $read = @(Read-DHIS2PersonalAccessToken -Id 'not a uid', 'TokAlice001' -Auth (Get-FakeAuth 'TokAlice001') -Hostname $script:Host1 -ErrorVariable failures -ErrorAction SilentlyContinue)
                @($read.Id) | Should -Be @('TokAlice001')
                @($script:Fake.Requests | Where-Object { $_.Path -like '*not a uid*' -or "$($_.Query['filter'])" -like '*not a uid*' }).Count | Should -Be 0
                @($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })[0].Exception.Message | Should -BeLike "*'not a uid'*"
                $script:Fake.Requests.Clear()
                @(Read-DHIS2PersonalAccessToken -Id 'x' -Auth (Get-FakeAuth 'TokAlice001') -Hostname $script:Host1 -ErrorAction SilentlyContinue).Count | Should -Be 0
                $script:Fake.Requests.Count | Should -Be 0
            }
            It 'never shows nor sends a token given as an id, <Case>' -ForEach @(
                @{ Case = 'as it is'; Prefix = '' }
                @{ Case = 'after a space'; Prefix = ' ' }
                @{ Case = 'after the ApiToken scheme of an Authorization header'; Prefix = 'ApiToken ' }
            ) {
                $plaintext = (Get-FakeAuth 'TokAlice002').Token
                $null = Read-DHIS2PersonalAccessToken -Id ($Prefix + $plaintext) -Auth (Get-FakeAuth 'TokAlice001') -Hostname $script:Host1 -ErrorVariable failures -ErrorAction SilentlyContinue
                $records = @($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $records.Count | Should -Be 1
                $records[0].ToString() | Should -Not -BeLike "*$plaintext*"
                [string]$records[0].TargetObject | Should -Not -BeLike "*$plaintext*"
                $script:Fake.Requests.Count | Should -Be 0
            }
            It 'neither asks for nor gives a key, and gives each field of the token' {
                $script:Fake.Tokens.Clear()
                $null = Add-FakeToken 'TokAlice001' 'UsrAlice001' -Expire 1767225600000 -Methods 'GET', 'POST'
                $read = @(Read-DHIS2PersonalAccessToken -Auth (Get-BasicAuth 'alice') -Hostname $script:Host1)
                @($read[0].PSObject.Properties.Name) | Should -Be @('Id', 'Expire', 'Created', 'CreatedBy', 'AllowedMethods')
                $read[0].Expire | Should -Be ([datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
                $read[0].Expire.Kind | Should -Be 'Utc'
                $read[0].CreatedBy | Should -BeExactly 'alice'
                @($read[0].AllowedMethods) | Should -Be @('GET', 'POST')
                $tokenReads = @($script:Fake.Requests | Where-Object { $_.Path -like 'api/apiToken*' })
                $tokenReads.Count | Should -Be 1
                @($tokenReads[0].Query['fields'][0].Split(',')) | Should -Not -Contain 'key'
            }
            It 'gives the expiry <Case>' -ForEach @(
                @{ Case = 'at the epoch for 0, which DHIS2 takes as expired'; Expire = 0; Expected = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc) }
                @{ Case = 'as the latest [datetime] for one past the year 9999'; Expire = [long]::MaxValue; Expected = [datetime]::SpecifyKind([datetime]::MaxValue, 'Utc') }
                @{ Case = 'as nothing when DHIS2 gives none'; Expire = $null; Expected = $null }
            ) {
                $script:Fake.Tokens.Clear()
                $null = Add-FakeToken 'TokAlice001' 'UsrAlice001' -Expire $Expire
                $read = @(Read-DHIS2PersonalAccessToken -Auth (Get-BasicAuth 'alice') -Hostname $script:Host1)
                $read.Count | Should -Be 1
                $read[0].Expire | Should -Be $Expected
            }
            It 'reads no token once DHIS2 refuses the account read' {
                { Read-DHIS2PersonalAccessToken -Auth (Get-BasicAuth 'nobody') -Hostname $script:Host1 } | Should -Throw '*HTTP 401*'
                @(Get-FakeRequest 'GET' 'api/apiToken').Count | Should -Be 0
            }
            It 'ends with DHIS2''s refusal alone where nothing catches it, rather than going on without the answer' {
                $run = Invoke-Scripted -NoTry -Variables @{ Auth = (Get-BasicAuth 'nobody') } -Command "Read-DHIS2PersonalAccessToken -Auth `$Auth -Hostname '$($script:Host1)'"
                $run.Stop | Should -BeNullOrEmpty
                @($run.Errors).Count | Should -Be 1
                $run.Errors[0].Exception.Message | Should -BeLike "GET 'api/me' failed with HTTP 401*"
            }
        }

        Describe 'Remove-DHIS2PersonalAccessToken' {
            BeforeEach {
                $null = Add-FakeToken 'TokAlice001' 'UsrAlice001'
                $null = Add-FakeToken 'TokAlice002' 'UsrAlice001'
                $null = Add-FakeToken 'TokAlice003' 'UsrAlice001'
                $null = Add-FakeToken 'TokBobby001' 'UsrBobby001' -SharedWith 'UsrAlice001'
                $script:AliceUsesOwnToken = Get-FakeAuth 'TokAlice003'
            }

            It 'reports a failed delete as that token''s error and still removes the tokens after it' {
                # alice may read bob's token, which bob shared with her, but not delete it: DHIS2 answers 403.
                $removed = @(Remove-DHIS2PersonalAccessToken -Id 'TokAlice001', 'TokBobby001', 'TokAlice002' -Auth $script:AliceUsesOwnToken -Hostname $script:Host1 `
                        -Force -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable failures)
                Get-DeletedId | Should -Be @('TokAlice001', 'TokBobby001', 'TokAlice002')
                @($removed | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('TokAlice001=Deleted', 'TokBobby001=Failed', 'TokAlice002=Deleted')
                $removed[1].HttpStatusCode | Should -Be 403
                # The error variable records the one error once per frame it passes through, so the check is on what
                # failed, not on how often it was recorded.
                $records = @($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $records.Count | Should -BeGreaterThan 0
                @($records | Where-Object { [string]$_.TargetObject -cne 'api/apiToken/TokBobby001' }).Count | Should -Be 0
                $records[0].Exception.StatusCode | Should -Be ([System.Net.HttpStatusCode]::Forbidden)
                $records[0].FullyQualifiedErrorId | Should -BeLike 'NeoIPCDhis2DeleteFailed*'
            }
            It 'deletes nothing under -WhatIf, and says what it would delete' {
                $removed = @(Remove-DHIS2PersonalAccessToken -Id 'TokAlice001', 'TokAlice002' -Auth $script:AliceUsesOwnToken -Hostname $script:Host1 -WhatIf 6>$null)
                @(Get-FakeRequest 'DELETE').Count | Should -Be 0
                @($removed.Outcome) | Should -Be @('WouldDelete', 'WouldDelete')
                $script:Fake.Tokens.Count | Should -Be 4
            }
            It 'ends the run at an HTTP 401 before the third token, once it has deleted the token it authenticates with' {
                $stop = $null
                $removed = [System.Collections.Generic.List[object]]::new()
                try {
                    Remove-DHIS2PersonalAccessToken -Id 'TokAlice003', 'TokAlice001', 'TokAlice002' -Auth $script:AliceUsesOwnToken -Hostname $script:Host1 -Force `
                        -ErrorAction SilentlyContinue | ForEach-Object { $removed.Add($_) }
                }
                catch { $stop = $_ }
                Get-DeletedId | Should -Be @('TokAlice003', 'TokAlice001')
                @($removed | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('TokAlice003=Deleted', 'TokAlice001=Failed')
                $stop | Should -Not -BeNullOrEmpty
                $stop.Exception.Message | Should -BeLike '*no longer accepts the credentials*'
                $stop.CategoryInfo.Category | Should -Be 'AuthenticationError'
                @($script:Fake.Tokens.Id) | Should -Contain 'TokAlice002'
            }
            It 'refuses an id that is no UID without sending anything for it' {
                $removed = @(Remove-DHIS2PersonalAccessToken -Id '../users/UsrBobby001', 'TokAlice001' -Auth $script:AliceUsesOwnToken -Hostname $script:Host1 `
                        -Force -ErrorAction SilentlyContinue -ErrorVariable failures)
                Get-DeletedId | Should -Be @('TokAlice001')
                @($removed | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('../users/UsrBobby001=Failed', 'TokAlice001=Deleted')
                @($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
            }
            It 'never shows nor sends a token given as an id, <Case>' -ForEach @(
                @{ Case = 'as it is'; Prefix = '' }
                @{ Case = 'after a space'; Prefix = ' ' }
                @{ Case = 'after the ApiToken scheme of an Authorization header'; Prefix = 'ApiToken ' }
            ) {
                $plaintext = (Get-FakeAuth 'TokAlice001').Token
                $removed = @(Remove-DHIS2PersonalAccessToken -Id ($Prefix + $plaintext) -Auth $script:AliceUsesOwnToken -Hostname $script:Host1 -Force -ErrorAction SilentlyContinue -ErrorVariable failures)
                $script:Fake.Requests.Count | Should -Be 0
                ($removed | Out-String) | Should -Not -BeLike "*$plaintext*"
                (@($failures | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | ForEach-Object { "$_ $($_.TargetObject)" }) -join ' ' | Should -Not -BeLike "*$plaintext*"
            }
            It 'says that DHIS2 refused the credentials, with DHIS2''s message, at an HTTP 401 before any deletion, for <Case>' -ForEach @(
                @{ Case = 'Basic authentication DHIS2 does not accept'; Kind = 'Basic'; Dhis2Message = 'Unauthorized' }
                @{ Case = 'an expired token'; Kind = 'ExpiredToken'; Dhis2Message = 'Failed to authenticate API token, token has expired.' }
            ) {
                $auth = if ($Kind -eq 'Basic') { Get-BasicAuth 'nobody' }
                else {
                    $null = Add-FakeToken 'TokAlice009' 'UsrAlice001' -Expire ([System.DateTimeOffset]::UtcNow.AddDays(-1).ToUnixTimeMilliseconds())
                    Get-FakeAuth 'TokAlice009'
                }
                $stop = $null
                $removed = [System.Collections.Generic.List[object]]::new()
                try {
                    Remove-DHIS2PersonalAccessToken -Id 'TokAlice001', 'TokAlice002' -Auth $auth -Hostname $script:Host1 -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { $removed.Add($_) }
                }
                catch { $stop = $_ }
                Get-DeletedId | Should -Be @('TokAlice001') -Because 'the second token is never sent'
                @($removed | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('TokAlice001=Failed')
                $stop.Exception.Message | Should -BeExactly "DHIS2 refused the credentials (HTTP 401) at the personal access token 'TokAlice001', so no later token was sent. DHIS2's message: $Dhis2Message"
                $stop.CategoryInfo.Category | Should -Be 'AuthenticationError'
                @($script:Fake.Tokens.Id) | Should -Contain 'TokAlice001'
            }
            It 'has a mandatory -Hostname without a default' {
                $parameter = (Get-Command Remove-DHIS2PersonalAccessToken).Parameters['Hostname']
                @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object Mandatory) | Should -Not -Contain $false
            }

            Context 'asked as a person would be' {
                It 'deletes the second token and reports it as deleted when -Confirm is declined for the first and accepted for the second' {
                    $run = Invoke-Scripted -Answers 'No', 'Yes' -Variables @{ Auth = $script:AliceUsesOwnToken } `
                        -Command "Remove-DHIS2PersonalAccessToken -Id 'TokAlice001', 'TokAlice002' -Auth `$Auth -Hostname '$($script:Host1)' -Confirm"
                    $run.Stop | Should -BeNullOrEmpty
                    $run.Errors.Count | Should -Be 0
                    $run.Prompts.Count | Should -Be 2
                    $run.Prompts[0] | Should -BeLike "*'TokAlice001'*"
                    $run.Prompts[1] | Should -BeLike "*'TokAlice002'*"
                    Get-DeletedId | Should -Be @('TokAlice002')
                    @($run.Output | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('TokAlice001=Declined', 'TokAlice002=Deleted')
                }
                It 'asks once for each token at the default confirm preference' {
                    $run = Invoke-Scripted -Answers 'Yes', 'Yes' -Variables @{ Auth = $script:AliceUsesOwnToken } `
                        -Command "Remove-DHIS2PersonalAccessToken -Id 'TokAlice001', 'TokAlice002' -Auth `$Auth -Hostname '$($script:Host1)'"
                    $run.Stop | Should -BeNullOrEmpty
                    $run.Prompts.Count | Should -Be 2
                    @($run.Output | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('TokAlice001=Deleted', 'TokAlice002=Deleted')
                }
                It 'asks nothing under -Force' {
                    $run = Invoke-Scripted -Variables @{ Auth = $script:AliceUsesOwnToken } `
                        -Command "Remove-DHIS2PersonalAccessToken -Id 'TokAlice001', 'TokAlice002' -Auth `$Auth -Hostname '$($script:Host1)' -Force"
                    $run.Stop | Should -BeNullOrEmpty
                    $run.Prompts.Count | Should -Be 0
                    Get-DeletedId | Should -Be @('TokAlice001', 'TokAlice002')
                }
                It 'asks under -Force when -Confirm is given too' {
                    $run = Invoke-Scripted -Answers 'No' -Variables @{ Auth = $script:AliceUsesOwnToken } `
                        -Command "Remove-DHIS2PersonalAccessToken -Id 'TokAlice001' -Auth `$Auth -Hostname '$($script:Host1)' -Force -Confirm"
                    $run.Prompts.Count | Should -Be 1
                    @(Get-FakeRequest 'DELETE').Count | Should -Be 0
                }
                It 'names in its confirmation the host the request goes to, given with spaces around it' {
                    $run = Invoke-Scripted -Answers 'Yes' -Variables @{ Auth = $script:AliceUsesOwnToken } `
                        -Command "Remove-DHIS2PersonalAccessToken -Id 'TokAlice001' -Auth `$Auth -Hostname ' $($script:Host1) ' -Confirm"
                    $run.Stop | Should -BeNullOrEmpty
                    $run.Prompts.Count | Should -Be 1
                    $run.Prompts[0] | Should -BeExactly "Delete the personal access token 'TokAlice001' on https://$($script:Host1)?"
                    Get-DeletedId | Should -Be @('TokAlice001')
                }
                # Where no try encloses it, PowerShell drops under SilentlyContinue an error a function throws and runs on:
                # the token reader would then hand back nothing, and the run ask for a password and delete with it.
                It 'stops before asking for credentials or deleting anything when -Token names no file, under -ErrorAction SilentlyContinue too' {
                    $missing = (Join-Path $TestDrive 'no-such-token.txt').Replace("'", "''")
                    $run = Invoke-Scripted -NoTry -Command "Remove-DHIS2PersonalAccessToken -Id 'TokAlice001' -Hostname '$($script:Host1)' -Token '$missing' -Force -ErrorAction SilentlyContinue"
                    $run.Stop | Should -BeNullOrEmpty
                    $run.Inputs | Should -BeNullOrEmpty
                    @(Get-FakeRequest 'DELETE').Count | Should -Be 0
                    $run.Output | Should -BeNullOrEmpty
                    @($run.Errors).Count | Should -Be 1
                    $run.Errors[0].Exception.Message | Should -BeExactly '-Token holds neither a DHIS2 personal access token nor the path of an existing file.'
                }
            }
        }

        Describe 'Clear-DHIS2PersonalAccessTokens' {
            BeforeEach {
                $past = [System.DateTimeOffset]::UtcNow.AddDays(-1).ToUnixTimeMilliseconds()
                $null = Add-FakeToken 'TokAlice001' 'UsrAlice001' -Expire $past
                $null = Add-FakeToken 'TokAlice002' 'UsrAlice001' -Expire 0
                $null = Add-FakeToken 'TokAlice003' 'UsrAlice001'
                # DHIS2 always gives an expiry (the column is NOT NULL); this token stands for an answer without one.
                $null = Add-FakeToken 'TokAlice004' 'UsrAlice001' -Expire $null
                $null = Add-FakeToken 'TokBobby001' 'UsrBobby001' -Expire $past -SharedWith 'UsrAlice001'
                $null = Add-FakeToken 'TokAdmin001' 'UsrAdmin001'
            }

            It 'deletes only the caller''s expired tokens by default, never one without an expiry' {
                $removed = @(Clear-DHIS2PersonalAccessTokens -Auth (Get-FakeAuth 'TokAlice003') -Hostname $script:Host1 -Force)
                Get-DeletedId | Should -Be @('TokAlice001', 'TokAlice002')
                @($removed.Outcome) | Should -Be @('Deleted', 'Deleted')
            }
            It 'deletes every one of the caller''s tokens with -All' {
                $null = Clear-DHIS2PersonalAccessTokens -All -Auth (Get-FakeAuth 'TokAdmin001') -Hostname $script:Host1 -Force
                Get-DeletedId | Should -Be @('TokAdmin001')
            }
            It 'deletes other users'' expired tokens too with -AllUsers, as a superuser' {
                $null = Clear-DHIS2PersonalAccessTokens -AllUsers -Auth (Get-FakeAuth 'TokAdmin001') -Hostname $script:Host1 -Force
                Get-DeletedId | Should -Be @('TokAlice001', 'TokAlice002', 'TokBobby001')
            }
            It 'ends the run at the first HTTP 401, once it has deleted the token it authenticates with' {
                $script:Fake.Tokens.Clear()
                $null = Add-FakeToken 'TokAlice003' 'UsrAlice001'
                $null = Add-FakeToken 'TokAlice001' 'UsrAlice001'
                $null = Add-FakeToken 'TokAlice002' 'UsrAlice001'
                { Clear-DHIS2PersonalAccessTokens -All -Auth (Get-FakeAuth 'TokAlice003') -Hostname $script:Host1 -Force -ErrorAction SilentlyContinue } |
                    Should -Throw '*no longer accepts the credentials*'
                Get-DeletedId | Should -Be @('TokAlice003', 'TokAlice001')
            }
            It 'deletes nothing under -WhatIf' {
                $removed = @(Clear-DHIS2PersonalAccessTokens -Auth (Get-FakeAuth 'TokAlice003') -Hostname $script:Host1 -WhatIf 6>$null)
                @(Get-FakeRequest 'DELETE').Count | Should -Be 0
                @($removed.Outcome) | Should -Be @('WouldDelete', 'WouldDelete')
            }
            It 'resolves the credentials once and passes them on to the deletion' {
                Mock Resolve-NeoIPCAuth { Get-BasicAuth 'alice' }
                $null = Clear-DHIS2PersonalAccessTokens -UserName 'alice' -Hostname $script:Host1 -Force
                Should -Invoke Resolve-NeoIPCAuth -Times 1 -Exactly
                Get-DeletedId | Should -Be @('TokAlice001', 'TokAlice002')
            }
            It 'asks for the password once, and deletes with the credentials it resolved' {
                Mock Read-Host {
                    if (-not $AsSecureString) { throw 'asked for the username' }
                    if ($script:PasswordAsked) { throw 'asked for the password a second time' }
                    $script:PasswordAsked = $true
                    [System.Net.NetworkCredential]::new('', 'made-up').SecurePassword
                }
                $script:PasswordAsked = $false
                $removed = @(Clear-DHIS2PersonalAccessTokens -UserName 'alice' -Hostname $script:Host1 -Force)
                Should -Invoke Read-Host -Times 1 -Exactly
                @($removed.Outcome) | Should -Be @('Deleted', 'Deleted')
            }
            It 'has a mandatory -Hostname without a default' {
                $parameter = (Get-Command Clear-DHIS2PersonalAccessTokens).Parameters['Hostname']
                @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | ForEach-Object Mandatory) | Should -Not -Contain $false
            }
            It 'asks once for each token and nothing of its own under -Confirm' {
                $run = Invoke-Scripted -Answers 'No', 'Yes' -Variables @{ Auth = (Get-FakeAuth 'TokAlice003') } `
                    -Command "Clear-DHIS2PersonalAccessTokens -Auth `$Auth -Hostname '$($script:Host1)' -Confirm"
                $run.Stop | Should -BeNullOrEmpty
                $run.Prompts.Count | Should -Be 2
                Get-DeletedId | Should -Be @('TokAlice002')
                @($run.Output | ForEach-Object { "$($_.Id)=$($_.Outcome)" }) | Should -Be @('TokAlice001=Declined', 'TokAlice002=Deleted')
            }
        }

        Describe 'Help' {
            It 'documents every parameter of <Name>' -ForEach @(
                @{ Name = 'Read-DHIS2PersonalAccessToken' }
                @{ Name = 'Remove-DHIS2PersonalAccessToken' }
                @{ Name = 'Clear-DHIS2PersonalAccessTokens' }
            ) {
                $help = Get-Help $Name -Full
                $help.Synopsis | Should -Not -BeLike "*$Name*" -Because 'a missing help block leaves Get-Help a synthesized syntax line'
                @($help.parameters.parameter | Where-Object { -not $_.description } | ForEach-Object name) | Should -BeNullOrEmpty
            }
            It 'parses a help block for every function of Public/PAT.ps1' {
                $path = Join-Path (Get-Module NeoIPC-Tools).ModuleBase 'Public/PAT.ps1'
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
                $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
                $functions.Count | Should -Be 3
                foreach ($f in $functions) { $f.GetHelpContent().Synopsis | Should -Not -BeNullOrEmpty -Because "$($f.Name) needs help" }
            }
        }
    }
}
