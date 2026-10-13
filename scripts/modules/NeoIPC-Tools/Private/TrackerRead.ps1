#Requires -Version 7.6
# What the tracker reads Read-PatientInfo, Read-EnrolmentInfo, and Read-EventInfo share: their errors, the program
# NEOIPC_CORE, a read of its records with DHIS2's refusals made plain, the org units a record lies in, the link into the
# Capture apps, and the conversion of the values DHIS2 returns.

function Get-NeoIPCDistinctValue {
    # The values in first-seen order without repeats, null, or empty ones, compared ordinally: codes and UIDs are
    # case-sensitive, while Sort-Object -Unique and Select-Object -Unique compare ignoring case. Returns one string[], empty
    # or not, so a caller assigns the call rather than wrapping it in @(), which would nest the array.
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Value)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $Value) { if (-not [string]::IsNullOrEmpty($v) -and $seen.Add($v)) { $result.Add($v) } }
    , $result.ToArray()
}

function Split-NeoIPCOptionalList {
    # Split-NeoIPCList's chunks, or a single empty chunk when there is no value: the one request a read without that list
    # makes. Several lists in one read are sent as the cross product of their chunks.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string[]]])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Value, [Parameter(Mandatory)][string]$Separator)
    $chunks = [System.Collections.Generic.List[string[]]]::new()
    if ($Value.Count -gt 0) { foreach ($chunk in (Split-NeoIPCList -Value $Value -Separator $Separator)) { $chunks.Add($chunk) } }
    else { $chunks.Add([string[]]@()) }
    , $chunks
}

function ConvertFrom-NeoIPCDhis2Timestamp {
    # A DHIS2 timestamp as [datetime]. DHIS2 writes them in the server's time without a zone ('2025-01-15T10:30:00.123'),
    # so they parse as DateTimeKind.Unspecified; RoundtripKind keeps a zone should one be given. No value gives $null.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    [datetime]::Parse($text, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-NeoIPCDhis2Username {
    # The username of a createdBy or updatedBy object a read returns, or $null when it has none.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$User)
    if ($User -isnot [System.Collections.IDictionary]) { return $null }
    $name = [string]$User['username']
    if ([string]::IsNullOrEmpty($name)) { return $null }
    $name
}

function New-NeoIPCTrackerReadError {
    # The error record a tracker read writes, or ends with, for a reason of its own (DHIS2's refusals keep the record the
    # GET helper made). Its ErrorId is NeoIPCTrackerRead<ErrorId>.
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][System.Management.Automation.ErrorCategory]$Category,
        [AllowNull()]$TargetObject
    )
    $exception = if ($Category -eq [System.Management.Automation.ErrorCategory]::InvalidArgument) { [System.ArgumentException]::new($Message) }
    else { [System.InvalidOperationException]::new($Message) }
    [System.Management.Automation.ErrorRecord]::new($exception, "NeoIPCTrackerRead$ErrorId", $Category, $TargetObject)
}

function Write-NeoIPCTrackerReadError {
    # Writes a non-terminating error of a tracker read through its cmdlet, so that the caller's -ErrorAction decides.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$ErrorId,
        [Parameter(Mandatory)][string]$Message,
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::ObjectNotFound,
        [AllowNull()]$TargetObject
    )
    $Cmdlet.WriteError((New-NeoIPCTrackerReadError -ErrorId $ErrorId -Message $Message -Category $Category -TargetObject $TargetObject))
}

function Test-NeoIPCTrackerReadInput {
    # Whether a tracker read has anything to read. False, after an error naming the parameter, when a filter given as an
    # argument holds no value, since reading without it would widen the read to every record; false without an error when
    # the cmdlet takes pipeline input and none of its filters received a value, since an empty upstream must not widen
    # the read either.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][hashtable]$Given,
        [AllowEmptyCollection()][string[]]$Explicit = @(),
        [switch]$ExpectingInput
    )
    foreach ($name in $Explicit) {
        if ((Get-NeoIPCDistinctValue -Value $Given[$name]).Count -eq 0) {
            Write-NeoIPCTrackerReadError -Cmdlet $Cmdlet -ErrorId 'EmptyFilter' -Category InvalidArgument -TargetObject $name `
                -Message "-$name holds no value, so it selects nothing; leave it out to read without it."
            return $false
        }
    }
    if (-not $ExpectingInput) { return $true }
    foreach ($name in $Given.Keys) { if ((Get-NeoIPCDistinctValue -Value $Given[$name]).Count -gt 0) { return $true } }
    $false
}

function Select-NeoIPCTrackerReadUid {
    # The values that are DHIS2 UIDs, after an error per value that is none: no record has it, and DHIS2 2.40 drops such a
    # value from some list parameters instead of refusing it, which would widen the read.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [AllowEmptyCollection()][string[]]$Value = @(),
        [Parameter(Mandatory)][string]$Noun
    )
    $valid = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $Value) {
        if (Test-NeoIPCMetadataUid -Id $v) { $valid.Add($v) }
        else {
            Write-NeoIPCTrackerReadError -Cmdlet $Cmdlet -ErrorId 'NotAUid' -TargetObject $v -Message "No $Noun has the UID '$v': it is not a DHIS2 UID."
        }
    }
    , $valid.ToArray()
}

function Resolve-NeoIPCTrackerReadOrgUnit {
    # The UIDs of the org units a tracker read is filtered by, from codes and UIDs looked up within the caller's hierarchy
    # (Resolve-NeoIPCOrgUnit), in the order given, after an error per code or UID that names no org unit there. Given says
    # whether any code or UID was given; Ids is empty when none of them names an org unit, and the read then reads nothing.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [AllowEmptyCollection()][string[]]$Code = @(),
        [AllowEmptyCollection()][string[]]$Id = @()
    )
    if ($Code.Count -eq 0 -and $Id.Count -eq 0) { return [pscustomobject]@{ Given = $false; Ids = [string[]]@() } }
    $found = Resolve-NeoIPCOrgUnit -Endpoint $Endpoint -Code $Code -Id $Id -Fields 'code'
    foreach ($c in $found.MissingCode) {
        Write-NeoIPCTrackerReadError -Cmdlet $Cmdlet -ErrorId 'OrgUnitNotFound' -TargetObject $c -Message "No org unit in your hierarchy has the code '$c' (codes compare exactly)."
    }
    foreach ($i in $found.MissingId) {
        Write-NeoIPCTrackerReadError -Cmdlet $Cmdlet -ErrorId 'OrgUnitNotFound' -TargetObject $i -Message "No org unit in your hierarchy has the UID '$i'."
    }
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $Code) { if ($found.ByCode.ContainsKey($c)) { $ids.Add([string]$found.ByCode[$c]['id']) } }
    foreach ($i in $Id) { if ($found.ById.ContainsKey($i)) { $ids.Add($i) } }
    [pscustomobject]@{ Given = $true; Ids = (Get-NeoIPCDistinctValue -Value $ids) }
}

function Get-NeoIPCCoreProgram {
    # The program NEOIPC_CORE, resolved by its code with api/metadata, which reads any further metadata the caller asks for
    # in the same request (-Query: more '<type>:filter' and '<type>:fields' pairs). Program is the program's dictionary
    # (id, code, and -ProgramField), Metadata the whole answer, which leaves out a type nothing matched rather than
    # listing it empty. Ends the read unless exactly one program the account can read has the code, compared exactly.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [AllowEmptyCollection()][string[]]$ProgramField = @(),
        [hashtable]$Query = @{}
    )
    $q = @{ 'programs:filter' = 'code:eq:NEOIPC_CORE'; 'programs:fields' = (@('id', 'code') + $ProgramField) -join ',' }
    foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] }
    $metadata = Invoke-NeoIPCDhis2Get @Endpoint -Path 'api/metadata' -QueryParameters $q -AsHashtable -Confirm:$false -WhatIf:$false
    $programs = @(if ($metadata -is [System.Collections.IDictionary]) {
            @($metadata['programs']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['code'] -ceq 'NEOIPC_CORE' }
        })
    if ($programs.Count -ne 1 -or -not (Test-NeoIPCMetadataUid -Id ([string]$programs[0]['id']))) {
        throw (New-NeoIPCTrackerReadError -ErrorId 'NoProgram' -Category ObjectNotFound -TargetObject 'NEOIPC_CORE' `
                -Message 'The instance holds no program NEOIPC_CORE that your account can read, so there are no NeoIPC tracker records to read.')
    }
    [pscustomobject]@{ Program = $programs[0]; Metadata = $metadata }
}

function Get-NeoIPCCoreTrackerList {
    # One read of NEOIPC_CORE's tracker records in the version's dialect (Get-NeoIPCTrackerList), with the two refusals
    # an account can act on made plain:
    #   1. no data-capture org units, which DHIS2 requires for reading the records of a CLOSED program such as
    #      NEOIPC_CORE: "User needs to be assigned data capture org units" (409 on 2.40's event read, 400 on 2.41, 403 on
    #      2.42 and later); on 2.40's tracked-entity and enrolment reads "Current user must be associated with at least
    #      one organisation unit when selection mode is ACCESSIBLE", and on its tracked-entity read also "User need to be
    #      associated with at least one organisation unit." (both 409);
    #   2. no data read access to the program: "User has no access to program: <uid>" (403), on 2.40's tracked-entity and
    #      enrolment reads "Current user is not authorized to read data from selected program:  <uid>" (409).
    # Every other failure passes through unchanged.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)]$Dialect,
        [Parameter(Mandatory)][ValidateSet('events', 'enrollments', 'trackedEntities')][string]$Resource,
        [Parameter(Mandatory)][hashtable]$Query,
        [Parameter(Mandatory)][string[]]$Fields
    )
    try { Get-NeoIPCTrackerList -Endpoint $Endpoint -Dialect $Dialect -Resource $Resource -Query $Query -Fields $Fields }
    catch {
        $exception = $_.Exception
        $status = if ($exception -is [System.Net.Http.HttpRequestException] -and $null -ne $exception.StatusCode) { [int]$exception.StatusCode } else { 0 }
        if ($status -in 400, 403, 409) {
            $answer = $exception.Message
            if ($answer -match 'data capture org units|associated with at least one organisation unit') {
                throw (New-NeoIPCTrackerReadError -ErrorId 'NoCaptureOrgUnits' -Category PermissionDenied -TargetObject $Resource `
                        -Message "Your account has no data-capture org units, which DHIS2 requires for reading NEOIPC_CORE's tracker records. $answer")
            }
            if ($answer -match 'no access to program:|read data from selected program:') {
                throw (New-NeoIPCTrackerReadError -ErrorId 'NoProgramAccess' -Category PermissionDenied -TargetObject $Resource `
                        -Message "Your account may not read NEOIPC_CORE's tracker records: it lacks data read access to the program. $answer")
            }
        }
        throw
    }
}

function Test-NeoIPCTrackedEntityMissing {
    # Whether a read failed because the one tracked entity it named does not exist, or is deleted: the enrolment and event
    # reads answer that with 400 "Tracked entity is specified but does not exist: <uid>" ("Tracked entity instance ..." on
    # 2.40) rather than with an empty list.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord, [Parameter(Mandatory)][string]$TrackedEntityId)
    $exception = $ErrorRecord.Exception
    $exception -is [System.Net.Http.HttpRequestException] -and $null -ne $exception.StatusCode -and [int]$exception.StatusCode -eq 400 -and
    $exception.Message -match ('Tracked entity (instance )?is specified but does not exist: ' + [regex]::Escape($TrackedEntityId) + '(\W|$)')
}

function New-NeoIPCUnexpectedItemError {
    # The error a tracker read ends with when DHIS2 returned a record the request did not ask for: DHIS2 2.42 and later
    # ignore a parameter they do not know, and widen the read instead of refusing it.
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param([Parameter(Mandatory)][string]$Resource, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Reason)
    New-NeoIPCTrackerReadError -ErrorId 'UnexpectedItem' -Category InvalidResult -TargetObject $Item `
        -Message ("The {0} read returned {1}, {2}. DHIS2 2.42 and later ignore a parameter they do not know and widen the read instead of refusing it, so this read returns nothing." -f $Resource, $Item, $Reason)
}

function Get-NeoIPCCoreOwner {
    # The org unit that owns NEOIPC_CORE's record of each given tracked entity, keyed by its UID. DHIS2 matches the org
    # units of an enrolment or event read against this owner, on every supported version, rather than against the org
    # unit the record was entered in. Read ACCESSIBLE, which for the CLOSED program NEOIPC_CORE is the caller's capture
    # scope, in chunks; a tracked entity the read does not return has no entry, and one it was not asked for ends the read.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, string]])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)]$Dialect,
        [Parameter(Mandatory)][string]$ProgramId,
        [AllowEmptyCollection()][string[]]$TrackedEntityId = @()
    )
    $ordinal = [System.StringComparer]::Ordinal
    $owners = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
    $distinct = Get-NeoIPCDistinctValue -Value $TrackedEntityId
    $ids = [string[]]@($distinct | Where-Object { Test-NeoIPCMetadataUid -Id $_ })
    $names = $Dialect.TrackedEntityQuery
    foreach ($chunk in (Split-NeoIPCList -Value $ids -Separator $names.Separator)) {
        $asked = [System.Collections.Generic.HashSet[string]]::new([string[]]$chunk, $ordinal)
        $query = @{ program = $ProgramId; $Dialect.OrgUnitMode = 'ACCESSIBLE'; $names.TrackedEntities = $chunk -join $names.Separator }
        foreach ($te in (Get-NeoIPCCoreTrackerList -Endpoint $Endpoint -Dialect $Dialect -Resource 'trackedEntities' -Query $query -Fields 'trackedEntity', 'programOwners[orgUnit,program]')) {
            $uid = [string]$te['trackedEntity']
            if (-not $asked.Contains($uid)) { throw (New-NeoIPCUnexpectedItemError -Resource 'trackedEntities' -Item "the tracked entity '$uid'" -Reason 'which it did not ask for') }
            foreach ($owner in @($te['programOwners'])) {
                if ($owner -is [System.Collections.IDictionary] -and [string]$owner['program'] -ceq $ProgramId) { $owners[$uid] = [string]$owner['orgUnit'] }
            }
        }
    }
    , $owners
}

function Split-NeoIPCTrackerItemByOrgUnit {
    # NEOIPC_CORE enrolments or events, as a read returns them, split by whether they lie in the given org units: entered in
    # one of them, or belonging to a patient whose NEOIPC_CORE record one of them owns. DHIS2 selects them by the owner,
    # which they do not carry, so the owners are read only for those entered elsewhere. Both lists keep the input order.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Endpoint,
        [Parameter(Mandatory)]$Dialect,
        [Parameter(Mandatory)][string]$ProgramId,
        [AllowEmptyCollection()][object[]]$Item = @(),
        [Parameter(Mandatory)][string[]]$OrgUnitId
    )
    $set = [System.Collections.Generic.HashSet[string]]::new($OrgUnitId, [System.StringComparer]::Ordinal)
    $elsewhere = @($Item | Where-Object { -not $set.Contains([string]$_['orgUnit']) })
    $owners = $null
    if ($elsewhere.Count -gt 0) {
        $owners = Get-NeoIPCCoreOwner -Endpoint $Endpoint -Dialect $Dialect -ProgramId $ProgramId -TrackedEntityId @($elsewhere | ForEach-Object { [string]$_['trackedEntity'] })
    }
    $inside = [System.Collections.Generic.List[object]]::new()
    $outside = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $Item) {
        $te = [string]$i['trackedEntity']
        if ($set.Contains([string]$i['orgUnit']) -or ($null -ne $owners -and $owners.ContainsKey($te) -and $set.Contains($owners[$te]))) { $inside.Add($i) }
        else { $outside.Add($i) }
    }
    [pscustomobject]@{ Inside = $inside.ToArray(); Outside = $outside.ToArray() }
}

function Get-NeoIPCTrackerSentValue {
    # The values of a single-value parameter the requests of a read send, one request per entry: the value when there is
    # exactly one, each value when the read sends one request per value of this parameter (-FanOut), else one $null, a
    # request without the parameter, whose values are compared on the client.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[string]])]
    param([AllowNull()][AllowEmptyCollection()][string[]]$Value, [switch]$FanOut)
    $sent = [System.Collections.Generic.List[string]]::new()
    if ($Value.Count -eq 1 -or ($Value.Count -gt 1 -and $FanOut)) { $sent.AddRange($Value) } else { $sent.Add($null) }
    , $sent
}

function Get-NeoIPCPatientAttributeValue {
    # A tracked entity's attribute values, keyed by the attributes' codes, compared exactly: an attribute the metadata read
    # returned, by its UID (-CodeByAttribute); any other by the code the value carries, which DHIS2 before 2.43.2 also
    # returns for an attribute the account cannot read. The first value of a code wins; indexing a code without a value
    # gives $null.
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.Dictionary[string, object]])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$TrackedEntity, [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$CodeByAttribute)
    $values = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($value in @($TrackedEntity['attributes'])) {
        if ($value -isnot [System.Collections.IDictionary]) { continue }
        $uid = [string]$value['attribute']
        $code = if ($CodeByAttribute.ContainsKey($uid)) { $CodeByAttribute[$uid] } else { [string]$value['code'] }
        if ($code -and -not $values.ContainsKey($code)) { $values[$code] = $value['value'] }
    }
    , $values
}

function Test-NeoIPCPatientIdMatch {
    # Whether DHIS2 takes a patient ID for one of the candidates. It compares attribute values lower-cased on both sides
    # (PostgreSQL's lower() on the stored value, Java's toLowerCase() on the filter's), which no single .NET comparison
    # reproduces for every script, so ordinal equality ignoring case and equal invariant lower-case forms both count.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string]$Value, [AllowEmptyCollection()][string[]]$Candidate = @())
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    foreach ($c in $Candidate) {
        if ([string]::Equals($Value, $c, [System.StringComparison]::OrdinalIgnoreCase) -or $Value.ToLowerInvariant() -ceq ([string]$c).ToLowerInvariant()) { return $true }
    }
    $false
}

function Test-NeoIPCTrackerDate {
    # Whether a timestamp lies within the days DHIS2 reads a date-only range parameter as: from the start of -After's day
    # (StartDateTime) to the end of -Before's day (EndDateTime), both in the server's time like the timestamp. A missing
    # timestamp lies in no range, as in DHIS2's SQL comparison.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Value, [Nullable[datetime]]$After, [Nullable[datetime]]$Before)
    if ($null -eq $After -and $null -eq $Before) { return $true }
    if ($Value -isnot [datetime]) { return $false }
    # PowerShell unwraps a Nullable that holds a value, so $After is the [datetime] itself here.
    if ($null -ne $After -and $Value -lt $After.Date) { return $false }
    if ($null -ne $Before -and $Value -ge $Before.Date.AddDays(1)) { return $false }
    $true
}

function Get-NeoIPCDhis2BaseUrl {
    # The address a browser opens the instance at: <scheme>://<host>[:<port>], https by default, the host from
    # Resolve-NeoIPCDhis2Hostname.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Scheme, [string]$Hostname, [Nullable[int]]$Port)
    $builder = [UriBuilder]::new($(if ($Scheme) { $Scheme } else { 'https' }), (Resolve-NeoIPCDhis2Hostname -Hostname $Hostname), $(if ($null -ne $Port) { $Port } else { -1 }))
    $builder.Uri.GetLeftPart([UriPartial]::Authority)
}

function Get-NeoIPCEnrollmentDashboardUrl {
    # Where an enrolment opens in the browser. Up to 2.41 that is Tracker Capture's dashboard. 2.42 and later have no
    # Tracker Capture, and their global shell answers its address with "Unable to find an app for this URL."; they serve
    # the Capture app at /apps/capture, the shell passing the hash route on to the app (global-shell-app
    # PluginLoader.jsx), and Capture's enrolment page reads enrollmentId, orgUnitId, programId, and teiId from it
    # (capture-app EnrollmentPage.container.tsx).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][version]$Version,
        [AllowEmptyString()][string]$EnrollmentId,
        [AllowEmptyString()][string]$TrackedEntityId,
        [AllowEmptyString()][string]$ProgramId,
        [AllowEmptyString()][string]$OrgUnitId
    )
    if ($Version -lt [version]'2.42') {
        # NEOIPC-COMPAT(tracker-capture-dashboard-link): remove once no supported instance runs 2.41 or earlier
        # (/api/system/info version 2.42 or later everywhere).
        return '{0}/dhis-web-tracker-capture/index.html#/dashboard?tei={1}&program={2}&ou={3}' -f $BaseUrl, $TrackedEntityId, $ProgramId, $OrgUnitId
    }
    '{0}/apps/capture#/enrollment?enrollmentId={1}&orgUnitId={2}&programId={3}&teiId={4}' -f $BaseUrl, $EnrollmentId, $OrgUnitId, $ProgramId, $TrackedEntityId
}
