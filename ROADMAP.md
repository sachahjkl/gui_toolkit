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
- **The update of an install for everyone.** The updater downloads and checks as now; "Restart to update" then starts
  the installed program elevated (`--system update <file>`), which checks the signature again with its own key and
  places the file, in one prompt per update. Until then such an install says that an administrator updates it. Intent:
  [src/md/features/install-scope.md](src/md/features/install-scope.md).
- **The elevated verb loads its libraries from System32 only.** Windows loads the libraries that a program imports from
  the program's folder first, before `dll_search_restrict` runs: a library put beside the download is loaded by the
  elevated verb of an install for everyone. Linking with `/DEPENDENTLOADFLAG:0x800` (Windows 10 1607 and later) closes
  it for every program. Intent: [src/md/features/install-scope.md](src/md/features/install-scope.md).
- **The programs offer the install for everyone.** Each program takes the new gui_toolkit: most change nothing
  (`Setup_Options.scopes` is every scope by default); a task manager calls `task_manager_start(args)` and drops its
  hand-off; a program that must stay per person gives `scopes = {.User}`. `--install --everyone` on the command line
  comes with it. Intent: [src/md/features/install-scope.md](src/md/features/install-scope.md).
- **A de-elevated start for an elevated program.** An administrator's elevated classeur (or a task manager that
  Ctrl+Shift+Esc started elevated) keeps Open, Open with and the terminal: on Windows the toolkit asks Explorer's shell, which runs
  at medium integrity, to start them (`IShellDispatch2::ShellExecute` through the desktop's `IShellView`), so the
  handler runs with the person's own token and never with the administrator's. On Linux there is no such way for
  root: no process of the user's session takes requests from root by design, and `sudo -u` would trust the user's
  environment and files from root, so a root program keeps refusing. Intent:
  [src/md/features/elevated-process.md](src/md/features/elevated-process.md).
- **cliche and opencode native draw with `ui.Mark_Editor`.** cliche drops its editor's model, painter and canvas for
  the toolkit's and keeps its window, its words and its outputs; opencode native opens the editor on a picture of its
  viewer or of its composer, and the result replaces the attachment. Intent:
  [src/md/features/mark-editor.md](src/md/features/mark-editor.md).
- **The rest of cliche's marks in `gt:marks`.** Speech balloons, step numbers, the magnifier, stickers, shadows and the
  picture's own operations (turn, mirror, resize, margins, cut out a band), each with its figures and its tests, when a
  program needs it. Intent: [src/md/features/mark-editor.md](src/md/features/mark-editor.md).
- **gt-file-picker as a Nix package.** The flake builds the compiler and the test fonts, no program of the
  repository: a package of gt-file-picker needs the native library's crates vendored (`importCargoLock`) and the
  portal's files installed with its store path in their `Exec=`. Then NixOS's portal configuration names it with no
  hand edit. Intent: [src/md/features/file-picker.md](src/md/features/file-picker.md).
- **The file picker's window a child of the asking program's.** The portal gives the caller's window (`x11:<id>`,
  `wayland:<handle>`); the picker's window then stays over it and moves with it. It needs `xdg-foreign` on Wayland
  and `WM_TRANSIENT_FOR` on X11 in the platform layer, and a `--parent` option of gt-file-picker. Intent:
  [src/md/features/file-picker.md](src/md/features/file-picker.md).
- **Measure `gt:filesearch` on a Windows home folder.** classeur's search and palette use `gt:filesearch` and
  `ui.Palette_Files` already. Left: the time and the memory of an index of a whole Windows home, before a whole home
  is the default there. Intent: [src/md/features/file-search.md](src/md/features/file-search.md).
- **X11's vblank timing seen on a real screen.** The Present extension's answers are read, but the virtual desktop's
  software renderer draws with PutImage and never answers: run the desktop test on an X11 session with a GPU to see
  frames start just in time there too. Intent: [src/md/infrastructure/vblank.md](src/md/infrastructure/vblank.md).
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
  while another test of the package started a child). Every start of the toolkit now goes through `process.start`'s
  one lock ([src/md/features/child-processes.md](src/md/features/child-processes.md)). A crash now names its place on Linux too
  (`gt:testkit/crashsite`); left: the next such run's report read and its cause fixed.

- **The programs on the shared start, restart, order and status pieces.** Each program replaces its own copy:
  `process.run` and `process.start` for its children (socle, atelier, inspecteur, classeur), `host.restart_after_exit`
  for its `launch_after`, `ui.Status_Line` for its `say`, and `ascii.compare_natural` for classeur's
  `name_compare`. Intent: [src/md/features/child-processes.md](src/md/features/child-processes.md),
  [src/md/features/program-start.md](src/md/features/program-start.md).
- **The programs on the shared second start, files, Mermaid, "Open with" and watcher.** Each program drops its own
  copy: `instance.Launch` and `host.instance_serve` for its second start (seven programs),
  `prefs_page.program_files` and `prefs_open` for its settings' start (six), `gt:markdown`'s Mermaid (papier,
  opencode native), `ui.Open_With` for its file menu (papier, classeur, feuille) and `fsx.Watch` for its folders
  (classeur, feuille). Intent: [src/md/features/second-start.md](src/md/features/second-start.md),
  [src/md/features/program-files.md](src/md/features/program-files.md).
- **classeur moves to the trash with `platform.move_to_trash`.** Its `fs/trash_linux.odin` repeats the toolkit's
  `volume_top`, `url_path` and local time word for word; a fix in one then reaches both. It keeps its trash listing
  and its Recycle Bin records, or these move into `platform` too.
- **papier's size words from `timefmt.size`.** papier's `size_text` gives way to the toolkit's words, so a size reads
  the same in every program.
- **A free file name.** A saved or downloaded file never overwrites another, and its number looks the same in every
  program. A procedure of `gt:fsx` creates the file with the next free number in one step (`O_EXCL`, `CREATE_NEW`); classeur, cliche,
  opencode native, Wren and the toolkit's trash drop their three styles.
- **One report for the live tests.** (Developer) `toolbox.Checks` and `check` give every program's live test the
  same report and exit code; papier, inspecteur, atelier and opencode native drop their own.
- **A trackpad swipe reader.** A two-finger swipe goes back and forward in any program, as it does in opencode native.
- **`ui.preview` leaves Shift+wheel to the program.** A program that scrolls sideways with Shift+wheel over a picture
  keeps it.
- **A middle click on a link opens it in a scroll area.** A clickable box (a link) wins the middle click over the
  scroll area's autoscroll.

## Later

- **Natural order that folds Latin accents.** Names sort as a French reader expects ("été" before "Étude"): a
  sibling of `ascii.compare_natural` folds Latin-1 and Latin Extended-A for display order, and classeur drops its own
  `fs.name_compare`. It needs an entry in `tools/unicode_case_allowed.txt`.
- **A launcher, a program of the suite.** One key, anywhere, opens a palette: a program, a file (`gt:filesearch`), a
  sum, a command of the suite's programs, papier's history; the first result in a few milliseconds and the keyboard
  never lost. It is worth doing only very well, so its design comes first, and a system each: the global key and the
  list of programs come from the Start menu on Windows, from `.desktop` files and the compositor on Linux (Wayland and
  X11 differ), from `/Applications` on macOS. Its intent comes after `gt:filesearch`.
- **An image viewer, a program of the suite.** A picture opens at once and the folder's others follow with the arrows;
  crop, turn and mark it. `gt:image`'s decoders, the thumbnails and the picture cache are there; it sits between cliche
  (capturing) and classeur (filing). After the launcher.
- **An archive as a file source.** A zip or a tar opens as a folder in every program's file dialog, and its files are
  copied out. classeur already browses zip, tar and tar.gz read-only over `gt:archive` (`fs/archive.odin`); the
  toolkit side is a `ui.File_Source` wrapper over another source, its reads off the interface's thread. Intent to
  write: the formats, read only or written, the index of a large archive.
- **Tab tear-off and a tab dropped on another window.** A tab dragged out of its row opens in a new window; dropped on
  another window's row, it moves there. `ui/reorder.odin` says when a drag leaves the row and where it lands; where
  positions are not known (Wayland), a system drag carries the tab. classeur and Wren drop their own.
- **Places, volumes and network locations in the file picker.** The places column shows the drives with their free
  space and the mounted shares, and the path bar opens `smb://`, `sftp://` and `trash:///`. classeur's volumes,
  locations and mDNS reader move to `gt:platform` and `gt:fsx`.
- **An application catalog.** The programs found from the desktop's menu entries, with their icons, and a process tied
  to its application. inspecteur's reader moves to `gt:desktop` (`apps`, `app_of`); the launcher uses it.
- **A picture view.** A picture or a diagram opens in a view fitted to the window, zoomed, panned, copied or saved.
  A view of `ui` over `ui.preview_image`; opencode native, papier, cliche and classeur drop their own wrappers.
- **A log view.** Entries with their time, level and source, a filter by level with counts, follow, search and copy.
  One view of `ui` for inspecteur's journal, Wren's console, socle's apply log and the toolkit's Diagnostics.
- **Name patterns.** A file name made from a pattern ({name}, {ext}, {n:3}, {date}, {time}) the same way in cliche's
  saves, classeur's batch rename, papier's Save as and feuille's page extracts.
- **A recent list.** Recent documents and folders: the newest first, capped, a removed item forgotten. `store.Recent`
  over `store.Kept` for feuille, classeur, the file picker and cliche's tray.
- **Wren's crash stacks and poison allocator for every program.** A crash report with a named stack in every program,
  and freed memory caught in the checks. Wren's `crashtrace` and `poison.odin` move to `gt:crash` and `gt:testkit`.
- **socle's disk size words from `timefmt.size`.** Its `size_words` gives way to the toolkit's, with a rounding
  option if socle's "512 GB" needs one.
- **papier's thumbnails on `ui.Thumb_Cache`.** papier keys a thumbnail by its content's hash: the cache takes a key
  that is not a path, and papier drops `thumbs.odin`.
- **cliche's history grid on the table's cards.** Its grid and thumbnails become a `ui.Table` card view and
  `ui.Thumb_Cache`.
- **feuille's marks on `gt:marks`.** Once the mark editor is in, feuille's text and shapes on a page use it, in page
  points, and its PDF writer stamps them.
- **Wren on the toolkit's lints, test scheduler and DevTools server.** Wren drops its globals and case lints, its test
  scheduler and its CDP server for `tests/globals`, `tools/run_tests` and `gt:devtools`.
- **classeur's tab reorder on `ui/reorder.odin`.** Its own slot and drag code goes; its drop onto another panel stays,
  with the tear-off above.
- **inspecteur's duration words from `timefmt`.** Its `duration_words` and `bits_text` give way to
  `timefmt.duration` and `timefmt.rate`, with a style for "3 days, 4 h 12 min" if `timefmt` lacks it.

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

- **A whole-disk file index on Windows.** What Everything does: NTFS's master file table read once and its change
  journal followed, every file of every disk found in milliseconds. It needs a privileged reader, a service installed
  with the program; it waits for a decision on whether the suite installs a service at all, and for `gt:filesearch` on
  trees to be in use. Intent: [src/md/features/file-search.md](src/md/features/file-search.md), "Windows".
- **A video and audio player inside a program.** A program plays a video or a sound in place, not in the system's
  program. The way open: decode with the system (Media Foundation on Windows, VA-API on Linux) into
  `render/video.odin`'s frames. It waits for a very light player, a library or a design, on Windows and Linux, that
  adds almost nothing to a program's size.
- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL and Vulkan only save about 1 MB for
  a harder build. Revisit only if gfx-rs publishes a reduced build.
