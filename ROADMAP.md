# Roadmap

## Now

- **Wren on the toolkit's licence card.** Wren shows `ui.licence_card` and the shop's thank-you page, as every other
  program does since this toolkit version, and drops its `about_card*.odin` and its card shaders: one card. Intent:
  [src/md/features/licence-card.md](src/md/features/licence-card.md).
- **opencode native and Wren drop their copies.** Each program is a thin layer over the toolkit: what it does again
  that the toolkit has goes. opencode native: its colour helpers, PNG read, JSON helpers, key/value rows, pill,
  spinner, time words, segmented control, model picker (the palette's `#` source). Wren: its re-exporting `config` and
  `i18n` packages, header parsing, size and duration words, JSON quoters and writer, crash bar and crash marker, command
  line (`gt:cli`), licence, install, diagnostics and update pages and its own updater, syntax colours, changelog and
  release tools. The smallest first; each session has the list with its files.

## Next
- **Wren's profile in its vendor's folder.** As papier, classeur, inspecteur, cliche, atelier and opencode native
  do, Wren keeps its profile in `<config>/FromentSoftware/Wren` (today `<config>/Wren`), its old folder moved once
  (`user_dirs_move`). Intent: [src/md/features/folders.md](src/md/features/folders.md).
- **Every program on the spacing scale.** Atelier (its own scale in `view.odin`), opencode native and Wren stop
  keeping values or scales of their own, as papier, classeur, inspecteur and cliche already do. Intent:
  [src/md/features/spacing.md](src/md/features/spacing.md).
- **Wren answers --quit.** As papier, classeur, inspecteur, cliche and opencode native do, it gives
  `Setup_Options.quit` and takes `instance.MESSAGE_QUIT` in its handler: atelier then closes it cleanly before it
  installs it, in place of ending its process. Intent: [src/md/features/quit.md](src/md/features/quit.md).
- **What's new in Wren.** As the other programs do, it gives its changelog to the settings (`Page_Options.changelog`)
  and calls `changelog_after_update` at start: after an update, a message that stays opens the page of what changed.
- **The last settings that Wren copies.** Wren drops its `browser.frame.*` for the toolkit's `rendering.frame_rate`
  (`Standard_Targets.pacer`, since 0.269), and its own text backend, emoji and renderer settings. (The
  desktop's and the motion's are the standard `Session` and `Appearance` sets; the window's place and the rows' look are
  the toolkit's since 0.265; an FPS display is opencode native's alone, so it stays its own.)
- **Wren's devtools fold by the toolkit's rule.** Wren's Network split becomes a `ui.Side_Panel`: it folds to a rail
  when the content would get less than its least, as papier's list, the settings and the views do. Intent:
  [src/md/features/side-panels.md](src/md/features/side-panels.md).
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
- **No test that crashes by chance on Linux.** Two CI runs stopped on an illegal instruction (an assertion or a bounds
  check) that no local run made again: once in `plugins`, twice in `process` (`each_signal_is_its_own`, each time
  while another test of the package started a child). `process` now runs one test at a time, as `os.process_start` is
  not safe from two threads; the plugins' starts were serialized already. Left: on Linux a crash's log still has no
  report of its place (the crash handler is installed on Windows only, as on Linux it caught `fail_now`'s trap).

## Later

- **Image nodes for a second program.** cliche's node catalogue of image transformations moves next to `gt:flowgraph`
  when papier or classeur gets workflows of its own; the graph's add palette (`ui.flow_palette`, a right click, a link
  dropped in the void) is the toolkit's already.

- **Personal keys and aliases in Wren.** A person sets a key or an alias for a command the same way in every program:
  papier, classeur, inspecteur, cliche and opencode native read the toolkit's keymap; Wren moves to it last (its
  `Command.name` becomes `ui.Command.id`). Intent: [src/md/features/keymap.md](src/md/features/keymap.md), "Migration".
- **Plugins in JavaScript.** A person adds commands, settings and views to a program with a plugin, which reaches only
  what they granted and never slows the window. Done: commands and toasts, views, settings (API level 3), `gt-runtime`
  with its JavaScript demos, the API explorer on the site, the plugin host in a process of its own (a crash or a hang of
  a plugin no longer reaches the program), capabilities (API level 4: the grant dialog, the plugin's data folder,
  files, `fetch` by origin, the clipboard, all done by the program's broker), lazy lists (API level 5), the process's
  sandbox on Linux, rich views (API level 6: icons by name, tones, badges, highlights), a program's own module
  (`from "app"`: the mechanism, its calls, events, permissions and generated `app.d.ts`), palette sources, menu and
  tool bar entries and a manifest's languages (API level 7), a plugin's settings' titles that follow the language
  without a reload, a lazy list's active row and its `onActivate` (API level 8). Next: opencode native turns plugins
  on and writes its module (sessions, messages, the composer) in its own repository. Intent:
  [src/md/features/plugins.md](src/md/features/plugins.md).
- **A plugin's process sandboxed by the system on Windows and macOS.** On Linux a plugin's process opens no file and no
  socket by itself (Landlock and a seccomp filter); elsewhere it still has the person's rights. Left: Windows, an
  AppContainer or a restricted token with a low integrity level, given by the program when it starts the process
  (`sandbox_spawn`; its pipes inherited, nothing else); macOS, the profile of `sandbox_init` once the toolkit builds
  there. Each is done when `tests/plugins/sandbox_test.odin` sees "escaped: none" there. Intent:
  [src/md/features/plugins.md](src/md/features/plugins.md), "As built: the sandbox".

## Maybe

- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL and Vulkan only save about 1 MB for
  a harder build. Revisit only if gfx-rs publishes a reduced build.
