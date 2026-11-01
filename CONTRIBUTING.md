# Contributing to gui_toolkit

## A change

- Every new function has its documentation (`docs/`), its test (`tests/`, [docs/testing.md](docs/testing.md)) and a CHANGELOG fragment.
- **CHANGELOG: one fragment per change in [changelog.d/](changelog.d/README.md)**, never an edit of `CHANGELOG.md`:

  ```
  changelog.d/20261026-143000-rich-paragraph.md
  ---------------------------------------------
  type: Added

  **`ui.rich_paragraph`**: mixed faces, code and links in one wrapping paragraph.
  ```

  `type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`; the text is the one entry, as it will read in the list.
  `odin run tools/changelog -- -new -type:Added -subject:rich-paragraph "-text:..."` writes it;
  `odin run tools/changelog -- -check` (run by the CI) checks every fragment.
- **The version is not a branch's business**: `ui/version.odin` and the README's badge say the last published version
  until the next one is published. A branch that needs a new version says so (in its pull request: "minor" when it adds
  or changes API, "patch" otherwise); `tools/changelog -check` fails when `ui/version.odin` differs from the last
  section of `CHANGELOG.md`.

## Publishing a version

`powershell -File tools\release.ps1 <version> ["one-line summary"]`, on a clean `master`:

1. `tools/changelog -assemble -version:<version>` makes the `## [<version>] - <date>` section from the fragments
   (by type, newest first), writes the version in `ui/version.odin` and the README's badge, and deletes the fragments;
2. the script commits that as `<version>: <summary>`, tags it `v<version>` (annotated), pushes `master` and the tag,
   and creates the GitHub release with the section as its notes (`tools/changelog -section -version:<version>`).

`-NoPush` stops after the tag, to look at the commit first. Semantic versioning: while the version is `0.x`, a minor
bump may change the API.

`tests/changelog` tests `tools/changelog` on a throwaway copy (malformed fragments, no fragment, two of
one subject, an assembled one left behind, a release).
