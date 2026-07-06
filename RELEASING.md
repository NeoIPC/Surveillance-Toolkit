# Releasing

This repository publishes **five independently-versioned products** from one shared history. Each
has its own version file, its own tag stream, and its own GitHub Release stream:

| Product | Tag prefix | Version file (source of truth) | Release assets |
|---------|-----------|--------------------------------|----------------|
| NeoIPC Core Surveillance Protocol | `protocol-v*` | `doc/protocol/VERSION` | `NeoIPC-Core-Protocol*.pdf`, `*.docx`, `compatibility.yml` |
| NeoIPC DHIS2 Metadata Package | `metadata-v*` | `metadata/VERSION` | `metadata-package/*.json`, data-dictionary CSV/XLSX, `compatibility.yml` |
| NeoIPC Surveillance Reports | `reports-v*` | `reports/VERSION` | `compatibility.yml` (render-ready sources ship in the tag's source archive) |
| NeoIPC Infectious Agent List | `infectious-agents-v*` | `metadata/common/infectious-agents/VERSION` | `NeoIPC-Infectious-Agents-<ver>.tar.gz` (canonical YAML + po4a-localized YAMLs + UID map) |
| NeoIPC Antibiotics List | `antibiotics-v*` | `metadata/common/antibiotics/VERSION` | `NeoIPC-Antibiotics-<ver>.tar.gz` (substance/group/AWaRe/list-element CSVs + gettext translation catalogue) |

A release tag is `<product>-vMAJOR.MINOR.PATCH[-prerelease]`, where `-prerelease` is a standard semver
pre-release identifier (dot-separated alphanumerics), e.g. `reports-v0.0.1-alpha`, `protocol-v1.3.0-preview1`,
`metadata-v1.2.0`, `infectious-agents-v1.0.0-rc.1`. Because the products are independent you can cut a
release for any one without touching the others — subject to the incorporation rule below.

## Shared inputs and the incorporation rule

The **infectious agent list** and the **antibiotics list** are shared inputs: the **protocol** compiles
them into its documents and the **metadata package** embeds them as option sets. Both are their own
products, so protocol and metadata **incorporate a specific released version** of each, declared in:

- `doc/protocol/compatibility.yml` (`incorporates.infectious-agents`, `incorporates.antibiotics`)
- `metadata/compatibility.yml` (same keys)

At every `protocol-v*` / `metadata-v*` release, CI enforces for each declared list that **(1)** the
`<list>-v<version>` release tag exists and **(2)** the list's committed source at the release commit is
**byte-identical** to what that release shipped (`git diff` against the tag). If a list changed since
its release, the product release **fails** — you must bump the list, release it, and update the
`compatibility.yml` first. This makes it impossible to ship a protocol/metadata release that
incorporates unreleased list content.

The content check tracks the committed source each list's consumers actually read. For the infectious
agent list that is the canonical `NeoIPC-Infectious-Agents.yaml` + its UID map **and** the legacy
pathogen CSVs the protocol still compiles (`NeoIPC-Owned-Pathogen-Concepts.csv`,
`NeoIPC-Pathogen-Concepts.csv`, `NeoIPC-Pathogen-Synonyms.csv`, `ListElements.csv`) — a transitional
union until the CSV→YAML migration moves the protocol onto the YAML. For the antibiotics list it is the
antibiotics/groups/AWaRe/list-element CSVs. **Translations are out of scope** — `.po` files churn via
Weblate, and requiring a list re-release for every translation update before any protocol/metadata
release would be too strict.

**Consequence — release order.** The very first protocol/metadata release requires the two lists to be
released first (there is no `<list>-v0.0.1-alpha` tag until you cut it). Order: **release the lists →
then protocol/metadata**.

## Reports compatibility (neoipcr / neoipc-app)

The reports are rendered by the `neoipcr` R package and drive the `neoipc-app` frontend's report
forms, so a reports release records the neoipcr + neoipc-app versions it was validated against in
`reports/compatibility.yml`. Those are **separate repositories**, so there is no in-repo content to
diff (unlike the lists above) — instead, at every `reports-v*` release CI verifies that each
`tested` version resolves to a **real tag** on its repo (`git ls-remote` against
`github.com/NeoIPC/neoipcr`, `github.com/NeoIPC/neoipc-app`): a published GitHub Release **or** an
immutable dev-snapshot tag (e.g. neoipcr's `v0.0.0.9000`, which is a pushed tag, not a formal Release).
The check is tag-existence. So a reports release can never claim compatibility with an unreleased
neoipcr/neoipc-app. Order: **release neoipcr + neoipc-app → then the reports** (and update
`reports/compatibility.yml` to the versions you validated against).

## How a release works

1. **Bump the product's version file** on `main` (via a PR): edit the relevant `VERSION` file to the
   version you intend to release. For a reports release, also update `reports/compatibility.yml` (the
   neoipcr / neoipc-app versions the reports were validated against). For a protocol/metadata release,
   make sure `compatibility.yml`'s incorporated list versions point at current list releases.
2. **Push the release tag** `<product>-v<that-version>`. That single push triggers the release — there
   is no separate "publish a Release" step; CI creates the GitHub Release itself.
3. CI (`.github/workflows/build.yml`) then, on the `<product>-v*` tag push:
   - validates the tag shape and that its version equals the released product's `VERSION` file;
   - rejects a moved / retagged tag and enforces the monotonic-version guard;
   - for a protocol/metadata release, runs the incorporation check above;
   - builds **only** that product;
   - creates the GitHub Release (generated notes; flagged **pre-release** automatically when the version
     carries a semver pre-release suffix) and attaches that product's assets.

The next version is **not** bumped automatically — bump the product's `VERSION` deliberately in the PR
that prepares the next release (step 1). Continuous CI (push / PR / manual dispatch) builds the protocol
and metadata products for validation but publishes nothing.

## Notes

- The **"Latest release"** badge on the repository tracks whichever tag is newest by date across all
  streams; the tag prefix identifies the product. Pass `--latest=false` when publishing an off-stream
  release if you do not want it to claim the badge.
- Each product's version is independent; they do **not** have to move together. The `--package-version`
  stamped into each localized `.pot`/`.po` header is derived from that product's `VERSION` file at
  localization time (documentation → protocol, reports → reports, infectious_agents → infectious-agents),
  so it tracks the version automatically and cannot drift — there is nothing to hand-edit.
- The **metadata** packages are **generated build artifacts**, never committed (see
  `metadata/dist/README.md`); they exist only as Release assets and CI build artifacts. The **reports**
  product has **no** generated package: its render-ready sources ship in the tag's auto source archive
  (a slimmer bundle is deferred — see `ToDo.md`), alongside the attached `compatibility.yml`.
