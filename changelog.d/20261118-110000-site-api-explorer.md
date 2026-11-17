type: Added

**The plugin API explorer and a guide to gt-runtime on the site**: [gt.sacha.house/plugins/api/](https://gt.sacha.house/plugins/api/)
shows every call of each module with its TypeScript signature, its level and its permission, every node of a view with
its fields (the ones the host keeps marked as state), and what each level added. A search box filters the calls and
nodes; each has its own anchor (`#views.register`, `#node.field`); `gt.d.ts` downloads from the page. The page is made
from `plugin-api/api.json` at each build of the site, and the build fails when that file is missing or malformed.
"Plugins and gt-runtime" in the Docs says what a plugin is, its manifest, a first plugin, and the counter and todo demos
with their source. `api.json` gives each field a `state`.
