# NeoIPC Metadata Distribution Packages

DHIS2 metadata packages for the NeoIPC Core surveillance program, rendered from the canonical `metadata/` directory
by [`scripts/Build-NeoIPCMetadataDistribution.ps1`](../../scripts/Build-NeoIPCMetadataDistribution.ps1). They let
you install NeoIPC into a DHIS2 instance without running the conversion pipeline.

| Package | Contents |
| --- | --- |
| `NEOIPC_CORE_TRK_<version>_DHIS<dhis2>-en.json` | **Install base** — the program and all of its configuration dependencies (data elements, generated option sets, program rules and variables, tracked-entity type and attributes, analytics groups, user groups and roles). **No** org-unit hierarchy and **no** users. |
| `NEOIPC_CORE_TRK_<version>_DHIS<dhis2>-en.play.json` | **Play / demo** — the install base plus a synthetic overlay (one test hospital and department per country, and synthetic test users). For local and test instances only — **contains no real data**. |

## Where to Get Them: Not Committed

These are **generated build artifacts**, not committed to the repository: a compressed single-line JSON blob is
undiffable and bloats the tree, and a committed copy silently goes stale (and once shipped a broken package). They
are produced from source on every CI build and published two ways:

- **Build artifact** — inside the `NeoIPC-Surveillance-Toolkit-metadata` artifact of the `Build` workflow, together
  with the data dictionary (every push / PR; retained for that run).
- **Release asset** — attached to a **GitHub Release** when a maintainer **manually** publishes one. Releasing the
  product and choosing its version is a deliberate human step, and the release is marked **pre-release (alpha)**; CI
  only attaches the rendered packages to it, and ends its notes with how to deploy them
  ([`metadata/RELEASE-NOTICE.md`](../RELEASE-NOTICE.md)).

To render them locally (to inspect or deploy), pass an explicit version — the `metadata/VERSION` file holds the
current one (the generator has no default version):

```pwsh
pwsh ./scripts/Build-NeoIPCMetadataDistribution.ps1 -Version (Get-Content ./metadata/VERSION -Raw).Trim()
```

This writes them into this directory (git-ignored). Regeneration is deterministic (byte-identical for unchanged
input). To change them, edit the `metadata/` directory (or the manifest values in the generator) — never a rendered
blob.

## Alpha Status

These are **alpha** artifacts. They carry a top-level `package` manifest key, which DHIS2's metadata importer
ignores and the deployment leaves out; its `deployment` entry, a NeoIPC addition, says how to deploy the package and
why a plain metadata import is no substitute. They do **not** yet follow the WHO `dhis2-package-exporter` sharing and
manifest conventions. A standards-compliant package, together with the user-group / role / permission model it
depends on, will supersede them.

## Supported DHIS2 Versions

The packages are verified with `Deploy-NeoIPCMetadata` (below) on DHIS2 **2.40.12**, **2.41.10**, **2.42.6** and
**2.43.1**, the newest patch of each line; the manifest declares `2.40.12.0`. On an earlier patch of those lines, or
on another line, the deployment stops before writing anything unless `-AllowHazard UnverifiedVersion` accepts the
release.

Earlier 2.40 patches are **not** supported: `2.40.3.2` carries a confirmed defect, fixed in `2.40.4`, and nothing
between `2.40.4` and `2.40.12` is exercised — so the declared version names a release the packages are tested on
rather than the lowest that might work.

## Deploying a Package

Deploy a package with NeoIPC-Tools' `Deploy-NeoIPCMetadata`, a dry run first:

```pwsh
Import-Module ./scripts/modules/NeoIPC-Tools
$auth = Resolve-NeoIPCAuth
Deploy-NeoIPCMetadata -Path <package>.json -Auth $auth -Hostname dhis2.example.org -DryRun
Deploy-NeoIPCMetadata -Path <package>.json -Auth $auth -Hostname dhis2.example.org
```

It writes only what differs from the instance, keeps what belongs to the instance (memberships, attribute values,
translations the package lacks), sends its requests in the order DHIS2 needs, stops before writing anything when it
finds a hazardous change it was not told to accept, and verifies the result. The host has no default, so a
deployment always names its target. The play package carries synthetic users; deploy it with `-SyntheticInstance`,
and only to a test instance.

A plain import, through the **Import/Export** app or a `POST` to `/api/metadata`, is no substitute:

- in one request, DHIS2 links an option group set to its groups or leaves it empty, depending on an order drawn
  when the server starts (which DHIS2 2.43 can also change while it runs), and reports success either way;
- repeated over an existing instance, it fails whole from DHIS2 2.42 on the program-rule actions that send
  notifications;
- on an instance in use, it clears what the package does not carry, such as the program's organisation units and
  the members of every org-unit group and user group.

[`docs/metadata-deployment.md`](../../docs/metadata-deployment.md) describes that behaviour, how the deployment
answers it, and the procedure for a production deployment. The install base assigns the program to no organisation
units: assign it to your hierarchy after the deployment.
