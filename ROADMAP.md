# Roadmap

## Now

- **Views, step 3: panels** — a view docks to an edge of its window or in a dock space of the program, with no tab strip when it is alone and its controls only on hover; the Dock items of the header's menu work, and the palette offers each view's moves. A dialog or an internal window dragged onto a dock target becomes a panel there, and a panel's tab dragged out becomes an internal window. Intent: [src/md/features/views.md](src/md/features/views.md), sections 2.5, 2.6 and 6.

## Next

- **Views, step 4: external windows** — a view opens in an OS window of its own and comes back to its home when that window is closed; Detach into a window works, and a drag out of the window opens one. Intent: [src/md/features/views.md](src/md/features/views.md), section 4.
- **The programs move to views** — papier, classeur, cliche, inspecteur, opencode native and Wren replace their dialogs, side panes and windows of their own with views, one program per release, the smallest first. Intent: [src/md/features/views.md](src/md/features/views.md), sections 1 and 7.

- **The toolkit's file picker in the showcase** — the file picker that opencode native's session is adding is shown in the fidget example and in the screenshots of the toolkit's site, with its description in the carousel.

## Later

- **Plugins in JavaScript** — a plugin builds its own screens and views, runs commands and reads settings through a dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
