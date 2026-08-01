# Weblate access control

Who may do what in the `neoipc` project on Hosted Weblate: the roles that exist, the teams built from
them, and the parts of the API that will mislead you. Component settings are a separate matter and live
in [`weblate-component-configuration.md`](weblate-component-configuration.md); how a round trip is
performed is in [`localization-pipeline.md`](localization-pipeline.md).

## Role ids

Roles are referred to by **number** everywhere in the API, and nothing it returns will tell you which
role a number is. This table is the translation, read off the role picker in the web interface — the one
place that shows a name and its id together.

It lists the **sixteen roles a project team may hold**, which is what that picker offers. That is not the
whole role set, and the rest is only partly known — so take the picker as authoritative for what can be
granted, and treat the total as open. Three roles are visibly outside it because they are not
project-scoped: *Workspace administration* (id 19, the one value the API will confirm), *Add workspace
projects*, and *Add new projects*, which is presumably the id 20 held by the site-wide `Project creators`
team. Ids 15 and 16 exist in the sequence and appear in no project picker; what they are has not been
established, and nothing here needs them. An earlier revision put upstream's total at eighteen, which
these do not add up to — the number was never verified against upstream and is dropped rather than
patched.

| id | role | id | role |
|---|---|---|---|
| 1 | Add suggestion | **9** | **Review strings** |
| 2 | Access repository | 10 | Manage repository |
| 3 | Power user | 11 | **Administration** |
| 4 | Translate | 12 | Billing |
| 5 | Edit source | 13 | Manage translation memory |
| 6 | Manage languages | 14 | Automatic translation |
| 7 | Manage glossary | **17** | **Translation coordinator** |
| 8 | Manage screenshots | 18 | Bulk editing |

These are this instance's numbers. They are database keys, not an ordering anyone chose: they do not
match the order the roles appear in Weblate's source, where `Administration` is first and is id 11, and
`Power user` is sixth and is id 3. Do not derive one from the other, and do not assume they carry to
another instance.

Reading the upstream source is still worth doing — it is where each role's **permissions** are defined,
so it answers what a role actually grants, which no part of this instance will tell you. It just cannot
answer which number a role is. One trap when reading it: `Administration` is built from every permission
by comprehension rather than by listing them, so searching that file for `unit.review` finds the two roles
that name it and misses the one that holds it implicitly.

## Three roles can approve, and only one of them should

The distinction is invisible from the API — all three arrive as a bare number — and two of them look
alike from a distance:

| role | grants |
|---|---|
| **Review strings** (9) | approving translations, and nothing else. **This is the one a reviewer team wants.** |
| **Translation coordinator** (17) | approving, *plus* adding translations, deleting other people's suggestions, posting announcements, and repository access |
| **Administration** (11) | every permission in the project |

The language teams below were first built with 17 rather than 9, and nothing in any API response would
have revealed it — a team carrying either reads as `roles: ['.../17/']`. Check a number against the table
above before granting it, and re-read the team afterwards.

## Per-language reviewer teams

The documented shape for review by language is a team holding *Review strings* and restricted to the
language it reviews, because Weblate applies a team's languages separately when deciding who may review,
save or suggest. So a Spanish editor cannot approve German.

| field | value |
|---|---|
| Name | `Editors — <Language>` |
| Roles | `9` — Review strings |
| Project selection | explicit (`0`), the defining project |
| Language selection | explicit (`0`), the one language |
| Users | the editors for that language |

**There is no ready-made Review team here.** Weblate creates the default set — Administration, Review,
Translate, Sources and the rest — for *Protected* and *Private* projects. This project carries only
Administration, so a reviewer team is created rather than populated.

## Creating one through the API

Teams read and write through the API perfectly well; two things about it are not obvious, and the first
fails without complaining.

**`roles`, `languages`, `projects` and `components` are read-only on the group serializer.** A `POST` to
`/api/groups/` that includes them creates the team, applies `name`, `defining_project`,
`language_selection` and `project_selection` — and drops the rest. The result is a team that grants
nothing and restricts nothing while looking created. `OPTIONS /api/groups/` states this plainly for each
field; asking it first is cheaper than discovering it afterwards.

Attach them through the sub-resources instead, then read the team back:

```
POST   /api/groups/<id>/roles/       {"role_id": 9}
POST   /api/groups/<id>/languages/   {"language_code": "de"}
DELETE /api/groups/<id>/roles/<role_id>/
```

**A successful `DELETE` looks like a failure through `wlc`.** It answers `204 No Content`, the client
tries to parse a body that is not there, and raises *"Server returned invalid JSON"* over an operation
that worked. Judge it by re-reading the team, never by the absence of an exception.

**`/api/roles/` is not an inventory.** It returns three roles to a project token and refuses the rest by
id, which is why the table above exists.

## The review workflow, as configured

Reviews are on for translations and for source strings. Suggestions are on for every component,
auto-accept is off, and **voting is off**: with most languages at zero percent, two gates on a pipeline
with no throughput reads to a contributor as "nothing I do ever lands". Turn voting on for a language once
it has two or more active contributors, not before.

`state:translated` means translated but **not yet approved**, so that search *is* the review queue. The
first of these is the one to hand an editor:

```
https://hosted.weblate.org/search/neoipc/-/<lang>/?q=state%3Atranslated   one language, whole project
https://hosted.weblate.org/search/neoipc/?q=state%3Atranslated            every language
https://hosted.weblate.org/projects/neoipc/-/<lang>/                      that language's overview
```

**Approving is a deliberate act, not a side effect of saving.** It is logged as its own change, and a
reviewer's own save leaves a string *translated* rather than *approved* — established from the state
rather than from documentation, which is silent on it: a language holding approved and unapproved strings
side by side could not look like that if saving approved.

**Quote the right queue size when recruiting.** A raw count includes the organism nomenclature, which the
project instructions already handle by batch confirmation rather than string by string — so the honest
number for a prospective editor is the queue *without* the infectious-agent component, and it is a small
fraction of the total. Read the current figures before quoting any; they move with every drain.

## Recusal, because permissions cannot express it

`Administration` is project-wide and **not** language-scoped, so whoever holds it can approve any
language, including ones they cannot read. Weblate has no setting meaning "not your own translation", and
no combination of teams produces one — a reviewer team grants approval over a language, not over other
people's work within it.

So it is a stated convention, the way editorial recusal works in journals:

- **An editor does not approve their own translation.** Saving it is the contribution; approving it is a
  second person's judgement, and one person cannot be both.
- **Where a language has only one editor**, their own work stays *translated* and waits. That is the
  honest state — it says "nobody has read this yet", which is true — and it is better than an approval
  that means only that the translator approved of themselves.
- **A project administrator does not approve a language they cannot read.** The permission allows it; the
  convention is that it is used for mechanical corrections and never for language judgements.

The editor-facing statement of the same rule is in [`translating.md`](translating.md), which is what a
reviewer actually reads.

## Where a person does this

**Operations → Users → Access control** in the project menu. That is where team membership is managed,
and it is the only place a role's name and id are visible together.
