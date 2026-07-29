# NeoIPC metadata distribution packages

Importable DHIS2 metadata packages for the NeoIPC Core surveillance program, rendered from the canonical `metadata/`
directory by [`scripts/Build-NeoIPCMetadataDistribution.ps1`](../../scripts/Build-NeoIPCMetadataDistribution.ps1). They
let you install NeoIPC into a DHIS2 instance without running the conversion pipeline.

| Package | Contents |
|---------|----------|
| `NEOIPC_CORE_TRK_<version>_DHIS<dhis2>-en.json` | **Install base** — the program and all of its configuration dependencies (data elements, generated option sets, program rules and variables, tracked-entity type and attributes, analytics groups, user groups and roles). **No** org-unit hierarchy and **no** users. |
| `NEOIPC_CORE_TRK_<version>_DHIS<dhis2>-en.play.json` | **Play / demo** — the install base plus a synthetic overlay (one test hospital and department per country, and synthetic test users). For local and test instances only — **contains no real data**. |

## Where to get them — not committed

These are **generated build artifacts**, not committed to the repository: a compressed single-line JSON blob is
undiffable and bloats the tree, and a committed copy silently goes stale (and once shipped a broken package). They
are produced from source on every CI build and published two ways:

- **Build artifact** — inside the `NeoIPC-Surveillance-Toolkit` artifact of the `Build` workflow (every push / PR;
  retained for that run).
- **Release asset** — attached to a **GitHub Release** when a maintainer **manually** publishes one. Releasing the
  product and choosing its version is a deliberate human step, and the release is marked **pre-release (alpha)**; CI
  only attaches the rendered packages to it.

To render them locally (to inspect or import), pass an explicit version — the `metadata/VERSION` file holds the
current one (the generator has no default version):

```pwsh
pwsh ./scripts/Build-NeoIPCMetadataDistribution.ps1 -Version (Get-Content ./metadata/VERSION -Raw).Trim()
```

This writes them into this directory (git-ignored). Regeneration is deterministic (byte-identical for unchanged
input). To change them, edit the `metadata/` directory (or the manifest values in the generator) — never a rendered
blob.

## Alpha — pre-standards

These are **alpha** artifacts. They import as-is — DHIS2's metadata importer ignores the top-level `package`
manifest key it does not recognise — but they do **not** yet follow the WHO `dhis2-package-exporter` sharing and
manifest conventions. A standards-compliant package, together with the user-group / role / permission model it
depends on, will supersede them.

## Supported DHIS2 versions — 2.40 and 2.41

The packages are generated for, and verified against, **2.40.12.0** and **2.41.9.0**; the manifest declares
`2.40.12.0`. On those two the two-pass import described below connects reliably, every time.

Earlier 2.40 patches are **not** supported: `2.40.3.2` carries a confirmed defect, fixed in `2.40.4`, and nothing
between `2.40.4` and `2.40.12.0` is currently exercised — so the declared version names a currently-verified
release rather than the lowest that might work.

**On 2.42 and 2.43 the import is not reliable.** There, a metadata import intermittently drops the members of
owned ordered collections: an `optionGroupSet` declaring 34 `optionGroups` arrives holding 0, and the import
summary reports nothing wrong. The behaviour is non-deterministic *across* instances but **sticky within one** —
a given instance reproduces the same outcome on every retry, so re-importing never clears it and only a freshly
created instance gives a different draw. The evidence points inside DHIS2's own import path rather than at
anything the package can encode around: the database itself ends up wrong on a bad draw, and the server caches
have been ruled out empirically. The root cause is not pinned.

The practical consequence on 2.42+ is that a successful-looking import is not evidence of a correct one. **Read
the option-group sets back and check their member counts** before treating the instance as provisioned. The
NeoIPC deployment runs 2.41 or older and is unaffected.

## Importing

Import into a target instance with `idScheme=UID` and a dry run first (via the DHIS2 **Import/Export** app, or a
metadata-import `POST` with `importMode=VALIDATE` then `COMMIT`). The install base assigns the program to no org
units — assign it to your hierarchy after import. The play package targets a fresh/empty instance.

**Apply the package twice.** This is not optional and not a retry: DHIS2 does not link an object's *owned*
reference collections to objects created in the **same** payload, so a single import leaves
`optionGroupSet.optionGroups`, `programRule.programRuleActions` and `userGroup.managedGroups` members-less —
**while reporting `status=OK`**. The second, identical import runs when every referenced object already exists,
and connects them. (Nested collections such as `optionGroup.options` link on the first pass; it is specific to
those three.) Skip it and you get an instance whose AWaRe and ATC option-group sets are empty and whose program
rules carry no actions, with nothing in either import summary to say so.

The toolkit's own importer does this for you — `Import-NeoIPCMetadataPackage -ConnectReferences` — and
`Test-NeoIPCMetadataImport` is the authoritative check that the collections actually linked. A second `status=OK`
is **not** that proof; on 2.42+ the second pass reports OK and still drops them (above).

After importing, verify rather than assume: read the option-group sets back and check their member counts. That
advice is essential on 2.42+, where the drop is silent and sticky, and cheap everywhere else.
