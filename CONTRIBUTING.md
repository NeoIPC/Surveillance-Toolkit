# Contributing

Thank you for wanting to help. There are two routes in, and which one you need depends entirely on
whether you are changing **translations** or anything else.

## Translations go through Weblate

**[hosted.weblate.org/projects/neoipc](https://hosted.weblate.org/projects/neoipc/)** — sign in, pick your
language, and start. No git, no pull request, no local checkout.

If you are new to translating this project, read **[`docs/translating.md`](docs/translating.md)** first. It
covers what each catalogue is for, the markup you will meet and must carry through unchanged, and how
review works here.

**A pull request that edits a translation catalogue will be closed**, and continuous integration rejects
it before a human sees it. That is not gatekeeping: Weblate is the only writer of those files, and a
second writer conflicts *every language of a catalogue at once*, because both sides rewrite adjacent
header lines in a single hunk that git cannot merge. It has happened, and it takes the whole project down
rather than one file. The catalogues Weblate owns are:

```
po/reports.<lang>.po        po/documentation.<lang>.po      po/infectious_agents.<lang>.po
po/metadata.<lang>.po       po/glossary.<lang>.po
```

**One catalogue you can translate is the opposite case** and a pull request is exactly right for it,
because it is not on Weblate at all: `po/antibiotics.<lang>.po`, whose source content is under a licence
that Weblate's free hosting does not accept, so it stays here.

There is a second catalogue outside Weblate, `scripts/po/*.po`, and it is **not** open for translation by
anyone — the messages in it are consumed by a mechanism that is not safe to feed community-supplied text,
which is why it was never registered. It is listed here only so its absence from the block above does not
read as an oversight. Please do not send translations for it.

## Everything else goes through a pull request

Code, documentation, protocol text, report layout, tooling. Fork, branch, open a pull request against
`main`. Requests are squash-merged, so a tidy commit-by-commit history on your branch is not something you
need to worry about.

**If a source string is wrong** — ambiguous, a typo, or impossible to translate well — that is a source
change rather than a translation one, so it belongs here rather than in Weblate. Saying so in a comment on
the string in Weblate is just as welcome; someone will carry it across.

## Licensing

The repository's terms are in [`LICENSE`](LICENSE). Some directories carry their own, narrower terms for
content taken from an external source; where they do, a `LICENSE.md` sits beside the content and says so.

Translations contributed through Weblate are published under **CC BY 4.0**, and Weblate shows you the full
contributor agreement before your first contribution. Please read it rather than clicking through: it
explains what becomes a permanent part of the public git history, including the name and e-mail address on
your Weblate account.

## Questions

Comment on the string in Weblate if it is about a particular string — that reaches the people who can
answer and stays attached to what it is about. Otherwise: **NeoIPC-Support@charite.de**.
