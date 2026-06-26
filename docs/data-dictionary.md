# NeoIPC Core data dictionary

A technology-agnostic **data dictionary** for the NeoIPC Core surveillance program — a spreadsheet that sits
between the machine-readable DHIS2 metadata and the end-user protocol. It documents everything collected
(patient attributes, per-event data elements, the event dates, and every code list in full, including the
pathogen and antimicrobial lists) in language meant for both epidemiologists and technical implementers.

It is a **generated release artifact**, distributed alongside the protocol and metadata releases — **not**
committed to source. Generate it on demand (below); CI also produces a fresh copy with every build.

## Sheets

| Sheet | Contents |
|-------|----------|
| About | Cover sheet: program identity, counts, provenance |
| Variables | One row per collected item — patient attributes, per-event data elements, and the event dates |
| Code lists | One row per (code list, value) — every option set in full |
| Forms & dates | One row per module/form and its event date |

Four CSVs (one per sheet, UTF-8 with BOM, LF) plus a multi-tab `.xlsx`. The CSVs are dependency-free; the
`.xlsx` is the polished workbook. For long code lists, the *Variables* sheet's "Allowed values" cell points to
the *Code lists* sheet in the same workbook — nothing is omitted.

## Generate

```sh
# CSV + .xlsx (default), written to artifacts/data-dictionary/. The .xlsx needs DocumentFormat.OpenXml (below).
./scripts/New-NeoIPCDataDictionary.ps1

# CSV only (no extra dependency):
./scripts/New-NeoIPCDataDictionary.ps1 -Format Csv
```

The `.xlsx` writer uses the MIT-licensed [DocumentFormat.OpenXml](https://github.com/dotnet/Open-XML-SDK) SDK,
restored with `dotnet` (the .NET 10 SDK). Provision it once:

```sh
# In the assembled workspace:
./scripts/Invoke-Workspace.ps1 -InstallDeps

# Standalone Surveillance-Toolkit checkout:
dotnet publish scripts/modules/NeoIPC-Tools/lib -o scripts/modules/NeoIPC-Tools/lib/bin
```

CI (`.github/workflows/build.yml`) generates the data dictionary into the uploaded build artifact on every build.

## How it is built

`Export-NeoIPCDataDictionary` (in the `NeoIPC-Tools` module) flattens the assembled metadata package
(`New-NeoIPCMetadataPackage`, export-free, no DHIS2 API) into the four sheets. DHIS2 UIDs are deliberately
omitted (technology-specific); the project's variable **code** is the stable, platform-neutral identifier.
