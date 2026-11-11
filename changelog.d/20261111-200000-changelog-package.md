type: Added

**`gt:changelog`**: a project's CHANGELOG made of fragments, one file per change in `changelog.d/`, as the toolkit's own. `release.ship` now assembles the fragments into the version's section and deletes them, instead of renaming `[Unreleased]`; it refuses a malformed fragment and a release with nothing in it. A hand-written `[Unreleased]` section is assembled too, after the fragments, and removed. `release.changelog_release` and `release.changelog_section` are gone: `changelog.assemble` and `changelog.section` replace them.
