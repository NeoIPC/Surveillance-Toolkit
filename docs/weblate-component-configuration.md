# Weblate component configuration

The `neoipc` project on Hosted Weblate hosts **five** gettext catalogues, plus a TBX terminology store,
which is a different kind of object and is out of scope here.

| Component | Catalogue | Source template |
|---|---|---|
| `neoipc-reports` | `po/reports.*.po` | `po/reports.pot` |
| `neoipc-core-surveillance-protocol` | `po/documentation.*.po` | `po/documentation.pot` |
| `neoipc-infectious-agents` | `po/infectious_agents.*.po` | `po/infectious_agents.pot` |
| `neoipc-dhis2-metadata` | `po/metadata.*.po` | `po/metadata.pot` |
| `neoipc-glossary` | `po/glossary.*.po` | `po/glossary.pot` |

`neoipc-glossary` carries two deviations the others do not, both deliberate. **`is_glossary: true`**, so
its 41 curated terms are simultaneously translatable *and* the terminology source surfacing in every
other component's sidebar — the reason it is a component rather than terms seeded into the TBX store, one
artifact serving both purposes with no one-way copy to drift. And a component-level
**`variant_regex`** of `_(tc|sc|plural|plural_tc|plural_sc)$`, because this is the only catalogue whose
keys carry casing and number variants of one concept; the regex groups them in the translator's view so
a term and its title-case form are edited together instead of appearing as unrelated strings.

Its keys are an API contract with the R report code (`sR$surveillance_end` and friends), which is why
the template stays repository-owned while the translations are Weblate's: exactly the `.pot`/`.po` seam,
and the reason the catalogue is generated rather than hand-written.

### Creating a component: three settings the creation branch decides for you

`neoipc-glossary` was created through the API on 2026-07-30 — `vcs: git`, `repo`/`push`/`branch` and the
uniform settings below, `push_branch: weblate-glossary`, `filemask: po/glossary.*.po`,
`new_base: po/glossary.pot`, `template:` **empty** (bilingual — see above), `file_format: po`,
`is_glossary: true`, `variant_regex: _(tc|sc|plural|plural_tc|plural_sc)$`, `priority: 60`. Three of the
values that came back were not the values sent, and none of them announced.

**They are not universal, so do not treat them as a checklist.** An earlier revision of this paragraph
said "the next component created here will meet the same three"; the next component — `neoipc-app`, from
a different repository — met **none** of them, and came back exactly as sent. Each of the three has a
specific trigger, which is what to check for: `manage_units` is forced for a **glossary** component,
linking happens when the `repo` URL **matches an existing component**, and the `new_lang` reset travelled
with the linking rather than standing on its own. Read the response back and compare it to what you sent;
that habit generalises, and a list of three remembered symptoms does not.

**`manage_units` is forced to `true`** for a glossary component, whatever the request said — so patch it
back to `false` afterwards and verify. Left `true`, a translator can add or remove terms, and these
msgids are an API contract with the R report code.

**Weblate silently *links* a component whose `repo` matches an existing one.** The request carried a
plain repository URL and no link field; the response carried
`linked_component: …/neoipc-dhis2-metadata/`. A linked component cannot own a push branch — operations
route through the parent — so `push_branch` came back as **`weblate-metadata`**, and glossary
translations would have been pushed onto the metadata catalogue's branch, mixing two catalogues into
whichever drain reached it first. That is the failure the one-component-per-catalogue topology exists to
prevent, arrived at by accident. `PATCH`ing `repo` with the same URL it already showed cleared
`linked_component`; `push_branch` then had to be set again, since the linked component had never really
held it. **Read `linked_component` back after any create**, and do not trust `repo` to tell you: it
displayed the real URL throughout, while the component was linked.

**`new_lang` came back `none`** where `contact` was sent, which would silently drop a translator's
request for a new language instead of mailing it. Patched.

Two method notes, both learned the same way. Read the uniform settings **from a sibling component over
the API** and post those values, rather than transcribing them from this document — uniformity then holds
by construction, and the field names are the API's own. And do **not** send `license` or any of the six
`*_message` fields: storing a value unticks the corresponding `inherit_*` flag and strands the component
on a frozen copy, whereas leaving them unsent inherits the project's — which is where the canonical text
lives. `effective_license` confirms the result (`CC-BY-4.0` here, with `license: ''`).

**Expect one churn commit on its first drain — about 28 changed lines per language, 35 for German.**
Roughly six of those are the header and flags: the retired repository-side merge copied the template's
flags into every catalogue, and `msgmerge --previous --no-wrap` — the arguments Weblate uses, because
this document mandates `po_line_wrap: 65535` — discards **all** of them. That is gettext modelling no
custom flags, not Weblate stripping *source* flags; a `fuzzy` injected alongside survives the same merge
while `ignore-same` does not. The remaining ~22 lines are the three translator-comment blocks re-flowing
and one long entry unwrapping, which follows from the `po_line_wrap` contract meeting catalogues polib
wrote at 78 and would happen against the previous template too.

**The `ignore-same` flags needed action, and got it.** Only a flag in the *template* survives a merge, so
`nec` and `surveillance_sc` — whose suppressions existed in `po/glossary.de.po` alone, kept alive by the
per-language flag-merging code this change deletes — would have been destroyed on the first drain and
been unrestorable, since the ownership gate now rejects a repository-side edit to a catalogue. Both are
source-equals-target, so *Unchanged translation* would then have started firing on them with nothing
recording that the suppression was deliberate. They are now declared in `glossary.yaml`, which puts them
in the template where every language inherits them durably.

Those five are configured **identically except where this document gives a reason.** That rule is the
point of the file: the components were created at different times against different Weblate defaults,
and the resulting drift was invisible until someone compared them by hand. A difference with no reason
recorded here is drift, and should be removed rather than explained after the fact.

For which *quality checks* to switch on rather than how a flag is delivered, see
[`weblate-checks-adoption.md`](weblate-checks-adoption.md), which carries a decision for every built-in
check and fixup measured against these catalogues.

## Where each kind of fact lives

Several settings only make sense against this split, and getting it wrong wastes hours — a source
property was twice looked for in the wrong file and the wrong language.

| Fact | Lives in | Survives a repository reset? |
|---|---|---|
| Translated text, fuzzy state | `po/<catalogue>.<lang>.po` | yes |
| Source string flags, including `priority:N` | `po/<catalogue>.pot` | yes |
| Explanation, labels, screenshots | Weblate's database only | yes (reset does not clear them) |
| Approval state, comments, suggestions, votes | Weblate's database only | not represented in gettext at all |

**Storing a source flag is not the same as it taking effect, and `priority:N` is the case where they come
apart.** Observed on the live instance, three independent ways agreeing:

1. Every source unit of `neoipc-dhis2-metadata` carries the flag the template gives it
   (`flags: "priority:10"`, `"priority:200"` — 2,714 of them). The template is parsed; the flags are real.
2. The **target** units of the same strings carry `flags: ""` and `priority: 100`, the default — and the
   translate view's own string-information panel for `dataElements/NEOIPC_ADMISSION_DOL/NAME` in German
   reports no flags set at all.
3. The German queue offers `NAME`, `SHORT_NAME`, `FORM_NAME`, `DESCRIPTION` in that order — positional —
   where `FORM_NAME` at `priority:200` would come first if priority were ordering it.

So the scheme is stored and inert *for its stated purpose*: it does not reorder any translator's work.

A detail that makes the asymmetry legible: the source unit's flag panel shows `priority:200, read-only`,
but the template carries only `priority:200` — Weblate adds `read-only` itself, so what that panel displays
is a **merged** set rather than the file's. The target panel for the same string displays nothing at all,
not even an injected flag. Two consequences worth knowing before reasoning about either: `read-only` on a
source unit is Weblate's own marker and not something to look for in the `.pot`, and the panel's pencil
edits `extra_flags` while the panel *displays* the merge, so a flag can be visible there and not be
editable away.

Two traps to avoid when reasoning about this. The `.po` files contain no flags at all, but that proves
nothing either way — Weblate strips source flags when it writes a target file, so their absence is what a
working mechanism looks like too. And a count of flags in the template proves only that the template has
them. What settles it is the target unit's own `flags`/`priority`, and the order the translate view
actually offers.

**A source unit's `extra_flags` DOES reach every language, and that is the only per-string route there
is.** Established by a reversible probe on one string, since no amount of reading settles it. Setting
`extra_flags: "priority:900"` on the source unit of a `priority:10` string moved its German target from
`priority: 100` to `900`, its flag panel from empty to `priority:900`, and its position in the German
queue from fourth to first — while the source unit's own `flags` stayed `priority:10`, i.e. the file
value, untouched. Clearing `extra_flags` reverted all three. `needs_commit` was false throughout: this
field is Weblate's database, so it produces nothing for the repository to commit.

Attempting the same on the *target* unit is refused outright — *"Source strings properties can be set only
on source strings"* — so there is no per-language flag at all. One write per string covers all nine.

| Route | Reaches the target? |
|---|---|
| Source unit's **file** flags, i.e. what the `.pot` carries | **No** |
| Source unit's **`extra_flags`** (API, `wlc edit-unit --extra-flags`) | **Yes**, all languages |
| Target unit's `extra_flags` | **Rejected by the API** |

Consequences worth stating before anyone builds on this. A per-string scheme that must actually take
effect has to go through the API, which means it is **invisible in git and absent from a freshly created
component** — so the repository has to stay the source of truth with the API call as a reconciliation
step, and a declarative *rule* (a Bulk edit add-on's query, which is small enough to record here) is
preferable to thousands of imperative writes that cannot be. And when checking whether a flag is live for
a language, read the **target's** `priority` field or its flag panel — **not** the target's API `flags`
field, which stayed `""` throughout even while `priority:900` was demonstrably in effect and ordering the
queue.

Why the `.pot` is nonetheless the right home for source metadata: for a bilingual gettext component
Weblate treats it as the **source translation** (`is_source: true`, `filename: po/<catalogue>.pot`), so
source-string flags are read from there onto the source units — and Weblate deliberately **strips them
when writing each `.po`**, because a source property has no business being duplicated per language. Write
such flags into the `.pot` only; a generator that also writes them into every `.po` produces thousands of
lines of churn that Weblate removes again on the next write.

What that does *not* buy is effect on the target units, which is the distinction the rest of this section
establishes. Both statements hold at once: the template is where the flag belongs, and the template is not
how the flag reaches a translator.

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
| `license` | `CC-BY-4.0`, **inherited** | Set at project level and left unset on every component, so `license` reads `''` and `effective_license` reads `CC-BY-4.0`. Storing the value on a component would untick `inherit_license` and freeze a copy — the same trap as [Message templates](#message-templates), and the reason a component-creation payload must not carry this field. Matches what every catalogue's own PO header declares, on all five. Two did not: `reports` headers said MIT and `infectious_agents` said CC BY-NC-ND 4.0. The headers were the wrong side — a NoDerivatives term cannot govern a translation catalogue, since a translation is the paradigm derivative work — and they were corrected. Keep them in step: the header and this field are two statements of one fact, and a reader who finds only one of them must not be misled |
| `report_source_bugs` | `NeoIPC-Support@charite.de` | Gives translators a route for source-string problems that is not a pull request comment |
| `language_regex` | `^[^.]+$` | The filemask contains dots, so the language code must not swallow them |
| `allow_translation_propagation` | `true` | The setting is **directional** — it controls whether updates in *other* components translate into *this* one. It matches on `(context, source)`, which is why the pair it was originally justified by cannot benefit: the protocol documentation and the DHIS2 metadata do share 33 source strings, including clinical definitions reproduced verbatim as form help text, but all 2 820 metadata units carry a `msgctxt` and all 689 documentation units carry none, so no key ever matches. Measured, the reach is **documentation↔reports (8 keys)** and **documentation↔infectious agents (6)**. The same reasoning makes it **inert for the glossary in both directions** — all 41 of its units carry a `msgctxt` and it shares no key with any other component — which is worth stating because the glossary looks like the component that would benefit most: it is the controlled vocabulary, and terms in it appear verbatim in the reports catalogue. What shares those is `is_glossary` and the terminology sidebar, not this setting. Keep it on for the pairs that can use it, and treat the protocol-to-form-text drift — a real quality problem, not a cosmetic inconsistency — as unsolved by it. Prospective in any case: enabling it does not backfill existing strings |
| `new_lang` | `contact` | Anyone signed in could otherwise create a new language file, and for the infectious-agent list that is 4 107 empty strings. Requesting contact keeps the door open while putting an administrator in the loop |
| `secondary_language` | German | Shows translators a second reference rendering beside English, in the one language the maintainer can personally vet |
| `file_format_params.po_set_last_translator` | `false` | Would write a contributor's e-mail address into the `Last-Translator` header. The contributor list maintained by the *Contributors in comment* add-on already records authorship, and the most recent single contributor is not interesting on its own |
| `agreement` (project level) | set | **Carries a promise this repository has to keep** — see [What the agreement commits us to](#what-the-agreement-commits-us-to). Contribution is gated on an explicit, recorded acceptance: the CC BY 4.0 licence, a right-to-contribute statement, and — because the add-ons publish it — plain notice that the contributor's name and e-mail address enter the public git history through the PO header contributor list and `Co-authored-by:` commit trailers. Informed consent rather than suppression; see [Message templates](#message-templates) for where those addresses land |

## Every remaining difference, and why

Four settings differ: three deliberate, one inert. Everything else is uniform. The three deliberate ones
are the component `priority` below, and the glossary's `is_glossary` and `variant_regex`, both explained
where the component is introduced at the top of this file.

### Deliberate

**`priority` — 60 glossary, 80 reports, 100 documentation, 120 metadata, 140 infectious-agents.**
Component priority is meant to order the translation queue across the whole project.

**The field cannot be raised, only the others lowered.** `priority` is a five-value *choice* field —
60 "Very high", 80, 100, 120, 140 "Very low", lower being offered earlier — so 60 is the ceiling and
there is no way to lift one component above another already sitting there. Giving the glossary the top
slot alone therefore meant demoting the other four by one step each, which is what the values above are.
That exhausts the scale exactly, so the next component added here cannot be slotted between two existing
ones; it can only join one of them.

**The glossary alone at the top.** It is 41 terms, so it is cheap to finish, and its renderings are
reused across every other catalogue — it feeds both the controlled vocabulary the reports render and the
terminology sidebar every other component sees. Settling it first makes every later decision cheaper and
more consistent, and settling it *late* means terminology decisions arrive after the strings that needed
them. It previously shared 60 with reports; a tie is not what "first" means, which is why the cascade
was applied.

**Then the reports.** They are essentially what generates the impact of the whole NeoIPC Surveillance
project, and they have the greatest audience reach.

> **Unverified: that any of this orders anything.** The field accepts the values and reads them back, and
> its own help text says *"Components with higher priority are offered first to translators"* — but that
> is the claim, not evidence for it, and the sibling `priority:N` *string* flag carried an equally clear
> claim while ordering nothing (see [Priority within a component](#priority-within-a-component--intended-and-not-achievable-from-the-repository)).
> The mechanism here is different — a stored component field rather than a flag Weblate strips out of a
> file — so that failure does not implicate it, and naming that difference is still not proof. The only
> observable is the rendered project page, and that is a **human** interface: Hosted Weblate deliberately
> keeps automated clients out of its HTML, and the API — which is the machine interface, and is where every
> other finding in this document came from — returns components in creation order, so it cannot show the
> effect. Confirming this is therefore a person opening the project page and reading the order off it.
> Until someone has, treat the ordering as intended rather than established.

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

### Priority within a component — intended, and not achievable from the repository

Component priority is only half of it: the ordering above holds *between* catalogues, and two of them
have a further ordering *inside* them that component priority cannot express. That needs a per-string
priority.

**Writing `priority:N` into the `.pot` does not deliver it**, and `metadata` is the proof rather than
the exception. That catalogue carries 2,714 such flags (2,329 × `priority:10`, 293 × `priority:200`,
92 × `priority:150`), emitted by the metadata pipeline — and it orders nobody's queue, because those
flags reach the source units and stop there. So **no catalogue has a working within-component ordering
today**, including the one that looks configured. The measurements and the three-way confirmation are
above, under *Where each kind of fact lives*.

The route that does work is a **source-string extra flag** set through the web interface or the API,
which propagates to every language from one write. Its cost is that it lives in Weblate's database:
invisible in git, unreviewable in a pull request, and absent from a component recreated from scratch.
That argues for expressing an ordering as a *rule* — a Bulk edit add-on's query, which is small enough
to record here — rather than as thousands of individual writes that cannot be.

`po/reports.pot` and `po/infectious_agents.pot` carry zero `priority:N` flags, which is now the correct
state rather than an omission to correct: the flag would be inert there too. What follows is the
intended ordering, recorded so that whoever configures it does so deliberately rather than inventing it.

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
(`chore(l10n): …`), the other three then-existing components as near-copies of an older Weblate default.
All six are now identical everywhere and inherited from the project, which is also what a newly created
component gets by default, so a fifth one needs nothing done to it here.

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
