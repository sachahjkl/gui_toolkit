# Roadmap

## Now

- **Views, splits inside a dock zone** — a zone holds several stacks side by side, and a dock space can have its views in its centre, so that inspecteur's Mission Control keeps its eight panels laid out as today when it moves to views. Intent: [src/md/features/views.md](src/md/features/views.md), section 6.
- **An empty fill never takes a label's room** — in a row of a fixed width, an empty `fill()` spacer gives up its width before a label that can shrink is cut, so no program cuts a name for a spacer, as inspecteur's process names were.

## Next

- **The programs move to views** — papier, classeur, cliche, inspecteur, opencode native and Wren replace their dialogs, side panes and windows of their own with views, one program per release, the smallest first. Intent: [src/md/features/views.md](src/md/features/views.md), sections 1 and 7.
- **The intent and the roadmap in every program** — each program gets its `src/md` folder with the design notes it keeps today in `docs/`, and its `ROADMAP.md` with its entries of the global to-do file; each project's tool checks the roadmap's format.
- **The toolkit's file picker in the showcase** — the file picker that opencode native's session is adding is shown in the fidget example and in the screenshots of the toolkit's site, with its description in the carousel.

## Later

- **Plugins in JavaScript** — a plugin builds its own screens and views, runs commands and reads settings through a dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
