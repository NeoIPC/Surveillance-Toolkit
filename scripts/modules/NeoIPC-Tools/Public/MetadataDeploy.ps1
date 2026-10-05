#Requires -Version 7.6
# Deploy-NeoIPCMetadata: brings a DHIS2 instance to a metadata package and proves it got there, for a synthetic
# seed and for production alike. The planning it rests on is in Private/MetadataDeploy.ps1; the DHIS2 behaviour
# behind each step is described in docs/metadata-deployment.md.

function Deploy-NeoIPCMetadata {
    <#
    .SYNOPSIS
        Deploy a metadata package to a DHIS2 instance: write exactly what differs, keep what belongs to the instance,
        and verify the result.
    .DESCRIPTION
        Reads every package object back from the instance, classifies it as new, changed or unchanged, and writes only
        the new and changed ones, in the order DHIS2 needs:
          1. a detach request: rules written without the actions that refer to something a parent's write removes
             (DHIS2 refuses to delete a stage section a live rule action targets, and a stage's write commits before
             its rules), and rules the package makes inert;
          2. R1, every written object, without the references DHIS2 would drop because their target is created in the
             same request;
          3. the resets of option group sets whose list changes other than by an append, or loses a group to another
             set (UNIQUE(optiongroupid) makes such a list fail in one write);
          4. R2, the deferred references, the final lists of the option group sets R1 cannot write (those step 3
             reset, those that gain a group created in this run or taken from another set, and those created in this
             run), and each parent that gives a child (a rule action, a stage section or notification template) to
             another stage or rule the package carries: R1 moves the child with its new parent, since DHIS2 2.40.12
             fails a request that writes both parents of an action or a template, and the caches are cleared again
             before R2, which must read the parents' collections from the database;
          5. on DHIS2 2.42 and later, each changed program-rule action with a notification template on its own (any
             update of one fails whole there): deleted, read back, re-created with its rule, verified, and restored
             from a snapshot if that fails;
          6. the -Delete entries, one object per request, each read back;
          7. last, every program of the package that exists on the instance (a new one is created in R1), once,
             carrying its live version, whenever anything that clients load with a program changed: clients reload a
             program's rules and forms only when its version changes. When a run fails after it has committed such a
             change but before this request, the summary's ProgramVersionPending names the programs, and a later run
             with -BumpProgramVersion moves them.
        Then it verifies: the round-trip (Test-NeoIPCMetadataImport against the written bodies, translations
        included), that every object now compares unchanged, that every declared rule action is served, the
        version bumps, and every delete.

        What belongs to the instance is copied from it into each written body and never compared: org-unit
        assignments and memberships, user-group memberships, attribute values, favourite marks, and the creation
        audit pair. So is the sharing of an object the package gives none, since DHIS2 resets the sharing of an
        object written without a public access string, grants included. For that reason the deployment stops before
        any write when the sharing the package gives an object has no public access string, or when the instance's
        sharing of an object it keeps has none; and DHIS2 refuses to write a kept grant to a user or user group that
        no longer exists, which the dry run shows. Translations the package lacks are kept, except those of a
        property whose value changes. Everything else the type maps describe is the package's: a property the
        package leaves out is cleared.

        Before any write, a hazard gate aborts unless each kind found is acknowledged with -AllowHazard:
          - UnverifiedVersion: an instance on a DHIS2 release the deployment was not verified on: a line other than
            2.40 to 2.43, or a patch below 2.40.12, 2.41.10, 2.42.6 or 2.43.1 in its line. The DHIS2 behaviour its
            rules answer to was read in the source of those four releases and observed on them;
          - OrphanDelete: a child the package drops from a written parent, which DHIS2 deletes with the parent's
            write (a stage's section, a rule's action, a program's attribute), and which neither -Delete nor another
            parent of the package lists;
          - OptionSetMembership: an option set losing members, which its write detaches unless the package gives them
            to another set (values stored under its data elements keep their codes either way), or gaining one
            anywhere but at the end, or an option set in -Delete (its options go with it);
          - OptionCodeChange: an option whose code changes (stored values are keyed by code);
          - OptionNameChange: an option that keeps its code and changes its name: every value stored under the code
            shows the new name, so each must be checked to be a new spelling of the same thing, not a new meaning;
          - SharingGrantRemoval: a permission the live sharing grants, through the public access string or a user's
            or user group's grant, that the sharing the package gives the object does not: a grant the package leaves
            out, or an access string it narrows. A missing access string grants every permission, and the data
            permissions count only for a type that shares data;
          - ActiveRuleDelete: a rule in -Delete that is not inert on the instance (inert: condition 'false' and no
            actions). Clients keep running a rule they cached after the server deletes it, so a rule is first made
            inert by one deployment and deleted by a later one.
        DHIS2 refuses to delete what something still refers to: a stage section or stage that a program-rule action,
        rule variable or rule refers to; an option set that a data element, a tracked-entity attribute, an attribute,
        an option group or an option group set refers to; an option group a group set lists; an option (which goes
        with its set) that an option group holds or an action targets; and, from 2.42, a notification template an
        action sends (up to 2.41 the template goes and the action keeps its id). The live objects decide which
        references exist. One whose holder goes first is no obstacle. One the package points elsewhere is repointed
        when R1 writes it, and when its target goes with a parent's write, the rule that holds the action writes it
        out first and R1 creates it again. Each other one stops the deployment before any write, naming it: a package
        object, new or kept, still referring to the target; one the package carries but R1 does not write, as it
        compares unchanged; one the package does not carry; and an action whose target goes with a parent's write
        while the action itself goes only with its rule's -Delete entry, or the package does not carry its rule. DHIS2
        also refuses to delete a program stage that has events, deleted ones included, which stops the deployment
        before any write too. A stage's DELETE deletes the event visualizations built on it and clears the stage on the
        map views that use it, so a stage in -Delete that one of them uses stops the deployment, and so does, on DHIS2
        2.40, any event visualization without a stage, which makes every stage's delete fail there. A program written
        without one of its stages or sections only detaches it, so each one the package drops must be listed in
        -Delete, which deletes it through its own endpoint. DHIS2 refuses an option whose name or code another option
        of its set holds, as the set is stored before the request, so a name or code passed from one option to another
        stops the deployment before any write: free it in one deployment and give it in a later one.

        A child the package moves to another parent it carries is no orphan, and nothing refers to it as removed. The
        move is refused before any write when the child is no rule action, stage section or notification template;
        when a program is either parent (a template's row holds its program apart from its stage, and programs are
        written last); when the old parent is one the package does not carry, whether -Delete deletes it or it stays
        on the instance; when one parent both gives a child and takes one; and, from DHIS2 2.42, when it is an action
        that sends a notification. An option moves between two sets the package carries in R1, written with both of
        them; one taken from a set the package does not carry is refused alike.

        It DRIVES a DHIS2 instance. A committing run confirms first (ConfirmImpact High); -Confirm:$false runs
        unattended. -DryRun writes nothing: it validates the final bodies in one VALIDATE request (which sees no
        failure that happens only when DHIS2 flushes the write, such as a unique key) and reports the plan, including
        the objects present only on the instance; it asks before clearing the caches. A package or arguments the
        deployment cannot carry out are refused before anything is written; any other failure throws a terminating
        error whose TargetObject is the summary.
    .PARAMETER Path
        Path to the metadata package JSON file.
    .PARAMETER Json
        The package JSON, instead of -Path.
    .PARAMETER Auth
        Auth hashtable from Resolve-NeoIPCAuth (Token or Basic). The deployment needs metadata write access and,
        for the cache clears, F_PERFORM_MAINTENANCE.
    .PARAMETER Hostname
        The DHIS2 host. Mandatory, with no default, so a deployment always names its target.
    .PARAMETER Scheme
        http or https. Default https.
    .PARAMETER Port
        DHIS2 port. Default none (the scheme's).
    .PARAMETER Delete
        Objects to delete, as type -> ids (@{ optionGroups = 'id1', 'id2'; programRules = 'id3' }). An entry for a
        child of an owning collection (a stage section, a rule action, ...) acknowledges the delete the parent's
        write performs; it is never deleted through its own endpoint. Programs are refused: DHIS2 deletes a program's
        stages, rules, rule variables and indicators with it, and the relationship types, event reports, event charts
        and event visualizations built on it, none of which a deployment checks or reads back. Single options are
        refused too: on DHIS2 2.40.12 an option's own DELETE, which DHIS2 runs as a metadata import with
        importStrategy DELETE, is refused while its set lists it, and on an earlier 2.40 patch such an import of an
        option that was not last in its set left a gap in the set's order, which broke every later read of the set.
        Drop an option from its set's list instead, or delete the whole set.
    .PARAMETER AllowHazard
        The hazard kinds this deployment accepts (see the description).
    .PARAMETER DryRun
        Plan, validate and report; write nothing.
    .PARAMETER SkipCacheClear
        Do not clear DHIS2's caches. A fresh DHIS2 2.40-2.42 JVM aborts the first metadata import unless they are
        cleared, the served-actions check cannot tell a stale cache from a missing action without a clear, and a child
        moved to another parent relies on R2 reading the old parent's collection from the database.
    .PARAMETER SyntheticInstance
        Deploy to a synthetic instance (the seed): every hazard kind is accepted, a dropped child needs no -Delete
        entry, users are deployed, and the package's memberships govern for every type whose package objects carry
        them. Never use it against an instance that holds real data.
    .PARAMETER BumpProgramVersion
        Write every existing program of the package last, carrying its live version, even when nothing else changed:
        after a run that failed once it had committed changes clients load with a program (its summary's
        ProgramVersionPending), so that clients reload them.
    .OUTPUTS
        [pscustomobject] summary: the plan per type, the objects written and deleted ("type|id" in Written and
        Deleted), the children moved to another parent (Moved), hazards, steps, version bumps, dropped translations,
        properties kept from the instance (Kept), package values of such properties, which are not written
        (IgnoredPackageValues), objects present live but absent from the package (LiveOnly), the verification, the
        programs whose version a failed run left unmoved (ProgramVersionPending), and the snapshots of notification
        actions taken before their re-creation (Snapshots).
    .EXAMPLE
        Deploy-NeoIPCMetadata -Path ./neoipc-metadata.json -Auth $auth -Hostname neoipc.example.org -DryRun
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Json')][string]$Json,
        [Parameter(Mandatory)][hashtable]$Auth,
        [Parameter(Mandatory)][string]$Hostname,
        [string]$Scheme = 'https',
        [Nullable[int]]$Port = $null,
        [System.Collections.IDictionary]$Delete = @{},
        [ValidateSet('UnverifiedVersion', 'OrphanDelete', 'OptionSetMembership', 'OptionCodeChange', 'OptionNameChange', 'SharingGrantRemoval', 'ActiveRuleDelete')]
        [string[]]$AllowHazard = @(),
        [switch]$DryRun,
        [switch]$SkipCacheClear,
        [switch]$SyntheticInstance,
        [switch]$BumpProgramVersion
    )

    # Every refusal below, and every failure inside a helper, ends the deployment whatever the caller's error
    # preference: under SilentlyContinue or Ignore, PowerShell drops a throw that no try encloses and runs on past it.
    $ErrorActionPreference = 'Stop'
    $ordinal = [System.StringComparer]::Ordinal
    $endpoint = @{ Auth = $Auth; Scheme = $Scheme; Hostname = $Hostname }
    if ($null -ne $Port) { $endpoint['Port'] = $Port }
    $target = '{0}://{1}{2}' -f $Scheme, $Hostname, $(if ($null -ne $Port) { ":$Port" } else { '' })

    $summary = [pscustomobject]@{
        Target              = $target
        Dhis2Version        = $null
        DryRun              = [bool]$DryRun
        Synthetic           = [bool]$SyntheticInstance
        Plan                = [System.Collections.Generic.List[object]]::new()
        Written             = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        Deleted             = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        Moved               = [System.Collections.Generic.List[object]]::new()
        Hazards             = [System.Collections.Generic.List[object]]::new()
        Steps               = [System.Collections.Generic.List[object]]::new()
        Versions            = [System.Collections.Generic.List[object]]::new()
        Kept                = [System.Collections.Generic.List[object]]::new()
        IgnoredPackageValues = [System.Collections.Generic.List[object]]::new()
        DroppedTranslations = [System.Collections.Generic.List[object]]::new()
        LiveOnly            = [System.Collections.Generic.List[object]]::new()
        Verification        = [System.Collections.Generic.List[object]]::new()
        ProgramVersionPending = [System.Collections.Generic.List[string]]::new()
        Snapshots           = [System.Collections.Generic.List[object]]::new()
        Succeeded           = $false
    }
    # What the run has done so far, set inside the nested helpers: whether a change that clients load with a program may
    # be committed (a run asked to move the programs' versions starts with one pending), whether the programs' request has
    # run, the package's programs that exist on the instance (all of the package's until the live read), and whether
    # the plan is complete and the live-only objects are listed. The programs the run writes last are in $lastPrograms.
    $progress = @{ ProgramScoped = [bool]$BumpProgramVersion; ProgramsWritten = $false; Programs = @(); Classified = $false; LiveOnlyListed = $false }
    $lastPrograms = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    $removedLive = $null

    # The objects of the package's types that the instance holds and the package does not, apart from those this run
    # removes: what a later -Delete may have to name.
    function Add-LiveOnly {
        $progress.LiveOnlyListed = $true
        foreach ($type in $types.Keys) {
            $all = Get-NeoIPCMetadataLiveList -Endpoint $endpoint -Type $type -Field 'id', 'code', 'name'
            $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($types[$type] | ForEach-Object { [string]$_['id'] }), $ordinal)
            $extra = @($all | Where-Object { -not $known.Contains([string]$_['id']) -and -not ($removedLive -and $removedLive.Contains("$type|$($_['id'])")) })
            if ($extra.Count -gt 0) {
                $summary.LiveOnly.Add([pscustomobject]@{ Type = $type; Count = $extra.Count
                        Sample = (@($extra | Select-Object -First 5 | ForEach-Object { '{0} {1}' -f $_['id'], $(if ($_['code']) { $_['code'] } else { $_['name'] }) }) -join '; ') })
            }
        }
        foreach ($x in $summary.LiveOnly) { Write-Host ("  live only {0,-24} {1}: {2}" -f $x.Type, $x.Count, $x.Sample) -ForegroundColor Gray }
    }
    function Get-PlanRow {
        foreach ($type in $types.Keys) {
            $statuses = @($state[$type].Values | ForEach-Object { $_.Status })
            [pscustomobject]@{ Type = $type; New = @($statuses -eq 'New').Count; Changed = @($statuses -eq 'Changed').Count; Unchanged = @($statuses -eq 'Unchanged').Count }
        }
    }
    function Write-Plan {
        foreach ($p in $summary.Plan) { if ($p.New + $p.Changed -gt 0) { Write-Host ("  {0,-34} new {1}, changed {2}, unchanged {3}" -f $p.Type, $p.New, $p.Changed, $p.Unchanged) } }
    }

    # Ends the cmdlet with a terminating error that carries the summary. Called from a nested function, it ends the
    # cmdlet at once, past any try/catch around the call, and it does so whatever the caller's error preference.
    function Exit-Deployment([string]$Message) {
        $summary.Succeeded = $false
        # Committed changes that clients load with a program reach them only once its version moves, and a later run
        # may find nothing left to write: name the programs, and the way to move them.
        $pending = @(if ($lastPrograms.Count -gt 0) { $lastPrograms.Keys } else { $progress.Programs })
        if ($progress.ProgramScoped -and -not $progress.ProgramsWritten -and $pending.Count -gt 0) {
            foreach ($id in $pending) { $summary.ProgramVersionPending.Add([string]$id) }
            $Message += ' Changes that clients load with the program have been committed, but its version has not moved, so clients keep what they cached: once the cause is fixed, deploy again with -BumpProgramVersion.'
        }
        # A dry run's summary is what -Delete and -AllowHazard are decided from, so it lists the objects present only on
        # the instance even when the run stops.
        if ($DryRun -and $progress.Classified -and -not $progress.LiveOnlyListed) {
            try { Add-LiveOnly } catch { $Message += " Listing the objects present only on the instance failed too: $($_.Exception.Message)" }
        }
        $record = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new($Message), 'NeoIPCDeploymentFailed',
            [System.Management.Automation.ErrorCategory]::InvalidResult, $summary)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    function Add-Step([string]$Name, [string]$Status, [string]$Detail) {
        $summary.Steps.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
        $color = switch ($Status) { 'OK' { 'Green' } 'Skipped' { 'Gray' } default { 'Red' } }
        Write-Host ("  {0,-34} {1}{2}" -f $Name, $Status, $(if ($Detail) { " — $Detail" } else { '' })) -ForegroundColor $color
    }
    function Get-ImportErrorText($Import) {
        if ($Import.ErrorMessage) { return [string]$Import.ErrorMessage }
        $texts = foreach ($tr in @($Import.TypeReports)) {
            if (-not $tr -or -not $tr.PSObject.Properties['objectReports']) { continue }
            foreach ($or in @($tr.objectReports)) {
                if (-not $or -or -not $or.PSObject.Properties['errorReports']) { continue }
                foreach ($er in @($or.errorReports)) {
                    $uid = if ($or.PSObject.Properties['uid']) { $or.uid } else { '' }
                    '[{0}] {1} {2}' -f $er.errorCode, $uid, $er.message
                }
            }
        }
        (@($texts) | Select-Object -First 5) -join ' / '
    }
    function ConvertTo-Payload([System.Collections.IDictionary]$ByType) {
        $p = [ordered]@{}
        foreach ($t in $ByType.Keys) { if (@($ByType[$t]).Count -gt 0) { $p[$t] = @($ByType[$t]) } }
        $p
    }
    function Invoke-DeployImport([string]$Name, [System.Collections.IDictionary]$ByType, [switch]$Validate) {
        $payload = ConvertTo-Payload $ByType
        $count = 0; foreach ($t in $payload.Keys) { $count += @($payload[$t]).Count }
        if ($count -eq 0) { Add-Step $Name 'Skipped' 'nothing to write'; return $null }
        # A committing request that carries what clients load with a program counts as committed unless the answer
        # shows it is not: status ERROR (an import with atomicMode ALL that fails commits nothing), or an HTTP 4xx
        # refusal, a proxy's included, whose body need not be DHIS2's. An answer lost on the way, to a proxy's timeout
        # or a dropped connection, can follow a commit.
        $scopedBefore = $progress.ProgramScoped
        if (-not $Validate -and @($payload.Keys | Where-Object { -not $script:NeoIPCDeployOutsideProgramTypes.Contains([string]$_) }).Count -gt 0) { $progress.ProgramScoped = $true }
        $import = Import-NeoIPCMetadata -Json ($payload | ConvertTo-Json -Depth 100 -Compress) @endpoint -ImportStrategy 'CREATE_AND_UPDATE' -AtomicMode 'ALL' -DryRun:$Validate -Confirm:$false
        if ($null -eq $import -or $import.Status -eq 'ERROR' -or (Test-RefusedStatus $import.HttpStatusCode)) { $progress.ProgramScoped = $scopedBefore }
        # Only -WhatIf declines here (every request runs with -Confirm:$false), and it returns before any commit.
        if ($null -eq $import) {
            if ($Validate) { Add-Step $Name 'Skipped' 'declined'; return $null }
            Exit-Deployment "Deployment step '$Name' was declined."
        }
        if (-not $Validate -and $import.Status -eq 'OK') {
            foreach ($t in $payload.Keys) { foreach ($b in $payload[$t]) { [void]$summary.Written.Add("$t|$($b['id'])") } }
        }
        $detail = '{0} object(s); status {1}, HTTP {2}{3}' -f $count, $import.Status, $import.HttpStatusCode,
        $(if ($null -ne $import.Total) { ", created $($import.Created), updated $($import.Updated)" } else { '' })
        if ($import.Status -ne 'OK') {
            Add-Step $Name 'Failed' "$detail — $(Get-ImportErrorText $import)"
            if (-not $Validate) { Exit-Deployment "Deployment step '$Name' failed: $(Get-ImportErrorText $import)" }
        }
        else { Add-Step $Name 'OK' $detail }
        $import
    }
    function Test-Gone([string]$Type, [string]$Id) { (Get-NeoIPCDhis2StatusCode @endpoint -Path "api/$Type/$Id") -eq 404 }
    # A request the server refused (HTTP 4xx) changed nothing; any other failure, an answer lost on the way included,
    # can follow a change.
    function Test-RefusedStatus($Code) { $null -ne $Code -and [int]$Code -ge 400 -and [int]$Code -lt 500 }
    function Test-Refused($ErrorRecord) { $ErrorRecord.Exception -is [System.Net.Http.HttpRequestException] -and (Test-RefusedStatus $ErrorRecord.Exception.StatusCode) }
    function Get-RefPayload([string[]]$Ids) { , @($Ids | ForEach-Object { [ordered]@{ id = $_ } }) }

    # ---- the package ---------------------------------------------------------------------------------------------
    $text = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Metadata package not found: '$Path'." }
        [System.IO.File]::ReadAllText($Path)
    }
    else { $Json }
    $pkg = ConvertFrom-NeoIPCMetadataJsonText -Json $text
    $types = [ordered]@{}
    $otherKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @($pkg.Keys)) {
        $objs = @(@($pkg[$key]) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
        if ($key -eq 'users') {
            if ($objs.Count -eq 0) { continue }
            if (-not $SyntheticInstance) { throw 'The package carries users. A deployment writes users only to a synthetic instance (-SyntheticInstance).' }
            $types['users'] = $objs; continue
        }
        $map = $script:NeoIPCMetadataTypeMaps[$key]
        if ($map -and $map.Nesting -ne 'NestedOnly') { $types[$key] = $objs } else { $otherKeys.Add([string]$key) }
    }
    if ($types.Contains('programs')) { $progress.Programs = @($types['programs'] | ForEach-Object { [string]$_['id'] }) }

    # ---- 1. version, preflight, confirmation, cache clear ---------------------------------------------------------
    # Every read passes -WhatIf:$false: the GET helper asks ShouldProcess, and a -WhatIf given to this cmdlet reaches
    # it (-Confirm:$false does not stop that), which would leave a dry run nothing to plan with. A read that fails ends
    # the run like any other failure, with the summary.
    try { $info = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/system/info' -Fields 'version' -AsHashtable -Confirm:$false -WhatIf:$false }
    catch { Exit-Deployment "Reading the DHIS2 version failed: $($_.Exception.Message)" }
    $summary.Dhis2Version = [string]$info['version']
    $version = ConvertTo-NeoIPCDhis2Version -Text $summary.Dhis2Version
    Write-Host ("Deploying metadata to {0} (DHIS2 {1}){2}{3}" -f $target, $summary.Dhis2Version,
        $(if ($DryRun) { ', dry run' } else { '' }), $(if ($SyntheticInstance) { ', synthetic instance' } else { '' }))

    $findings = @(Test-NeoIPCMetadataExpression -Package $pkg -MinimumSeverity Warning)
    $errorFindings = @($findings | Where-Object { $_.Severity -eq 'Error' })
    foreach ($f in @($findings | Where-Object { $_.Severity -eq 'Warning' } | Select-Object -First 10)) { Write-Warning ("Expression {0} {1} {2}: {3}" -f $f.Rule, $f.ObjectType, $f.ObjectName, $f.Message) }
    if ($errorFindings.Count -gt 0) {
        throw ("The package's expressions have {0} error finding(s), first: {1} {2} — {3}" -f $errorFindings.Count, $errorFindings[0].ObjectType, $errorFindings[0].ObjectName, $errorFindings[0].Message)
    }

    if (-not $DryRun -and -not $PSCmdlet.ShouldProcess($target, 'Deploy the metadata package')) { return }
    function Clear-Dhis2Cache([string]$Name) {
        try { $r = Invoke-NeoIPCDhis2Post @endpoint -Path 'api/maintenance' -QueryParameters @{ cacheClear = 'true' } -Confirm:$false }
        catch { Exit-Deployment "Clearing the DHIS2 caches failed: $($_.Exception.Message)" }
        if ([int]$r.StatusCode -lt 200 -or [int]$r.StatusCode -ge 300) {
            Exit-Deployment "Clearing the DHIS2 caches was refused (HTTP $($r.StatusCode)); it needs F_PERFORM_MAINTENANCE."
        }
        Add-Step $Name 'OK' "HTTP $($r.StatusCode)"
    }
    if ($SkipCacheClear) { Add-Step 'cache clear' 'Skipped' '-SkipCacheClear' }
    elseif (-not $DryRun -or $PSCmdlet.ShouldProcess($target, 'Clear the DHIS2 caches before the dry run')) { Clear-Dhis2Cache 'cache clear' }
    else { Add-Step 'cache clear' 'Skipped' 'declined' }

    # ---- 2. live state -------------------------------------------------------------------------------------------
    try { $schema = Get-NeoIPCMetadataSchemaIndex -Endpoint $endpoint }
    catch { Exit-Deployment "Reading the DHIS2 schemas failed: $($_.Exception.Message)" }
    foreach ($k in $otherKeys) {
        if ($schema.ByPlural.ContainsKey($k)) { throw "The package carries '$k', a DHIS2 metadata type without a type map, which a deployment cannot compare." }
        Write-Verbose "Leaving out the top-level key '$k', which is no metadata type."
    }
    # Before it writes an object of a shareable type whose sharing has no public access string, DHIS2 resets that
    # sharing: the default public access, the importing user as owner unless one is given, every grant removed, the
    # package's included.
    $shareable = [System.Collections.Generic.HashSet[string]]::new([string[]]@($types.Keys | Where-Object { $schema.ByPlural.ContainsKey($_) -and $schema.ByPlural[$_].Shareable }), $ordinal)
    $noPublic = @(foreach ($type in $shareable) {
            foreach ($o in $types[$type]) { if ($null -ne $o['sharing'] -and -not ($o['sharing'] -is [System.Collections.IDictionary] -and $o['sharing']['public'])) { "$type $($o['id'])" } }
        })
    if ($noPublic.Count -gt 0) {
        throw ("DHIS2 resets the sharing of an object whose sharing has no public access string, grants included: {0}. Give their sharing a public access string, or leave the sharing out, which keeps an existing object's." -f ($noPublic -join ', '))
    }
    $expansion = Get-NeoIPCMetadataNestedExpansion -IncludeSyntheticFk
    function Get-LiveType([string]$Type, [string[]]$Ids) {
        $fields = [System.Collections.Generic.List[string]]::new()
        foreach ($f in ':owner', 'translations', 'sharing') { $fields.Add($f) }
        if ($expansion.ContainsKey($Type)) { foreach ($ce in $expansion[$Type]) { $fields.Add("$($ce.ArrayProp)[:owner]") } }
        $r = Get-NeoIPCMetadataLiveObject -Endpoint $endpoint -Type $Type -Id $Ids -Field $fields.ToArray()
        if ($r.Failure) { Exit-Deployment "Reading the live $Type failed: $($r.Failure)" }
        $r.ById
    }
    $live = @{}
    foreach ($type in $types.Keys) { $live[$type] = Get-LiveType $type @($types[$type] | ForEach-Object { [string]$_['id'] }) }
    if ($types.Contains('programs')) { $progress.Programs = @($progress.Programs | Where-Object { $live['programs'][$_] }) }

    $deleteIds = @{}
    foreach ($type in @($Delete.Keys)) {
        $t = [string]$type
        if ($t -eq 'users' -or ($script:NeoIPCMetadataExcludedTypes -contains $t -and $t -ne 'organisationUnits')) { throw "A deployment does not delete '$t'." }
        if ($t -eq 'programs') { throw "A deployment does not delete programs: DHIS2 deletes a program's stages, rules, rule variables and indicators with it, and the relationship types, event reports, event charts and event visualizations built on it, none of which a deployment checks or reads back." }
        # On 2.40 a set's options are a list indexed by sort_order. DHIS2 runs an option's own DELETE as a metadata import
        # with importStrategy DELETE, which 2.40.12 refuses while the set lists the option; on an earlier 2.40 patch such
        # an import of an option that was not last left a gap in the index, which broke every later read of the set.
        if ($t -eq 'options') { throw "A deployment does not delete single options: drop them from their set's list, which detaches them (an OptionSetMembership hazard), or delete the whole set." }
        if (-not $script:NeoIPCMetadataTypeMaps.Contains($t)) { throw "-Delete names '$t', which is no metadata type a deployment knows." }
        $deleteIds[$t] = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@($Delete[$type]) | ForEach-Object { [string]$_ } | Where-Object { $_ }), $ordinal)
    }
    $childTypes = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($m in $script:NeoIPCDeployOwnedChildren.Values) { foreach ($c in $m.Values) { [void]$childTypes.Add([string]$c) } }
    foreach ($t in $deleteIds.Keys) {
        foreach ($id in $deleteIds[$t]) {
            if ($types.Contains($t) -and @($types[$t] | Where-Object { [string]$_['id'] -ceq $id }).Count -gt 0) { throw "-Delete names $t $id, which the package still carries." }
        }
    }
    $deleteLive = @{}
    foreach ($t in $deleteIds.Keys) {
        if ($childTypes.Contains($t) -or $script:NeoIPCMetadataTypeMaps[$t].Nesting -eq 'NestedOnly') { continue }
        $deleteLive[$t] = Get-LiveType $t @($deleteIds[$t])
    }
    # A program written without one of its stages or sections only detaches it: DHIS2 maps neither collection with a
    # cascade. Each one the package drops is therefore deleted through its own endpoint, and must be listed in -Delete.
    if ($types.Contains('programs')) {
        foreach ($o in $types['programs']) {
            $l = $live['programs'][[string]$o['id']]
            if (-not $l) { continue }
            foreach ($prop in 'programStages', 'programSections') {
                $keep = Get-NeoIPCDeployRefIdList $o[$prop]
                foreach ($cid in (Get-NeoIPCDeployRefIdList $l[$prop])) {
                    if ($keep -ccontains $cid -or ($deleteIds.ContainsKey($prop) -and $deleteIds[$prop].Contains($cid))) { continue }
                    throw "Program $($o['id']) no longer lists $prop $cid. Writing the program would only detach it: list it in -Delete, which deletes it through its own endpoint."
                }
            }
        }
    }
    # DHIS2 refuses to delete a program stage that any event refers to, a deleted one included until it is purged (the
    # event deletion handler's veto counts every row). One event decides, so one is read, in every org unit.
    if ($deleteLive.ContainsKey('programStages')) {
        $dialect = Get-NeoIPCTrackerDialect -Version $version
        $listKey = $dialect.ListKey['events']
        foreach ($id in $deleteIds['programStages']) {
            $l = $deleteLive['programStages'][$id]
            if (-not $l) { continue }
            $query = @{ program = (Get-NeoIPCDeployRefId $l['program']); programStage = $id; includeDeleted = 'true'; $dialect.OrgUnitMode = 'ALL' }
            try { $events = Invoke-NeoIPCDhis2Get @endpoint -Path 'api/tracker/events' -Fields 'event' -QueryParameters $query -PageSize 1 -AsHashtable -Confirm:$false -WhatIf:$false }
            catch { Exit-Deployment "Reading whether program stage $id has events failed (it needs the authority to search all org units): $($_.Exception.Message)" }
            if ($events -isnot [System.Collections.IDictionary] -or -not $events.Contains($listKey)) { Exit-Deployment "Reading whether program stage $id has events returned no '$listKey' list." }
            if (@($events[$listKey] | Where-Object { $_ -is [System.Collections.IDictionary] }).Count -gt 0) { throw "Program stage $id has events, and DHIS2 refuses to delete a stage that has any, deleted ones included until they are purged: the package must keep it." }
        }
        # A stage's DELETE also deletes the event visualizations built on it (event reports and charts are rows of the
        # same table) and clears the stage on the map views that use it, through their deletion handlers. On DHIS2 2.40
        # those handlers compare every visualization's stage without a null check, so one without a stage makes every
        # stage's delete fail. None of it is the package's, so each stops the deployment. One the deploying user cannot
        # see is not found.
        $stageIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($deleteIds['programStages'] | Where-Object { $deleteLive['programStages'][$_] }), $ordinal)
        if ($stageIds.Count -gt 0) {
            $uses = [System.Collections.Generic.List[string]]::new()
            foreach ($vt in 'eventVisualizations', 'mapViews') {
                try { $all = Get-NeoIPCMetadataLiveList -Endpoint $endpoint -Type $vt -Field 'id', 'name', 'programStage[id]' }
                catch { Exit-Deployment "Reading the live $vt failed: $($_.Exception.Message)" }
                foreach ($x in $all) {
                    $named = "$vt $($x['id'])$(if ($x['name']) { " ('$($x['name'])')" })"
                    $sid = Get-NeoIPCDeployRefId $x['programStage']
                    if ($sid -and $stageIds.Contains($sid)) { $uses.Add("$named uses programStages $sid") }
                    elseif (-not $sid -and $vt -eq 'eventVisualizations' -and $version -lt [version]'2.41') { $uses.Add("$named has no stage") }
                }
            }
            if ($uses.Count -gt 0) {
                throw ("DHIS2 deletes the event visualizations built on a stage it deletes and clears the stage on the map views that use it, and on 2.40 fails a stage's delete while any event visualization has no stage: {0}. Change or delete them first, or keep the stage." -f ($uses -join '; '))
            }
        }
    }

    # ---- 3. classify ---------------------------------------------------------------------------------------------
    $governed = @{}
    foreach ($type in $types.Keys) {
        $governed[$type] = if ($SyntheticInstance -and $type -ne 'users') {
            [string[]]@($script:NeoIPCDeployMembershipProperties | Where-Object { $p = $_; @($types[$type] | Where-Object { $_.Contains($p) }).Count -gt 0 })
        }
        else { [string[]]@() }
    }
    $copyOwned = @{}
    foreach ($type in $types.Keys) {
        $copyOwned[$type] = if ($type -eq 'users') { [string[]]@($script:NeoIPCDeployOwnedProperties | Where-Object { $_ -notin $script:NeoIPCDeployMembershipProperties }) }
        else { [string[]]@($script:NeoIPCDeployOwnedProperties | Where-Object { $_ -notin $governed[$type] }) }
        if (-not $SyntheticInstance) {
            foreach ($p in @($copyOwned[$type] | Where-Object { $_ -notin 'created', 'createdBy' })) {
                $n = @($types[$type] | Where-Object { -not (Test-NeoIPCDeployEmpty $_[$p]) }).Count
                if ($n -gt 0) { $summary.IgnoredPackageValues.Add([pscustomobject]@{ Type = $type; Property = $p; Objects = $n }) }
            }
        }
    }
    $state = @{}
    foreach ($type in $types.Keys) {
        $state[$type] = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
        foreach ($o in $types[$type]) {
            $id = [string]$o['id']
            $l = $live[$type][$id]
            $state[$type][$id] = if (-not $l) { [pscustomobject]@{ Status = 'New'; Changed = [string[]]@() } }
            else {
                $diff = Compare-NeoIPCDeployObject -Type $type -PackageObject $o -Live $l -Version $version -GovernedOwned $governed[$type]
                [pscustomobject]@{ Status = $(if ($diff.Count -gt 0) { 'Changed' } else { 'Unchanged' }); Changed = [string[]]$diff }
            }
        }
    }

    # An option that is created or changed is written with its set: from 2.41 only the set's write renumbers its
    # options' sortOrder to their list position, and an option written alone keeps the package's sortOrder, which
    # ties with or passes its neighbours.
    $createdInSet = [System.Collections.Generic.Dictionary[string, int]]::new($ordinal)
    if ($types.Contains('options')) {
        foreach ($o in $types['options']) {
            $st = $state['options'][[string]$o['id']]
            if ($st.Status -eq 'Unchanged') { continue }
            $setId = Get-NeoIPCDeployRefId $o['optionSet']
            if (-not $types.Contains('optionSets') -or -not $state['optionSets'].ContainsKey($setId)) { throw "Option $($o['id']) belongs to option set $setId, which the package does not carry." }
            if ($st.Status -eq 'New') { $createdInSet[$setId] = 1 + [int]$createdInSet[$setId] }
            if ($state['optionSets'][$setId].Status -eq 'Unchanged') { $state['optionSets'][$setId] = [pscustomobject]@{ Status = 'Changed'; Changed = [string[]]@() } }
        }
    }
    foreach ($row in (Get-PlanRow)) { $summary.Plan.Add($row) }
    $progress.Classified = $true

    # ---- 4. bodies -----------------------------------------------------------------------------------------------
    $bodies = @{}
    $pkgById = @{}
    foreach ($type in $types.Keys) {
        $bodies[$type] = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
        $pkgById[$type] = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
        $keptCount = @{}
        foreach ($o in $types[$type]) {
            $id = [string]$o['id']
            $pkgById[$type][$id] = $o
            $st = $state[$type][$id]
            if ($st.Status -eq 'Unchanged') { continue }
            $l = $live[$type][$id]
            $made = New-NeoIPCDeployBody -Type $type -PackageObject $o -Live $l -CopyOwned $copyOwned[$type] -ChangedProperties $st.Changed -LiveVersion:($type -in 'programs', 'optionSets') -Shareable:($shareable.Contains($type))
            $bodies[$type][$id] = $made.Body
            foreach ($d in $made.DroppedTranslations) { $summary.DroppedTranslations.Add($d) }
            if ($l) { foreach ($p in $copyOwned[$type]) { if ($p -notin 'created', 'createdBy' -and -not (Test-NeoIPCDeployEmpty $l[$p])) { $keptCount[$p] = 1 + [int]$keptCount[$p] } } }
            if ($made.SharingKept) { $keptCount['sharing'] = 1 + [int]$keptCount['sharing'] }
        }
        foreach ($p in $keptCount.Keys) { $summary.Kept.Add([pscustomobject]@{ Type = $type; Property = $p; Objects = $keptCount[$p] }) }
    }
    $newKeys = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    foreach ($type in $types.Keys) { foreach ($id in $state[$type].Keys) { if ($state[$type][$id].Status -eq 'New') { [void]$newKeys.Add("$type|$id") } } }

    # ---- 5. option group sets ------------------------------------------------------------------------------------
    $gsPlan = $null
    if ($types.Contains('optionGroupSets')) {
        try { $all = Get-NeoIPCMetadataLiveList -Endpoint $endpoint -Type 'optionGroupSets' -Field 'id', 'optionGroups[id]' }
        catch { Exit-Deployment "Reading the live option group sets failed: $($_.Exception.Message)" }
        $liveLists = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
        foreach ($s in $all) { $liveLists[[string]$s['id']] = Get-NeoIPCDeployRefIdList $s['optionGroups'] }
        $newGroups = [System.Collections.Generic.HashSet[string]]::new($ordinal)
        if ($types.Contains('optionGroups')) { foreach ($id in $state['optionGroups'].Keys) { if ($state['optionGroups'][$id].Status -eq 'New') { [void]$newGroups.Add($id) } } }
        $gsResult = Get-NeoIPCDeployGroupSetPlan -PackageSets @($types['optionGroupSets']) -LiveLists $liveLists -NewGroups $newGroups
        if ($gsResult.Errors.Count -gt 0) { throw ($gsResult.Errors -join ' ') }
        $gsPlan = $gsResult.Plan
    }

    # ---- 6. moves, orphans and the hazard gate -------------------------------------------------------------------
    # A child the package lists under another parent it carries moves there: R1 writes the child and its new parent,
    # and R2 the parent it leaves ($moveSources), since on DHIS2 2.40.12 a request that writes both parents of a rule
    # action or a notification template fails whole.
    $moveResult = Get-NeoIPCDeployMove -Types $types -Live $live -State $state -Version $version -DeleteLive $deleteLive
    if ($moveResult.Errors.Count -gt 0) { throw ($moveResult.Errors -join ' ') }
    $moveSources = $moveResult.Sources
    $movedKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@($moveResult.Moves | ForEach-Object { "$($_.Type)|$($_.Id)" }), $ordinal)
    foreach ($m in $moveResult.Moves) {
        $summary.Moved.Add($m)
        Write-Host ("  move {0} {1}: {2} -> {3}" -f $m.Type, $m.Id, ($m.From -replace '\|', ' '), ($m.To -replace '\|', ' '))
    }
    $orphans = [System.Collections.Generic.List[object]]::new()
    foreach ($parentType in $script:NeoIPCDeployOwnedChildren.Keys) {
        if (-not $types.Contains($parentType)) { continue }
        foreach ($id in $bodies[$parentType].Keys) {
            if ($state[$parentType][$id].Status -ne 'Changed') { continue }
            foreach ($prop in $script:NeoIPCDeployOwnedChildren[$parentType].Keys) {
                $childType = $script:NeoIPCDeployOwnedChildren[$parentType][$prop]
                $keep = Get-NeoIPCDeployRefIdList $pkgById[$parentType][$id][$prop]
                foreach ($cid in (Get-NeoIPCDeployRefIdList $live[$parentType][$id][$prop])) {
                    if ($keep -ccontains $cid -or $movedKeys.Contains("$childType|$cid")) { continue }
                    $orphans.Add([pscustomobject]@{ Type = $childType; Id = $cid; ParentType = $parentType; ParentId = $id; Property = $prop })
                }
            }
        }
    }
    $orphanKeys = [System.Collections.Generic.HashSet[string]]::new([string[]]@($orphans | ForEach-Object { "$($_.Type)|$($_.Id)" }), $ordinal)
    foreach ($t in $deleteIds.Keys) {
        if (-not ($childTypes.Contains($t) -or $script:NeoIPCMetadataTypeMaps[$t].Nesting -eq 'NestedOnly')) { continue }
        foreach ($id in $deleteIds[$t]) {
            if (-not $orphanKeys.Contains("$t|$id")) { throw "-Delete names $t $id, which no written parent drops: a child is removed by writing its parent without it, never through its own endpoint." }
        }
    }
    # What this deployment removes that exists on the instance: the children its writes drop, the -Delete entries
    # present live, and what DHIS2 deletes with them ($deletedWith, by entry), none of which the package may carry
    # (a move out of a -Delete entry was refused above). The -Delete entries go after R2, one type after another, each
    # type before the types it refers to.
    $deleteOrder = Get-NeoIPCDeployDeleteOrder -Type @($deleteLive.Keys) -Schema $schema
    $removedLive = [System.Collections.Generic.HashSet[string]]::new($orphanKeys, $ordinal)
    $deletedWith = [System.Collections.Generic.Dictionary[string, string[]]]::new($ordinal)
    foreach ($t in $deleteOrder) {
        foreach ($id in $deleteIds[$t]) {
            $l = $deleteLive[$t][$id]
            if (-not $l) { continue }
            $with = [System.Collections.Generic.List[string]]::new()
            if ($script:NeoIPCDeployDeletedWith.ContainsKey($t)) {
                foreach ($prop in $script:NeoIPCDeployDeletedWith[$t].Keys) {
                    $ct = $script:NeoIPCDeployDeletedWith[$t][$prop]
                    foreach ($c in (Get-NeoIPCDeployRefIdList $l[$prop])) {
                        if ($types.Contains($ct) -and $pkgById[$ct].ContainsKey($c)) { throw "The package carries $ct $c, which DHIS2 deletes with $t ${id}: leave it out of the package, or give it a new id under a parent the package keeps." }
                        $with.Add("$ct|$c")
                    }
                }
            }
            $deletedWith["$t|$id"] = $with.ToArray()
            foreach ($k in @("$t|$id") + $with) { [void]$removedLive.Add($k) }
        }
    }
    # The removals by a parent's write, in R1, or in R2 for a parent that gives a child away. An action that still
    # refers to one is written out by its rule in the detach request, before both: inside R1, DHIS2 deletes what a
    # parent drops before the request's rule actions commit (stages commit at schema order 1509, actions at 1610), and
    # a notification action created again on its own after R2 would still send a template R2 removes. A program's own
    # children go with its last write, and the -Delete entries after R2.
    $removedByWrite = [System.Collections.Generic.HashSet[string]]::new([string[]]@($orphans | Where-Object { $_.ParentType -ne 'programs' } | ForEach-Object { "$($_.Type)|$($_.Id)" }), $ordinal)

    function Add-Hazard([string]$Kind, [string]$Type, [string]$Id, [string]$Detail) {
        $summary.Hazards.Add([pscustomobject]@{ Kind = $Kind; Type = $Type; Id = $Id; Detail = $Detail })
    }
    if (-not (Test-NeoIPCDeployVerifiedVersion -Version $version)) {
        Add-Hazard 'UnverifiedVersion' 'DHIS2' $summary.Dhis2Version ("is no release this deployment was verified on: {0}, or a later patch of one of their lines" -f
            (($script:NeoIPCDeployVerifiedReleases | ForEach-Object { "$_" }) -join ', '))
    }
    foreach ($o in $orphans) {
        if (-not ($deleteIds.ContainsKey($o.Type) -and $deleteIds[$o.Type].Contains($o.Id))) {
            Add-Hazard 'OrphanDelete' $o.Type $o.Id "dropped from $($o.ParentType) $($o.ParentId).$($o.Property), which DHIS2 deletes with the parent's write"
        }
    }
    if ($types.Contains('optionSets')) {
        foreach ($id in $bodies['optionSets'].Keys) {
            if ($state['optionSets'][$id].Status -ne 'Changed') { continue }
            $liveList = Get-NeoIPCDeployRefIdList $live['optionSets'][$id]['options']
            $keep = Get-NeoIPCDeployRefIdList $pkgById['optionSets'][$id]['options']
            $lost = @($liveList | Where-Object { $keep -cnotcontains $_ })
            # The same members in another order are how the authored order reaches the instance, so a reorder is no
            # hazard; a new option placed before an existing one changes the membership other than by appending.
            $lastLive = -1
            for ($i = 0; $i -lt $keep.Count; $i++) { if ($liveList -ccontains $keep[$i]) { $lastLive = $i } }
            $inserted = @(for ($i = 0; $i -lt $lastLive; $i++) { if ($liveList -cnotcontains $keep[$i]) { $keep[$i] } })
            # An option the package gives to another set moves there in R1, with both sets' writes; one it lists in no
            # set is only detached. Either way, the values stored under this set's data elements keep its code.
            $movedTo = [System.Collections.Generic.Dictionary[string, string]]::new($ordinal)
            foreach ($o in $lost) {
                $to = if ($pkgById.Contains('options') -and $pkgById['options'].ContainsKey($o)) { Get-NeoIPCDeployRefId $pkgById['options'][$o]['optionSet'] }
                if ($to -and $to -cne $id) { $movedTo[$o] = $to }
            }
            $detached = @($lost | Where-Object { -not $movedTo.ContainsKey($_) })
            $what = [System.Collections.Generic.List[string]]::new()
            if ($detached.Count -gt 0) { $what.Add(("loses {0} option(s): {1}; the set's write detaches them, leaving them in no set" -f $detached.Count, (($detached | Select-Object -First 5) -join ', '))) }
            if ($movedTo.Count -gt 0) {
                $what.Add(("gives {0} option(s) to another set: {1}" -f $movedTo.Count, ((@($lost | Where-Object { $movedTo.ContainsKey($_) }) | Select-Object -First 5 | ForEach-Object { "$_ to $($movedTo[$_])" }) -join ', ')))
            }
            if ($inserted.Count -gt 0) { $what.Add(("gains {0} option(s) before existing ones: {1}" -f $inserted.Count, (($inserted | Select-Object -First 5) -join ', '))) }
            if ($what.Count -gt 0) { Add-Hazard 'OptionSetMembership' 'optionSets' $id ($what -join '; ') }
        }
    }
    if ($deleteIds.ContainsKey('optionSets')) { foreach ($id in $deleteIds['optionSets']) { Add-Hazard 'OptionSetMembership' 'optionSets' $id 'deleted, and its options with it' } }
    if ($types.Contains('options')) {
        foreach ($id in $bodies['options'].Keys) {
            $l = $live['options'][$id]
            if ($l -and [string]$l['code'] -cne [string]$pkgById['options'][$id]['code']) { Add-Hazard 'OptionCodeChange' 'options' $id "code '$($l['code'])' -> '$($pkgById['options'][$id]['code'])'" }
        }
        # A stored value holds an option's code and shows the name of the option that carries the code now: an option
        # that keeps its code under another name changes what every value stored under that code says. Only a review
        # can tell a new spelling from a new meaning.
        foreach ($id in $bodies['options'].Keys) {
            $l = $live['options'][$id]; $p = $pkgById['options'][$id]
            if ($l -and [string]$l['code'] -ceq [string]$p['code'] -and [string]$l['name'] -cne [string]$p['name']) {
                Add-Hazard 'OptionNameChange' 'options' $id ("code '{0}': '{1}' -> '{2}'" -f $l['code'], $l['name'], $p['name'])
            }
        }
        # DHIS2 checks each option it is given against the other options of its set as the set is stored before the
        # request, a member the same request drops included, and refuses one whose name or code another of them holds
        # (OptionObjectBundleHook.checkDuplicateOption, E4028, comparing case-sensitively and skipping a member without
        # a name or code). A name or code passed from one option to another therefore takes two deployments.
        $members = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
        foreach ($id in $bodies['options'].Keys) {
            $sid = Get-NeoIPCDeployRefId $pkgById['options'][$id]['optionSet']
            if ($sid -and -not $members.ContainsKey($sid) -and $live.Contains('optionSets') -and $live['optionSets'][$sid]) { $members[$sid] = Get-NeoIPCDeployRefIdList $live['optionSets'][$sid]['options'] }
        }
        $unread = @($members.Values | ForEach-Object { $_ } | Where-Object { -not $live['options'].ContainsKey($_) } | Select-Object -Unique)
        $memberLive = if ($unread.Count -gt 0) { Get-LiveType 'options' $unread } else { @{} }
        $clashes = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $bodies['options'].Keys) {
            $p = $pkgById['options'][$id]
            $sid = Get-NeoIPCDeployRefId $p['optionSet']
            if (-not $sid -or -not $members.ContainsKey($sid)) { continue }
            foreach ($m in $members[$sid]) {
                if ($m -ceq $id) { continue }
                $q = if ($live['options'].ContainsKey($m)) { $live['options'][$m] } else { $memberLive[$m] }
                if (-not $q -or $null -eq $q['name'] -or $null -eq $q['code']) { continue }
                $same = @(if ([string]$q['code'] -ceq [string]$p['code']) { "code '$($p['code'])'" }; if ([string]$q['name'] -ceq [string]$p['name']) { "name '$($p['name'])'" })
                if ($same.Count -gt 0) { $clashes.Add("option $id takes the $($same -join ' and ') that option $m holds in set $sid") }
            }
        }
        if ($clashes.Count -gt 0) {
            throw ("DHIS2 refuses an option whose name or code another option of its set holds, as the set is stored before the request (E4028): {0}. Free the name or code in one deployment, and give it in a later one." -f ($clashes -join '; '))
        }
    }
    foreach ($type in $types.Keys) {
        $dataShareable = $schema.ByPlural.ContainsKey($type) -and $schema.ByPlural[$type].DataShareable
        foreach ($id in $bodies[$type].Keys) {
            $o = $pkgById[$type][$id]; $l = $live[$type][$id]
            if (-not $l -or -not $o['sharing']) { continue }
            $lost = Get-NeoIPCDeploySharingLoss -Live (Convert-NeoIPCSharing $l['sharing']) -Package (Convert-NeoIPCSharing $o['sharing']) -DataShareable:$dataShareable
            if ($lost.Count -gt 0) { Add-Hazard 'SharingGrantRemoval' $type $id ($lost -join '; ') }
        }
    }
    if ($deleteIds.ContainsKey('programRules')) {
        foreach ($id in $deleteIds['programRules']) {
            $l = $deleteLive['programRules'][$id]
            if ($l -and -not (Test-NeoIPCDeployInertRule -Rule $l)) { Add-Hazard 'ActiveRuleDelete' 'programRules' $id "is not inert on the instance, which takes condition 'false' and no actions: make it inert in one deployment and delete it in a later one" }
        }
    }
    # Not `ForEach-Object Kind`: the member-name form asks ShouldProcess, so under -WhatIf it yields nothing and the
    # gate would pass every hazard.
    $kinds = @($summary.Hazards | ForEach-Object { $_.Kind } | Select-Object -Unique)
    $open = @(if (-not $SyntheticInstance) { $kinds | Where-Object { $_ -notin $AllowHazard } })
    foreach ($h in $summary.Hazards) { Write-Host ("  hazard {0}: {1} {2} {3}" -f $h.Kind, $h.Type, $h.Id, $h.Detail) -ForegroundColor $(if ($h.Kind -in $open) { 'Red' } else { 'Yellow' }) }
    if ($open.Count -gt 0) {
        Exit-Deployment ("Unacknowledged hazard(s): {0}. Nothing was written. Acknowledge with -AllowHazard {1}, after checking each one above." -f ($open -join ', '), ($open -join ', '))
    }

    # ---- 7. references to what this deployment removes, and the detach request -------------------------------------
    # DHIS2 refuses to delete what something still refers to ($NeoIPCDeployReferenceProperties), and the whole request
    # fails; up to 2.41 a notification template goes from under the action that sends it. So, before any write:
    #   - a package object, new or kept, that refers to something removed stops the deployment;
    #   - on the instance, the objects as they are now decide. One that goes itself first is no obstacle: an action
    #     its rule drops, a -Delete entry, with what goes with it. One the package points elsewhere is repointed when
    #     R1 writes it, in time for a removal after it; for a removal by a parent's write ($removedByWrite), which only
    #     an action can refer to (a stage's section or notification template), the rule that holds it writes it out
    #     once beforehand, and R1 creates it again. One R1 does not write, and one the package does not carry, stop
    #     the deployment.
    # Rules the package makes inert are written in the same first request.
    $detachIds = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    $detachDrop = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    $recreated = [System.Collections.Generic.HashSet[string]]::new($ordinal)
    if ($removedLive.Count -gt 0) {
        $removedTypes = [System.Collections.Generic.HashSet[string]]::new([string[]]@($removedLive | ForEach-Object { ($_ -split '\|', 2)[0] }), $ordinal)
        foreach ($rt in $script:NeoIPCDeployReferenceProperties.Keys) {
            $refTypes = @($script:NeoIPCDeployReferenceProperties[$rt].Values) + @(if ($rt -eq 'programRuleActions') { 'programNotificationTemplates' })
            if (@($refTypes | Where-Object { $removedTypes.Contains($_) }).Count -eq 0) { continue }
            if ($types.Contains($rt)) {
                foreach ($o in $types[$rt]) {
                    $still = @((Get-NeoIPCDeployReference -Type $rt -Object $o) | Where-Object { $removedLive.Contains($_) })
                    if ($still.Count -gt 0) { Exit-Deployment "The package's $rt $($o['id']) refers to $($still -join ', '), which this deployment removes. Nothing was written." }
                }
            }
            $fields = [System.Collections.Generic.List[string]]::new()
            $fields.Add('id')
            foreach ($p in $script:NeoIPCDeployReferenceProperties[$rt].Keys) { $fields.Add("$p[id]") }
            if ($rt -eq 'programRuleActions') { $fields.Add('templateUid'); $fields.Add('programRule[id]') }
            try { $all = Get-NeoIPCMetadataLiveList -Endpoint $endpoint -Type $rt -Field $fields.ToArray() }
            catch { Exit-Deployment "Reading the live $rt failed: $($_.Exception.Message)" }
            foreach ($x in $all) {
                $hits = @((Get-NeoIPCDeployReference -Type $rt -Object $x) | Where-Object { $removedLive.Contains($_) })
                if ($hits.Count -eq 0) { continue }
                $xid = [string]$x['id']
                $what = "$rt $xid refers to $($hits -join ', '), which this deployment removes"
                $early = @($hits | Where-Object { $removedByWrite.Contains($_) }).Count -gt 0
                if ($removedLive.Contains("$rt|$xid")) {
                    if ($early) {
                        $rid = if ($rt -eq 'programRuleActions') { Get-NeoIPCDeployRefId $x['programRule'] } else { $null }
                        if ($rid -and $types.Contains('programRules') -and $bodies['programRules'].ContainsKey($rid)) { [void]$detachIds.Add($rid); continue }
                        Exit-Deployment "$what with a parent's write, but goes itself only later, with its rule's -Delete entry: make the rule inert in an earlier deployment. Nothing was written."
                    }
                    # It goes first: with its parent's write, which comes before the -Delete entries, or as one of them,
                    # whose types go each before the types it refers to.
                    continue
                }
                if (-not ($types.Contains($rt) -and $pkgById[$rt].ContainsKey($xid))) {
                    # An action is deleted only with its rule.
                    $how = if ($rt -eq 'programRuleActions') { "list its rule $(Get-NeoIPCDeployRefId $x['programRule']) in -Delete, which deletes its actions with it" } else { 'list it in -Delete' }
                    Exit-Deployment "$what, and the package does not carry it: $how, or remove the reference first. Nothing was written."
                }
                if (-not $early) {
                    # R1 writes it as the package states it, without the reference; one R1 does not write keeps it.
                    if ($bodies[$rt].ContainsKey($xid)) { continue }
                    Exit-Deployment "$what, and the package carries it, but this deployment does not write it, as it compares unchanged, so the reference would stay: remove it first. Nothing was written."
                }
                $rid = if ($rt -eq 'programRuleActions') { Get-NeoIPCDeployRefId $x['programRule'] } else { $null }
                if (-not ($rid -and $types.Contains('programRules') -and $pkgById['programRules'].ContainsKey($rid))) {
                    Exit-Deployment "$what with a parent's write, and the package does not carry the rule $rid that holds it, which would have to write it out first. Nothing was written."
                }
                if (-not $bodies['programRules'].ContainsKey($rid)) {
                    $bodies['programRules'][$rid] = (New-NeoIPCDeployBody -Type 'programRules' -PackageObject $pkgById['programRules'][$rid] -Live $live['programRules'][$rid] -CopyOwned $copyOwned['programRules'] -Shareable:($shareable.Contains('programRules'))).Body
                    $state['programRules'][$rid] = [pscustomobject]@{ Status = 'Changed'; Changed = [string[]]@() }
                }
                [void]$detachIds.Add($rid)
                if (-not $detachDrop.ContainsKey($rid)) { $detachDrop[$rid] = [System.Collections.Generic.HashSet[string]]::new($ordinal) }
                [void]$detachDrop[$rid].Add($xid)
                [void]$recreated.Add($xid)
            }
        }
    }
    if ($types.Contains('programRules')) {
        foreach ($id in @($bodies['programRules'].Keys)) {
            if ($state['programRules'][$id].Status -eq 'Changed' -and (Test-NeoIPCDeployInertRule -Rule $pkgById['programRules'][$id]) -and
                -not (Test-NeoIPCDeployInertRule -Rule $live['programRules'][$id])) { [void]$detachIds.Add($id) }
        }
    }
    # A detached rule lists the actions that exist now, less those it leaves out once (it may gain new ones, which R1
    # creates), and a reference to an object this run creates keeps its live value, since that object does not exist
    # before R1 (DHIS2 refuses a reference to a missing object, E5002). It keeps listing an action it gives to another
    # rule, which R1 moves there. R1 writes the rule again when its body differs, or R2 when it gives an action away.
    $newIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($newKeys | ForEach-Object { ($_ -split '\|', 2)[1] }), $ordinal)
    $ruleProps = $script:NeoIPCMetadataTypeMaps['programRules'].Properties
    $detach = [System.Collections.Generic.Dictionary[string, object]]::new($ordinal)
    foreach ($id in $detachIds) {
        $liveRule = $live['programRules'][$id]
        $liveActions = Get-NeoIPCDeployRefIdList $liveRule['programRuleActions']
        $drop = $detachDrop[$id]
        $d = Copy-NeoIPCDeployValue $bodies['programRules'][$id]
        $kept = @(if ($d.Contains('programRuleActions')) { @($d['programRuleActions']) | Where-Object { $aid = Get-NeoIPCDeployRefId $_; $liveActions -ccontains $aid -and -not ($drop -and $drop.Contains($aid)) } })
        $givenAway = @($liveActions | Where-Object { $movedKeys.Contains("programRuleActions|$_") -and -not ($drop -and $drop.Contains($_)) } | ForEach-Object { [ordered]@{ id = $_ } })
        if ($d.Contains('programRuleActions') -or $givenAway.Count -gt 0) { $d['programRuleActions'] = @($kept) + @($givenAway) }
        foreach ($p in @($ruleProps.Keys)) {
            if ($ruleProps[$p] -ne 'id' -or -not $newIds.Contains([string](Get-NeoIPCDeployRefId $d[$p]))) { continue }
            if ($null -ne $liveRule[$p]) { $d[$p] = Copy-NeoIPCDeployValue $liveRule[$p] } else { $d.Remove($p) }
        }
        $detach[$id] = $d
    }
    $summary.Plan.Clear()
    foreach ($row in (Get-PlanRow)) { $summary.Plan.Add($row) }

    # ---- 8. the requests: what is written when -------------------------------------------------------------------
    $templateSteps = [System.Collections.Generic.List[string]]::new()
    # An action the detach request deletes is created again by R1, so it needs no step of its own.
    if ($version -ge [version]'2.42' -and $types.Contains('programRuleActions')) {
        foreach ($id in $bodies['programRuleActions'].Keys) {
            if ($state['programRuleActions'][$id].Status -eq 'Changed' -and $bodies['programRuleActions'][$id]['templateUid'] -and -not $recreated.Contains($id)) { $templateSteps.Add($id) }
        }
    }
    $programScoped = [bool]$BumpProgramVersion
    foreach ($type in $types.Keys) { if (-not $script:NeoIPCDeployOutsideProgramTypes.Contains($type) -and $bodies[$type].Count -gt 0) { $programScoped = $true } }
    foreach ($key in $removedLive) { if (-not $script:NeoIPCDeployOutsideProgramTypes.Contains(($key -split '\|')[0])) { $programScoped = $true } }
    if ($types.Contains('programs') -and $programScoped) {
        foreach ($o in $types['programs']) {
            $id = [string]$o['id']
            if ($state['programs'][$id].Status -eq 'New') { continue }
            $lastPrograms[$id] = if ($bodies['programs'].ContainsKey($id)) { $bodies['programs'][$id] }
            else { (New-NeoIPCDeployBody -Type 'programs' -PackageObject $o -Live $live['programs'][$id] -CopyOwned $copyOwned['programs'] -LiveVersion -Shareable:($shareable.Contains('programs'))).Body }
        }
    }

    $write = [ordered]@{}
    foreach ($type in $types.Keys) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($o in $types[$type]) {
            $id = [string]$o['id']
            if (-not $bodies[$type].ContainsKey($id)) { continue }
            if ($type -eq 'programRules' -and $detach.ContainsKey($id) -and
                ($detach[$id] | ConvertTo-Json -Depth 100 -Compress) -ceq ($bodies['programRules'][$id] | ConvertTo-Json -Depth 100 -Compress)) { continue }
            if ($type -eq 'programs' -and $lastPrograms.ContainsKey($id)) { continue }
            if ($type -eq 'programRuleActions' -and $templateSteps.Contains($id)) { continue }
            $list.Add($bodies[$type][$id])
        }
        if ($list.Count -gt 0) { $write[$type] = $list.ToArray() }
    }
    $deferral = Get-NeoIPCDeployDeferral -Write $write -New $newKeys -Schema $schema
    $r1 = [ordered]@{}; $r2 = [ordered]@{}; $resets = [System.Collections.Generic.List[object]]::new()
    foreach ($type in $write.Keys) {
        $first = [System.Collections.Generic.List[object]]::new(); $second = [System.Collections.Generic.List[object]]::new()
        foreach ($b in $write[$type]) {
            $key = "$type|$($b['id'])"
            # A parent that gives a child to another is written once R1 has moved the child (step 6).
            if ($moveSources.Contains($key)) { $second.Add($b); continue }
            $b1 = if ($deferral.ContainsKey($key)) { ConvertTo-NeoIPCDeployFirstPass -Body $b -Deferred $deferral[$key] } else { $b }
            $needsSecond = $deferral.ContainsKey($key)
            if ($type -eq 'optionGroupSets' -and $gsPlan -and $gsPlan.ContainsKey([string]$b['id'])) {
                $gp = $gsPlan[[string]$b['id']]
                $b1 = Copy-NeoIPCDeployValue $b1
                $b1['optionGroups'] = Get-RefPayload $gp.R1
                if ($gp.Category -eq 'Reset') { $z = Copy-NeoIPCDeployValue $b; $z['optionGroups'] = @(); $resets.Add($z) }
                if ($null -ne $gp.R2) { $needsSecond = $true }
            }
            $first.Add($b1)
            if ($needsSecond) { $second.Add($b) }
        }
        $r1[$type] = $first.ToArray()
        if ($second.Count -gt 0) { $r2[$type] = $second.ToArray() }
    }

    # ---- 9. dry run ----------------------------------------------------------------------------------------------
    if ($DryRun) {
        # Every object once, in its final form: deferred links included, group sets with their final lists.
        $final = [ordered]@{}
        foreach ($type in $types.Keys) {
            $list = @($bodies[$type].Values)
            if ($type -eq 'programs') { $list += @($lastPrograms.Keys | Where-Object { -not $bodies['programs'].ContainsKey($_) } | ForEach-Object { $lastPrograms[$_] }) }
            if ($list.Count -gt 0) { $final[$type] = $list }
        }
        try { $v = Invoke-DeployImport 'validate (dry run)' $final -Validate }
        catch { Exit-Deployment "The dry run's validation request failed: $($_.Exception.Message)" }
        Add-Step 'note' 'OK' 'VALIDATE stops before DHIS2 flushes a write, so a unique-key or cascade failure shows only in a commit'
        Write-Plan
        try { Add-LiveOnly } catch { Exit-Deployment "Listing the objects present only on the instance failed: $($_.Exception.Message)" }
        if ($v -and $v.Status -ne 'OK') { Exit-Deployment "The dry run's validation failed: $(Get-ImportErrorText $v)" }
        $summary.Succeeded = $true
        return $summary
    }

    # ---- 10. commit ----------------------------------------------------------------------------------------------
    function Assert-Gone([string]$Name, [object[]]$Keys) {
        $left = @(foreach ($k in $Keys) { $t, $i = $k -split '\|', 2; if (-not (Test-Gone $t $i)) { $k } })
        if ($left.Count -gt 0) { Add-Step $Name 'Failed' "still present: $($left -join ', ')"; Exit-Deployment "$Name left $($left.Count) object(s) in place: $($left -join ', ')." }
        Add-Step $Name 'OK' "$(@($Keys).Count) object(s) read back as gone"
    }
    function Assert-ChildGone([string]$Name, [object[]]$Orphans) {
        # A child with an endpoint is read back directly; a NestedOnly one has none, so its parent must no longer list it.
        $left = foreach ($o in $Orphans) {
            if ($script:NeoIPCMetadataTypeMaps[$o.Type].Nesting -ne 'NestedOnly') { if (-not (Test-Gone $o.Type $o.Id)) { "$($o.Type)|$($o.Id)" }; continue }
            $p = Invoke-NeoIPCDhis2Get @endpoint -Path "api/$($o.ParentType)/$($o.ParentId)" -Fields "$($o.Property)[id]" -AsHashtable -Confirm:$false -WhatIf:$false
            # DHIS2 leaves out only null values, so a parent read without the list is a failed read, not an empty list.
            if ($p -isnot [System.Collections.IDictionary] -or $null -eq $p[$o.Property]) { Exit-Deployment "${Name}: reading $($o.ParentType) $($o.ParentId) back returned no '$($o.Property)' list." }
            if ((Get-NeoIPCDeployRefIdList $p[$o.Property]) -ccontains $o.Id) { "$($o.Type)|$($o.Id)" }
        }
        $left = @($left)
        if ($left.Count -gt 0) { Add-Step $Name 'Failed' "still present: $($left -join ', ')"; Exit-Deployment "$Name left $($left.Count) dropped child(ren) in place: $($left -join ', ')." }
        foreach ($o in $Orphans) { [void]$summary.Deleted.Add("$($o.Type)|$($o.Id)") }
        Add-Step $Name 'OK' "$(@($Orphans).Count) dropped child(ren) read back as gone"
    }

    # A notification action whose re-creation failed is created again from the snapshot taken before its DELETE.
    # Whatever the failed attempt left is deleted first: writing over an existing action that carries a template is an
    # update, which fails from 2.42. Returns whether it was restored, and what happened, in a sentence.
    function Restore-TemplateAction([string]$Id, $Snapshot, $RuleBody) {
        $failed = { param([string]$Text) [pscustomobject]@{ Restored = $false; Text = $Text } }
        try {
            if (-not (Test-Gone 'programRuleActions' $Id)) {
                [void](Invoke-NeoIPCDhis2Delete @endpoint -Path "api/programRuleActions/$Id" -AllowUnencrypted -Confirm:$false)
                if (-not (Test-Gone 'programRuleActions' $Id)) { return (& $failed 'It could not be removed for its restore; its snapshot is in the summary (Snapshots).') }
            }
            $r = Import-NeoIPCMetadata -Json ([ordered]@{ programRuleActions = @($Snapshot); programRules = @($RuleBody) } | ConvertTo-Json -Depth 100 -Compress) @endpoint -AtomicMode 'ALL' -Confirm:$false
            if ($r.Status -eq 'OK' -and -not (Test-Gone 'programRuleActions' $Id)) { return [pscustomobject]@{ Restored = $true; Text = 'It was restored from its snapshot.' } }
            return (& $failed "Its restore failed (status $($r.Status): $(Get-ImportErrorText $r)); its snapshot is in the summary (Snapshots).")
        }
        catch { return (& $failed "Its restore failed ($($_.Exception.Message)); its snapshot is in the summary (Snapshots).") }
    }

    try {
        if ($detach.Count -gt 0) {
            [void](Invoke-DeployImport 'detach' ([ordered]@{ programRules = @($detach.Values) }))
            $detached = @($orphans | Where-Object { $_.ParentType -eq 'programRules' -and $detach.ContainsKey($_.ParentId) })
            if ($detached.Count -gt 0) { Assert-ChildGone 'detach read-back' $detached }
        }
        [void](Invoke-DeployImport 'R1' $r1)
        # Each dropped child is read back after the request that writes its parent: the detach request, R1, R2 for a
        # parent that gives a child away, or the programs' request.
        $laterOrphans = @($orphans | Where-Object { -not ($_.ParentType -eq 'programRules' -and $detach.ContainsKey($_.ParentId)) -and -not ($_.ParentType -eq 'programs' -and $lastPrograms.ContainsKey($_.ParentId)) })
        $r1Orphans = @($laterOrphans | Where-Object { -not $moveSources.Contains("$($_.ParentType)|$($_.ParentId)") })
        $r2Orphans = @($laterOrphans | Where-Object { $moveSources.Contains("$($_.ParentType)|$($_.ParentId)") })
        if ($r1Orphans.Count -gt 0) { Assert-ChildGone 'R1 read-back' $r1Orphans }
        if ($resets.Count -gt 0) {
            [void](Invoke-DeployImport 'group-set resets' ([ordered]@{ optionGroupSets = $resets.ToArray() }))
            foreach ($z in $resets) {
                $s = Invoke-NeoIPCDhis2Get @endpoint -Path "api/optionGroupSets/$($z['id'])" -Fields 'optionGroups[id]' -AsHashtable -Confirm:$false -WhatIf:$false
                if ($s -isnot [System.Collections.IDictionary] -or $null -eq $s['optionGroups']) { Exit-Deployment "Reading option group set $($z['id']) back after its reset returned no 'optionGroups' list." }
                if ((Get-NeoIPCDeployRefIdList $s['optionGroups']).Count -gt 0) { Exit-Deployment "The reset of option group set $($z['id']) left groups in it." }
            }
        }
        # R2 writes the parents children moved away from, and must read their collections from the database. DHIS2
        # evicts its caches at the end of each commit, but inside the commit's transaction, so a read in between can
        # cache a collection as it was: they are cleared once more before R2.
        if ($moveSources.Count -gt 0) {
            if ($SkipCacheClear) { Add-Step 'cache clear (moves)' 'Skipped' '-SkipCacheClear' } else { Clear-Dhis2Cache 'cache clear (moves)' }
        }
        [void](Invoke-DeployImport 'R2' $r2)
        if ($r2Orphans.Count -gt 0) { Assert-ChildGone 'R2 read-back' $r2Orphans }

        foreach ($aid in $templateSteps) {
            $body = $bodies['programRuleActions'][$aid]
            $rid = Get-NeoIPCDeployRefId $body['programRule']
            $missing = @((Get-NeoIPCDeployReference -Type 'programRuleActions' -Object $body) | Where-Object { $t, $i = $_ -split '\|', 2; Test-Gone $t $i })
            if ($missing.Count -gt 0) { Exit-Deployment "Program-rule action $aid refers to $($missing -join ', '), which does not exist." }
            $snapshot = (Get-LiveType 'programRuleActions' @($aid))[$aid]
            $summary.Snapshots.Add([pscustomobject]@{ Type = 'programRuleActions'; Id = $aid; Object = $snapshot })
            $ruleBody = if ($bodies['programRules'].ContainsKey($rid)) { $bodies['programRules'][$rid] }
            else { (New-NeoIPCDeployBody -Type 'programRules' -PackageObject $pkgById['programRules'][$rid] -Live (Get-LiveType 'programRules' @($rid))[$rid] -CopyOwned $copyOwned['programRules'] -Shareable:($shareable.Contains('programRules'))).Body }
            $others = @((Get-NeoIPCDeployRefIdList $ruleBody['programRuleActions']) | Where-Object { $_ -cne $aid })
            $othersBefore = @{}
            if ($others.Count -gt 0) {
                $read = Get-NeoIPCMetadataLiveObject -Endpoint $endpoint -Type 'programRuleActions' -Id $others -Field 'id', 'lastUpdated'
                if ($read.Failure) { Exit-Deployment "Reading the other actions of rule $rid before re-creating program-rule action $aid failed: $($read.Failure)" }
                $othersBefore = $read.ById
            }
            # Its DELETE counts as done unless DHIS2 refused it, and a restored action is what clients hold already.
            $scopedBefore = $progress.ProgramScoped
            $progress.ProgramScoped = $true
            try { [void](Invoke-NeoIPCDhis2Delete @endpoint -Path "api/programRuleActions/$aid" -AllowUnencrypted -Confirm:$false) }
            catch {
                if (Test-Refused $_) { $progress.ProgramScoped = $scopedBefore }
                Exit-Deployment "Deleting program-rule action $aid for its re-creation failed: $($_.Exception.Message)"
            }
            if (-not (Test-Gone 'programRuleActions' $aid)) { $progress.ProgramScoped = $scopedBefore; Exit-Deployment "Program-rule action $aid is still present after its DELETE." }
            # From here the action is gone, so a failed re-creation, an exception included, ends in its restore. Once DHIS2
            # has accepted the re-creation, a check that cannot read the result stops the run without a restore, which
            # would delete and write again what most likely holds the package's version already.
            $failure = $null; $unverified = $null
            try {
                $import = Import-NeoIPCMetadata -Json ([ordered]@{ programRuleActions = @($body); programRules = @($ruleBody) } | ConvertTo-Json -Depth 100 -Compress) @endpoint -AtomicMode 'ALL' -Confirm:$false
                if ($import.Status -ne 'OK') { $failure = "its re-creation ended with status $($import.Status) ($(Get-ImportErrorText $import))" }
            }
            catch { $failure = $_.Exception.Message }
            if (-not $failure) {
                try {
                    $after = Get-NeoIPCMetadataLiveObject -Endpoint $endpoint -Type 'programRuleActions' -Id @($aid) -Field 'id', 'templateUid', 'programRule[id]'
                    if ($after.Failure) { throw $after.Failure }
                    $ruleNow = Invoke-NeoIPCDhis2Get @endpoint -Path "api/programRules/$rid" -Fields 'programRuleActions[id]' -AsHashtable -Confirm:$false -WhatIf:$false
                    if ($ruleNow -isnot [System.Collections.IDictionary] -or $null -eq $ruleNow['programRuleActions']) { throw "the read of rule $rid held no 'programRuleActions' list" }
                    $othersAfter = @{}
                    if ($others.Count -gt 0) {
                        $read = Get-NeoIPCMetadataLiveObject -Endpoint $endpoint -Type 'programRuleActions' -Id $others -Field 'id', 'lastUpdated'
                        if ($read.Failure) { throw $read.Failure }
                        $othersAfter = $read.ById
                    }
                }
                catch { $unverified = $_.Exception.Message }
                if (-not $unverified) {
                    $listed = Get-NeoIPCDeployRefIdList $ruleNow['programRuleActions']
                    $touched = @($others | Where-Object { -not $othersAfter[$_] -or [string]$othersAfter[$_]['lastUpdated'] -cne [string]$othersBefore[$_]['lastUpdated'] })
                    $unlisted = @((Get-NeoIPCDeployRefIdList $ruleBody['programRuleActions']) | Where-Object { $listed -cnotcontains $_ })
                    if (-not $after.ById.ContainsKey($aid)) { $failure = 'it is missing after its re-creation' }
                    elseif ([string]$after.ById[$aid]['templateUid'] -cne [string]$body['templateUid']) { $failure = 'its template is not linked' }
                    elseif ($unlisted.Count -gt 0) { $failure = "its rule does not list $($unlisted -join ', ')" }
                    elseif ($touched.Count -gt 0) { $failure = "the rule's other actions changed: $($touched -join ', ')" }
                }
            }
            if ($failure) {
                $restore = Restore-TemplateAction $aid $snapshot $ruleBody
                if ($restore.Restored) { $progress.ProgramScoped = $scopedBefore }
                Add-Step "template action $aid" 'Failed' "$failure. $($restore.Text)"
                Exit-Deployment "Re-creating program-rule action $aid failed: $failure. $($restore.Text)"
            }
            if ($unverified) {
                Add-Step "template action $aid" 'Failed' "re-created with its rule, but reading the result back failed: $unverified"
                Exit-Deployment "Program-rule action $aid was re-created with its rule, but reading the result back for its check failed: $unverified. It was left as written; deploy again to check it."
            }
            [void]$summary.Written.Add("programRuleActions|$aid"); [void]$summary.Written.Add("programRules|$rid")
            Add-Step "template action $aid" 'OK' 're-created with its rule; the template is linked, the rule lists all its actions, the others are untouched'
        }

        foreach ($t in $deleteOrder) {
            foreach ($id in $deleteIds[$t]) {
                $l = $deleteLive[$t][$id]
                if (-not $l) { Add-Step "delete $t $id" 'Skipped' 'already absent'; continue }
                $readBack = @("$t|$id") + @($deletedWith["$t|$id"])
                $mustStay = [System.Collections.Generic.List[string]]::new()
                # A delete counts as done unless DHIS2 refused it: an answer lost on the way can follow a delete.
                $scopedBefore = $progress.ProgramScoped
                if (-not $script:NeoIPCDeployOutsideProgramTypes.Contains($t)) { $progress.ProgramScoped = $true }
                if ($t -eq 'optionGroups') {
                    # Emptied first: from 2.41.10 a group's DELETE deletes its member options, and on 2.40.12 it fails
                    # while the group has members. Emptied (and out of every set, which R2 ensured), it deletes alone.
                    foreach ($m in (Get-NeoIPCDeployRefIdList $l['options'])) { $mustStay.Add("options|$m") }
                    $put = Invoke-NeoIPCDhis2Put @endpoint -Path "api/optionGroups/$id/options" -Body '{"identifiableObjects":[]}' -Confirm:$false
                    if ([int]$put.StatusCode -lt 200 -or [int]$put.StatusCode -ge 300) {
                        if (Test-RefusedStatus $put.StatusCode) { $progress.ProgramScoped = $scopedBefore }
                        Exit-Deployment "Emptying option group $id failed (HTTP $($put.StatusCode))."
                    }
                    $scopedBefore = $progress.ProgramScoped
                }
                try { [void](Invoke-NeoIPCDhis2Delete @endpoint -Path "api/$t/$id" -AllowUnencrypted -Confirm:$false) }
                catch {
                    if (Test-Refused $_) { $progress.ProgramScoped = $scopedBefore }
                    Add-Step "delete $t $id" 'Failed' $_.Exception.Message; Exit-Deployment "Deleting $t $id failed: $($_.Exception.Message)"
                }
                Assert-Gone "delete $t $id" $readBack
                foreach ($k in $readBack) { [void]$summary.Deleted.Add($k) }
                $lost = @($mustStay | Where-Object { $tt, $ii = $_ -split '\|', 2; Test-Gone $tt $ii })
                if ($lost.Count -gt 0) { Exit-Deployment "Deleting $t $id also removed $($lost -join ', ')." }
            }
        }

        if ($lastPrograms.Count -gt 0) {
            [void](Invoke-DeployImport 'programs (version)' ([ordered]@{ programs = @($lastPrograms.Values) }))
            $progress.ProgramsWritten = $true
            $programOrphans = @($orphans | Where-Object { $_.ParentType -eq 'programs' -and $lastPrograms.ContainsKey($_.ParentId) })
            if ($programOrphans.Count -gt 0) { Assert-ChildGone 'programs read-back' $programOrphans }
        }
    }
    catch {
        # Only a failure that is not the deployment's own reaches this: Exit-Deployment ends the cmdlet at once.
        Exit-Deployment $_.Exception.Message
    }

    # ---- 11. verify ----------------------------------------------------------------------------------------------
    $written = [ordered]@{}
    foreach ($type in $types.Keys) { if ($bodies[$type].Count -gt 0) { $written[$type] = @($bodies[$type].Values) } }
    foreach ($id in $lastPrograms.Keys) { if (-not $bodies['programs'].ContainsKey($id)) { $written['programs'] = @(@($written['programs']) + @($lastPrograms[$id]) | Where-Object { $_ }) } }
    $failures = [System.Collections.Generic.List[string]]::new()
    # A value mismatch on a type-map property or nested spec is the convergence check's to judge, with DHIS2's
    # normalizations applied (below); one on anything else (attribute values, a user's names) fails here.
    function Test-MappedField([string]$Type, [string]$Field) {
        $m = $script:NeoIPCMetadataTypeMaps[$Type]
        [bool]($m -and ($m.Properties.Contains($Field) -or ($m.Nested -and $m.Nested.Contains($Field))))
    }
    try {
        $disc = @((Test-NeoIPCMetadataImport -Package $types -Auth $Auth -Scheme $Scheme -Hostname $Hostname -Port $Port -Expected $written -CheckTranslations) | Where-Object { $_.Kind })
        $fatal = @($disc | Where-Object {
                $_.Kind -in 'Missing', 'LinkDrop', 'OrderDrift', 'ValueDrop', 'FetchFailed', 'TranslationMismatch' -or
                ($_.Kind -eq 'FieldMismatch' -and $_.Field -ne 'version' -and -not (Test-MappedField $_.Type $_.Field))
            })
        foreach ($d in $fatal) { $summary.Verification.Add([pscustomobject]@{ Check = 'round-trip'; Type = $d.Type; Id = $d.Id; Detail = "$($d.Kind) $($d.Field): $($d.Detail)" }) }
        if ($fatal.Count -gt 0) { $failures.Add("$($fatal.Count) round-trip discrepancy(ies)") }

        $notConverged = 0
        foreach ($type in $types.Keys) {
            $now = Get-LiveType $type @($types[$type] | ForEach-Object { [string]$_['id'] })
            foreach ($o in $types[$type]) {
                $id = [string]$o['id']
                $l = $now[$id]
                $diff = if ($l) { @((Compare-NeoIPCDeployObject -Type $type -PackageObject $o -Live $l -Version $version -GovernedOwned $governed[$type]) | Where-Object { $_ -ne 'password' }) } else { @('(missing)') }
                if ($diff.Count -gt 0) { $notConverged++; $summary.Verification.Add([pscustomobject]@{ Check = 'converged'; Type = $type; Id = $id; Detail = "still differs: $($diff -join ', ')" }) }
            }
        }
        if ($notConverged -gt 0) { $failures.Add("$notConverged object(s) still differ from the package") }

        if ($types.Contains('programRuleActions') -and @($types['programRuleActions']).Count -gt 0) {
            if (-not $SkipCacheClear) { Clear-Dhis2Cache 'cache clear (served check)' }
            $short = @((Test-NeoIPCProgramRuleActionServed -Package ([ordered]@{ programRules = @($types['programRules']); programRuleActions = @($types['programRuleActions']) }) -Auth $Auth -Scheme $Scheme -Hostname $Hostname -Port $Port) | Where-Object { $_.Kind })
            foreach ($s in $short) { $summary.Verification.Add([pscustomobject]@{ Check = 'served'; Type = 'programRules'; Id = $s.RuleId; Detail = $s.Detail }) }
            if ($short.Count -gt 0) { $failures.Add("$($short.Count) rule(s) not serving every declared action") }
        }

        foreach ($pair in @(@('optionSets', $bodies['optionSets']), @('programs', $lastPrograms))) {
            $vt = $pair[0]; $vb = $pair[1]
            if (-not $vb -or $vb.Count -eq 0) { continue }
            $ids = @($vb.Keys | Where-Object { $state[$vt][$_].Status -ne 'New' })
            if ($ids.Count -eq 0) { continue }
            $now = (Get-NeoIPCMetadataLiveObject -Endpoint $endpoint -Type $vt -Id $ids -Field 'id', 'version').ById
            foreach ($id in $ids) {
                $before = [long]$live[$vt][$id]['version']
                $expected = if ($vt -eq 'optionSets') { $before + [Math]::Max(1, [int]$createdInSet[$id]) } else { $before + 1 }
                $stored = if ($now[$id]) { [long]$now[$id]['version'] } else { $null }
                $summary.Versions.Add([pscustomobject]@{ Type = $vt; Id = $id; Before = $before; Expected = $expected; Stored = $stored })
                if ($stored -ne $expected) { $failures.Add("$vt $id stored version $stored, expected $expected") }
            }
        }
    }
    catch {
        # Only a failure that is not the deployment's own reaches this: Exit-Deployment ends the cmdlet at once.
        Exit-Deployment "The deployment wrote its changes, but verifying them failed: $($_.Exception.Message)"
    }

    Write-Plan
    try { Add-LiveOnly } catch { $failures.Add("listing the objects present only on the instance failed: $($_.Exception.Message)") }
    if ($summary.DroppedTranslations.Count -gt 0) { Write-Host "  $($summary.DroppedTranslations.Count) translation(s) of changed values dropped" -ForegroundColor Yellow }
    if ($failures.Count -gt 0) {
        foreach ($v in @($summary.Verification | Select-Object -First 20)) { Write-Host ("  verify {0}: {1} {2} {3}" -f $v.Check, $v.Type, $v.Id, $v.Detail) -ForegroundColor Red }
        Exit-Deployment ("The deployment wrote its changes but failed verification: {0}." -f ($failures -join '; '))
    }
    Add-Step 'verify' 'OK' 'round-trip, convergence, served actions, versions'
    $summary.Succeeded = $true
    $summary
}
