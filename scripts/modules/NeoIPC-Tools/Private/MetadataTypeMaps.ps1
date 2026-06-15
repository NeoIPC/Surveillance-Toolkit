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
    'href', 'user', 'publicAccess', 'lastUpdatedDuration'
)

# Server-derived i18n PROJECTIONS — read-only mirrors of a translatable base field
# (name / shortName / formName / description), recomputed from translations[] + locale and never
# imported. Stripped by EXPLICIT key, NOT by a "display*" prefix: many AUTHORED config properties
# also start with "display" (verified in metadata.json: displayInReports x251, displayInList,
# displayInForm, displayInListNoProgram, displayOnVisitSchedule, displayGenerateEventBox,
# displayFrontPageList, displayIncidentDate, displayDensity) and MUST round-trip.
$script:NeoIPCMetadataDisplayProjections = @(
    'displayName', 'displayShortName', 'displayFormName', 'displayDescription'
)

# Fields deferred to a later milestone — dropped from the M1 dir AND ignored by the comparator
# (so M1's gate is purely structural). `translations` move to gettext PO in M4b (decision 11);
# carrying them faithfully through flat CSV cells — including the nested leftSide/rightSide.translations
# on validation rules — is out of scope for M1. Stripped recursively by Remove-NeoIPCMetadataNoise.
$script:NeoIPCMetadataDeferredFields = @('translations')

# Whole object TYPES excluded from the package entirely (not field-stripping): account/PII-shaped
# objects, and server-generated / environment-coupled collections. Excluded from both emit and the
# comparator, so their presence in a source export is not reported as a round-trip difference.
$script:NeoIPCMetadataExcludedTypes = @(
    'users', 'userRoles', 'userGroups', 'apiToken',   # account/PII tier
    'categoryOptionCombos',                            # server-generated (regenerate-on-import)
    'organisationUnits', 'organisationUnitLevels',     # environment-coupled (separate concern)
    'organisationUnitGroups', 'organisationUnitGroupSets'
)

# Object types deferred PAST Milestone 1 — not PII/server/env-excluded, just later scope.
# The analytics favorites (verified present: eventVisualizations x8, visualizations x3) carry very
# large, analytics-specific property sets. Comparator-ignored in M1 exactly like excluded types; a
# later milestone adds real handlers.
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
#                 matches by id (preserve-if-present); the seed is not on the M1 critical path.
#                 'code' as a seed relies on the NeoIPC convention that every object carries a code:
#                 DHIS2 itself makes code OPTIONAL (nullable `String code` in BaseIdentifiableObject)
#                 and enforces per-type uniqueness for most types EXCEPT options
#                 (Option.hbm.xml -> unique="false") — option codes repeat across option sets, so
#                 'options' uses the optionSet|code composite. Verified against refs/dhis2-core.
#   Nesting     - TopLevel | NestedOnly | BothPlaces (where the object lives in the package).
#   Properties  - ordered prop -> class. Classes: bool | int | string | id | idArray | idArrayOrdered |
#                 intArray | stringArray. 'idArrayOrdered' is for DHIS2 <list> ref-collections whose
#                 element order is the data and is NOT recoverable from an element-level sortOrder
#                 (categoryCombos.categories, categories.categoryOptions, optionGroupSets.optionGroups,
#                 programStageSections.dataElements/programIndicators, programSections.trackedEntityAttributes);
#                 it preserves array order in the cell, and the normalizer compares it positionally.
#                 Plain 'idArray' is for <set>s and for <list>s whose order is recoverable from each
#                 element's sortOrder (e.g. optionSets.options). The synthesized 'id' key, 'sharing'
#                 (carried as a normalized JSON cell),
#                 'translations' (JSON cell, comparator-ignored in M1), and the audit/noise fields
#                 (handled by Remove-NeoIPCMetadataNoise) are implicit and NOT listed here.
# Derived from the empirical per-type shapes in metadata.json, not from the prior art or the spec.
$script:NeoIPCMetadataTypeMaps = [ordered]@{
    'dataElements'          = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; formName = 'string'; description = 'string'; url = 'string'
        valueType = 'string'; domainType = 'string'; aggregationType = 'string'; zeroIsSignificant = 'bool'
        categoryCombo = 'id'; optionSet = 'id'; commentOptionSet = 'id'; aggregationLevels = 'intArray'; legendSets = 'idArray' } }
    'options'               = @{ NaturalKey = @('optionSet', 'code'); Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; sortOrder = 'int'; optionSet = 'id' } }
    'optionSets'            = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; valueType = 'string'; version = 'int'; options = 'idArray' } }
    'optionGroups'          = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; description = 'string'; optionSet = 'id'; options = 'idArray' } }
    'optionGroupSets'       = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; description = 'string'; dataDimension = 'bool'; optionSet = 'id'; optionGroups = 'idArrayOrdered' } }
    'dataElementGroups'     = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; dataElements = 'idArrayOrdered' } }
    'indicatorTypes'        = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = [ordered]@{
        name = 'string'; factor = 'int'; number = 'bool' } }
    'categories'            = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; dataDimensionType = 'string'; dataDimension = 'bool'; categoryOptions = 'idArrayOrdered' } }
    'categoryCombos'        = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; dataDimensionType = 'string'; skipTotal = 'bool'; categories = 'idArrayOrdered' } }
    'categoryOptions'       = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; organisationUnits = 'idArray' } }
    'trackedEntityAttributes' = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; formName = 'string'; description = 'string'; pattern = 'string'; fieldMask = 'string'
        valueType = 'string'; aggregationType = 'string'
        confidential = 'bool'; displayInListNoProgram = 'bool'; displayOnVisitSchedule = 'bool'; generated = 'bool'; inherit = 'bool'
        orgunitScope = 'bool'; skipSynchronization = 'bool'; unique = 'bool'
        optionSet = 'id'; legendSets = 'idArray' } }
    'programRuleVariables'  = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = [ordered]@{
        name = 'string'; programRuleVariableSourceType = 'string'; valueType = 'string'; useCodeForOptionSet = 'bool'
        program = 'id'; dataElement = 'id'; trackedEntityAttribute = 'id'; programStage = 'id' } }
    'programRules'          = @{ NaturalKey = 'name'; Nesting = 'TopLevel'; Properties = [ordered]@{
        name = 'string'; description = 'string'; condition = 'string'; priority = 'int'
        program = 'id'; programStage = 'id'; programRuleActions = 'idArray' } }
    'programRuleActions'    = @{ NaturalKey = 'id'; Nesting = 'BothPlaces'; Properties = [ordered]@{
        programRuleActionType = 'string'; content = 'string'; data = 'string'; location = 'string'; templateUid = 'string'
        programRule = 'id'; dataElement = 'id'; trackedEntityAttribute = 'id'; programStageSection = 'id'
        programStage = 'id'; programIndicator = 'id'; optionGroup = 'id'; option = 'id' } }
    'programStageSections'  = @{ NaturalKey = 'name'; Nesting = 'BothPlaces'
        Properties = [ordered]@{ name = 'string'; description = 'string'; sortOrder = 'int'; programStage = 'id'; dataElements = 'idArrayOrdered'; programIndicators = 'idArrayOrdered' }
        Nested = [ordered]@{ renderType = @{ Wrap = $true; Fields = [ordered]@{ DESKTOP = 'string'; MOBILE = 'string' } } } }
    'programSections'       = @{ NaturalKey = 'name'; Nesting = 'BothPlaces'
        Properties = [ordered]@{ name = 'string'; sortOrder = 'int'; program = 'id'; trackedEntityAttributes = 'idArrayOrdered' }
        Nested = [ordered]@{ renderType = @{ Wrap = $true; Fields = [ordered]@{ DESKTOP = 'string'; MOBILE = 'string' } } } }
    'validationRules'       = @{ NaturalKey = 'name'; Nesting = 'TopLevel'
        Properties = [ordered]@{ name = 'string'; operator = 'string'; periodType = 'string'; importance = 'string'; skipFormValidation = 'bool'; organisationUnitLevels = 'intArray' }
        Nested = [ordered]@{
            leftSide  = @{ Wrap = $false; Fields = [ordered]@{ expression = 'string'; missingValueStrategy = 'string'; slidingWindow = 'bool' } }
            rightSide = @{ Wrap = $false; Fields = [ordered]@{ expression = 'string'; missingValueStrategy = 'string'; slidingWindow = 'bool' } } } }
    'trackedEntityTypes'    = @{ NaturalKey = 'name'; Nesting = 'TopLevel'
        Properties = [ordered]@{ name = 'string'; description = 'string'; featureType = 'string'; allowAuditLog = 'bool'
            maxTeiCountToReturn = 'int'; minAttributesRequiredToSearch = 'int' }
        Nested = [ordered]@{ style = @{ Wrap = $false; Fields = [ordered]@{ icon = 'string' } } } }
    'programs'              = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; description = 'string'
        programType = 'string'; accessLevel = 'string'; enrollmentDateLabel = 'string'; incidentDateLabel = 'string'
        version = 'int'; expiryDays = 'int'; completeEventsExpiryDays = 'int'; maxTeiCountToReturn = 'int'
        minAttributesRequiredToSearch = 'int'; openDaysAfterCoEndDate = 'int'
        displayFrontPageList = 'bool'; displayIncidentDate = 'bool'; ignoreOverdueEvents = 'bool'; onlyEnrollOnce = 'bool'
        selectEnrollmentDatesInFuture = 'bool'; selectIncidentDatesInFuture = 'bool'; skipOffline = 'bool'; useFirstStageDuringRegistration = 'bool'
        categoryCombo = 'id'; trackedEntityType = 'id'
        organisationUnits = 'idArray'; programStages = 'idArray'; programSections = 'idArray'; notificationTemplates = 'idArray' } }
    'programStages'        = @{ NaturalKey = 'name'; Nesting = 'BothPlaces'; Properties = [ordered]@{
        name = 'string'; description = 'string'; executionDateLabel = 'string'; reportDateToUse = 'string'; validationStrategy = 'string'
        minDaysFromStart = 'int'; sortOrder = 'int'
        allowGenerateNextVisit = 'bool'; autoGenerateEvent = 'bool'; blockEntryForm = 'bool'; displayGenerateEventBox = 'bool'
        enableUserAssignment = 'bool'; generatedByEnrollmentDate = 'bool'; hideDueDate = 'bool'; openAfterEnrollment = 'bool'
        preGenerateUID = 'bool'; referral = 'bool'; remindCompleted = 'bool'; repeatable = 'bool'
        program = 'id'; programStageSections = 'idArray'; notificationTemplates = 'idArray' } }
    'programIndicators'    = @{ NaturalKey = { if ($_['code']) { $_['code'] } else { $_['name'] } }; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; description = 'string'; expression = 'string'; filter = 'string'
        aggregationType = 'string'; analyticsType = 'string'; decimals = 'int'; displayInForm = 'bool'; program = 'id' } }
    'attributes'           = @{ NaturalKey = 'code'; Nesting = 'TopLevel'; Properties = [ordered]@{
        code = 'string'; name = 'string'; shortName = 'string'; description = 'string'; valueType = 'string'
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
