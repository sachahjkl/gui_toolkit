# Agent skills

Asked by the user on 2026-11-18. Two skills, `gt-plugin` and `gui-toolkit`, in `skills/<name>/SKILL.md`, published by
`tk skills` (`tools/tk/skills.odin`) as an HTTP catalog on the site and as `gt-skills.zip` in each release. How to
install them: [docs/skills.md](../../../docs/skills.md).

## Purpose

The toolkit's aim is an agent that writes a screen on the fly ([features/plugins.md](../features/plugins.md), "The
toolkit as a runtime"). An agent that does not know the API writes a web page, a Node module or a layout of its own.
A skill gives it the method and the rules at the moment the task starts, and points it to the generated types and the
guides for the rest.

## Decisions

- **Two skills, by reader.** A plugin's author writes JavaScript against `gt.d.ts` and never sees Odin. A program's
  author writes Odin against `ui`, `host` and the tests. Their tasks, their pitfalls and their references do not
  overlap. The description is what an agent sees before it loads a skill: one description for both would trigger on
  every Odin task with the plugins' text, and on every plugin task with the threads' rules.
- **The references are copied when a skill is published, never kept in the repository.** `tk skills` reads each
  `references/<file>` that a `SKILL.md` names and copies its source at that moment: `docs/<file>`, or a source of
  `SKILL_SOURCES` (`gt.d.ts` from `plugin-api/`). So a reference is the page of the same commit. A copy committed beside
  the skill would be a second version of a page that some change forgets.
- **A reference with no source is an error**, in `tk ci` (`skills -check`). A page renamed in `docs/` fails the check
  of the change that renamed it, not the release.
- **A skill is an index with a method, not a summary of the docs.** It holds what the docs do not say in one place:
  the order of the work, the rules that break a program on its first day, and the page to read per subject. What a page
  says stays in the page. A skill that repeats the docs drifts from them at their first change.
- **The level is checked.** gt-plugin names the plugin API's level in one fixed form ("API level" and its number), and the check
  compares it with `PLUGIN_API_LEVEL`. A level raised without the skill fails `tk ci`. The fixed form is what makes a
  plain text checkable: any other mention says "level 4", without "API".
- **An HTTP catalog with the toolkit's version.** opencode reads a catalog's `index.json` and keeps the files in a
  cache until a skill's `version` changes. The version is `ui.VERSION`, read from `src/ui/version.odin`: each release
  makes opencode download the skills again, with no number of their own to keep. The site is the catalog
  (`https://gt.sacha.house/skills/`), written by `site_build`, so one line of `opencode.json` installs them.
- **The zip is made beside the demos** (`tk demos`, the Release workflow), from the release's tag. Its root holds the
  skill folders, so it unpacks as it is into `~/.config/opencode/skills` or `~/.claude/skills`. It has no `index.json`:
  a folder of skills has none.
- **The frontmatter is checked as YAML would read it.** opencode and Claude Code parse it as YAML. A description with
  `": "` or `" #"` is another YAML value, or none: the check refuses it rather than quote it, so the file stays plain.
  The name must be the folder's: both programs take the skill's id from the folder.
- **A skill is published on purpose.** `SKILLS` lists the skills. A folder of `skills/` that is not in the list is an
  error, so a draft never reaches the catalog.

## Subtle points

- The site is built from master. Between two releases its catalog can hold newer pages under the last release's
  version, and opencode keeps the files it has until the next release. A program pinned to a version takes the zip of
  that release.
- A reference's links to other pages work only when that page is a reference of the same skill. A link out of `docs/`
  (`../src/md/...`) does not resolve in the copy. The agent can still read the toolkit's checkout when it has one.
- `SKILL.md` names its references in code spans, not as Markdown links: `tk doc_check` checks every link of a tracked
  Markdown file, and `references/` exists only in the published copy.

## Refused

- **One skill for the toolkit.** See "Two skills, by reader".
- **The references copied into the repository.** See "The references are copied when a skill is published".
- **A skill that repeats the docs.** See "A skill is an index with a method".
- **A version of the skills' own.** It would need a rule for when to raise it. The toolkit's version changes at each
  release, which is when the references change.
