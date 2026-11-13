# release: a program's release

`import release "gt:release"` (the package is named `tk_release`). The steps of a release, the same on a laptop and in a
release workflow; a project's own tool (`tools/<tool>`) gives them its `Config` and calls them as its commands.

```odin
CONFIG :: release.Config{
	name = "classeur", repository = "https://github.com/sachahjkl/classeur",
	changelog = "CHANGELOG.md", version_file = VERSION_FILE, version_line = "APP_VERSION :: ",   // (the file of APP_VERSION)
	program = "build/classeur", dist = "build/dist",
	files = {{"README.md", "README.md"}, {"LICENSE", "LICENSE"}},
	check = run_check,
}
release.package_(CONFIG, args)   // <tool> package [version]
release.notes(CONFIG, args)      // <tool> notes <version>
release.ship(CONFIG, args)       // <tool> ship <patch|minor|major|x.y.z> [--dry-run]
```

| Step | What it does |
|---|---|
| `package_` | `<dist>/<name>-<version>-linux-x64.tar.gz` (stripped, mode 755, owner 0) or `<name>-<version>-windows-x64.zip`: the program and `files`, and `<archive>.sha256`. A version given (a tag, `v` or not) must be the sources'. |
| `notes` | The changelog's section of a version on the standard output: a GitHub release's notes. |
| `ship` | From a clean checkout (any branch, a worktree, a detached HEAD): the fragments checked (a malformed one stops it, and so does nothing to release), then `publish` (below): the number, the fragments assembled into `## [<version>] - <today>` with the version's link, the sources' version set, `check` run, a commit (the changelog, `changelog.d/` and the version file), the annotated tag `v<version>`, master and the tag pushed at once. `--dry-run` shows the section it would release. |

The changelog is made of fragments ([changelog.md](changelog.md)): a change adds its file to `changelog.d/`, beside
`Config.changelog`, and never edits the changelog. `ship` assembles them: the version's section, its link
(`<repository>/releases/tag/v<version>`), the fragments deleted. A changelog that still has an `## [Unreleased]` section
written by hand gets its entries in the version too, after the fragments', and loses the section.

A program that updates itself ([update.md](update.md)) gives its product in `Config.update`: `package_` then writes, beside
the archive, the program alone (`expected_file_name`, stripped on Linux as in the archive), what an installed copy downloads,
and its manifest and `.sig` (`manifest_name`), signed by `$UPDATE_SIGNING_KEY` ([toolbox.md](toolbox.md)). A release (a
version given) without the key is refused; a package without a version is not signed. The release workflow gives the key
as a secret and uploads `<dist>/*`.

The pure parts are there for a project's own steps: `version_of`, `version_set`, `semver`, `semver_newer`. The changelog's
are in `gt:changelog` ([changelog.md](changelog.md)).

A release workflow on a tag `v*` runs the project's checks, `package`, then `gh release create <tag> <dist>/* --notes-file`
with `notes`' output (classeur's and papier's `.github/workflows/release.yml`).

## publish: the number, the commit, the tag and the push

`release.publish(Publish)` is the end of every release, `ship`'s and the toolkit's own (`tk release`):

1. `git fetch --tags origin master`, then HEAD rebased on `origin/master` (a worktree or a detached HEAD works);
2. the version: `version_next(last, asked)`, `last` the highest tag `v<x.y.z>` (or `Publish.floor`, the sources' version, when
   no tag says more); `asked` is `patch`, `minor`, `major` or an exact `x.y.z`, which must come after `last`;
3. `Publish.write(version)` writes the release's files and gives the paths to commit and the subject (the checkout is reset
   when it fails);
4. a commit, the annotated tag `v<version>`, then `git push --atomic origin HEAD:refs/heads/master refs/tags/v<version>`.

When origin moved meanwhile (another session published), the atomic push is refused and nothing went out: the commit and
the tag are undone and it starts again at 1 with the next number, `Publish.tries` times (3). A tag is never published
without its commit on master. `Publish.no_push` stops after the tag.
