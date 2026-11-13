# changelog.d

One file per change, assembled into `CHANGELOG.md` when a version is published. A branch adds its fragment here and
never edits `CHANGELOG.md` nor `src/ui/version.odin`: two branches never conflict on them.

A fragment is `changelog.d/<yyyyMMdd-HHmmss>-<subject>.md` (subject: lowercase letters, digits and `-`):

```
type: Added

**`ui.thing`**: what it does, in one entry (no leading "- ").
```

- `type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security` ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)): it picks the subsection.
- The text is one entry of the list, as it will read there. It may span lines; sub-items are indented `  - ` lines;
  no blank line, no heading.
- One change, one fragment. Two fragments may share a subject (the time keeps them apart).

The package `src/changelog` reads and assembles them ([docs/changelog.md](../docs/changelog.md)); a program made with the
toolkit keeps its own the same way, and `release.ship` assembles them.

`odin run tools/changelog -- -new -type:Added -subject:thing "-text:**...**: ..."` writes one;
`-Check` (CI) says whether they are all well formed and none was already released; `-Assemble` prints what the next
version brings. `odin run tools/tk -- release <patch|minor|major|x.y.z>` assembles them into a `## [<version>]` section, writes the version and
deletes them.
