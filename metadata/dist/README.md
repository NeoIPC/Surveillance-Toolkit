# NeoIPC metadata distribution packages

Importable DHIS2 metadata packages for the NeoIPC Core surveillance program, rendered from the canonical `metadata/`
directory by [`scripts/New-NeoIPCMetadataDistribution.ps1`](../../scripts/New-NeoIPCMetadataDistribution.ps1). They
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

To render them locally (to inspect or import), pass an explicit version — the repository `VERSION` file holds the
current one (the generator has no default version):

```pwsh
pwsh ./scripts/New-NeoIPCMetadataDistribution.ps1 -Version (Get-Content ./VERSION -Raw).Trim()
```

This writes them into this directory (git-ignored). Regeneration is deterministic (byte-identical for unchanged
input). To change them, edit the `metadata/` directory (or the manifest values in the generator) — never a rendered
blob.

## Alpha — pre-standards

These are **alpha** artifacts. They import as-is — DHIS2's metadata importer ignores the top-level `package`
manifest key it does not recognise — but they do **not** yet follow the WHO `dhis2-package-exporter` sharing and
manifest conventions. A standards-compliant package, together with the user-group / role / permission model it
depends on, will supersede them.

## Importing

Import into a target instance with `idScheme=UID` and a dry run first (via the DHIS2 **Import/Export** app, or a
metadata-import `POST` with `importMode=VALIDATE` then `COMMIT`). The install base assigns the program to no org
units — assign it to your hierarchy after import. The play package targets a fresh/empty instance.
