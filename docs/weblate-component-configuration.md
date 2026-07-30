# Weblate component configuration

The `neoipc` project on Hosted Weblate hosts five gettext catalogues, plus a TBX terminology store
that is a different kind of object and is out of scope here.

| Component | Catalogue | Source template |
|---|---|---|
| `neoipc-reports` | `po/reports.*.po` | `po/reports.pot` |
| `neoipc-core-surveillance-protocol` | `po/documentation.*.po` | `po/documentation.pot` |
| `neoipc-infectious-agents` | `po/infectious_agents.*.po` | `po/infectious_agents.pot` |
| `neoipc-dhis2-metadata` | `po/metadata.*.po` | `po/metadata.pot` |
| `neoipc-glossary` | `po/glossary.*.po` | `po/glossary.pot` |

`neoipc-glossary` carries two deviations the others do not, both deliberate. **`is_glossary: true`**, so
its 41 curated terms are simultaneously translatable *and* the terminology source surfacing in every
other component's sidebar — the reason it was registered as a component rather than seeded into the TBX
store, one artifact serving both purposes with no one-way copy to drift. And a component-level
**`variant_regex`** of `_(tc|sc|plural|plural_tc|plural_sc)$`, because this is the only catalogue whose
keys carry casing and number variants of one concept; the regex groups them in the translator's view so
a term and its title-case form are edited together instead of appearing as unrelated strings.

Its keys are an API contract with the R report code (`sR$surveillance_end` and friends), which is why
the template stays repository-owned while the translations are Weblate's: exactly the `.pot`/`.po` seam,
and the reason the catalogue is generated rather than hand-written.

**Expect one churn commit on its first drain.** The retired repository-side merge copied the template's
source flags (`terminology`, `read-only`) into every catalogue. Weblate strips source flags when it
writes a `.po`, so its first write removes them — a header-and-flags-only diff, self-correcting, and not
worth a repository-side edit to pre-empt. The `ignore-same` flags are the exception: that one is
translator-managed, and German carries two more than the other languages, which is real state to keep.

Those five are configured **identically except where this document gives a reason.** That rule is the
point of the file: the components were created at different times against different Weblate defaults,
and the resulting drift was invisible until someone compared them by hand. A difference with no reason
recorded here is drift, and should be removed rather than explained after the fact.

## Where each kind of fact lives

Several settings only make sense against this split, and getting it wrong wastes hours — a source
property was twice looked for in the wrong file and the wrong language.

| Fact | Lives in | Survives a repository reset? |
|---|---|---|
| Translated text, fuzzy state | `po/<catalogue>.<lang>.po` | yes |
| Source string flags, including `priority:N` | `po/<catalogue>.pot` | yes |
| Explanation, labels, screenshots | Weblate's database only | yes (reset does not clear them) |
| Approval state, comments, suggestions, votes | Weblate's database only | not represented in gettext at all |

The middle row is the one that surprises people. For a bilingual gettext component Weblate treats the
`.pot` as the **source translation** (`is_source: true`, `filename: po/<catalogue>.pot`), so
`priority:N` and other source-string flags are read from there and apply to every language. Weblate
deliberately **strips them when writing each `.po`**, because a source property has no business being
duplicated per language. Write such flags into the `.pot` only; a generator that also writes them into
every `.po` produces thousands of lines of churn that Weblate removes again on the next write.

## Settings that must not diverge

These are uniform across all five components. Changing one on a single component is drift unless a
reason is added below.

| Setting | Value | Why it is load-bearing |
|---|---|---|
| `vcs` | `git` | Weblate pushes a branch and never calls the forge API; pull requests are opened by this repository's own tooling, so Weblate's credentials need push rights and nothing else |
| `merge_style` | `rebase` | Keeps Weblate's history linear so its branch stays rebase-mergeable. Merging upstream instead would put merge commits into every translation pull request |
| `push_on_commit` | `false` | **Load-bearing.** The Squash add-on rewrites the un-merged commit range after each commit cycle, so a branch tip that was already pushed is orphaned and the next push is rejected as non-fast-forward. With `auto_lock_error` on, that rejection locks the component against translators. Pushing once per drain, immediately before opening the pull request, avoids the window entirely |
| `auto_lock_error` | `true` | Fail-closed. A component that cannot push accumulates work that cannot reach git; locking makes that visible instead of letting it pile up silently. It clears itself once a push succeeds |
| `commit_pending_age` | `24` | A safety net only. The drain commits explicitly rather than waiting for it |
| `file_format_params.dos_eol` | `false` | The repository is LF-only. Weblate is one of the writers of these files, so this is the same contract as pinning newlines in every other tool that touches them |
| `file_format_params.po_line_wrap` | `65535` | Must match the repository side. Three po4a configs (`reports`, `documentation`, `infectious_agents`) pass `--wrap-po newlines`; `scripts/po4a.cfg` passes `--wrap-po no`; `metadata` has no po4a config at all — it is written by `Write-NeoIPCMetadataPoText`, which emits one line per field and never wraps; and `glossary` is written by `update-glossary-po.py`, which pins polib's `wrapwidth` to 65535 because polib's default of 78 had made it the only wrapped template here (longest line 91, against 1830 in the po4a-generated ones). All five therefore expect an unwrapped file. A mismatch means each writer re-flows what the other wrote: one component sitting at the xgettext default of 77 produced an 18,000-line diff of pure re-wrapping |
| `file_format_params.po_keep_previous` | `true` | Keeps `#| msgid` so translators can see what a changed source string used to say |
| `file_format_params.po_remove_obsolete` | `false` | Obsolete entries are cheap and let a reverted source change recover its translation |
| `file_format_params.po_no_location` | `false` | Keep `#:` source references wherever line numbers *might* be real — stripping them is lossy and hard to reverse. Measured. The protocol documentation is fully informative (10 files, lines 1–1032). Reports is mixed: of 67 `.Rmd` files referenced, **45 carry real line numbers and 22 carry only `:1`**, as do all 10 YAML/YML files (six string-resource files and four `_quarto-en.yml` configs) — so roughly a quarter of its references are informative and the rest are dead weight. The infectious-agent list is 99.4 % `:1` but still carries 23 real AsciiDoc references. The metadata catalogue emits no location comments at all, so the setting is moot there. Since the repository-browser URL is configured, these become clickable links to the surrounding context |
| `enable_suggestions` | `true` | The editorial model is peers advise, editor decides; suggestions are how peers advise |
| `suggestion_voting` / `suggestion_autoaccept` | `false` / `0` | Voting needs at least two active contributors in a language before it reads as anything but a second obstacle |
| `manage_units` | `false` | Source strings come from this repository. Translators must not add or remove them |
| `license` | `CC-BY-4.0` | Should match what the catalogue's own PO header declares. **Two currently do not** — every `po/reports.<lang>.po` header still says MIT and every `po/infectious_agents.<lang>.po` header still says CC BY-NC-ND 4.0, while both components are registered here as CC BY 4.0. The decision is that the **headers** are wrong and are to be corrected (a NoDerivatives term cannot govern a translation catalogue, since a translation is the paradigm derivative work). Until that lands, this row states the target, not the state |
| `report_source_bugs` | `NeoIPC-Support@charite.de` | Gives translators a route for source-string problems that is not a pull request comment |
| `language_regex` | `^[^.]+$` | The filemask contains dots, so the language code must not swallow them |
| `allow_translation_propagation` | `true` | The setting is **directional** — it controls whether updates in *other* components translate into *this* one. The protocol documentation and the DHIS2 metadata share 33 source strings, including whole clinical definitions reproduced verbatim as form help text; translated independently those drift, and drift between the protocol and what a clinician reads while entering data is a data-quality problem, not an inconsistency. Note it is prospective: enabling it does not backfill existing strings |
| `new_lang` | `contact` | Anyone signed in could otherwise create a new language file, and for the infectious-agent list that is 4 107 empty strings. Requesting contact keeps the door open while putting an administrator in the loop |
| `secondary_language` | German | Shows translators a second reference rendering beside English, in the one language the maintainer can personally vet |
| `file_format_params.po_set_last_translator` | `false` | Would write a contributor's e-mail address into the `Last-Translator` header. The contributor list maintained by the *Contributors in comment* add-on already records authorship, and the most recent single contributor is not interesting on its own |
| `agreement` (project level) | set | **Carries a promise this repository has to keep** — see [What the agreement commits us to](#what-the-agreement-commits-us-to). Contribution is gated on an explicit, recorded acceptance: the CC BY 4.0 licence, a right-to-contribute statement, and — because the add-ons publish it — plain notice that the contributor's name and e-mail address enter the public git history through the PO header contributor list and `Co-authored-by:` commit trailers. Informed consent rather than suppression; see [Message templates](#message-templates) for where those addresses land |

## Every remaining difference, and why

Two settings differ: one deliberate, one inert. Everything else is uniform.

### Deliberate

**`priority` — 60 glossary, 60 reports, 80 documentation, 100 metadata, 120 infectious-agents.**
Component priority orders the translation queue across the whole project.

**The glossary alongside reports.** It is 41 terms, so it is cheap to finish, and it feeds both the
controlled vocabulary the reports render and the terminology sidebar every other component sees — so
settling it first makes every later decision cheaper and more consistent.

**Reports first too.** They are essentially what generates the impact of the whole NeoIPC Surveillance
project, and they have the greatest audience reach.

**Then the protocol documentation.** The surveillance protocol and the definitions are the heart of
the work and the reference for everyone working within the project.

**Then the DHIS2 metadata**, which is required for data entry and maintenance only. Strings displayed
during data entry and in reporting clearly matter more than the metadata names and descriptions, which
are invisible to anyone who is not an administrator.

**Then the infectious-agent list**, which is mostly untranslatable taxonomy in any case.

Note the scale runs opposite to the `priority:N` *string* flag: here a **lower number means higher
priority**, which is why the catalogue that matters most carries 60 rather than 120. Two fields named
"priority", pointing in opposite directions, is a genuine trap — confirm against the wording in the
component settings UI, which labels the values ("Very high" … "Very low") rather than showing numbers.

### Priority within a component — intended, not yet configured

Component priority is only half of it: the ordering above holds *between* catalogues, and two of them
have a further ordering *inside* them that component priority cannot express. That needs the
`priority:N` string flag, which lives in the `.pot` — see the source-flag rule above.

**None of this is in place today.** `po/reports.pot` and `po/infectious_agents.pot` contain **zero**
`priority:N` flags; the only catalogue with a within-component ordering is `metadata`
(2,329 × `priority:10`, 293 × `priority:200`, 92 × `priority:150`), generated by the metadata
pipeline. What follows is the intended ordering, recorded so the flags can be written deliberately
rather than invented later.

**Within reports**, the Partner Report, the Patient-Data Report and the Partner Certificate rank
highest: they are meant to reach non-academic team members, patients and the general public, who have
no English fallback. The Validation Report is for people entering data — important, but most of them
**currently** have to get along with an untranslated DHIS2 user interface and, for now, untranslated
metadata in any case. The Reference Report probably has the greatest reach of all, but most of its
audience can read it in English.

That "currently" is load-bearing rather than hedging: the metadata catalogue exists to remove exactly
that condition, so this particular justification expires as that catalogue fills. Revisit the
Validation Report's standing then — do not read it as a permanent property of its audience.

**Within the infectious-agent list**, the handful of strings that are genuinely translatable rank
clearly above the nomenclature, which is identical in most languages.

### Inert

**`edit_template` — `false` on metadata, `true` elsewhere. Inert; the difference does not matter.**
The setting governs whether users may edit the *monolingual base file*, which is the `template` field
— and `template` is empty on all five components, because they are bilingual. There is nothing for it
to act on, whatever its value.

Worth recording because the opposite conclusion is easy to reach: the source translation *is* backed
by a repository-owned file (`po/<catalogue>.pot`), so it looks as though enabling this could make
Weblate a second writer of the `.pot` and reintroduce the hazard that declining Weblate's "Update POT
file (xgettext)" add-on exists to prevent. It cannot, because `edit_template` governs `template`, not
`new_base`. Two different fields, and only the empty one is in scope.

## What the agreement commits us to

The contributor agreement is stored on Weblate, but one clause is an obligation on **this
repository**, so it is recorded here where the code that must honour it lives.

Translators are told they may opt out of being named in the acknowledgements of published NeoIPC
reports, by writing to the support address. Nothing in this repository implements that yet, and no
report currently names translators at all — so the promise is not yet broken, but it becomes binding
the moment the first acknowledgement is published. Whatever gathers translator credits must filter
them against a committed opt-out list **inside the credit-gathering step**, before any caller sees a
name; filtering at one report's emit site means the next report to grow an acknowledgements section
silently re-credits someone who asked not to be.

The agreement is equally explicit about what the opt-out cannot do: it does not remove a contributor's
name or address from the PO header contributor list or from `Co-authored-by:` commit trailers, both of
which are permanent once merged. Do not let anyone widen that promise.

## Message templates

`commit_message`, `add_message`, `delete_message`, `merge_message`, `addon_message` and
`pull_message` were each stored separately per component — metadata in a conventional-commit style
(`chore(l10n): …`), the other three as near-copies of an older Weblate default. All six are now
identical everywhere and inherited from the project.

Unifying them mattered for more than tidiness: **the stored value is what takes effect the moment
anyone unticks "inherit from project"**, so divergent copies are a latent surprise rather than dead
weight. Three traps came out of doing it, all worth knowing before touching these fields again.

**Writing a stored value silently unticks inheritance.** Setting an explicit template turns the
corresponding `inherit_*` flag off, because that is exactly what the checkbox means. Normalising the
values therefore *creates* drift in the inherit flags unless they are re-ticked afterwards.

**A stored template cannot be blanked.** The API rejects an empty value with
`{"code":"blank","detail":"This field may not be blank."}`, so a component can never fall back to
having no stored copy at all; it can only hold the same text as everyone else.

**Two of them carried CRLF, and it did not reach git.** The project-level `commit_message` and
`addon_message` held literal `\r\n`; they are now LF. Weblate evidently normalises newlines when it
creates the commit, because **no commit message in this repository contains a carriage return** —
checked byte-accurately across every commit reachable from every ref. Normalising the templates was
therefore tidiness rather than a fix, and is recorded here so nobody re-derives the alarming version:
a first attempt to measure this counted 23 carriage returns in a commit, which was an artefact of
PowerShell's `Out-String` joining lines with `\r\n`, not a property of the commit. Measure git objects
with `git cat-file`, never through a shell string conversion.

### A squashed commit's subject names one language; its body covers them all

The *Squash* add-on runs with `squash: author`, so each drain produces **one commit per contributor**,
spanning every language that contributor touched — within one component, since the add-on's scope is
per component. Observed on `main`: a commit titled *"Translated using Weblate (Turkish)"* changes
eight of the infectious-agent catalogue's language files (`de`, `el`, `es`, `et`, `fr`, `it`, `ne`,
`tr`).

The commit itself is complete — the **body** concatenates every squashed commit's message with its
per-language completion statistics, and `append_trailers` adds `Co-authored-by:` plus one
`Translate-URL:` per language. Only the **subject line** is unrepresentative, being the first squashed
message's subject. Read the body or the file list; do not take the subject as a summary.

The add-on's `commit_message` is therefore set to the static text
`Translations update from Weblate`.

**It was first set to `Translations update from Weblate ({{ component_name }})`, and that did not
work.** The markup documentation lists add-on *messages* among the templated fields, which reads as
though the component name would interpolate — but the Squash add-on's own `commit_message` key is not
one of them. Four commits landed on the `weblate-reports` branch carrying the literal braces in their
subject. They never reached `main`: the placeholder was replaced with static text and a *Reset and
reapply* re-derived the branch, which is exactly the containment the check below was written for.
Do not restore the templated form on the strength of the documentation; it has been tried.

One deliberate trade remains, and it was made knowingly: the field is used *"instead of the combined
commit messages from the squashed commits"*, so the per-language `Currently translated at …%` lines
are lost. The `Translate-URL:` trailers still name every language touched, and those percentages are a
point-in-time snapshot that is stale the moment it is written.

**The general lesson is worth more than the setting.** Any templated value here is a claim about
Weblate's behaviour that the documentation may not actually support for the specific field being set.
Squashed commits land on a `weblate-<catalogue>` branch and are visible in the pull request before
they reach `main`, so read the rendered subject there rather than assuming it interpolated.

The stored copies were also fossils in their own right: one still referenced
`component_linked_childs`, a Weblate template variable since renamed to `component_linked_children`.
Dormant, but further evidence that the components were built at different times against different
defaults.
