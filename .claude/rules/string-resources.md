---
paths: "reports/**/*.yaml,glossary*.yaml,common/figure-strings*.yaml,reports/common/helpers.R,reports/*/_setup.qmd"
---

## String Resources

- **Never** use single letters or bare numbers as YAML keys in string resource files. po4a's YAML module fails to extract some single-letter keys (e.g., `u`), and short keys are not expressive. Use descriptive names instead (e.g., `female`/`male`/`undetermined` instead of `f`/`m`/`u`). When a YAML key must map to a short code from DHIS2, add a mapping in the R code — option codes included, however stable they look (`delivery_room`, not `"1"`): the key then names what the label means for translators, and a changed option code changes one R mapping but no translated string. The one numeric key is a validation rule's id under the Validation Report's `problems`, since the id is the rule's name wherever it appears (neoipcr's registry, the report's headings). *(repo-specific)*
- String values must not be duplicated across YAML layers (glossary, common, report-specific) or across report-specific files. If two reports share a string, move it to `common.yaml`. Run `scripts/Test-StringResourceLayers.ps1` to check before committing changes to string resource files. *(repo-specific)*
- **Glossary casing** follows the AMA Manual's capitalization rules. Disease names are common nouns and are lowercase in running text (e.g., "necrotizing enterocolitis", "pneumonia") unless they contain a proper noun (e.g., "Crohn's disease"). The sentence-case variants (`_sc`) exist for labels, not because the terms are proper nouns; how they are derived is set out under "Glossary Naming Convention" below. *(repo-specific)*
- A YAML *value* is prose and follows the English rule; a YAML *key* is an identifier and does not. The glossary is the exception both ways: its keys become the `msgctxt` that identifies a translator's unit, so a glossary key is part of the translatable surface and moves with its value **and every R call site in the same change**, or the units are recreated twice. *(repo-specific)*

## String Resource Cascade

`helpers.R::get_string_resources()` implements a cascading YAML merge for localized string resources. Each report provides a base `content/_sR.yaml` (English), and the cascade overlays language-specific overrides using `modifyList()` (recursive merge).

### Cascade Order (Lowest → Highest Priority)

Paths are relative to each report's directory (e.g., `reports/Partner-Report/`).

1. `../../glossary.yaml` — controlled vocabulary (English base)
2. `../common.yaml` — shared domain terms (English base)
3. `content/_sR.yaml` — report-specific strings (English base)
4. `../../glossary.<lang>.yaml` — controlled vocabulary (language override)
5. `../../glossary.<lang>_<territory>.yaml` — controlled vocabulary (language+territory override)
6. `../common.<lang>.yaml` — shared domain terms (language override)
7. `../common.<lang>_<territory>.yaml` — shared domain terms (language+territory override)
8. `content.<lang>/_sR.yaml` — report-specific strings (language override)
9. `content.<lang>_<territory>/_sR.yaml` — report-specific strings (language+territory override)

Each level only needs to contain the keys it wants to override — `modifyList()` preserves unmodified keys from earlier levels. Only the three English levels are written by hand: po4a and `scripts/update-glossary-po.py` generate the `<lang>` levels from the Weblate catalogues, so a translation changes in Weblate, never in those files (see the localization rules), and no repository file provides a `<lang>_<territory>` level.

### Setup Pattern (in Each Report's `_setup.qmd`)

```r
locale <- Sys.getenv("LC_ALL")                 # e.g. "de_DE.UTF-8"
localeObj <- parse_locales(locale)[[1]]         # list(language="de", territory="DE", codeset="UTF-8")
sR <- get_string_resources(localeObj)           # cascading YAML merge
```

**Important**: `get_string_resources()` reads `localeObj` from the calling scope (not from its parameter `x`). The `localeObj` variable must exist in the parent environment.

### Locale Resolution for Content Files

`helpers.R::get_localised_path(file_name, language, territory)` resolves localized content files with fallback:

`content.<lang>_<territory>/` → `content.<lang>/` → `content/`

### Variable Naming

All reports store the string resource result in `sR` (accessed via `sR$key`).

### YAML Conventions

- Use `>-` (folded, strip trailing newline) for multi-line strings that should be a single paragraph
- Use `|` (literal, keep trailing newline) for strings with intentional newlines (e.g., email templates)
- Use `>` **only** when a trailing newline is intended (rare)
- Quote a numeric YAML key — a validation rule's id, the only one allowed (see the guardrail against bare numbers as keys): `"45"` (otherwise YAML interprets it as an integer)
- Read string resources with `string_resource_handlers()` from `reports/common/helpers.R` (as `get_string_resources()` does), which sets one handler on both the `bool#yes` and the `bool#no` tag: YAML 1.1 reads a bare yes, no, on, off, y or n as a logical, but in string resources such a word is a label (po4a writes a translated `Yes` unquoted), so it stays text, and only true and false are logicals

### Glossary Naming Convention

**One key per term.** `glossary.yaml` holds the AMA canonical (lowercase) form — `necrotizing_enterocolitis: "necrotizing enterocolitis"` — and nothing else for that term.

**Casing is derived, not stored.** `sR$necrotizing_enterocolitis_sc` returns `"Necrotizing enterocolitis"`, produced by `get_string_resources()` after the whole cascade rather than translated as a second key.

Casing is a rendering concern: the renderer knows whether it is starting a label or a sentence, and the translator supplies the term. Storing it would make translators translate the same word twice, put a second identical hit in every other component's glossary sidebar, diluting the terminology decisions the sidebar exists to carry, and multiply against the plural axis, so that a term needing six Arabic forms would need eighteen keys.

- The rule is `sentence_case()` in `reports/common/helpers.R`, and it uppercases **the first character only**, through `stringr::str_to_upper(locale = …)` so the language's own casing applies. Turkish shows why the language is passed rather than left to the process: `i` uppercases to `İ`, while base `toupper()` follows the *process* locale and gives a plain `I` wherever that locale is not Turkish or the platform lacks it. Delegating to ICU also covers languages nobody has enumerated (Azerbaijani shares the Turkish rule, Lithuanian has its own) and returns a caseless script such as Devanagari unchanged, with no special case.
- **Not `str_to_sentence()` or `str_to_title()`**: both normalize the whole string, and this glossary is largely abbreviations, so `str_to_sentence()` renders `primary sepsis/BSI` as `Primary sepsis/bsi` and `str_to_title()` as `Primary Sepsis/Bsi`. No word-by-word repair rescues title case, since the token `sepsis/BSI` needs it on one side of the slash and not on the other; that is also why there is no derived `_tc` form.
- **Store the AMA canonical (running-text) form, not sentence case** — the direction is load-bearing, not arbitrary. **Most terms already begin with a capital** (`AWaRe`, `BSI`, `CVC`, `ESBL`, `HAP`, `ICHI`, `MRSA`, `NEC`, `NeoIPC Surveillance`, …), so uppercasing the first character is a **no-op** on most of the glossary and cannot damage anything. Deriving the other way round has no such property: lowercasing the first character of a stored sentence-case form yields `aWaRe`, `bSI`, and `neoIPC Surveillance`, and `str_to_lower()` yields `aware`, `bsi`, `neoipc surveillance`. Storing sentence case moves the damage from a direction where it cannot occur to one where it occurs for most terms.
- **Do not add a `_tc` key.** If a rendering genuinely needs a form the rule cannot produce, an explicit `_sc` in the language's own glossary layer still wins — the derivation only fills a variant that is absent — but reach for that having established the rule is wrong, not by habit.
- Abbreviations (CVC, HAP, INV, NEC, SSI) are always uppercase, and proper nouns (NeoIPC Surveillance) keep their canonical casing — both are unaffected, since capitalizing an already-capital first letter changes nothing.
- **The glossary has no plural machinery, deliberately.** A two-slot form (`key` plus `key_plural`, fused into one gettext plural entry) holds two forms and no more, so Ukrainian and Polish (3) and Arabic (6) are unrepresentable in it, and the glossary holds no plural family. Count-dependent strings are handled where they belong, in report prose; the set is established in [`docs/count-dependent-strings.md`](../../docs/count-dependent-strings.md).
- A term and the display label built from it are **separate entries in separate layers, and must not share a key**. The bare term belongs here (`mrsa: MRSA`, `3gcr: 3GCR`) so Weblate can carry it as terminology into every catalogue's sidebar; the descriptive label a table actually renders belongs in `reports/common.yaml` under a `_label` key (`mrsa_label: "Methicillin-resistant Staphylococcus aureus (MRSA)"`). Reusing one key across both layers does not merely duplicate — `common.yaml` sits later in the cascade and silently overrides, so the glossary entry becomes unreachable and translating it changes nothing anyone sees.
