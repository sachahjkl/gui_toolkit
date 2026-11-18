# Agent skills

Two skills teach a coding agent to work with the toolkit. opencode and Claude Code load them when a task needs them.
Each skill is a `SKILL.md` and the references it names: pages of this documentation and the plugin API's types,
copied when the skill is published.

| Skill | What it is for |
|---|---|
| `gt-plugin` | Writing, running and testing a plugin in JavaScript for a program of the toolkit, or a small application for gt-runtime: the manifest, views, lazy lists, settings, permissions. |
| `gui-toolkit` | Building or changing a program in Odin on the toolkit: where state lives, work off the interface's thread, the tests, the changelog, and which page of this documentation to read for each subject. |

Their sources are [skills/gt-plugin/SKILL.md](../skills/gt-plugin/SKILL.md) and
[skills/gui-toolkit/SKILL.md](../skills/gui-toolkit/SKILL.md).

## Install them in opencode

Add the site's catalog to `opencode.json`, in your project or in `~/.config/opencode/opencode.json`:

```json
{
	"skills": ["https://gt.sacha.house/skills/"]
}
```

opencode downloads the skills from there. The catalog's version is the toolkit's last release: opencode downloads
them again after each release.

Or unpack `gt-skills.zip` from the [latest release](https://github.com/sachahjkl/gui_toolkit/releases/latest) into
`~/.config/opencode/skills`. It holds the folders `gt-plugin/` and `gui-toolkit/`.

## Install them in Claude Code

Unpack `gt-skills.zip` into `~/.claude/skills` (all your projects), or into the `.claude/skills` folder of one project.

## Pin them to a version

The site's catalog is made from the toolkit's master branch, as the rest of the site. If your program pins an older
version of the toolkit, unpack the `gt-skills.zip` of that release: its references are the documentation of that
version.

## Make them

`odin run tools/tk -- skills <out>` writes the catalog into `<out>`. `-zip:<file>` writes the zip, and `-check`
checks the skills without writing. `tk site_build` writes the catalog to the site's `skills/` folder, and `tk demos`
writes `gt-skills.zip` for the release. The reasons are in
[src/md/infrastructure/skills.md](../src/md/infrastructure/skills.md).
