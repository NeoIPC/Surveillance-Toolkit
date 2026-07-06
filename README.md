# Surveillance-Toolkit
This repository contains the surveillance toolkit of the NeoIPC Project

## Licensing

Except where noted below, this repository is licensed under the [MIT License](LICENSE).

Two data directories compile content from upstream sources whose terms are stricter than MIT. Each is governed by the **strictest of its upstream licenses** — the effective license is dictated by what those sources permit, not a restriction NeoIPC chose to impose — and each carries its own `LICENSE.md` with the reasoning and full attribution:

| Directory | Effective license | Upstream sources |
|-----------|-------------------|------------------|
| [`metadata/common/infectious-agents/`](metadata/common/infectious-agents/LICENSE.md) | CC BY-NC-ND 4.0 (plus CDC agency-material terms) | NHSN, LPSN, MycoBank, ICTV |
| [`metadata/common/antibiotics/`](metadata/common/antibiotics/LICENSE.md) | CC BY-NC-ND 4.0 | WHO AWaRe classification / ATC/DDD index |

Both land on **no-derivatives** because a no-derivatives source dominates each: MycoBank for the infectious agents, and the WHO ATC/DDD index (which does not permit modifying the classification) for the antibiotics — even though the AWaRe classification the antibiotics also draw on is the more permissive share-alike CC BY-NC-SA 3.0 IGO. We are not stricter than we need to be; the strictest upstream term simply wins.

The gettext translation catalogues under [`po/`](po/) each declare, in their header, the license of the content they localize: MIT for the reports and scripts, CC BY 4.0 for the protocol documentation and the DHIS2 metadata, and the licenses above for the two data lists.
