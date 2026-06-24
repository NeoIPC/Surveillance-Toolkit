# NeoIPC metadata distribution packages

Importable DHIS2 metadata packages for the NeoIPC Core surveillance program, rendered from the canonical `metadata/`
directory by [`scripts/New-NeoIPCMetadataDistribution.ps1`](../../scripts/New-NeoIPCMetadataDistribution.ps1). They
let you install NeoIPC into a DHIS2 instance without running the conversion pipeline.

| File | Contents |
|------|----------|
| `NEOIPC_CORE_TRK_<version>_DHIS<dhis2>-en.json` | **Install base** — the program and all of its configuration dependencies (data elements, generated option sets, program rules and variables, tracked-entity type and attributes, analytics groups, user groups and roles). **No** org-unit hierarchy and **no** users. |
| `NEOIPC_CORE_TRK_<version>_DHIS<dhis2>-en.play.json` | **Play / demo** — the install base plus a synthetic overlay (one test hospital and department per country, and synthetic test users). For local and test instances only — **contains no real data**. |

## Generated — do not hand-edit

These files are build outputs. To change them, edit the `metadata/` directory (or the manifest values in
`scripts/New-NeoIPCMetadataDistribution.ps1`) and regenerate:

```pwsh
pwsh ./scripts/New-NeoIPCMetadataDistribution.ps1
```

They are committed **compressed** (single line) and tagged `linguist-generated`, so review the source directory and
the generator — not the rendered blob. Regeneration is deterministic (byte-identical for unchanged input).

## Alpha — pre-standards

These are **alpha** artifacts. They import as-is — DHIS2's metadata importer ignores the top-level `package`
manifest key it does not recognise — but they do **not** yet follow the WHO `dhis2-package-exporter` sharing and
manifest conventions. A standards-compliant package, together with the user-group / role / permission model it
depends on, will supersede them.

## Importing

Import into a target instance with `idScheme=UID` and a dry run first (via the DHIS2 **Import/Export** app, or a
metadata-import `POST` with `importMode=VALIDATE` then `COMMIT`). The install base assigns the program to no org
units — assign it to your hierarchy after import. The play package targets a fresh/empty instance.
