# Roadmap

## Now

- **One mechanism for work off the interface's thread.** A program asks "do this off the thread, give me the result",
  and no disk, network or process call runs on the interface's thread. Move ocn's `Work_Pool` (`opencode_native/src/work_pool.odin`:
  a few ordered threads, an optional delay, a threadless pool that a test pumps) into the toolkit, with one "chores"
  pool per program and the result back through `ui.post`; perhaps a task type with ask/take as `ui.Worker`. `gt:store`
  and `ui.Worker` use it if that is simpler. Then audit ocn, papier, classeur, inspecteur, cliche, wren and the toolkit
  for system calls in a build or an event (`os.*`, `platform.open_path`, launch, stat, file reads and writes,
  synchronous D-Bus, `platform.notify` instead of `notify_async`), and add a debug mode or a test that marks a
  forbidden call on the interface's thread.
- **A menu as wide as its content.** A context menu measures icon, widest label, gap, widest shortcut (or a
  submenu's arrow) and margins, so a label such as "Show as QR code" beside Ctrl+Shift+Q is never cut while the menu
  fits. A label is cut, with a tooltip of the full text, only at the available width. The same rule for submenus,
  the palette and the pickers; a test with a long label and a long shortcut.
- **A dialog opens without a flash.** The first visible image of a modal is at its final size, and the veil and the
  dialog fade together. Today the height comes from the previous image's measure, so the first image has none and
  the dialog jumps (seen in wren). A test: the dialog's box does not change between the first visible image and the
  next; checked with captures image by image.
- **The dialog's close button in its corner.** A control in a rounded corner sits at a margin m from both edges,
  with a concentric radius `r_int = max(r_ext - m, 0)`. One toolkit helper places a corner control for every dialog,
  and a toolbar beside it never touches it.
- **The toolkit's button replaces ocn's `bevel_button`.** `ui.button` and its `Button_Options` have what ocn's
  button has, except the program's rounding and the glow of intent buttons: add those, then ocn deletes
  `bevel_button` (ocn's `opencode_native/src/desktop.odin` guesses an intent from the button's id). Wren's hand-made
  icon and text buttons (`icon_square_button`, `dt_btn`) become `ui.button` too.
- **Themes of your own, for every program.** In the Theme section of the settings, a visible line says that a person
  can make their themes, with the file's path as a link that opens it in the system's editor. The toolkit creates the
  file at the first opening, filled with comments that explain the keys, the colour format, `from = ...`, the light
  versions and an example, on a worker, and reloads it when it changes. ocn then deletes its `themes_file_open` and
  its template (`opencode_native/src/theme.odin`).

## Next

- **opencode native and Wren move to views.** papier, classeur, cliche and inspecteur are migrated: their dialogs, side
  panes and windows of their own are views. opencode native and Wren follow. Intent:
  [src/md/features/views.md](src/md/features/views.md), sections 1 and 7.
- **The intent and the roadmap in every program.** Each program gets its `src/md` folder with the design notes it keeps
  today in `docs/`, and its `ROADMAP.md` with its entries of the global to-do file; each project's tool checks the
  roadmap's format.
- **The file browser in the showcase.** The toolkit's file browser and path bar are shown in the fidget example and in
  the screenshots of the toolkit's site, with their description in the carousel.
- **One settings base for every program.** Each toolkit setting that changes the feel or the rendering becomes a
  `config.Def` declared by the toolkit beside the code that uses it, with today's default, and one `prefs_page` shows
  them by group; technical ones go in a folded "Advanced" group, never blocked. Groups: Appearance (theme, mode,
  finish, glow; rounding, corner smoothing; text size, zoom, density; animations; system title, kept window
  placement, toast position), Text and fonts (interface, mono and prose families, emoji source, system fallback;
  grey or subpixel smoothing, subpixel steps, grid fit, DirectWrite mode, atlas or Slug, Slug tolerance; gamma,
  contrast, coverage exponent, blend space; colour and async emoji; atlas pages and caches), Scrolling (smooth
  scroll and `ui.Scroll_Settings`, wheel lines, scroll bar width and autohide, middle-click autoscroll, touch fling
  stop speed), Input (key repeat, undo steps and merge, list type-ahead, number steps), Delays and menus (one tooltip
  delay instead of three constants, submenu hover, menu item height, palette fade), Rendering (present mode, frame
  latency, partial redraw, blur limit, filter precision), Updates (`update.auto`, `update.channel`,
  `update.base_url`), Desktop, Accessibility (what `gt:a11y` sets) and Diagnostics (fps, layout warnings, GPU
  profile, devtools).
  - The programs drop their copies: ocn's twenty `appearance.*`, `update.*` and `window.placement`
    (`appearance.style` is `appearance.finish`); wren's `font.*` and `text.*`; `update.auto` in papier, classeur,
    inspecteur and ocn; papier's `picker.*`, inspecteur's `view.*` and classeur's `look.*` become `appearance.*`.
  - `gt:config` gains a group › subgroup hierarchy read from the dotted name, with a title per level
    (`config/titles.odin`); "Advanced" replaces "hidden" for technical settings, and "hidden" stays for a
    program's state.
  - One format, `gt:config`'s `name=value`, for every program; exporters only to JSON, TOML and INI (no import of
    them); a one-time import of each program's former file. Each program keeps its own file in its own folder: the
    programs share the definitions, not the values.
- **The settings page, finished once.** `prefs_page` gets an "Open the settings file" link that opens the file with
  the system's program, a sidebar resized with the mouse and its width kept, and nothing that overflows or is cut at
  any window size. Its bounded numbers use the number widget (exact value typed, wheel, − and +), keeping "write on
  the release of a drag, at once for a key, a click or a wheel notch"; past `SLIDER_STEPS_MAX` it has a field without
  a slider today.
- **One widget for a number in every program.** The programs set each number with the toolkit's number widget
  (`ui.number_int`, `ui.number_f32`, `ui.number_f64`: exact value typed, wheel, − and +, a slider when bounded).
- **Widgets that carry one concept behave the same.** A table of widgets × behaviours (wheel, keyboard, focus and
  Tab, accessibility, context menu, disabled, tooltip, Shift for a bigger step, typed exact value, reset by double
  click); each empty cell between two widgets of one concept is a bug or a written decision. Cliche's list of
  workflows can go back to `ui.button` now that a `ui.next({text_align = ...})` is kept.
- **Context menus as rich as the palette, everywhere.** Move ocn's context menu mechanism (`ctx_check`/`ctx_open`: the
  innermost target takes the click, one menu per kind of target) into the toolkit. `text_edit` gets `line_edit`'s
  field menu (ocn's composer menu redoes it), as rich as the command palette. Find the programs that test "rect
  contains the mouse" for a right click and use `ui.pointer_on`. Remove the `search = true` that the default made
  useless, and take every menu icon from one font.
- **One search band for menus, palettes and pickers.** The darkened band of the toolkit's context menu (a field's
  background, a line below) everywhere: ocn's palette (`opencode_native/src/palette.odin`, `###pal_top`) and pickers
  (`picker.odin`) and the other programs' searches use the toolkit's drawing (`dialog_top_draw` or its equivalent,
  made public if needed).
- **One command registry and one palette.** Wren has its registry (`commands.odin`, icons in `command_icons.odin`)
  and its palette beside the toolkit's (`ui` commands, `command_shortcut`): the biggest duplicate seen. Decide which
  is the reference, then merge without an alias.
- **One icon set: Lucide.** Wren's security chip and the rest still use its `GLYPH_*` font; move them to Lucide and
  decide whether every program drops its own icon font. Generate every constant of `lucide.ttf` (1918 glyphs) instead
  of adding them by hand to `lucide.odin`.
- **Rich paste in the toolkit.** ocn's paste of files, an image or text, decided once the three answers are in and
  the image decoded off the interface's thread; `paste.odin` knows only text.
- **One image decoder.** ocn decodes through the Rust `image` crate while the toolkit has its decoders (png,
  `clipboard_image_decode`): two paths for one concept.
- **One JSON helper.** Reading and writing, with ocn's `jstr`/`jnum`. cliche writes JSON by hand with `fmt.sbprintf`,
  where braces are argument markers (a file was unreadable).
- **Small tools that programs redo.** ocn's `rect_contains` (the toolkit has `contains`), `hint_action`, `well`;
  Wren's `dialog_line` (a wrapping label) and `dialog_field` (a `line_edit` with Enter and Escape); cliche's hand-drawn
  record dot (a `ui.dot`, Lucide has no filled circle). Check what exists first.
- **Kept values per key.** ocn's `Kept_Zooms` (one value per id, kept in a file, forgotten at its rest value) and the
  zoom per session become a setting kept by key, above `gt:store`.
- **Dialog pieces from Wren.** `dialog_preferred` (`vault_shell.odin`: a `modal_sized` height from its content
  measured at the previous image plus its footer) becomes an option of `modal_sized`; a `ui.prompt` beside
  `ui.confirm` (title, sentence, a field secret or not, Cancel / OK); `secret_wipe` (a `Text_Field` and its undo
  history zeroed) belongs to the toolkit's secret field; `busy_spinner` becomes `ui.spinner`; `toolbar_panel_rect`
  (a panel right-aligned under its button) becomes an alignment option of `ctx_menu_open_rect`.
- **Pieces from cliche.** A host stops its frame once a window is marked closed, before the input hook sees Close, so
  a window that hides instead of closing cannot close (cliche works around with `app_close_asked`): give the close
  request back to the program. A toast default that never covers a window's toolbar (today `set_toast_area` per
  case). Snapshot undo and deferred file writing (check `ui/edit_history.odin` first). `Worker_Fonts` (a per-thread
  font state made at first need) into `gt:font`. `CLICHE_TIMING` (time marks per step, enabled by an environment
  variable) beside `render_trace`. A `host` helper to open a hidden window ahead (`preload_device`, then a hidden
  `host_open` at wake-up, cliche's `app_prewarm`).
- **The workflow engine in the toolkit.** cliche's pure workflow engine and node catalogue (image transformations in a
  graph) can serve papier and classeur. Fix one node graph convention for every program: Space scrolls, the add
  palette opens on Shift+A, a right click, or a link dropped in the void.
- **Standard folders in every program.** `platform.user_dir(kind, program)` (Config, Data, Cache, State) is in the
  toolkit; the programs still read `XDG_*`, `APPDATA` and `LOCALAPPDATA` themselves (classeur 17 times, wren 12, ocn
  its own `config_dir`, papier, inspecteur, cliche). Each program moves to it, and the toolkit's own `XDG_DATA_HOME`
  reads (`gt:desktop`) too.
- **Wren logs through `gt:log`.** The other programs write their log through the toolkit's `gt:log` (levels, off the
  interface's thread, rotation, its last lines in a crash report); Wren moves to it.
- **Every program in French and English.** All the toolkit's texts go through `tr` (field menus, menus, dialogs,
  the settings page); the language loading that `docs/i18n.md` describes; a toolbox tool that extracts the `tr` calls
  of a program and the toolkit into a catalogue and reports translations whose text is gone; a base setting
  `general.language` (default: the system's); then every program passes its texts through `tr`. English stays the
  key, French is the first loaded language. Today only wren calls `tr`.
- **A program builds only the modules it uses.** Measured: Odin emits no unreached procedure, an unreached foreign
  import is not linked and an unread `#load` is not in the binary, so splitting packages gains nothing by itself (an
  `@(init)` or `@(require)` of a dead package is kept). The real gains, in order: a subset of `lucide.ttf` (about
  −875 KB, 86 names used of 1913); `devtools` behind `#config(TOOLKIT_DEVTOOLS, ODIN_DEBUG)` with `start_from_env`
  returning nil otherwise (−352 KB and about −2 s of release build; ocn, papier, classeur and inspecteur call it
  unconditionally); the fallback fonts behind `#config(FONT_EMBED_FALLBACK, true)` (−159 KB); one native crate
  (`gt`, in the `native` folder) with cargo features instead of `gt_text`, `gt_mermaid` and `gt_a11y` and their std collisions
  (`--allow-multiple-definition`), built by `tk build_native` (−0.4 MB, more if wgpu-native joins); `FONT_BACKEND`
  native by default outside Windows (today's dwrite default gives a Linux binary without text). Then a feature list
  per program in `gt:toolbox`, from which the defines, native steps and link flags come, called by every build tool.
  Outside the plan: shipping stripped (−7.5 MB).
- **Platforms that plug in and out, toward macOS.** Everything specific to a system sits in `*_windows`, `*_linux`,
  `*_darwin` or `*_other` files behind a clear interface, with no scattered `when ODIN_OS` in portable code. The
  gate: `odin check` of every toolkit and program package for darwin_arm64 passes (`*_other` files that say "not on
  this system"), checked by the CI like Windows.
- **Paid licences for every program, as in Wren.** The code stays open source: the repositories' licences do not
  change. Extract what Wren has (`license_shell.odin` and the program side into the toolkit, generic and configured
  per program; the server worker made configurable, one for all or one per program; secrets through sops; a purchase
  and licence page on each program's site), all ready for the user to create the products.
- **The toolkit's site, a level up.** New showcase examples for the recent work (machined finish, shades and intents,
  the palette, menus, dialogs, the number widget, buttons, the settings page, the node graph and inspector, own
  themes), and a rich carousel of captures, each with a description, made by `tk screenshots` / `theme_shots` without
  a window on the desktop.
- **Programs announce what they did.** Move every program's confirmation toasts (papier "Copied", classeur's copies
  and moves, inspecteur, wren) to `ui.announce`, and register `.Session` to get the Messages setting.
- **Colours by intent everywhere.** `accent_button`, `danger_button` and `warn_button` became soft pairs: check every
  program that relied on a solid background, and replace hard-coded greens and reds with intents or `hue()`. Badges
  use `ui.ink_on` instead of a copied contrast calculation. Decide whether Cancel (red as Danger) becomes the rule for
  every dialog's Cancel button, `ui.confirm` included.
- **Checks after toolkit fixes.** No program still draws its own scrollbar (`ui.scrollbar_paint`); no program sets a
  radius by hand on a child placed in a corner (`box_drawn_radii` handles the parent's border); every program that
  read or served the Wayland clipboard its own way is checked; papier, classeur and inspecteur can enable WebP site
  images (`site.build_images`).

## Later

- **Plugins in JavaScript.** A plugin builds its own screens and views, runs commands and reads settings through a
  dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit
  (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
- **The host tests on Linux too.** `tests/host` runs on Windows only: on Linux, its windows without a screen get no
  renderer after a few tests in one process (each test passes alone), so a renderer closed seems to keep something of
  its device. Freed whole, the tests of a program's windows (resize steps, waits) run on the system that needs them most.
- **One scroll per axis.** A wide table in a message (ocn's markdown) shows two horizontal scrollbars, its own and its
  container's. The toolkit keeps only the innermost box that overflows on an axis, or reports the nesting.
- **A key read outside the open dialog is reported.** A dialog keeps the keyboard; ocn's palette read its arrows
  outside its dialog. Document the trap, or let the toolkit report the read.
- **Demo states injected.** A demo mode that injects states that need an account (an unlocked vault, a PIN asked), so
  a capture needs no temporary code change.
- **Test pitfalls removed.** `odin test` run by hand on a package that draws text fails (the embedded font library
  comes only from `tools/run_tests`): document it or make it impossible to miss. Running the toolkit's tests from
  Wren needs Wren's nix shell (wgpu); locally mermaid (library not built), http (not done in 300 s) and update fail.
- **A naming rule for packages.** A package named as a core package (`image`) conflicts: prefix it with `tk_`, as
  `tk_prefs_page`. Write it down as a rule.
- **Windows hidden files in the file browser.** The file browser hides only names that start with "." on Windows,
  because `core:os` does not give the hidden attribute. See
  [src/md/features/file-browser.md](src/md/features/file-browser.md).
- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL + Vulkan only saves about 1 MB
  (glow, the GLES backend, naga's GLSL and SPIR-V front ends) for a harder build with bindgen. Revisit only if gfx-rs
  publishes a reduced build. If done: `packages.wgpu-native-min` in the flake (`buildNoDefaultFeatures`, features
  `wgsl vulkan`, `WGPU_NATIVE_VERSION` set or `CreateInstance` panics), a `tk build_wgpu` for CI outside Nix, a test
  that creates an instance; Windows unchanged.
