# NeoIPC metadata pipeline — static data tables (no logic).
# Dot-sourced as a private module file; consumed by Private/Metadata.ps1 and the
# Public/Metadata.ps1 converter cmdlets. Definitions live here ONCE so the normalizer
# and the semantic-diff comparator provably share the same strip/ignore rules.

# Per-instance noise stripped before round-trip emit AND ignored by the comparator.
# Applied RECURSIVELY at every depth (embedded link/join sub-objects carry most of it).
# "Fields we never want" — kept forward-safe across DHIS2 versions even when absent today.
$script:NeoIPCMetadataStripList = @(
    'created', 'lastUpdated', 'createdBy', 'lastUpdatedBy',
    'access', 'favorite', 'favorites', 'userAccesses', 'userGroupAccesses', 'externalAccess',
    'href', 'user', 'publicAccess', 'lastUpdatedDuration',
    'users',  # the anonymised, per-deployment member list ON a userGroup object — dropped on capture, so common groups carry no members. (Does NOT affect sharing.users grants: those live inside the 'sharing' object, which Convert-NeoIPCSharing normalizes separately — reducing each grant to {id, access} and preserving it as authorization intent — and the recursive strip never reaches into the sharing branch.)
    'organisationUnits',  # per-deployment org-unit ASSIGNMENT / membership — organisationUnitGroups membership, the program's org-unit assignment, a categoryOption's restriction. Always references org-unit INSTANCES (anonymised in the export), never config; dropped on capture so common carries none. (Distinct from organisationUnitGroupSets.organisationUnitGroups and userGroups.managedGroups, which are definition→definition CONFIG and are kept.)
    'path'   # organisationUnit's materialised ancestor path — derived from `parent`, recomputed on import
)

# Server-derived i18n PROJECTIONS — read-only mirrors of a translatable base field, recomputed from
# translations[] + locale and never imported. Stripped by EXPLICIT key, NOT by a "display*" prefix: many
# AUTHORED config properties also start with "display" (verified in metadata.json: displayInReports x251,
# displayInList, displayInForm, displayInListNoProgram, displayOnVisitSchedule, displayGenerateEventBox,
# displayFrontPageList, displayIncidentDate, displayDensity) and MUST round-trip. The base fields mirrored
# here are name / shortName / formName / description (on most types) plus subjectTemplate / messageTemplate
# (only on NotificationTemplateObject subtypes — programNotificationTemplates — per NotificationTemplateObject.java).
$script:NeoIPCMetadataDisplayProjections = @(
    'displayName', 'displayShortName', 'displayFormName', 'displayDescription',
    'displaySubjectTemplate', 'displayMessageTemplate'
)

# Fields dropped from the per-type CSV directory AND ignored by the structural comparator. `translations` is
# deliberately NOT carried in CSV cells: i18n lives in a separate, translator-facing gettext PO component
# (po/metadata.<lang>.po), converted to/from each object's translations[] by Export/Import-NeoIPCMetadataTranslation
# (see Private/MetadataTranslation.ps1). So the CSV round-trip stays purely structural — translations are stripped
# here by Remove-NeoIPCMetadataNoise and round-tripped losslessly through the PO path instead.
$script:NeoIPCMetadataDeferredFields = @('translations')

# Whole object TYPES excluded from the package entirely (not field-stripping): account/PII-shaped
# objects, server-generated collections, and authored-instance content the export carries only in
# anonymised form. Excluded from emit, the comparator, AND the PO, so their presence in a source
# export is not reported as a round-trip difference.
$script:NeoIPCMetadataExcludedTypes = @(
    'users', 'apiToken',           # account/PII tier (users are fully anonymised in the export; the play variant gets synthetic authored accounts)
    'categoryOptionCombos',        # server-generated (regenerate-on-import)
    'organisationUnits'            # authored content (real production UIDs / ISO codes / English names) the export carries only as anonymised instances (code:null, dummy O… ids, name:"Anonymized Org Unit"); assembled from the directory via Read-NeoIPCAuthoredOrgUnit, never the converter type-map. The org-unit GROUPS / GROUP-SETS / LEVELS stay non-closure (translatable classification config).
)

# Option SETS whose member options are domain-authored elsewhere — generated from a richer canonical source, not
# hand-maintained in the per-type CSV directory: NEOIPC_PATHOGENS from infectious-agents/NeoIPC-Infectious-Agents.yaml
# (3269 options) and NEOIPC_ANTIMICROBIAL_SUBSTANCES from antibiotics/NeoIPC-Antibiotics.csv (242) — together
# 3511/3557 of all options. The set definitions AND their member options are dropped from the materialised
# directory (ConvertFrom-NeoIPCMetadataPackage) and ignored by the comparator (Compare-NeoIPCMetadataCore), so the
# round-trip gate does not flag their absence. They are NOT dropped from the closure: New-NeoIPCMetadataPackage
# builds the importable package from the export's closure, which carries them, so the import stays complete — the
# closure export is the splice source for these sets. Keyed by CODE (stable across instances); the per-option
# cascade resolves these codes to their optionSet UIDs at runtime.
$script:NeoIPCMetadataDomainOptionSetCodes = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('NEOIPC_PATHOGENS', 'NEOIPC_ANTIMICROBIAL_SUBSTANCES'), [System.StringComparer]::Ordinal)

# Program rules that are GENERATED elsewhere — the pathogen / substance / resistance / field-gating machinery the
# ontology + capability matrix produce (Add-NeoIPCGeneratedMetadata). Identified by the generator PLANS, not a
# regex (see Get-NeoIPCMetadataGeneratedKeys), and dropped from the materialised directory and the comparator the
# same way the domain option sets are — the YAML / matrix are their single source. This list holds only the
# DEPLOYED rules a generator family does NOT reproduce by name yet still supersedes, so the family predicate alone
# would miss them: the stale HAP aggregate 'NeoIPC HAP - set pathogen attribute variables' (15 dead ASSIGNs the
# per-slot resistance rules replace — the colistin #22/#23 residue), which the directory, like the assembled
# package, sheds as superseded cruft.
$script:NeoIPCMetadataRetiredRuleNames = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('NeoIPC HAP - set pathogen attribute variables'), [System.StringComparer]::Ordinal)

# NON-CLOSURE types — first-class NeoIPC metadata the dependency closure cannot reach STRUCTURALLY, packaged
# as deployment config with their real UIDs. They are converted, compared, and round-tripped like any other
# type, but the closure (index + prune) and the owned-id / UID-regeneration scan skip them. Distinct from
# excluded types (not handled at all) and deferred types (not yet handled). Two families:
#
#   Org-unit GROUPS, GROUP-SETS, and LEVEL definitions — real deployment config that production (not just
#   play) needs: neoipcr reads org-unit group memberships for org-unit roles, World-Bank income classes, and
#   reference-centre / test-unit / trial-site identification. The NEOIPC_CORE program references the groups
#   only by CODE inside expression strings (d2:inOrgUnitGroup('NEO_DEPARTMENT')), never by structured {id}, so
#   the {id}-walk closure cannot pull them in. (The org-unit INSTANCES themselves are NOT here — they are
#   excluded authored content the export anonymises; see $NeoIPCMetadataExcludedTypes.)
#
#   userRoles and userGroups — the access-control config. userRoles (authorities + restrictions) are
#   deployment-agnostic and referenced only by user accounts (which are excluded/synthetic), so nothing in
#   the program closure points at them. userGroups carry the group definitions; one of them
#   (NEOIPC_PATHOGEN_LIST_ADMINS) is the recipientUserGroup of every program notification template, so a
#   closure object DOES reference it by {id} — but since userGroups is packaged whole, that reference is
#   satisfied without indexing the type into the closure walk (previously it resolved only because excluded
#   types are treated as import-time overlays). Their per-deployment membership (the anonymised users[]) is
#   stripped on capture, so common groups carry no members.
$script:NeoIPCMetadataNonClosureTypes = @(
    'organisationUnitGroups', 'organisationUnitGroupSets', 'organisationUnitLevels',
    'userRoles', 'userGroups'
)

# Object types not yet handled — not PII/server/env-excluded, just unhandled for now. The analytics
# favorites (verified present: eventVisualizations x8, visualizations x3) carry very large, analytics-
# specific property sets, so they are comparator-ignored exactly like excluded types (no handler yet).
$script:NeoIPCMetadataDeferredTypes = @(
    'visualizations', 'eventVisualizations'
)

# DHIS2 system default objects (default Category / CategoryCombo / CategoryOption /
# CategoryOptionCombo). Fixed system UIDs — never authored, minted, or diffed as package content.
$script:NeoIPCMetadataDefaultUids = @(
    'GLevLNI9wkl',
    'bjDvmb4bfuf',
    'xYerKDKCefk',
    'HllvX50cXC0'
)

# Per-type conversion maps. Each entry:
#   NaturalKey  - property name (or @('a','b') composite) used as the deterministic-mint SEED for
#                 id-less authored objects. Real exports carry ids on every object, so the round-trip
#                 matches by id (preserve-if-present); the mint seed is not used on the round-trip path.
#                 'code' as a seed relies on the NeoIPC convention that every object carries a code:
#                 DHIS2 itself makes code OPTIONAL (nullable `String code` in BaseIdentifiableObject)
#                 and enforces per-type uniqueness for most types EXCEPT options
#                 (Option.hbm.xml -> unique="false") — option codes repeat across option sets, so
#                 'options' uses the optionSet|code composite. Verified against refs/dhis2-core.
#   Nesting     - TopLevel | NestedOnly | BothPlaces (where the object lives in the package).
#   Properties  - ordered prop -> class. Classes: bool | int | string | idString | id | idArray |
#                 idArrayOrdered | intArray | stringArray. 'idString' is a bare-string UID reference (not a
#                 {id} object) — e.g. programRuleActions.templateUid -> a programNotificationTemplate; it
#                 serializes like a string but the closure follows it as a dependency edge. 'idArrayOrdered'
#                 is for DHIS2 <list> ref-collections whose
#                 element order is the data and is NOT recoverable from an element-level sortOrder
#                 (categoryCombos.categories, categories.categoryOptions, optionGroupSets.optionGroups,
#                 programStageSections.dataElements/programIndicators, programSections.trackedEntityAttributes);
#                 it preserves array order in the cell, and the normalizer compares it positionally.
#                 Plain 'idArray' is for <set>s and for <list>s whose order is recoverable from each
#                 element's sortOrder (e.g. optionSets.options). The synthesized 'id' key, 'sharing'
#                 (carried as a normalized JSON cell),
#                 'translations' (JSON cell, currently comparator-ignored), and the audit/noise fields
#                 (handled by Remove-NeoIPCMetadataNoise) are implicit and NOT listed here.
# Derived from the empirical per-type shapes in metadata.json, not from the prior art or the spec.
#
# The name-family properties are factored into two shared bases that mirror DHIS2's own class hierarchy
# (BaseIdentifiableObject -> BaseNameableObject, verified against refs/dhis2-core): a type re-spelling
# `name`/`shortName`/`description` in ~15 entries is exactly how `trackedEntityTypes` once silently dropped
# `shortName` (the DHIS2 2.42 E4000 regression). `[ordered] + [ordered]` copies and preserves order, and THROWS
# on a duplicate key at import time — so re-spelling a base property over the base is a load error, not drift.
# `code` sits FIRST (matching every coded type) so it can host the whole identifiable family; `formName` is
# interleaved between `shortName` and `description` on dataElements/trackedEntityAttributes, which the base cannot
# express, so those two keep their name-family explicit. programRuleActions authors no name -> no base, explicit
# `code`-less entry (the documented exception; see docs/dhis2-code-on-first-class-types.md). The four EmbeddedObject
# nested types (…DataElements, …TrackedEntityAttributes, trackedEntityTypeAttributes, analyticsPeriodBoundaries)
# never take a base: DHIS2 does not resolve them by code, and two carry only a DERIVED name.
$script:NeoIPCMetadataIdentifiableBase = [ordered]@{ code = 'string'; name = 'string' }
$script:NeoIPCMetadataNameableBase = $script:NeoIPCMetadataIdentifiableBase + [ordered]@{ shortName = 'string'; description = 'string' }
# Short unqualified aliases the per-type entries below read (they resolve to the $script: bases at load time).
$IdentifiableBase = $script:NeoIPCMetadataIdentifiableBase
$NameableBase = $script:NeoIPCMetadataNameableBase

$script:NeoIPCMetadataTypeMaps = [ordered]@{
    'dataElements'          = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; formName = 'string'; description = 'string'; url = 'string'
        valueType = 'string'; domainType = 'string'; aggregationType = 'string'; zeroIsSignificant = 'bool'
        categoryCombo = 'id'; optionSet = 'id'; commentOptionSet = 'id'; aggregationLevels = 'intArray'; legendSets = 'idArray' } }
    'options'               = @{ NaturalKey = @('optionSet', 'code'); Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        sortOrder = 'int'; optionSet = 'id' } }
    'optionSets'            = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        valueType = 'string'; version = 'int'; options = 'idArray' } }
    'optionGroups'          = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $NameableBase + [ordered]@{
        optionSet = 'id'; options = 'idArray' } }
    'optionGroupSets'       = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        description = 'string'; dataDimension = 'bool'; optionSet = 'id'; optionGroups = 'idArrayOrdered' } }
    'dataElementGroups'     = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        shortName = 'string'; dataElements = 'idArrayOrdered' } }
    'indicatorTypes'        = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        factor = 'int'; number = 'bool' } }
    'categories'            = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        shortName = 'string'; dataDimensionType = 'string'; dataDimension = 'bool'; categoryOptions = 'idArrayOrdered' } }
    'categoryCombos'        = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        dataDimensionType = 'string'; skipTotal = 'bool'; categories = 'idArrayOrdered' } }
    'categoryOptions'       = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        shortName = 'string' } }   # organisationUnits (restriction) is per-deployment — stripped
    'trackedEntityAttributes' = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; formName = 'string'; description = 'string'; pattern = 'string'; fieldMask = 'string'
        valueType = 'string'; aggregationType = 'string'
        confidential = 'bool'; displayInListNoProgram = 'bool'; displayOnVisitSchedule = 'bool'; generated = 'bool'; inherit = 'bool'
        orgunitScope = 'bool'; skipSynchronization = 'bool'; unique = 'bool'
        optionSet = 'id'; legendSets = 'idArray' } }
    'programRuleVariables'  = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        programRuleVariableSourceType = 'string'; valueType = 'string'; useCodeForOptionSet = 'bool'
        program = 'id'; dataElement = 'id'; trackedEntityAttribute = 'id'; programStage = 'id' } }
    'programRules'          = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        description = 'string'; condition = 'string'; priority = 'int'
        program = 'id'; programStage = 'id'; programRuleActions = 'idArray' } }
    'programRuleActions'    = @{ NaturalKey = 'id'; Nesting = 'BothPlaces'; Properties = [ordered]@{
        programRuleActionType = 'string'; content = 'string'; data = 'string'; location = 'string'; templateUid = 'idString'
        programRule = 'id'; dataElement = 'id'; trackedEntityAttribute = 'id'; programStageSection = 'id'
        programStage = 'id'; programIndicator = 'id'; optionGroup = 'id'; option = 'id' } }
    'programStageSections'  = @{ NaturalKey = 'name'; Nesting = 'BothPlaces'
        Properties = $IdentifiableBase + [ordered]@{ description = 'string'; sortOrder = 'int'; programStage = 'id'; dataElements = 'idArrayOrdered'; programIndicators = 'idArrayOrdered' }
        Nested = [ordered]@{ renderType = @{ Wrap = $true; Fields = [ordered]@{ DESKTOP = 'string'; MOBILE = 'string' } } } }
    'programSections'       = @{ NaturalKey = 'name'; Nesting = 'BothPlaces'
        Properties = $IdentifiableBase + [ordered]@{ sortOrder = 'int'; program = 'id'; trackedEntityAttributes = 'idArrayOrdered' }
        Nested = [ordered]@{ renderType = @{ Wrap = $true; Fields = [ordered]@{ DESKTOP = 'string'; MOBILE = 'string' } } } }
    'validationRules'       = @{ NaturalKey = 'name'; Nesting = 'TopLevel'
        Properties = $IdentifiableBase + [ordered]@{ operator = 'string'; periodType = 'string'; importance = 'string'; skipFormValidation = 'bool'; organisationUnitLevels = 'intArray' }
        Nested = [ordered]@{
            leftSide  = @{ Wrap = $false; Fields = [ordered]@{ expression = 'string'; missingValueStrategy = 'string'; slidingWindow = 'bool' } }
            rightSide = @{ Wrap = $false; Fields = [ordered]@{ expression = 'string'; missingValueStrategy = 'string'; slidingWindow = 'bool' } } } }
    'trackedEntityTypes'    = @{ NaturalKey = 'name'; Nesting = 'TopLevel'
        Properties = $NameableBase + [ordered]@{ featureType = 'string'; allowAuditLog = 'bool'
            maxTeiCountToReturn = 'int'; minAttributesRequiredToSearch = 'int' }
        Nested = [ordered]@{ style = @{ Wrap = $false; Fields = [ordered]@{ icon = 'string' } } } }
    'programs'              = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $NameableBase + [ordered]@{
        programType = 'string'; accessLevel = 'string'; enrollmentDateLabel = 'string'; incidentDateLabel = 'string'
        version = 'int'; expiryDays = 'int'; completeEventsExpiryDays = 'int'; maxTeiCountToReturn = 'int'
        minAttributesRequiredToSearch = 'int'; openDaysAfterCoEndDate = 'int'
        displayFrontPageList = 'bool'; displayIncidentDate = 'bool'; ignoreOverdueEvents = 'bool'; onlyEnrollOnce = 'bool'
        selectEnrollmentDatesInFuture = 'bool'; selectIncidentDatesInFuture = 'bool'; skipOffline = 'bool'; useFirstStageDuringRegistration = 'bool'
        categoryCombo = 'id'; trackedEntityType = 'id'
        programStages = 'idArray'; programSections = 'idArray'; notificationTemplates = 'idArray' } }   # organisationUnits (the program's org-unit assignment) is per-deployment — stripped
    'programStages'        = @{ NaturalKey = 'name'; Nesting = 'BothPlaces'; Properties = $IdentifiableBase + [ordered]@{
        description = 'string'; executionDateLabel = 'string'; reportDateToUse = 'string'; validationStrategy = 'string'
        minDaysFromStart = 'int'; sortOrder = 'int'
        allowGenerateNextVisit = 'bool'; autoGenerateEvent = 'bool'; blockEntryForm = 'bool'; displayGenerateEventBox = 'bool'
        enableUserAssignment = 'bool'; generatedByEnrollmentDate = 'bool'; hideDueDate = 'bool'; openAfterEnrollment = 'bool'
        preGenerateUID = 'bool'; referral = 'bool'; remindCompleted = 'bool'; repeatable = 'bool'
        program = 'id'; programStageSections = 'idArray'; notificationTemplates = 'idArray' } }
    'programIndicators'    = @{ NaturalKey = { if ($_['code']) { $_['code'] } else { $_['name'] } }; Nesting = 'TopLevel'; Properties = $NameableBase + [ordered]@{
        expression = 'string'; filter = 'string'
        aggregationType = 'string'; analyticsType = 'string'; decimals = 'int'; displayInForm = 'bool'; program = 'id' } }
    'programNotificationTemplates' = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        subjectTemplate = 'string'; messageTemplate = 'string'
        notificationTrigger = 'string'; notificationRecipient = 'string'
        notifyUsersInHierarchyOnly = 'bool'; notifyParentOrganisationUnitOnly = 'bool'; sendRepeatable = 'bool'
        relativeScheduledDays = 'int'; deliveryChannels = 'stringArray'
        recipientUserGroup = 'id'; recipientProgramAttribute = 'id'; recipientDataElement = 'id' } }
    'attributes'           = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $NameableBase + [ordered]@{
        valueType = 'string'
        mandatory = 'bool'; unique = 'bool'; objectTypes = 'stringArray'
        categoryAttribute = 'bool'; categoryOptionAttribute = 'bool'; categoryOptionComboAttribute = 'bool'
        categoryOptionGroupAttribute = 'bool'; categoryOptionGroupSetAttribute = 'bool'; constantAttribute = 'bool'
        dataElementAttribute = 'bool'; dataElementGroupAttribute = 'bool'; dataElementGroupSetAttribute = 'bool'
        dataSetAttribute = 'bool'; documentAttribute = 'bool'; eventChartAttribute = 'bool'; eventReportAttribute = 'bool'
        indicatorAttribute = 'bool'; indicatorGroupAttribute = 'bool'; legendSetAttribute = 'bool'; mapAttribute = 'bool'
        optionAttribute = 'bool'; optionSetAttribute = 'bool'; organisationUnitAttribute = 'bool'
        organisationUnitGroupAttribute = 'bool'; organisationUnitGroupSetAttribute = 'bool'; programAttribute = 'bool'
        programIndicatorAttribute = 'bool'; programStageAttribute = 'bool'; relationshipTypeAttribute = 'bool'
        sectionAttribute = 'bool'; sqlViewAttribute = 'bool'; trackedEntityAttributeAttribute = 'bool'
        trackedEntityTypeAttribute = 'bool'; userAttribute = 'bool'; userGroupAttribute = 'bool'
        validationRuleAttribute = 'bool'; validationRuleGroupAttribute = 'bool'; visualizationAttribute = 'bool' } }
    'organisationUnits'     = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        shortName = 'string'; openingDate = 'string'; closedDate = 'string'; level = 'int'; parent = 'id'; image = 'id' } }
    'organisationUnitGroups' = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $NameableBase + [ordered]@{
        symbol = 'string'; color = 'string' } }   # organisationUnits (membership) is per-deployment — stripped on capture; re-authored as common + play overlays
    'organisationUnitGroupSets' = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $NameableBase + [ordered]@{
        compulsory = 'bool'; dataDimension = 'bool'; includeSubhierarchyInAnalytics = 'bool'; organisationUnitGroups = 'idArray' } }   # idArray (NOT idArrayOrdered): OrganisationUnitGroupSet.hbm.xml maps organisationUnitGroups as an unordered <set> (no list-index) -> member order is not significant, ordinal-sort for determinism. Contrast optionGroupSets.optionGroups, an ordered <list> with a sort_order column -> idArrayOrdered.
    'organisationUnitLevels' = @{ NaturalKey = 'level'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        level = 'int'; offlineLevels = 'int' } }
    'userRoles'             = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        description = 'string'; authorities = 'stringArray'; restrictions = 'stringArray' } }   # description is userRole's OWN field (BaseIdentifiableObject, not nameable) — not the name-family one
    'userGroups'            = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = $IdentifiableBase + [ordered]@{
        managedGroups = 'idArray' } }
    'programStageDataElements' = @{ NaturalKey = 'id'; Nesting = 'NestedOnly'
        Parent = @{ Type = 'programStages'; ArrayProp = 'programStageDataElements'; FkProp = 'programStage'; FkSynthetic = $false }
        Properties = [ordered]@{ compulsory = 'bool'; allowFutureDate = 'bool'; allowProvidedElsewhere = 'bool'
            renderOptionsAsRadio = 'bool'; skipAnalytics = 'bool'; skipSynchronization = 'bool'; displayInReports = 'bool'
            sortOrder = 'int'; dataElement = 'id'; programStage = 'id' }
        Nested = [ordered]@{ renderType = @{ Wrap = $true; Fields = [ordered]@{ DESKTOP = 'string'; MOBILE = 'string' } } } }
    'programTrackedEntityAttributes' = @{ NaturalKey = 'id'; Nesting = 'NestedOnly'
        Parent = @{ Type = 'programs'; ArrayProp = 'programTrackedEntityAttributes'; FkProp = 'program'; FkSynthetic = $false }
        Properties = [ordered]@{ name = 'string'; valueType = 'string'; mandatory = 'bool'; searchable = 'bool'
            renderOptionsAsRadio = 'bool'; displayInList = 'bool'; sortOrder = 'int'; program = 'id'; trackedEntityAttribute = 'id' }
        Nested = [ordered]@{ renderType = @{ Wrap = $true; Fields = [ordered]@{ DESKTOP = 'string'; MOBILE = 'string' } } } }
    'trackedEntityTypeAttributes' = @{ NaturalKey = 'id'; Nesting = 'NestedOnly'
        Parent = @{ Type = 'trackedEntityTypes'; ArrayProp = 'trackedEntityTypeAttributes'; FkProp = 'trackedEntityType'; FkSynthetic = $false }
        Properties = [ordered]@{ name = 'string'; valueType = 'string'; mandatory = 'bool'; searchable = 'bool'
            displayInList = 'bool'; trackedEntityType = 'id'; trackedEntityAttribute = 'id' } }
    'analyticsPeriodBoundaries' = @{ NaturalKey = 'id'; Nesting = 'NestedOnly'
        Parent = @{ Type = 'programIndicators'; ArrayProp = 'analyticsPeriodBoundaries'; FkProp = 'programIndicator'; FkSynthetic = $true }
        Properties = [ordered]@{ analyticsPeriodBoundaryType = 'string'; boundaryTarget = 'string'; offsetPeriods = 'int'; offsetPeriodType = 'string' } }
}

# The set of property NAMES whose ref-collection order must be preserved (not sorted) — derived from
# the 'idArrayOrdered' class above so the type maps stay the single source of truth. The normalizer
# (Remove-NeoIPCMetadataNoise) keys on property name to compare these positionally; a name that is
# idArrayOrdered in ANY type is therefore treated as ordered in EVERY type that carries it — which is
# why 'dataElements' is idArrayOrdered on both dataElementGroups (a <set>, harmless to keep in order)
# and programStageSections (a <list>, where order is the form layout). Verified against refs/dhis2-core
# *.hbm.xml: these are the <list>-mapped collections with no element-level sortOrder to recover from.
$script:NeoIPCMetadataOrderedRefProps = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(foreach ($map in $script:NeoIPCMetadataTypeMaps.Values) {
        foreach ($prop in $map.Properties.Keys) { if ($map.Properties[$prop] -eq 'idArrayOrdered') { $prop } }
    }),
    [System.StringComparer]::Ordinal)

# The ref-collections DHIS2 actually persists as ORDERED <list>s (a sort_order list-index column), keyed by
# "<type>|<property>". This is the round-trip VERIFIER's source of truth for an order check (Test-NeoIPCMetadataImport
# OrderDrift): only these collections are guaranteed to read back in the imported order, so only these may be compared
# positionally against DHIS2. It is deliberately NARROWER than $NeoIPCMetadataOrderedRefProps above, for two reasons:
# (1) that set is keyed by property NAME and serves the NORMALIZER's cell determinism (preserve-in-cell, NOT
#     server-order), so it cannot distinguish two types that share a property name; and
# (2) `dataElementGroups.dataElements` is classed idArrayOrdered there only so its CSV cell stays stable, but DHIS2
#     maps DataElementGroup.members as an unordered <set> (no list-index — DataElementGroup.hbm.xml), so it is
#     EXCLUDED here: ordering it positionally would false-positive (the server returns members in hash order).
# Each entry verified against refs/dhis2-core *.hbm.xml as a <list> with <list-index column="sort_order" base="1">.
$script:NeoIPCMetadataServerOrderedRefs = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'optionGroupSets|optionGroups'                  # OptionGroupSet.hbm.xml <list>
        'categories|categoryOptions'                    # Category.hbm.xml <list>
        'categoryCombos|categories'                     # CategoryCombo.hbm.xml <list>
        'programStageSections|dataElements'             # ProgramStageSection.hbm.xml <list> (form layout)
        'programStageSections|programIndicators'        # ProgramStageSection.hbm.xml <list>
        'programSections|trackedEntityAttributes'       # ProgramSection.hbm.xml <list>
        # NestedOnly attribute lists — genuine <list> with sort_order, but their order lives on the PARENT
        # collection (TrackedEntityTypeAttribute has no element sortOrder at all), so the verifier checks it
        # positionally on the parent's child-id sequence (the NestedOnly pass), not via a parent field compare.
        'programs|programTrackedEntityAttributes'       # Program.hbm.xml <list name="programAttributes">
        'trackedEntityTypes|trackedEntityTypeAttributes' # TrackedEntityType.hbm.xml <list>
    ),
    [System.StringComparer]::Ordinal)

# Translatable base property -> DHIS2 ObjectTranslation TOKEN. A translations[] entry serializes as
# { property = <TOKEN>, locale = <java-locale string, e.g. "de">, value = <translated string> }
# (refs/dhis2-core dhis-api .../translation/Translation.java). The TOKEN is the literal @Translatable.key()
# value, NOT a generic uppercase of the property name — three forms break that rule
# (enrollmentDateLabel -> ENROLLMENT_DATE_LABEL, subjectTemplate -> SUBJECT_TEMPLATE,
# messageTemplate -> MESSAGE_TEMPLATE), so the mapping is enumerated, not computed. Verified against
# refs/dhis2-core: translation/Translatable.java, translation/TranslationProperty.java, and each type's
# @Translatable getters (BaseIdentifiableObject/BaseNameableObject/NotificationTemplateObject + Program /
# ProgramStage / ProgramRuleAction / ValidationRule). This is the complete set of tokens that can occur on
# the metadata types NeoIPC carries. The per-type translatable property set is the INTERSECTION of a type's
# mapped Properties with these keys (Get-NeoIPCMetadataTranslatableField), so it auto-tracks the type maps.
$script:NeoIPCMetadataTranslatableProperties = [ordered]@{
    name                = 'NAME'
    shortName           = 'SHORT_NAME'
    formName            = 'FORM_NAME'
    description         = 'DESCRIPTION'
    subjectTemplate     = 'SUBJECT_TEMPLATE'
    messageTemplate     = 'MESSAGE_TEMPLATE'
    content             = 'CONTENT'
    instruction         = 'INSTRUCTION'
    enrollmentDateLabel = 'ENROLLMENT_DATE_LABEL'
    incidentDateLabel   = 'INCIDENT_DATE_LABEL'
    executionDateLabel  = 'EXECUTION_DATE_LABEL'
    dueDateLabel        = 'DUE_DATE_LABEL'
}

# (type -> tokens) deliberately NOT carried as translatable, even though the type's translations[] may contain
# them: a translations[] entry on one of these is dropped from the PO WITHOUT the usual "token the type map
# does not carry" warning, because the drop is intentional, not drift. Only FORM_NAME on the three nameable
# config types (programs / programStages / trackedEntityTypes): in the live export their base `formName` is
# empty and their FORM_NAME translation merely duplicates the NAME translation. DHIS2's getDisplayFormName()
# falls back to the NAME translation when the base formName is empty (BaseNameableObject.getFormNameFallback ->
# getDisplayName), so the displayed form name is identical with or without the FORM_NAME entry — carrying it
# would only add a PO string duplicating NAME. (dataElements / trackedEntityAttributes DO carry a non-empty
# base formName, so FORM_NAME stays translatable there and is not listed here.)
$script:NeoIPCMetadataTranslationIgnoredTokens = @{
    programs           = @('FORM_NAME')
    programStages      = @('FORM_NAME')
    trackedEntityTypes = @('FORM_NAME')
}

# Default target languages for the metadata PO component — the same nine the reports' po4a / glossary pipeline
# targets (see Surveillance-Toolkit CLAUDE.md). Overridable per call via the cmdlets' -Locale parameter.
$script:NeoIPCMetadataTranslationLocales = @('af', 'de', 'el', 'es', 'et', 'fr', 'it', 'ne', 'tr')

# Per-string Weblate PRIORITY for the metadata PO. The converter exports the FULL @Translatable surface (DHIS2
# marks `name` @Translatable on every object — BaseIdentifiableObject.getDisplayName — so nothing is dropped),
# but the thousands of strings on metadata/common are dominated by internal labels no end-user sees (program-rule and
# program-rule-variable names — #{var} expression identifiers — raw data-element / category / userRole names). So
# every (type, TOKEN) listed below is ELEVATED to the given Weblate priority (higher = translated first); every
# (type, TOKEN) NOT listed is DEPRIORITISED to $NeoIPCMetadataLowTranslationPriority so translators clear the
# user-facing strings first and the internal ones sink to the bottom of the queue (nothing is excluded — the
# whole surface stays translatable). The bands: form-entry labels (200) > option values / notifications /
# org-unit names (150) > user-facing titles + descriptions (100, the Weblate default — no flag emitted) > the
# unlisted internal remainder (low). Retune as translation needs change.
$script:NeoIPCMetadataLowTranslationPriority = 10
$script:NeoIPCMetadataTranslationPriorities = [ordered]@{
    dataElements                 = [ordered]@{ FORM_NAME = 200 }                                                   # data-entry field labels
    trackedEntityAttributes      = [ordered]@{ FORM_NAME = 200; NAME = 150 }
    programStageSections         = [ordered]@{ NAME = 200; DESCRIPTION = 100 }                                     # form section headers
    programSections              = [ordered]@{ NAME = 200 }
    programs                     = [ordered]@{ ENROLLMENT_DATE_LABEL = 200; INCIDENT_DATE_LABEL = 200; NAME = 100; SHORT_NAME = 100; DESCRIPTION = 100 }
    programStages                = [ordered]@{ EXECUTION_DATE_LABEL = 200; NAME = 150; DESCRIPTION = 100 }
    options                      = [ordered]@{ NAME = 150 }                                                        # dropdown values
    programNotificationTemplates = [ordered]@{ SUBJECT_TEMPLATE = 150; MESSAGE_TEMPLATE = 150 }                    # messages users receive
    organisationUnits            = [ordered]@{ NAME = 150; SHORT_NAME = 150 }
    organisationUnitGroups       = [ordered]@{ NAME = 100; SHORT_NAME = 100; DESCRIPTION = 100 }
    organisationUnitGroupSets    = [ordered]@{ NAME = 100; SHORT_NAME = 100; DESCRIPTION = 100 }
    optionSets                   = [ordered]@{ NAME = 100 }
    optionGroups                 = [ordered]@{ NAME = 100; SHORT_NAME = 100; DESCRIPTION = 100 }
    programIndicators            = [ordered]@{ NAME = 100; SHORT_NAME = 100; DESCRIPTION = 100 }
}
