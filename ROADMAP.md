# Roadmap

## Now

- **The programs on the everything palette.** Each program calls `palette_chosen` before its content, names the
  elements its commands act through (`ui.act_name`, `command:<id>`) so Shift+Enter reaches them, and turns a dialog that
  asks one value into a command with arguments (opencode native's Rename the session and Set the model). Intent:
  [src/md/features/everything-palette.md](src/md/features/everything-palette.md).
- **opencode native and Wren drop their copies.** Each program is a thin layer over the toolkit: what it does again
  that the toolkit has goes. opencode native: its colour helpers, PNG read, JSON helpers, key/value rows, pill,
  spinner, time words, segmented control, model picker (the palette's `#` source). Wren: its re-exporting `config` and
  `i18n` packages, header parsing, size and duration words, JSON quoters and writer, crash bar and crash marker, command
  line (`gt:cli`), licence, install, diagnostics and update pages and its own updater, syntax colours, changelog and
  release tools. The smallest first; each session has the list with its files.
- **No black strip under machined buttons on Windows.** With partial redraw on, Windows 11 shows thin black strips just
  under a row of quiet machined buttons (atelier's Programs step); WebGPU on Linux draws the same scene exactly, so
  the cause is on the Direct3D 11 window's path. `tests/partial_redraw_layers` holds the scene, which the Windows CI runs.

## Next
- **Display titles and a vendor's folders.** Every program shows a capitalised title (Papier, Classeur, Inspecteur,
  Cliche, Atelier, Wren, Opencode Native) while its binary and package keep the lowercase name, and keeps its settings
  in its vendor's folder (`%APPDATA%\FromentSoftware\Papier`, `~/.config/FromentSoftware/Papier`), the old folders
  moved once. Intent: [src/md/features/folders.md](src/md/features/folders.md).
- **Every program on the spacing scale.** The toolkit's pages (settings, setup) and the programs lay out with the
  scale's roles, cards and list cards, and stop keeping values or scales of their own (atelier's `view.odin` holds one
  today). Intent: [src/md/features/spacing.md](src/md/features/spacing.md).
- **No graphics driver on Windows, tested.** A window whose hardware Direct3D 11 device is refused falls back to WARP,
  and a program without a console that cannot open its window says why in a message box; both are written and
  type-checked, not yet run. A test on the Windows CI (a fault that refuses the hardware device, a child started without
  a console) proves them. Intent: [src/md/infrastructure/no-graphics.md](src/md/infrastructure/no-graphics.md).
- **opencode native and Wren answer --quit.** As papier, classeur, inspecteur and cliche do, each gives
  `Setup_Options.quit` and takes `instance.MESSAGE_QUIT` in its handler (opencode native first takes a single instance):
  atelier then closes it cleanly before it installs it, in place of ending its process. Intent:
  [src/md/features/quit.md](src/md/features/quit.md).
- **What's new in opencode native and Wren.** As papier, classeur, inspecteur and cliche do since their 0.26 and 0.10,
  each gives its changelog to the settings (`Page_Options.changelog`) and calls `changelog_after_update` at start:
  after an update, a message that stays opens the page of what changed.
- **The last settings that programs copy.** opencode native drops `advanced.frame_rate` for the toolkit's
  `rendering.frame_rate` (`Standard_Targets.pacer`, since 0.269), and Wren its `browser.frame.*`; Wren drops its own
  text backend, emoji and renderer settings. (The
  desktop's and the motion's are the standard `Session` and `Appearance` sets; the window's place and the rows' look are
  the toolkit's since 0.265; an FPS display is opencode native's alone, so it stays its own.)
- **opencode native on the toolkit's pieces.** Its branch `toolkit-0.266` takes the toolkit's JSON, rich paste
  (`ui.paste_answer`: its menu's Paste attaches an image as Ctrl+V does), kept zooms (`store.Kept`), context menus
  (`ui.context_take`), window place and standard folders in place of its own; it waits for its merge and release.
- **One image decoder.** opencode native decodes pictures with the toolkit's `gt:image` instead of its Rust crate. The
  switch is written (`ocn-views/build/gt-image-only.patch`), and WebP is now inside the toolkit's native library on
  every system: it waits only for opencode native to move up from toolkit 0.266. Intent:
  [src/md/features/image-decode.md](src/md/features/image-decode.md).
- **Platforms that plug in and out, toward macOS.** The toolkit's packages compile for macOS in its CI (`tk ci`,
  `-check:darwin_arm64`), and every portable file names the system's facts, not the system (`SYSTEM_DIRECT3D`,
  `font.SYSTEM_RASTERIZER`); papier, classeur, inspecteur and cliche check theirs for macOS. What is left: opencode
  native and Wren check theirs. (The native library's links stay beside their `foreign` blocks, in
  `font/backend_native.odin` and `mermaid.odin`: a `foreign import` is its file's.)
- **Colours by intent in opencode native.** Its 85 `HEX_*` constants become the theme's intents and hues, so a theme
  changes them all, as cliche's graph colours do since its 0.8.

## Later

- **A path completes in the palette.** In the run mode of a `Path` setting or argument, Tab completes the folder typed
  from a read on a chore, as the file browser reads. Intent:
  [src/md/features/everything-palette.md](src/md/features/everything-palette.md).
- **OpenGL when Vulkan is missing.** On a Linux machine with OpenGL and no Vulkan driver (an old GPU, some virtual
  machines), a program draws through wgpu's GL backend instead of saying that it cannot. It waits for wgpu-native to
  take the display in its instance descriptor: today its GL instance has no backend on Linux. Intent:
  [src/md/infrastructure/no-graphics.md](src/md/infrastructure/no-graphics.md).

- **Image nodes for a second program.** cliche's node catalogue of image transformations moves next to `gt:flowgraph`
  when papier or classeur gets workflows of its own; the graph's add palette (`ui.flow_palette`, a right click, a link
  dropped in the void) is the toolkit's already.

- **Personal keys and aliases for every program.** Classeur's keys of one's own (Ctrl+Enter in its palette) and its
  aliases typed whole become the toolkit's, so a person sets a key or an alias for a command in any program, the same
  way. The toolkit has them; the programs move to them next. Intent:
  [src/md/features/keymap.md](src/md/features/keymap.md), "Migration".
- **Plugins in JavaScript.** A plugin builds its own screens and views, runs commands and reads settings through a
  dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit
  (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
- **Demo states injected.** A demo mode that injects states that need an account (an unlocked vault, a PIN asked), so
  a capture needs no temporary code change.
- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL and Vulkan only save about 1 MB for
  a harder build. Revisit only if gfx-rs publishes a reduced build.
