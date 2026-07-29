# NeoIPC Surveillance Toolkit

[![Build](https://github.com/NeoIPC/Surveillance-Toolkit/actions/workflows/build.yml/badge.svg)](https://github.com/NeoIPC/Surveillance-Toolkit/actions/workflows/build.yml)
[![Translation status](https://hosted.weblate.org/widgets/neoipc/-/svg-badge.svg)](https://hosted.weblate.org/engage/neoipc/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Everything a neonatal department needs in order to take part in NeoIPC surveillance, and everything
the project needs in order to analyse what they collect: the surveillance protocol and its case
definitions, the DHIS2 configuration that gathers the data, the reference lists of infectious agents
and antimicrobial substances, and the reports that give each participating department its results.

[NeoIPC](https://neoipc.org) works to reduce the transmission of resistant bacteria in neonatal
intensive care across Europe and globally. Its
[surveillance system](https://neoipc.org/surveillance/) collects healthcare-associated infection and
antimicrobial-use data from neonatal departments so that a department can compare itself against the
network. This repository is the **normative source** for that surveillance: when a case definition
changes here, the change propagates to the data-collection forms, the analysis code and the reports.
Where code and the definitions in this repository disagree, the definitions win.

## What's in here

| Path | Contents |
|------|----------|
| [`doc/protocol/`](doc/protocol/) | The **NeoIPC Core Surveillance Protocol** in AsciiDoc, including the eight normative case definitions under [`definitions/`](doc/protocol/definitions/) — clinical sepsis, the two laboratory-confirmed bloodstream-infection variants, the three surgical-site-infection depths, necrotising enterocolitis and pneumonia. |
| [`metadata/`](metadata/) | The **canonical DHIS2 configuration** for the `NEOIPC_CORE` tracker program — data elements, option sets, program rules, tracked-entity attributes and the organisation-unit scaffold — authored as reviewable per-type CSVs plus externalised expression files rather than one opaque JSON blob. See [`metadata/common/README.md`](metadata/common/README.md). |
| [`metadata/common/infectious-agents/`](metadata/common/infectious-agents/) | The **NeoIPC Infectious Agent List** — a pragmatic ontology of organisms with their synonyms and phenotypic resistance categories, named from LPSN, MycoBank and ICTV. Licensed separately; see below. |
| [`metadata/common/antibiotics/`](metadata/common/antibiotics/) | The **NeoIPC Antibiotics List** — substances, groups and WHO AWaRe categories. Licensed separately; see below. |
| [`reports/`](reports/) | Five **Quarto reports**, drawing their data from the [neoipcr](https://github.com/NeoIPC/neoipcr) R package: the Partner Report a department receives, the network-wide Reference Report, a Validation Report that flags data-quality problems, a Partner Certificate, and a Patient Data Report answering data-subject access requests. |
| [`po/`](po/) | The **gettext catalogues** behind every localized artifact, managed with [po4a](https://po4a.org/) and translated on Weblate. |
| [`glossary.yaml`](glossary.yaml) | The controlled vocabulary the reports and translators share, so one concept reads the same way everywhere. |
| [`scripts/`](scripts/) | PowerShell entry points — `Build-*.ps1` render an artifact, `Test-*.ps1` check an invariant, `Invoke-Localization.ps1` drives the translation pipeline. Shared logic lives in the [`NeoIPC-Tools`](scripts/modules/NeoIPC-Tools/README.md) module. |
| [`docs/`](docs/) | Design references for the pieces whose reasoning does not fit in a source comment — the metadata pipeline, the infectious-agent ontology, the Weblate component contract. |

## Products and releases

The repository publishes **five independently versioned products** from one shared history, each with
its own version file, tag stream and releases:

| Product | Tag prefix |
|---------|-----------|
| NeoIPC Core Surveillance Protocol | `protocol-v*` |
| NeoIPC DHIS2 Metadata Package | `metadata-v*` |
| NeoIPC Surveillance Reports | `reports-v*` |
| NeoIPC Infectious Agent List | `infectious-agents-v*` |
| NeoIPC Antibiotics List | `antibiotics-v*` |

The infectious-agent and antibiotics lists are shared inputs: the protocol compiles them and the
metadata package embeds them as option sets, so both declare the exact list release they incorporate
and CI refuses a release that would ship unreleased list content. [`RELEASING.md`](RELEASING.md) has
the full mechanics.

To install NeoIPC into a DHIS2 instance you want the **metadata package** — an importable JSON
release asset, with a synthetic play variant for test instances. It is a generated artifact and is
deliberately not committed; [`metadata/dist/README.md`](metadata/dist/README.md) explains where to
get it and how to import it.

**That package is alpha — expect to adapt it rather than deploy it.** It is version `0.0.1-alpha`.
It does not yet follow the WHO `dhis2-package-exporter` sharing and manifest conventions: it imports
because DHIS2 ignores the manifest key it does not recognise, not because it conforms. It also
attaches the program to no organisation units, so the hierarchy is yours to build and connect.

It has been verified against DHIS2 **2.40.12** and **2.41.9** only — earlier 2.40 patches are not
supported, `2.40.3.2` in particular carrying a confirmed defect that was fixed in `2.40.4`. On
**2.42 and 2.43** an import
intermittently drops the members of owned ordered collections — an option-group set arrives holding
none of its groups — and reports no error while doing so. The failure is non-deterministic but sticks
to an instance: it recurs identically there, while a freshly created instance may take the same
package cleanly. The cause is open and there is no workaround short of rebuilding the instance, so on
those versions **verify what actually landed instead of trusting a successful-looking import**. The
running NeoIPC deployment is unaffected — it is on 2.41 or older.

## Working with the toolkit

The tooling is PowerShell 7.6 or newer plus, depending on what you are building, R and Quarto (reports),
Asciidoctor PDF and Pandoc (protocol), or po4a (translations). Every script carries comment-based
help, so `Get-Help ./scripts/Build-PartnerReport.ps1 -Full` is the reference for its arguments.

```powershell
git clone --recurse-submodules https://github.com/NeoIPC/Surveillance-Toolkit.git
cd Surveillance-Toolkit
```

The `--recurse-submodules` matters only for translation work: [`tools/po4a`](tools/po4a) is a
submodule, and the localization pipeline needs it.

[`doc/README.md`](doc/README.md) lists the prerequisites for building the protocol documents and how
to install them on Windows and Ubuntu. On Windows, po4a runs under the Windows Subsystem for Linux —
it does not run natively.

## Part of the NeoIPC surveillance system

| Repository | Role |
|------------|------|
| **Surveillance-Toolkit** | *(this repository)* The protocol, the case definitions, the DHIS2 metadata and the report sources |
| [neoipcr](https://github.com/NeoIPC/neoipcr) | R package that reads NeoIPC data out of DHIS2 and computes the surveillance indicators |
| [NeoIPC-Reporting](https://github.com/NeoIPC/NeoIPC-Reporting) | Service that renders this repository's reports on demand and serves them over HTTP |
| [neoipc-app](https://github.com/NeoIPC/neoipc-app) | DHIS2 application through which people request reports and administer reference data |

Surveillance data itself is collected in a DHIS2 instance configured from the metadata package above.
The deployment configuration for the NeoIPC network's own instances is maintained privately and
contains no part of the definitions — those are all here.

## Contributing

Contributions are welcome. Much of this repository is incomplete or thin on documentation, because
the tools and the partner network are being built at the same time; issues and pull requests that
sharpen either are useful.

Two things are worth knowing before you start. Case definitions are normative — a pull request that
changes one is a scientific change, not an editorial one, so raise an issue first. And the reports'
translated text lives in gettext catalogues, not in the source files: change the English string and
regenerate, never hand-edit a generated localized file.

**Translations.** The protocol, the report text, the infectious-agent names and the DHIS2 metadata
are translated on [Weblate](https://hosted.weblate.org/projects/neoipc/), who support this project's
translation effort with their software, expertise and free hosting. Contributions in any language are
welcome, and no git knowledge is needed — translating in the web interface is enough. Feedback on a
translation belongs in Weblate's per-string comments, where the person who wrote it will see it,
rather than on a pull request.

## Licensing

Except where noted below, this repository is licensed under the [MIT License](LICENSE).

Two data directories compile content from upstream sources whose terms are stricter than MIT. The effective license of each is dictated by what its sources permit — not a restriction NeoIPC chose to impose — and each carries its own `LICENSE.md` with the reasoning and full attribution:

| Directory | Effective license | Upstream sources |
|-----------|-------------------|------------------|
| [`metadata/common/infectious-agents/`](metadata/common/infectious-agents/LICENSE.md) | CC BY-NC-ND 4.0 (plus CDC agency-material terms) | NHSN, LPSN, MycoBank, ICTV |
| [`metadata/common/antibiotics/`](metadata/common/antibiotics/LICENSE.md) | CC BY-NC-SA 3.0 IGO | WHO AWaRe classification / ATC/DDD index |

The two directories land on different Creative Commons terms because their upstream licences differ. The infectious-agent list is **no-derivatives** — its MycoBank source is CC BY-NC-ND, incorporated with permission. The antibiotic list is a **derivative** of the WHO AWaRe classification (CC BY-NC-SA 3.0 IGO); ShareAlike requires a derivative to keep the same licence, so it is CC BY-NC-SA 3.0 IGO (the ATC codes, substance names and group descriptions it also carries are reproduced unchanged from the WHOCC ATC/DDD index, not adapted). We apply the licence the upstream terms require, no stricter.

The gettext translation catalogues under [`po/`](po/) declare their licence in their own headers. Two of them are mid-correction and currently disagree with their templates: the translated `reports` and `infectious_agents` catalogues still carry MIT and CC BY-NC-ND 4.0 respectively, while both `.pot` templates declare CC BY 4.0. The templates carry the intended terms — a catalogue of extracted strings is not automatically bound by the licence of the directory it was extracted from, and a no-derivatives term cannot govern a translation, which *is* a derivative work. The translated files are written by the translation platform rather than by this repository, so that correction is applied there and not here.

## Funding

The NeoIPC project has received funding from the European Union's Horizon 2020 research and
innovation programme under grant agreement No 965328.
