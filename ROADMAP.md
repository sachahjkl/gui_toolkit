# Roadmap

## Now

- **One command palette for every program.** One toolkit palette, the same look, keys and prefixes in every program,
  fed by sources: a prefix chooses what is searched (commands, sessions, models, history, paths, tabs), a source may be
  asynchronous (its list read off the interface's thread, ranked off it when large), and a row can be more than a
  command (a title, a detail, an icon, a checked or active mark). opencode native's palette with its prefixes and
  Wren's own registry and palette become sources of it and go; what helps one program helps all, and opencode native
  may change where the shared palette is more consistent. The intent comes first.

## Next

- **Wren moves to views.** Wren's bookmark, vault and security-key dialogs become views, as in the other programs.
  Intent: [src/md/features/views.md](src/md/features/views.md), sections 1 and 7.
- **No program blocks its interface's thread.** Each program's tests run its windows with the toolkit's blocking check
  on and fail when a disk, process or D-Bus call happens in a build, so the CI finds it.
- **The last settings that programs copy.** The toolkit gets standard Desktop, Accessibility and Diagnostics groups
  (fps, layout warnings, GPU profile, devtools) and one kept window placement that replaces the four copies in opencode
  native, inspecteur, classeur and papier. inspecteur's zebra rows and rules become appearance settings; Wren drops its
  own text backend, emoji and renderer settings.
- **Rich paste in the toolkit.** Pasting files, an image or text is decided once the clipboard's answers are in, the
  image decoded off the interface's thread; today the toolkit's paste knows only text, and opencode native does the rest
  itself.
- **One image decoder.** opencode native decodes pictures with the toolkit's `gt:image` instead of its Rust crate;
  `gt:image` gains GIF first.
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

- **Plugins in JavaScript.** A plugin builds its own screens and views, runs commands and reads settings through a
  dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit
  (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
- **The host tests on Linux too.** The host tests run on Windows only: on Linux, windows without a screen get no
  renderer after a few tests in one process. Freed whole, the tests of a program's windows run on both systems.
- **Demo states injected.** A demo mode that injects states that need an account (an unlocked vault, a PIN asked), so
  a capture needs no temporary code change.
- **Test pitfalls written down.** Running `odin test` by hand on a package that draws text fails without the test
  runner's embedded fonts: the testing guide says so, or the runner makes it impossible to miss.
- **A naming rule for packages.** The contributing guide states it: a package whose name a core package or a program
  can take is named with the toolkit's prefix.
- **Windows hidden files in the file browser.** The file browser hides only names that start with "." on Windows; it
  reads the system's hidden attribute instead. See [src/md/features/file-browser.md](src/md/features/file-browser.md).
- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL and Vulkan only save about 1 MB for
  a harder build. Revisit only if gfx-rs publishes a reduced build.
