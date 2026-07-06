# Surveillance-Toolkit
This repository contains the surveillance toolkit of the NeoIPC Project

## Licensing

Except where noted below, this repository is licensed under the [MIT License](LICENSE).

Two data directories compile content from upstream sources whose terms are stricter than MIT. The effective license of each is dictated by what its sources permit — not a restriction NeoIPC chose to impose — and each carries its own `LICENSE.md` with the reasoning and full attribution:

| Directory | Effective license | Upstream sources |
|-----------|-------------------|------------------|
| [`metadata/common/infectious-agents/`](metadata/common/infectious-agents/LICENSE.md) | CC BY-NC-ND 4.0 (plus CDC agency-material terms) | NHSN, LPSN, MycoBank, ICTV |
| [`metadata/common/antibiotics/`](metadata/common/antibiotics/LICENSE.md) | CC BY-NC-SA 3.0 IGO | WHO AWaRe classification / ATC/DDD index |

The two directories land on different Creative Commons terms because their upstream licences differ. The infectious-agent list is **no-derivatives** — its MycoBank source is CC BY-NC-ND, incorporated with permission. The antibiotic list is a **derivative** of the WHO AWaRe classification (CC BY-NC-SA 3.0 IGO); ShareAlike requires a derivative to keep the same licence, so it is CC BY-NC-SA 3.0 IGO (the ATC codes, substance names and group descriptions it also carries are reproduced unchanged from the WHOCC ATC/DDD index, not adapted). We apply the licence the upstream terms require, no stricter.

The gettext translation catalogues under [`po/`](po/) each declare, in their header, the license of the content they localize: MIT for the reports and scripts, CC BY 4.0 for the protocol documentation and the DHIS2 metadata, and the licenses above for the two data lists.
