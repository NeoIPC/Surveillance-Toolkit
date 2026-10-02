---
paths: "scripts/Build-*.ps1,scripts/modules/NeoIPC-Tools/**,reports/common/**"
---

## Report Wrappers

- **Always** keep the report PowerShell wrapper scripts (`scripts/Build-*.ps1` — Reference, Partner, Partner-Certificate, Patient-Data, Validation) aligned on any concept that applies across more than one of them: variable and parameter names, helper-call patterns, `$extraFields` / build-report JSON schema, user-facing behaviour and argument surfaces. **(a)** Before adding a new concept (parameter, variable, helper call, JSON field, etc.) to one wrapper script, grep the other wrapper scripts for preexisting implementations and **reuse or extend** existing patterns rather than inventing parallel code. **(b)** When adding a concept that could legitimately apply to other wrapper scripts, **ask the user** whether it should be added to those other scripts in the same pass. **(c)** When reading or editing across multiple wrapper scripts, **proactively assess and highlight any divergence** you notice — even if fixing it is out of the current task's scope, flag it and record it wherever this project tracks work, rather than letting it slip. *(repo-specific)*

### PowerShell Scripts

Every script file and exported function uses an approved PowerShell verb (`Get-Verb`) and a PascalCase noun, chosen by behaviour, as the approved-verb guardrail in `CLAUDE.md` says (`New-` returns an in-memory object, `Build-` assembles an artefact, `Export-` writes data to a file). The report wrappers are `Build-*.ps1` (e.g. `Build-PartnerReport.ps1`), all in `scripts/`; they import their shared helpers from the `NeoIPC-Tools` module (`scripts/modules/NeoIPC-Tools`).

### Argument Handling

- The PowerShell wrappers pass parameters to Quarto via `-P key:value` flags
- `dhis2_connection_options()` / `dhis2_dataset_options()` in neoipcr coerce string inputs internally — single source of truth for types and defaults
- Casing per layer: PowerShell `PascalCase` → Quarto document `camelCase` → R `snake_case`, mapped once at each boundary
- Defaults defined only in neoipcr functions, not duplicated in PowerShell scripts or Quarto document YAML — **except the DHIS2 host**: neoipcr, a public library, defaults to no deployment's host, so the production host default lives in `reports/common/helpers.R::get_connection_options()` (used by every report R entry point). Pass `--host` / `-P dhis2Hostname` to override it.

### Auth Flow

neoipcr is the single authentication authority. The PowerShell scripts resolve credentials via `Resolve-NeoIPCAuth` (token or username/password), then set scoped environment variables (`NEOIPC_DHIS2_TOKEN`, `NEOIPC_DHIS2_USER`, `NEOIPC_DHIS2_PASSWORD`) so neoipcr in child R/Quarto processes finds them automatically. No `-P "token:..."` in Quarto renders. The **host** resolves separately from authentication — an explicit `hostname` argument, else the `NEOIPC_DHIS2_HOST` environment variable (the report tooling supplies the production default when neither is set).

Environment-variable fallback chain in `neoipcr::get_auth_data()`:
1. `NEOIPC_DHIS2_SESSION_ID` → session_id (Docker only)
2. `NEOIPC_DHIS2_TOKEN` → token
3. `NEOIPC_DHIS2_USER` + `NEOIPC_DHIS2_PASSWORD` → username/password
4. `interactive()` → prompt for username/password
5. `!interactive()` → `rlang::abort()` with actionable error
