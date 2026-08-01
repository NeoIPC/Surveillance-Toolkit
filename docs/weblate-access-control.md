# Weblate access control

Who may do what in the `neoipc` project on Hosted Weblate: the roles that exist, the teams built from
them, and the parts of the API that will mislead you. Component settings are a separate matter and live
in [`weblate-component-configuration.md`](weblate-component-configuration.md); how a round trip is
performed is in [`localization-pipeline.md`](localization-pipeline.md).

## Role ids

Roles are referred to by **number** everywhere in the API, and nothing it returns will tell you which
role a number is. This table is the translation, read off the role picker in the web interface — the one
place that shows a name and its id together.

It lists the **sixteen roles a project team may hold**, which is what that picker offers. Upstream defines
**eighteen**; the difference is roles that are not project-scoped and so cannot be granted here at all —
*Workspace administration* (id 19, the one value the API will confirm), *Add workspace projects*, and
*Add new projects*, which is presumably the id 20 held by the site-wide `Project creators` team. Ids 15
and 16 exist in the sequence and appear in no project picker; what they are has not been established, and
nothing here needs them.

| id | role | | id | role |
|---|---|---|---|---|
| 1 | Add suggestion | | 10 | Manage repository |
| 2 | Access repository | | 11 | **Administration** |
| 3 | Power user | | 12 | Billing |
| 4 | Translate | | 13 | Manage translation memory |
| 5 | Edit source | | 14 | Automatic translation |
| 6 | Manage languages | | 17 | **Translation coordinator** |
| 7 | Manage glossary | | 18 | Bulk editing |
| 8 | Manage screenshots | | | |
| **9** | **Review strings** | | | |

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

## Where a person does this

**Operations → Users → Access control** in the project menu. That is where team membership is managed,
and it is the only place a role's name and id are visible together.
