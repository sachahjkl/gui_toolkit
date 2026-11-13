# changelog: a CHANGELOG made of fragments

`import changelog "gt:changelog"` (the package is named `tk_changelog`; a tool imports it by a relative path). A project's
`CHANGELOG.md` is made of fragments: one file per change in `changelog.d/`, beside `CHANGELOG.md`. A branch adds its
fragment and never edits `CHANGELOG.md` nor the version, so two branches never conflict on them. When a version is
published, `assemble` writes the fragments into that version's section and deletes them. Pure Odin with `core:os`.

A fragment is `changelog.d/<yyyyMMdd-HHmmss>-<subject>.md` (subject: lowercase letters, digits and `-`):

```
type: Added

**`ui.thing`**: what it does, in one entry (no leading "- ").
```

- `type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security` ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)).
  It gives the subsection.
- The text is one entry of the list, as it will read there. It can span lines. Sub-items are indented `  - ` lines. It has
  no blank line and no heading.
- One change, one fragment. Two fragments can share a subject: the time keeps them apart.

`CHANGELOG.md` follows Keep a Changelog: `## [x.y.z] - yyyy-mm-dd` sections, newest first, and the versions' links at its
end. It has no `## [Unreleased]` section: the fragments are what is not released.

```odin
o := changelog.Options{
	root = ".",                                                     // CHANGELOG.md and changelog.d/ ("": the current folder)
	link = "https://github.com/owner/repo/releases/tag/v%s",        // a version's link ("": none)
	version = read_version, set_version = write_version,           // optional: where the project keeps its version
	user = &project,                                                // what version and set_version get
}
path, why := changelog.new_fragment(".", "Added", "thing", "**`ui.thing`**: what it does.")
errors, fragments := changelog.check(o)              // every fragment well formed, none already released (CI)
ready, _ := changelog.check(o, "1.4.0")              // and ready to tag 1.4.0: no fragment left, its section there
text, problems := changelog.preview(".")             // what the next version brings ("": nothing)
entries, refused := changelog.assemble(o, "1.4.0")   // the release: today's date, or `date = "2026-11-11"`
body, ok := changelog.section(".", "1.4.0")          // the body of that version's section: a release's notes
```

| Procedure | What it does |
|---|---|
| `new_fragment(root, type, subject, text, when_ = {})` | Writes a fragment and returns its path, or why not. The subject is made from `subject`, or from the text's bold part. |
| `check(o, release = "")` | The problems and the number of fragments. A fragment is malformed, already in a released section, or the same text as another. With `Options.version`: the version in the sources differs from the last released one (a branch never writes it). With `release`: fragments are left, or the newest section or the sources' version is another one. |
| `preview(root)` | The body that `assemble` writes, without writing it. |
| `assemble(o, version, date = "")` | Refuses a malformed fragment, a version that is not `x.y.z`, a version already released, and nothing to publish. Otherwise: the section `## [<version>] - <date>` above the newest one, by type in the order above and newest fragment first, the version's link before the other links, `Options.set_version` called, the fragments deleted. |
| `section(root, version)` | The body of a version's section, without the links at the end of the file. `ok` is false when the section is not there. |

`Options.version` is `proc(root: string, user: rawptr) -> string` and `Options.set_version` is `proc(root, version: string,
user: rawptr) -> bool`; each gets `Options.user`.

## The changelog command of a project's tool

`command(project) -> toolbox.Command` is the `changelog` command of a project's tool ([toolbox.md](toolbox.md)), over its
`toolbox.Project` (copied): the changelog beside `Project.changelog`, the versions' link from `Project.repository`, and the
version line, which `check` compares with the last released version. `project_options(&project)` gives these Options.

| Line | What it does |
|---|---|
| `changelog new <type> <text> [-subject:<subject>]` | One fragment (`new_fragment`); its name from the subject, else from the text. Exit code 1 when the type or the text is refused. |
| `changelog check` | Every fragment well formed, the sources' version the last released one (`check`). |
| `changelog preview` | What the next version brings (`preview`). |

Another line is refused with exit code 2.

## A changelog written by hand

A project from before the fragments can still have an `## [Unreleased]` section with `### Added`, `### Fixed`... and its
entries. `check` and `preview` read it, and `assemble` puts its entries into the new version after the fragments' entries of
each type. Then `assemble` removes the `[Unreleased]` section and its link. An entry outside a subsection, or a subsection
that is not one of the six types, is a problem of `check`, and `assemble` refuses it.

## Users

- `tools/changelog`: the toolkit's own fragments on the command line (`-new`, `-check`, `-assemble`, `-section`), with its
  version in `src/ui/version.odin` and the README's badge as `set_version`.
- `release.ship` ([release.md](release.md)): a program's release assembles its fragments.
