# Roadmap

## Now

- **Wren on the toolkit's palette and views.** Wren is the last program with a palette and dialogs of its own: its
  command registry feeds the toolkit's palette (its tabs under `@`, its history and bookmarks under `/`, its vault
  under `$`, `about:config` under `:`), and its bookmark, vault and security-key dialogs become views. Intents:
  [src/md/features/palette.md](src/md/features/palette.md), [src/md/features/views.md](src/md/features/views.md)
  (sections 1 and 7).

## Next
- **Every row of tabs on a strip.** The dock's stacks, classeur's tab rows and Wren's tab strip scroll with the
  toolkit's arrows when their tabs are too many, as `ui.tabs` and the views' stacks do; today they cut or scroll in their
  own way. Intent: [src/md/features/strip.md](src/md/features/strip.md).
- **No program blocks its interface's thread.** Each program's tests run its windows with the toolkit's blocking check
  on and fail when a disk, process or D-Bus call happens in a build, so the CI finds it.
- **The last settings that programs copy.** The toolkit gets standard Desktop, Accessibility and Diagnostics groups
  (fps, layout warnings, GPU profile, devtools) and one kept window placement that replaces the four copies in opencode
  native, inspecteur, classeur and papier. inspecteur's zebra rows and rules become appearance settings; Wren drops its
  own text backend, emoji and renderer settings.
- **Rich paste in the toolkit.** Pasting files, an image or text is decided once the clipboard's answers are in, the
  image decoded off the interface's thread; today the toolkit's paste knows only text, and opencode native does the rest
  itself.
- **One image decoder.** opencode native decodes pictures with the toolkit's `gt:image` instead of its Rust crate:
  `gt:image` reads GIF now, the program's switch is left. Intent:
  [src/md/features/image-decode.md](src/md/features/image-decode.md).
- **One JSON helper.** Reading and writing JSON goes through one toolkit package, used by the toolkit's own stores and
  exports and by opencode native, instead of three private helpers and a program's own.
- **Kept values per key.** A value kept per id in a file and forgotten at its rest value (opencode native's zoom per
  session) becomes a toolkit setting kept by key.
- **Context menus from opencode native in the toolkit.** The innermost target under the pointer takes the right click,
  one menu per kind of target, for every program; classeur drops its needless menu search options.
- **A table of widgets and their behaviours.** The table of widgets × behaviours (wheel, keys, Tab, accessibility,
  context menu, disabled, tooltip, Shift step, typed value, reset by double click), written down; each empty cell
  between two widgets of one concept is a bug or a written decision.
- **Small tools that programs still redo.** The toolkit keeps one way to test a point in a rect; Wren's dialog field
  becomes a line edit option for Enter and Escape; a menu opened under a button takes an alignment, so Wren's panel
  placement goes.
- **The rest of cliche's pieces.** Fonts per worker thread move into `gt:font`, cliche's timing marks join the
  renderer's trace, a host helper opens a hidden window ahead, toasts never cover a window's tool bar, and the toolkit
  offers deferred file writing.
- **Image nodes and the graph's keys in the toolkit.** cliche's node catalogue of image transformations moves next to
  `gt:flowgraph` for papier and classeur, and the node graph itself opens its add palette on Shift+A, a right click or a
  link dropped in the void.
- **Standard folders in every program.** opencode native's own config folder, papier's and classeur's runtime folder
  reads and inspecteur's autostart folders go through the toolkit's standard folders.
- **Wren logs through `gt:log`.** Wren writes its log through the toolkit, as the other programs do.
- **One native crate.** One native library with features replaces the toolkit's three native libraries, so no program
  links with multiple-definition flags.
- **Platforms that plug in and out, toward macOS.** The portable files that still test the system move that code into
  system files, and the CI checks every toolkit and program package for macOS, as it does for Windows.
- **Colours by intent everywhere.** inspecteur's heat cells use the toolkit's ink-on choice, and each program's
  hard-coded greens and reds become intents or hues.
- **Light site images in every program.** papier, classeur, inspecteur and cliche publish their site's pictures as WebP,
  as opencode native does.

## Later

- **Personal keys and aliases for every program.** Classeur's keys of one's own (Ctrl+Enter in its palette) and its
  aliases typed whole become the toolkit's, so a person sets a key or an alias for a command in any program, the same
  way. Intent: [src/md/features/palette.md](src/md/features/palette.md), "Decisions".
- **Plugins in JavaScript.** A plugin builds its own screens and views, runs commands and reads settings through a
  dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit
  (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
- **The host tests on Linux too.** The host tests run on Windows only: on Linux, windows without a screen get no
  renderer after a few tests in one process. Freed whole, the tests of a program's windows run on both systems.
- **Demo states injected.** A demo mode that injects states that need an account (an unlocked vault, a PIN asked), so
  a capture needs no temporary code change.
- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL and Vulkan only save about 1 MB for
  a harder build. Revisit only if gfx-rs publishes a reduced build.
