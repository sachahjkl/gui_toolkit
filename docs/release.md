# release: a program's release

`import release "gt:release"` (the package is named `tk_release`). The steps of a release, the same on a laptop and in a
release workflow; a project's own tool (`tools/<tool>`) gives them its `Config` and calls them as its commands.

```odin
CONFIG :: release.Config{
	name = "classeur", repository = "https://github.com/sachahjkl/classeur",
	changelog = "CHANGELOG.md", version_file = "src/main.odin", version_line = "APP_VERSION :: ",
	program = "build/classeur", dist = "build/dist",
	files = {{"README.md", "README.md"}, {"LICENSE", "LICENSE"}},
	check = run_check,
}
release.package_(CONFIG, args)   // <tool> package [version]
release.notes(CONFIG, args)      // <tool> notes <version>
release.ship(CONFIG, args)       // <tool> ship <version> [--dry-run]
```

| Step | What it does |
|---|---|
| `package_` | `<dist>/<name>-<version>-linux-x64.tar.gz` (stripped, mode 755, owner 0) or `<name>-<version>-windows-x64.zip`: the program and `files`, and `<archive>.sha256`. A version given (a tag, `v` or not) must be the sources'. |
| `notes` | The changelog's section of a version on the standard output: a GitHub release's notes. |
| `ship` | From a clean `master`: `[Unreleased]` becomes `[<version>] - <today>` with a new empty `[Unreleased]` above it and the version's link at the end, the sources' version set, `check` run, then a commit, the annotated tag `v<version>` and the push. `--dry-run` shows the section it would release. |

The pure parts are there for a project's own steps: `version_of`, `version_set`, `semver`, `semver_newer`,
`changelog_release`, `changelog_section`.

A release workflow on a tag `v*` runs the project's checks, `package`, then `gh release create <tag> <dist>/* --notes-file`
with `notes`' output (classeur's and papier's `.github/workflows/release.yml`).
