# The localization pipeline

How translatable text gets out of this repository, into Weblate, and back again — and the handful of
properties that make the round trip safe. Everything here was learned by breaking it, so each rule is
stated with the failure it prevents rather than as a preference.

Companion documents: [`weblate-component-configuration.md`](weblate-component-configuration.md) holds the
canonical per-component settings and a reason for every deviation;
[`weblate-checks-adoption.md`](weblate-checks-adoption.md) holds the per-catalogue decision on quality
checks. This document is about the *process*: who writes what, and how a round trip is performed without
losing translations or wedging a component.

## Ownership: one writer per file

The repository owns the `.pot` templates. Weblate owns the `.po` translations and is their **only**
writer.

| Catalogue | Owner |
|---|---|
| `po/reports.*.po` | Weblate |
| `po/documentation.*.po` | Weblate |
| `po/infectious_agents.*.po` | Weblate |
| `po/metadata.*.po` | Weblate |
| `po/glossary.*.po` | Weblate |
| `po/antibiotics.*.po` | repository — its licence bars it from Hosted Weblate's free plan |
| `scripts/po/*.po` | repository — its mechanism is unsuitable for community translation |

Two writers on one `.po` is not a merge inconvenience; it conflicts **every language of a catalogue at
once**, because both sides rewrite adjacent header lines inside a single hunk git cannot auto-merge. That
is why `Invoke-Localization.ps1 -Update` restores every Weblate-owned catalogue from `HEAD` after po4a
runs, and refuses to start when one is already dirty.

The same rule governs the header contract: a field the repository cannot keep true is left out of the
files it writes, and a field Weblate refreshes is left alone in the files Weblate writes. See
`POT-Creation-Date` in `scripts/modules/NeoIPC-Tools/Private/PoHeader.ps1` for the worked case.

## A drain, and why it is not a batch operation

A **drain** moves translations from Weblate into `main`: commit → push to `weblate-<catalogue>` → open a
pull request → **squash**-merge it → delete the branch.

The critical property is that a pushed `weblate-<catalogue>` branch is **perishable**. Two independent
events invalidate it, and after either one the branch carries a commit Weblate no longer holds:

1. **Anything committed in that component.** The Squash add-on regroups the entire un-merged range on
   every commit cycle, so the earlier commits are rewritten rather than appended to. In practice this
   means roughly *any translated string* — a translator saving work invalidates a branch pushed minutes
   earlier.
2. **Any movement of `main` at all.** Weblate pulls and rebases its pending commits onto the new tip,
   minting new identities. The component need not be involved: a pull request touching no catalogue
   whatsoever invalidates every open `weblate-*` branch in the project.

Trigger 2 is the one with teeth, because it makes drains **strictly serial**. Merging one drain moves
`main`, which invalidates the other three. Four branches pushed together cannot be merged together, and
attempting it merges commits Weblate no longer holds — after which Weblate cannot prove `main` already
contains its work, replays it, and conflicts across every component simultaneously.

So: **push a Weblate branch only when you intend to merge it promptly**, and handle one component per
merge cycle.

### The procedure

Lock the component being drained, and only that one. Locking removes trigger 1 for it; nothing removes
trigger 2, which is why the verification sits immediately before the merge rather than in a batch
beforehand. The others need no lock, because none of them can supersede this branch: every component is
standalone and so holds its own checkout, and each push branch carries its own catalogue's files alone —
so nothing committed elsewhere is in this branch or in this component's export. Locking them as well
would freeze every translator in the project for the length of somebody else's drain.

```
for each component, one at a time:
    lock it                     # removes trigger 1; the unlock must be guaranteed, including on abort
    force-update weblate-<catalogue> to Weblate's current tip
    wait for checks to settle
    wait for the approval                           <- under the lock, not between two invocations
    re-verify: branch tip == Weblate's tip          <- immediately before merging, not earlier
    squash-merge                                    <- refusing a branch that carries more than one commit
    confirm the head branch is gone
    let Weblate pull the new main and settle
    unlock it
```

`scripts/sync-weblate.py` implements exactly that loop; `drain <component>` is one invocation and does
the whole cycle, and `status` reports where every component stands without touching anything. It covers
**every git-backed component in the Weblate project**, not only this repository's — which repository
backs each one is read from Weblate per component, so a catalogue living in another repository (the app's
`i18n/*.po`) is drained the same way and by the same command. The filter is on that backing, so the one
component it does not list is the Weblate-local terminology store, which has no repository behind it and
nothing to drain; asking it to act on that one answers `unknown component`, which reads as a typo. The account it runs as needs push rights on whichever
repository that is. Run the
drain as the **automation account** rather than as yourself: a repository that requires an approving
review will not let an account approve a pull request it opened, so a drain run as the maintainer can
only be merged by overriding branch protection, while one opened by the automation account is approved
normally. The tool prints which identity it is acting as before it writes anything.

One consequence of that account has to be handled by hand: it holds no Copilot entitlement, so a review
request is accepted and then silently dropped. The tool detects that and says so instead of claiming it
asked — when it does, request the review yourself. It also declines to ask at all for a pull request past
Copilot's limits of 300 files or 20,000 lines, which most translation drains exceed.

Weblate's own tip is readable without fetching objects, which matters because fetching its export into a
clone that holds the superseded commits fails object negotiation:

```sh
git ls-remote https://hosted.weblate.org/git/neoipc/<component>/ refs/heads/main
```

Locking is a deliberate step here, not merely something that happens to a component on error. The unlock
must be structural rather than remembered: a component left locked is invisible to the maintainer and
silently blocks every translator, which is how a lock outlived its incident once already.

**The approval is waited for under that lock, in the same run that merges, and there is no way to split
it.** A pull request the drain opened itself needs someone else's approval, and splitting that across two
invocations — approve after the first, merge in a second — puts a person's attention span inside the
window the lock exists to close. Anything committed in that gap re-squashes the range, so the merging run finds the branch
superseded and recreates it — which deletes the head branch, closes the approved pull request, and
spends the approval on something that no longer exists. The operator learns this from the forge refusing
the merge for want of a review, which describes the symptom and not the cause. So the merging run holds
the lock and waits, and when it does have to replace an approved-but-superseded request it says so
rather than discovering it later.

## Verifying a drain

A drain must never lose a translation, and **line counts cannot show that** — Weblate re-wraps and
re-orders freely, so a diff of tens of thousands of lines routinely contains no semantic change at all.
One drain here was a net deletion of ~1,700 lines per file and changed nothing but line wrapping.

Compare entries, not lines. "Was translated before, is not now" is **not** by itself a regression: when a
source string changes, its unit ceases to exist and a new one replaces it. Three outcomes, and only two
of them are defects:

| Outcome | Meaning | Verdict |
|---|---|---|
| **gone** | the msgid is absent from the new catalogue | source string changed — expected |
| **demoted** | the msgid is still present but now needs editing | needs an explanation |
| **emptied** | the msgid is still present but its translation is empty | a real loss |

Reporting *gone* as loss is a live trap: one drain here showed 159 apparent "losses" in German and
Spanish, every one of them a msgid retired by a source-string change in the same release, with zero
demoted and zero emptied.

When reading a catalogue programmatically, exclude obsolete (`#~`) entries. `polib` iterates them, and
counting them produces defects that cannot ship — an audit here reported a live defect that turned out to
be an obsolete entry.

## Recovering a diverged component

If a component ends up unable to rebase — a stale branch was merged, a branch was force-pushed, a race
was lost — the remedy is Weblate's **Reset and reapply** (`reset-keep`). It is non-destructive: it
re-derives the checkout from `main` and re-applies pending translations on top. Nothing is lost, because
whatever was merged is already on `main` and what Weblate discards is a redundant copy of it.

Never hand-edit a catalogue to resolve this, and never reach for a plain `reset`, which is destructive.
The cost of a lost race is a locked component plus one reset — a nuisance, not damage.

## Merging: squash, and check the message

Pull requests raised from a `weblate-<catalogue>` branch are squashed like every other pull request
here. **Refuse one whose branch carries more than one commit.**

One commit is what makes a squash safe. Squashing it reproduces its patch exactly, so Weblate still
recognizes its own work as merged and drops it on the next rebase. Several commits fuse into a patch
matching none of them, and Weblate replays work it can no longer prove had landed — conflicting across
every component, not just the one merged. That is what squash-merging three translation pull requests
did on 2026-07-27, and it is why the count is checked rather than assumed: the Squash add-on collapses
each push to one commit, but that is a setting, not a law.

**Read the pre-filled message before confirming.** On a single-commit branch it is that commit's own
message, so it needs no rewriting — but `append_trailers` credits Weblate's own service account as a
co-author, and the squash is the only point at which that trailer can be dropped. A tool is not a
contributor. Which identities those are is recorded in `po/non-human-identities.yaml`, matched on
address rather than display name, because one address appears there under several names.

**Delete the head branch on merge.** A squash merge rewrites SHAs, so the pushed tip stops being an
ancestor of `main`, Weblate's next push is rejected as non-fast-forward, and with *Lock on error* enabled
that rejection locks the component against translators.

## Uploading a catalogue

Occasionally a catalogue needs a mechanical correction that no translator should have to make by hand —
an identifier embedded in translated text that a source change renamed, for instance. Upload it to
Weblate rather than committing it; committing is what the ownership rule forbids, and Weblate would
overwrite it regardless.

Choose the method by what is being asserted:

- **`--method translate`** marks the entries translated. Use it only where the translation is a prior
  human decision being carried across a mechanical change, not where anything about the wording is new.
- **`--method fuzzy`** updates the text and leaves the entry needing review. Use it wherever the
  correction is mechanical but the language has not been reviewed — for example correcting a catalogue in
  a language nobody available can vouch for. It changes nothing about the review state, so it asserts
  nothing.
- **`--conflicts replace-translated`** replaces translated entries but not approved ones. Prefer it to a
  blanket overwrite.

**`wlc` exits silently on success and on having matched nothing.** A zero exit is not evidence the upload
landed. Verify by downloading the catalogue back and comparing entries, and by reading the per-language
statistics before and after — the counts should move by exactly the number of entries sent.

An upload matches on `msgid`, so an entry whose source string has since changed matches nothing and is
silently dropped. Check a prepared file against the live catalogue before sending it: two entries in one
73-entry upload here targeted msgids that a spelling fix had already retired, and would have vanished
without a word.

## Rendering a translated document

po4a writes a translated source into `doc/protocol/<language>/`, so a localized build renders a document
that sits **one directory below** the untranslated one. Everything the document reaches by a relative path
therefore means something different, and the references split into two classes that do not share a root:

| class | lives at | reached by |
|---|---|---|
| **localized** — the protocol, its definitions, the generated antibiotic and infectious-agent lists | `doc/protocol/<language>/` | `{locale-dir}`, which the build sets to the language, or `.` for the untranslated source |
| **shared** — the header, `img/`, the PDF theme | `doc/protocol/` | plain relative paths, kept working by asciidoctor's `--base-dir` |

Picking one root breaks the other class, and it breaks it *quietly*: with only `--base-dir`, a German
build reads the **English** definitions and the English appendix lists and renders perfectly; with only
the culture directory, it finds no images and no header. Both roots are passed on every render.

`--base-dir` is what makes the shared half work, because it sets `{docdir}`, and `{docdir}` is what a
relative include and `imagesdir` resolve against. That is worth knowing precisely, since the
documentation does not say it and the behaviour is easy to get backwards: rendering `root/sub/doc.adoc`
with `--base-dir root` reports `docdir=<…>/root` and resolves `include::header.adoc` to `root/header.adoc`.
It governs output paths too, so `-D` and `-o` are passed absolute — a relative output directory would
land under `doc/protocol/`.

Two consequences that are not obvious from the switches:

- **`lang` must be passed to the renderer**, not merely computed. The document keys two things on it —
  asciidoctor's own caption translations in `doc/locale/attributes-<lang>.adoc`, and the localized title
  page and watermark — and a build that omits it produces a document in the target language with English
  captions and an English cover, with no diagnostic anywhere.
- **A fragment that a document `include`s carries `--keep 0`**, while the document itself keeps the
  threshold. The threshold decides whether a translation is fit to publish, and that is a judgement about
  the document, not about each fragment it assembles. German sits at 91.89 % overall and one of its
  definitions holds two untranslated strings; at the shared threshold po4a withholds that file and the
  whole German build fails on a missing include. Withholding a fragment protects nobody — it only decides
  whether the reader gets that paragraph in English or gets no document at all.

**The set of rendered cultures is asserted, not observed.** `Build-NeoIPCCoreProtocol.ps1` compares what
it discovered against `po/documentation.po4a.cfg`, the one witness to where a translated source lives that
is independent of the build's own convention — comparing discovery against the filesystem it just read
would establish nothing. It fails when the config declares a translated protocol that exists and discovery
did not find it, and it names the languages held below the threshold on every run. Both halves exist
because this failed silently for seven months: po4a moved its output into subdirectories, the builder kept
globbing the flat name nothing writes any more, and a build that renders one culture exits exactly like
one that renders ten.
