# Deploying NeoIPC Metadata to DHIS2

`Deploy-NeoIPCMetadata` (NeoIPC-Tools) brings a DHIS2 instance to a NeoIPC metadata package, and it is the one
sanctioned way to do so, for a test instance and for production alike. It writes only what differs, keeps what
belongs to the instance, orders its requests the way DHIS2 needs, refuses hazardous changes unless they are
acknowledged, and then proves that the instance holds the package. This note records the DHIS2 behaviour each of
those rules answers to, the algorithm, and the procedure for a production deployment.

The behaviour described here was observed on DHIS2 2.40.12, 2.41.10, 2.42.6 and 2.43.1, the newest patch of each
line, and read in the DHIS2 source at those tags: the `dhis2/dhis2-core` repository for the server, and the
`v40` branch of `dhis2/tracker-capture-app` for the client. Paths below are relative to those repositories. A
cause is given only where the source settles it; everything else is stated as observed.

## 1. What a Plain Metadata Import Does

A `POST /api/metadata` with the default `importStrategy=CREATE_AND_UPDATE` replaces each object it is given by the
version in the payload: `mergeMode=REPLACE` is the default on 2.40, and from 2.41 the only behaviour
(`DefaultObjectBundleService.handleUpdates` sets it whatever the request asks). Applied to an instance that is
already in use, that has five consequences:

1. Whatever the payload leaves out is cleared: a program's organisation-unit assignment, every org-unit group's
   and user group's members, attribute values, and the translations the payload lacks. Each updated object whose
   payload carries no `created` is stamped as created now.
2. A child that a written parent no longer lists is deleted with the parent's write (a stage's sections and data
   elements, a rule's actions, a program's attributes), and an option set's write detaches the options it no
   longer lists. A program's stages and sections are not deleted that way: a program written without one only
   detaches it (section 2.6, item 5). A child that another parent written in the same request lists can move there
   or fail the request whole, depending on its kind and the DHIS2 line (section 2.11).
3. Some references to objects created in the same request are silently dropped (section 2.1).
4. From 2.42, the request fails whole when it updates a rule action that sends a notification (section 2.2).
5. Whether a program's or an option set's version moves depends on the version the payload carries (section 2.3),
   and clients reload a program's rules and an option set's options only when it does (sections 2.3 and 2.9).

`importMode=VALIDATE` reports none of the failures that happen while DHIS2 writes (section 2.7), so a dry run of a
plain import does not predict its outcome.

## 2. DHIS2 Behaviour the Deployment Answers To

### 2.1 Commit Order and Links Created in the Same Request

An import commits type by type, in the order of each type's schema `order` (the importer's
`DefaultObjectBundleService.getSortedClasses`, through `DefaultSchemaService.getMetadataSchemas`). The orders that
matter here are the same on all four lines:

| Type | Order | Type | Order |
| --- | --- | --- | --- |
| `users` | 101 | `programStageSections`, `programNotificationTemplates` | 1508 |
| `userGroups` | 102 | `programStages` | 1509 |
| `options` | 1040 | `programs` | 1520 |
| `optionSets` | 1050 | `programRuleActions` | 1610 |
| `optionGroups`, `optionGroupSets` | 1051 | `programRules` | 1620 |

When it connects an object's references, the preheat keeps only references to objects that already have a
database id (`DefaultPreheatService.connectReferences`: `if (ref != null && ref.getId() != 0)`, on all four lines).
An object created in the same request has none until its own type commits. Hence the rule, confirmed live for
every case the package contains:

1. A reference to an object of a type that commits **earlier** links.
2. A reference to an object of a type that commits **at the same time or later** is dropped, with status OK,
   unless the target lists the referrer under an owned property of its own: then the link is made from the
   target's side when it commits (a rule listing its actions, a stage listing its sections, a program listing its
   stages).
3. Within one type, objects commit in array order, so a reference to an object later in the array is dropped (a
   user group managing a group listed after it).
4. Import hooks link an org unit to its parent and a user to its org units, whatever the order.

Types that share an order commit in an order that can change from one start of the DHIS2 server to the next:
`getMetadataSchemas` sorts the values of a map keyed by class (`HashMap` up to 2.42.6, `ConcurrentHashMap` in
2.43.1) with a stable sort, so ties keep the map's iteration order, which follows the classes' identity hash codes.
`OptionGroup` and `OptionGroupSet` share order 1051 (their `SchemaDescriptor` classes). In one request that creates
both, a server that commits sets first links no group to any set; one that commits groups first links them all.
Up to 2.42.6 the map is filled once, when the server starts, so the draw holds until it restarts. On 2.43.1 the same
map also takes the schemas DHIS2 creates on demand for other classes (`getSchema` adds them with
`computeIfAbsent`), and a map that grows can change the order of two keys, so the draw can change while the server
runs.

A deployment therefore sends the references that rules 2 and 3 would drop in a second request, R2, once every
target exists. For the play package as a whole, which creates everything on a new instance, that is exactly
`optionGroupSets.optionGroups`: its managing user group comes after the groups it manages.

### 2.2 Rule Actions That Send a Notification

From 2.42, `ProgramRuleAction.setTemplateUid` no longer stores the UID: it builds a new, unsaved
`ProgramNotificationTemplate` holding only that UID (`dhis-api/.../programrule/ProgramRuleAction.java`, dhis2-core
commit `deb5cea36e`, DHIS2-17515; not in 2.41.10). Any request that updates an existing action carrying
`templateUid` fails whole with a `TransientPropertyValueException` naming `notificationTemplate`, and rolls back.
Creating such an action works when the template exists live or in the request; deleting it and creating it again
works; a rule written without the action objects in the payload keeps them. On 2.41 and earlier these actions
update like any other.

### 2.3 Versions

Programs and option sets carry a version (`VersionedObjectObjectBundleHook`, the same rules on all four lines):

1. On update, a payload version lower than the stored one is ignored, an equal one is stored plus one, and a
   higher one is stored as given (`preUpdate`).
2. Each option created in an existing set moves the set's version by one (`postCreate`). Options commit before
   their set (1040 before 1050), so a set written with its live version together with *n* new options ends at
   live + max(1, *n*).
3. An option updated alone leaves its set's version as it was (observed), and a program's version moves only when
   the program itself is written.

Tracker Capture reloads a program's metadata, its rules included, only when the program's version differs from
the one it cached, and an option set only when the set's version does (`core/tracker-capture.js`, the version
comparisons at lines 282, 512 and 563 on `v40`). A deployment that changes what clients load must move those
versions, and move the program's last.

### 2.4 Option Order

On 2.40.12 a set's options are a list indexed by the `sort_order` column, numbered from 1
(`OptionSet.hbm.xml`: `<list-index column="sort_order" base="1"/>`), the column `Option.sortOrder` also maps. From
2.41.10 they are an unindexed collection ordered by that column (`<bag ... order-by="sort_order">`; on 2.43.1
`@OrderBy("sortOrder ASC")` in `OptionSet.java`). Observed on all four lines:

1. A set's options are stored in the order of the set's `options` list, so the package must carry that list in
   the authored order. NeoIPC-Tools builds it from each option's authored `sortOrder`.
2. Writing a set with the same members in another order reorders them exactly.
3. From 2.41, writing a set renumbers its options' `sortOrder` to their list positions, while an option written
   alone keeps the `sortOrder` its body carries, which can tie with or pass its neighbours. On 2.40 an option
   written alone moves to the position its `sortOrder` names, and the list stays consistent.
4. DHIS2 runs an option's own `DELETE` as a metadata import with `importStrategy=DELETE`
   (`AbstractCrudController.deleteObject`), and 2.40.12 refuses it while the option's set lists it (409, "deleted
   object would be re-saved by cascade"). On an earlier 2.40 patch, such an import of an option that was not the last
   of its set left a gap in the set's index, after which every read of the set failed (HTTP 500). 2.40.12 reaches such
   a gap when an option's new set is written without its old set (section 2.11): a read of the old set's options then
   answered HTTP 200, with an empty entry in the gap. Whether fuller reads of the set fail is not established.
5. DHIS2 checks each option it is given against the other options of its set as the set is stored before the
   request, a member the same request drops included, and refuses one whose name or code another of them holds
   (`OptionObjectBundleHook.checkDuplicateOption`, E4028, comparing case-sensitively and passing over a member
   without a name or code, on all four lines). A request that passes a name or a code from one option to another,
   a swap included, therefore fails whole, in a validation too.

### 2.5 Option Group Sets

A group belongs to at most one set: the join table `optiongroupsetmembers` is unique on the group
(`OptionGroupSet.hbm.xml`: `<many-to-many ... column="optiongroupid" unique="true">`, all four lines). DHIS2
rewrites a set's list row by row, so:

1. A write that moves a group within a set (a swap, a reorder) fails whole on that unique key, and so can a
   removal, which moves the groups after it.
2. A group moved from one set to another in one request commits or fails depending on which set DHIS2 writes
   first, which the payload does not control: on 2.40.12 the outcome changed between runs on one server; on
   2.41.10 to 2.43.1 one direction committed and the reverse failed, whatever the array order.
3. Two requests always land exactly: the first writes the list empty, the second writes the new list.

### 2.6 Deletes

1. **Rules.** `ProgramRule.programRuleActions` deletes orphans (`ProgramRule.hbm.xml`:
   `cascade="all-delete-orphan"`, all four lines): a rule written without an action deletes the action, and a
   rule's `DELETE` deletes its actions. An action's own `DELETE` fails on 2.40.12 (409, "deleted object would be
   re-saved by cascade") and works from 2.41.10.
2. **Stage sections.** `ProgramStage.programStageSections` is `delete-orphan` on 2.40.12 and `all-delete-orphan`
   from 2.41.10 (`ProgramStage.hbm.xml`). From 2.41.10 a section's own `DELETE` answers 200 and deletes nothing;
   the stage written without the section deletes it on every line, leaving the other sections as they were.
3. **A section a rule action targets.** The stage's write deletes the sections it no longer lists through the
   deletion handlers (`ProgramStageObjectBundleHook.preUpdate`), and `ProgramRuleDeletionHandler` vetoes the
   delete of a section a rule action references. Stages commit before rules (1509 before 1620), so the request
   fails whole even when it also drops the action. 2.40.12, 2.42.6 and 2.43.1 report the veto; 2.41.10 reports a
   `TransientPropertyValueException` naming `ProgramStageDataElement.programStage` instead. Writing the rule
   without the action first, and the stage afterwards, works on every line.
4. **Notification templates.** A stage's and a program's `notificationTemplates` delete orphans
   (`cascade="all-delete-orphan"`), and a stage's `DELETE` takes its templates with it. Neither runs a deletion
   handler. Up to 2.41.10 an action holds its template's id in a plain column (`templateUid` in
   `ProgramRuleAction.hbm.xml`), so the template goes and the action keeps an id that points at nothing
   (`ProgramRuleActionDeletionHandler` guards only the template's own `DELETE`). From 2.42 the action refers to the
   template through a foreign key (migration `V2_42_7`), which refuses the delete, and the whole request fails.
5. **Program stages and program sections.** `Program.programStages` and `Program.programSections` carry no cascade
   (`Program.hbm.xml` up to 2.42.6, `Program.java` on 2.43.1), so a program written without one only detaches it.
   A stage's own `DELETE` deletes its sections with it (`ProgramStageSectionDeletionHandler`), and the deletion
   handlers veto the delete of a stage that a rule, a rule variable or a rule action refers to, directly or through
   one of the stage's sections (`ProgramRuleDeletionHandler`, `ProgramRuleVariableDeletionHandler`), and of a stage
   that any event refers to: the event deletion handler's query counts every row, a deleted event included until it
   is purged (`ProgramStageInstanceDeletionHandler` on 2.40.12, `EventDeletionHandler` on 2.41.10 and 2.42.6,
   `TrackerEventDeletionHandler` and `SingleEventDeletionHandler` on 2.43.1). A stage's `DELETE` also deletes the
   event visualizations built on it (`EventVisualizationDeletionHandler`, and `EventChartDeletionHandler` and
   `EventReportDeletionHandler`, whose classes map the same `eventvisualization` table) and clears the stage on the
   map views that use it (`MapViewDeletionHandler`). On 2.40.12 the three visualization handlers compare every
   visualization's stage without checking for none (2.41.10 checks), so a single visualization without a stage makes
   every stage's delete fail.
6. **Option groups.** A group's `members` cascade to the options (`OptionGroup.hbm.xml`: `cascade="all"`). From
   2.41.10 a group's `DELETE` deletes its member options with it; on 2.40.12 it fails while the group has members
   (409). On every line it fails while a group set lists the group (foreign key
   `fk_optiongroupsetmembers_optiongroupid`, which no deletion handler clears). Emptied through
   `PUT /api/optionGroups/{id}/options` with `{"identifiableObjects": []}` and out of every set, a group deletes alone
   and its options stay.
7. **Option sets.** A set's `DELETE` deletes its options. It fails while a data element uses the set
   (`DataElementDeletionHandler`) or while a tracked-entity attribute, an attribute, an option group or an option
   group set refers to it, and, since its options go by cascade, while an option group holds one of them or a rule
   action targets one (foreign keys).
8. A delete request for several types deletes them in creation order, so a dependent type can fail on a foreign
   key. One object per request avoids that.
9. **Programs.** Through the deletion handlers, a program's `DELETE` deletes its stages, rules, rule variables and
   indicators (`ProgramStageDeletionHandler`, `ProgramRuleDeletionHandler`, `ProgramRuleVariableDeletionHandler`,
   `ProgramIndicatorDeletionHandler`) and the relationship types, event reports, event charts and event
   visualizations built on it, while map views only lose their reference to it. Its enrollments and events veto it
   (`ProgramInstanceDeletionHandler` and `ProgramStageInstanceDeletionHandler` on 2.40.12, `EnrollmentDeletionHandler`
   and `EventDeletionHandler` on 2.41.10 and 2.42.6, `EnrollmentDeletionHandler`, `TrackerEventDeletionHandler` and
   `SingleEventDeletionHandler` on 2.43.1). A deployment therefore deletes no program.

An HTTP 200 does not prove a delete (item 2), so every delete is read back.

### 2.7 What a Dry Run Sees

In `importMode=VALIDATE`, `DefaultObjectBundleService.commit` returns before it writes anything ("skip if validate
only", all four lines). A validation therefore sees none of the failures that happen only while DHIS2 writes: the
unique key of section 2.5, the cascades and the vetoes of section 2.6, the template action of section 2.2.

### 2.8 The First Import on a Fresh Server

Observed on 2.40.12, 2.41.10 and 2.42.6, not on 2.43.1: on a freshly started server with an empty database, the
first metadata import aborts (409, on `ValidationRule.periodType`) unless the caches are cleared first
(`POST /api/maintenance?cacheClear=true`, which needs the `F_PERFORM_MAINTENANCE` authority).

### 2.9 Client Caches

Tracker Capture (`v40`) fetches the rules of each program whose version changed (`core/tracker-capture.js`, lines
615 to 621), writes them into its IndexedDB store with `db.setAll` (`d2-tracker/dhis2.tracker-metadata.js`,
line 133), which adds and replaces but never removes (the IndexedDB adapter's `setAll` only calls `put`,
`vendor/dhis/dhis2-storage-idb-e5bdf19229.js`), and runs every rule it holds for the program
(`MetaDataFactory.getByProgram("programRules", ...)`). Only clearing the app's cache removes a rule. A rule deleted
on the server therefore keeps running in every client that cached it, while a rule changed to do nothing reaches
clients like any other change, once the program's version moves.

### 2.10 What Reads Back Differently

1. Sharing reads back with an `owner`, the importing user, on every line, and `external: false` on 2.40.12; a
   user or user-group map the package leaves out reads back empty.
2. Translations read back as written.
3. Validation-rule sides gain `translations: null`, and org-unit opening and closing dates come back as
   timestamps.
4. The `name` and `valueType` of program and tracked-entity-type attributes are derived from the attribute, not
   stored, and a tracked-entity type's `shortName` is not stored before 2.42.

### 2.11 A Child Moved to Another Parent

A rule action can move from one rule to another, a stage section or a notification template from one stage to
another, and an option from one set to another, while both parents stay. Observed on all four lines, with the
child's own row and both parents' lists read back after every request:

| Child | One request that writes both parents, 2.40.12 | The same, 2.41.10 to 2.43.1 | The new parent written first, the old parent in a later request |
| --- | --- | --- | --- |
| Rule action | fails whole (409, "deleted object would be re-saved by cascade") | moves | moves |
| Stage section | moves | moves | moves |
| Notification template | fails whole (409, the same message) | moves | moves |
| Option, between two option sets | moves | moves | moves, but on 2.40.12 the old set reads with an empty entry until its own write |

Hibernate's message on 2.40.12 names the conflict: the old parent's write deletes the child as an orphan, and the new
parent's collection, which cascades its saves to the child (`cascade="all-delete-orphan"` on a rule's actions and a
stage's templates, on every line), reaches it again. A stage's sections on 2.40.12 are `delete-orphan` only. Why the
same mappings move the child from 2.41.10 is not traced. Between the two tags the importer's merge was renamed
(`DefaultMergeService` to `DefaultMetadataMergeService`) and gained two guards that leave a payload's collections
alone, and Hibernate, 5.6.15 on both, came to be started through JPA (`HibernateConfig`).

The later request reads the old parent's collection from the database: every metadata commit ends by evicting
Hibernate's second-level caches, collections included (`DefaultObjectBundleService.commit` through
`HibernateCacheManager.clearCache`, on all four lines). A rule's cached list of actions, which an action's own change
of `programRule` does not update, therefore does not reach the next request. The eviction runs inside the commit's
transaction, before it ends, and on the server that ran the request only, so a read of the old parent's collection in
between, or on another server of a cluster, could cache it as it was. A deployment therefore clears the caches again
before the later request; a cluster's other servers are not covered.

Writing the old parent still listing the child, and then without it, does not move a section: the old stage's write
takes the section back, and its next write deletes it.

A notification template's row holds its stage and its program in two columns of their own (`programstageid` for
`ProgramStage.notificationTemplates`, `programid` for `Program.notificationTemplates`), so a stage's write does not
take a template from a program, nor a program's from a stage, and the parent written without it then deletes it as an
orphan. The probe moved templates between two stages only.

## 3. The Algorithm

1. **Prepare.** Read the DHIS2 version, clear the caches (section 2.8; a dry run asks first), and lint the
   package's expressions (`Test-NeoIPCMetadataExpression`): an error finding aborts, warnings are reported.
2. **Read the live objects.** Every package object, by id, in batches, with its owned fields, translations and
   sharing, and the children that have no endpoint of their own expanded.
3. **Classify** each package object as new, changed or unchanged. Compared: the properties and nested fields the
   type maps describe, after the normalizations of section 2.10; the collections DHIS2 keeps in order (an option
   set's options, a group set's groups, a section's data elements) as sequences, all others as sets; the
   translations the package carries; and sharing, reduced to `public` and the user and user-group grants. A
   version and an option's `sortOrder` are never compared (sections 2.3 and 2.4).
4. **Build the bodies** of the new and changed objects. The package governs every property the type maps
   describe, so a property it leaves out is cleared. The properties that belong to the instance are copied from
   the live object: `organisationUnits`, `users`, `attributeValues`, `favorites`, `created` and `createdBy`. The
   package's translations govern; live translations the package lacks are kept, except those of a property whose
   value changes, which are dropped and reported. An option that is new or changed is written with its set
   (section 2.4).
5. **Versions.** A written option set carries its live version. An existing program is written once, in the last
   request, carrying its live version, whenever anything clients load with it changed: an object written, a link
   made in R2, a template action re-created, or an object deleted. It thereby moves exactly once, after everything
   else.
6. **Defer links** to objects created in this run that DHIS2 would drop (section 2.1) to R2.
7. **Stage the group sets and the moves** (sections 2.5 and 2.11). A set whose list changes other than by appending
   is written in R1 with its live list, emptied after R1, and given its final list in R2. A set that only appends
   groups belonging to no set is written directly; one that appends a group another set loses, or a group created in
   this run, gets its final list in R2. A rule action, stage section or notification template that the package lists
   under another rule or stage it carries is no orphan of its old parent: R1 writes it with its new parent, and the
   old parent is written in R2. An option the package gives to another set it carries moves in R1, written with both
   sets. A child or option taken from a parent the package does not carry, whether `-Delete` deletes that parent or it
   stays on the instance, is refused (section 4).
8. **Gate** the hazards (section 4), and check the references to what the deployment removes, and the events, event
   visualizations and map views of a stage it deletes (section 4.1), before anything is written.
9. **Commit**, in this order:
   1. the detach request: the rules written without the actions that refer to something a parent's write removes
      (an action the package drops, or one it points elsewhere, which R1 then creates again), and the rules made
      inert (section 2.6, items 3 and 4). A reference in such a rule to an object the run creates keeps its live
      value, since that object does not exist before R1, and R1 writes the rule again, or R2 when it gives an action
      to another rule, which it keeps listing until then;
   2. R1: every new and changed object but the parents a child moves away from, without its deferred links;
   3. the group sets emptied in step 7;
   4. R2: the deferred links, the staged lists, and the parents a child moved away from, after the caches are cleared
      once more when a child moves (section 2.11);
   5. from 2.42, each changed rule action that sends a notification, on its own (section 2.2): every reference
      checked, a snapshot taken, the action deleted and read back as gone, then created again with its rule and
      verified. Should the re-creation fail, the action is restored from the snapshot, after whatever the failed
      attempt left is deleted (writing over an action that carries a template is an update), and the deployment stops;
      the snapshot stays in the summary. Should only its check fail to read the result back, the deployment stops and
      leaves the action as DHIS2 accepted it, since a restore would delete and write again what most likely holds the
      package's version;
   6. the `-Delete` entries, one object per request, type by type, each type before the types it refers to through
      its own objects or what DHIS2 deletes with them (an attribute before the option set it uses, although
      attributes commit first), and otherwise in descending schema order. Each is read back together with what
      DHIS2 deletes with it (section 2.6): an option group, out of every set by then (a set the package keeps lets go
      of it in R2, a set in `-Delete` goes first) and emptied first, its former options read back as still present; a
      rule with its actions, which the gate lets through only when the rule is inert or `ActiveRuleDelete` is
      acknowledged (section 5); a program stage with its sections and notification templates, and a program section,
      which a program's write would only detach (section 2.6, item 5); an option set with its options. A child of an
      owning collection is never deleted through its own endpoint: its parent's write removes it (the detach request
      for an action of a rule it writes, R1 for any other child of a stage or a rule, R2 for one whose parent gives
      another child away, the programs' request for a program's), and a `-Delete` entry for it only acknowledges that;
   7. the programs (step 5).
10. **Verify.** The round trip against the bodies actually written, translations included
    (`Test-NeoIPCMetadataImport -Expected -CheckTranslations`); every object comparing unchanged once more; every
    declared rule action served, after a cache clear (`Test-NeoIPCProgramRuleActionServed`); the version of each
    written set and program; and every delete. Any discrepancy fails the deployment.

The deployment returns a summary: the plan per type, the objects it wrote and deleted, the children it moves, the
hazards, each step and its result, the versions, the properties kept from the instance and the package's values for
them, which it does not write, the dropped translations, the objects present on the instance but absent from the
package (apart from those it removes), and the snapshots of the notification actions it re-created. A package or
arguments it cannot carry out are refused before anything is written, whatever the caller's error preference; any
other failure, a failed read included, throws a terminating error (`NeoIPCDeploymentFailed`) whose target object is
that summary, with the plan from the moment the objects are classified.

A run that fails after it may have committed a change that clients load with a program, but before the program's
own request, leaves the program's version where it was, and a later run may find nothing left to write, so clients
would keep what they cached. A request counts as committed unless the answer shows it was not (an import with
status `ERROR`, which with `atomicMode=ALL` commits nothing, or an HTTP 4xx refusal, a proxy's included), since an
answer lost on the way, to a proxy's timeout or a dropped connection, can follow a commit. The failed run's summary
names those programs (`ProgramVersionPending`); once the cause is fixed, a run with `-BumpProgramVersion` writes
them, which moves their versions. Such a run that fails before the programs' request names them again.

A **dry run** (`-DryRun`) performs steps 1 to 8, sends one `VALIDATE` request with every object once, in its final
form, and lists the objects present only on the instance, also when the gate or the reference check stops it. It
writes nothing, and it cannot see the failures of section 2.7.

`-SyntheticInstance` is for a test instance only: every hazard is acknowledged, the package's memberships govern
for every type whose objects carry them, and users are deployed.

## 4. Hazards

The gate runs before the first write and stops the deployment unless each hazard kind found is acknowledged with
`-AllowHazard`:

| Kind | What it is | Why it is a hazard |
| --- | --- | --- |
| `OrphanDelete` | A child a written parent no longer lists, and that neither `-Delete` nor another parent of the package lists | DHIS2 deletes it with the parent's write (section 1, item 2) |
| `OptionSetMembership` | An option set that loses members, to no set or to another one, or gains one anywhere but at the end, or a set in `-Delete` | The values stored under the set's data elements keep the codes of the options it loses, and its write detaches those the package lists in no set; an insertion moves every later option in the list users pick from; deleting a set deletes its options |
| `OptionCodeChange` | An option whose code changes | Stored values hold the option's code, not its id |
| `OptionNameChange` | An option that keeps its code and changes its name | Stored values hold the code, so every value under it shows the new name; only a review tells a new spelling of the same thing from a new meaning |
| `SharingGrantRemoval` | A user or user-group grant present on the instance and absent from the package | Users lose access |
| `ActiveRuleDelete` | A rule in `-Delete` that is not inert on the instance | Clients keep running it (section 2.9) |

A single option in `-Delete` stops the deployment whatever is acknowledged (section 2.4, item 4): drop it from its
set's list instead, or delete the whole set. So does a program in `-Delete` (section 2.6, item 9); a stage or
program section that a program no longer lists and `-Delete` does not name, since the program's write would only
detach it (section 2.6, item 5); a stage in `-Delete` that has events, or that an event visualization or a map view
uses, and on 2.40 any event visualization without a stage while a stage is in `-Delete` (section 4.1); an object
the package carries that DHIS2 would delete with a `-Delete` entry (section 4.1); and an option whose name or code
another option of its set holds as the set is stored (section 2.4, item 5): a name or code passed from one option to
another, a swap included, takes two deployments, one that frees it and a later one that gives it. Of the children
the package moves to another parent (section 2.11), these stop it too, as not observed or not possible in two
requests: one that is no rule action, stage section or notification template; a notification template with a
program as either parent, since its row holds its program apart from its stage and programs are written last; a
child taken from a parent the package does not carry, whether `-Delete` deletes that parent or it stays on the
instance, and likewise an option taken from a set the package does not carry; a parent that both gives a child and
takes one, since it would have to be written both after and before a move; from 2.42, an action that sends a
notification, which is created again on its own after R2 instead of with its new rule in R1; and a child the package
lists under two parents.

A reorder of an option set's members is no hazard: it is how the order reaches the instance (section 2.4).

### 4.1 References to What the Deployment Removes

DHIS2 refuses to delete what something still refers to, and the whole request fails (section 2.6, items 3 to 7): a
stage section or stage that a rule, a rule variable or a rule action refers to; from 2.42, a notification template
that an action sends (up to 2.41 the template goes and the action keeps an id that points at nothing); an option set
that a data element, a tracked-entity attribute, an attribute, an option group or an option group set refers to; an
option group that a group set lists; and an option, which goes with its set, that an option group holds or a rule
action targets. Before anything is written, the deployment checks every object of those referring types, in the
package and on the instance, against what it removes: the children its writes drop, the `-Delete` entries, and what
DHIS2 deletes with them (a rule's actions, a stage's sections and notification templates, a set's options). A child
the package moves between two parents it keeps is not among them, since R1 moves it there before the old parent is
written; one the package carries that DHIS2 would delete with a `-Delete` entry stops the deployment.

1. A package object, new or kept, that refers to something removed stops the deployment.
2. On the instance, the objects as they are now decide, since DHIS2's checks read them:
   1. One that goes itself first is no obstacle: an action its rule drops, which the rule's write removes first
      (the detach request when what the action refers to goes with a parent's write, R1 otherwise), and a `-Delete`
      entry, with what goes with it, since the `-Delete` entries go type by type, each before the types it refers to
      (section 3, step 9.6). A rule in `-Delete` goes only after R2, so when what its action refers to goes with a
      parent's write, the deployment stops: make the rule inert in an earlier deployment (section 5).
   2. One the package points elsewhere is repointed when R1 writes it, in time for a removal after R1. One R1 does
      not write, as it compares unchanged, keeps its reference, and the deployment stops: an attribute's option
      set, for instance, which the package does not state. A removal with a parent's write, in R1 or, for a parent
      a child moves away from, in R2, which only an action can refer to (a section or a notification template its
      stage drops), comes first: the rule that holds the action on the instance writes it out once in the detach
      request, and R1 creates it again. That also covers a notification action, which from 2.42 is created again
      only after R2. When the package does not carry that rule, the deployment stops.
   3. One the package does not carry stops the deployment, naming it; for an action, the message names the rule
      that holds it, whose `-Delete` entry would take the action with it.

DHIS2 also refuses to delete a program stage that any event refers to, a deleted one included (section 2.6, item 5).
For each stage in `-Delete` the deployment reads one event, in every org unit (`ouMode=ALL` on 2.40,
`orgUnitMode=ALL` from 2.41, which needs the authority to search all org units), and a stage that has one stops the
deployment: the package must keep it. A stage's delete also deletes the event visualizations built on it and clears
the stage on the map views that use it, none of which is the package's, and on 2.40 it fails while any event
visualization has no stage (section 2.6, item 5). The deployment reads every event visualization and map view, and
stops when one uses a stage in `-Delete`, or, on 2.40, when an event visualization has no stage. One the deploying
user cannot see is not found.

Other refusals are not checked, such as that of a data element that events hold values for. A delete one of them
refuses stops the deployment after its writes, and the summary names the programs whose versions are pending
(section 3).

## 5. Retiring a Rule

A rule deleted on the server keeps running in Tracker Capture (section 2.9), so a rule is retired in two
deployments:

1. The package makes the rule inert: condition `false`, no actions. The deployment writes the rule first, which
   deletes its actions, and moves the program's version, so every client reloads the rule as inert.
2. A later deployment, once clients have synchronized, lists the rule in `-Delete`. A rule in `-Delete` that is not
   inert on the instance is an `ActiveRuleDelete` hazard, deleted only when that is acknowledged.

## 6. Deploying to Production

1. Take a verified backup of the database.
2. Rehearse on a restore of that backup, on the same DHIS2 version, with the same package and arguments.
3. Agree a maintenance window: between the first request and the last, data entry may see a partly deployed
   program.
4. Run `-DryRun`, review its plan, the children it moves, its hazards and its objects present only on the instance,
   decide on `-Delete` and `-AllowHazard`, then deploy. An `OptionNameChange` is acknowledged only once every option
   it lists is known to keep its meaning under the new name.
5. Check the result: the summary's verification, the forms in the data-entry app, and, where a deployment deleted
   a rule, that users clear Tracker Capture's cache. After a failed run, fix the cause and deploy again, with
   `-BumpProgramVersion` when its summary names programs under `ProgramVersionPending` (section 3).

```pwsh
$auth = Resolve-NeoIPCAuth
Deploy-NeoIPCMetadata -Path ./neoipc-metadata.json -Auth $auth -Hostname dhis2.example.org -DryRun
Deploy-NeoIPCMetadata -Path ./neoipc-metadata.json -Auth $auth -Hostname dhis2.example.org -Delete @{ optionGroups = 'id1' }
```

The host is mandatory and has no default, so a deployment always names its target.

## 7. Tests

`scripts/modules/NeoIPC-Tools/Tests/MetadataDeploy.Tests.ps1` exercises the planning functions and the whole
deployment against an in-memory stand-in for DHIS2. It applies the version rules; the orphan deletes of a rule's
actions, a stage's sections and a stage's or program's notification templates, unless another parent of the same
request lists the child, which then moves there; a parent's write taking the children it lists from their old
parent, a notification template only from a parent of the same type (section 2.11); the delete cascades (an option
group's member options as from 2.41.10); and the collection endpoint's replacement. It fails a request the way DHIS2
does: a reference, single or in a collection, to an object that does not exist (E5002), for the properties the tests
use, and an option whose name or code another option of its set holds as stored (E4028), in a validation too; while
it writes, on the unique key of section 2.5 (in either order of the sets), on 2.40.12 on a request that writes both
parents of a moved rule action or notification template (section 2.11), on an update of a template action from 2.42
(section 2.2), on a stage's write that drops a section a live action targets (section 2.6, item 3), and from 2.42 on
a stage's or program's write that drops a template a live action sends (section 2.6, item 4); and on the delete
vetoes and foreign keys of section 2.6 for stages (events included), option sets and option groups. Like DHIS2, it
refuses a rule action's own `DELETE` on 2.40.12 and keeps a stage section on its own `DELETE` from 2.41.10
(section 2.6, items 1 and 2). One test assembles the real play package and pins the references deferred to R2
(section 2.1).
