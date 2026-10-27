# Changelog

All notable changes to gui_toolkit. The project follows [semantic versioning](https://semver.org); while the version is
`0.x`, a minor bump may change the API. The version is also available in code as `ui.VERSION`.

## [0.48.0] - 2026-10-27

### Added
- **`ui.NAMED_PALETTES`**: eleven more palettes from well-known editor schemes, each with its own accent: Gruvbox and Gruvbox Light, Naysayer, Solarized and Solarized Light, Monokai, Tokyo Night, Catppuccin (Mocha) and Catppuccin Latte, One Dark and Everforest. `palette_named` finds them by name; a test checks that every named palette keeps its text legible on its background and panels and its `dark` flag in line with its background.

## [0.47.2] - 2026-10-27

### Changed
- **The native libraries are built without fat LTO again** (`tools/build_text.ps1`, `tools/build_a11y.ps1`): with it (`gt_text.lib` 6.4 MB instead of 33 MB) the `text` tests crashed on the CI runner at their first test (`atlas_stress`, a signal) while they pass on a development machine; the cause is not found, and the size is not worth a crashing test run. Wren builds these crates into its own library and is not affected.

### Fixed
- **The text tests no longer fail now and then on a CI runner** (`text_test.atlas_stress`, "Signal caught: Unknown", sometimes a runner that never ended): DirectWrite throws C++ exceptions and catches them itself when an entry of its process-wide cache does not fit, and the Windows test runner of `core:testing` takes any exception on a test's thread for a crash and kills that thread. The tests of `tests/text`, `tests/color_glyphs` and `tests/text_backends` now run their body on a thread of their own (`tests/unwatched`), where a caught C++ exception is ignored and any other exception still fails the test. The `text` package runs on several threads again in `tools/test_windowless.ps1`. Outside the test runner nothing changes: DirectWrite catches these exceptions itself.
- **A test package that does not end names itself** (	ools/test_windowless.ps1): each package is killed after 300 s, with its log (the state changes of its tests) in the CI's, instead of the CI cutting the whole step off after twelve minutes with nothing to read.
- **The CI's cold build of the Rust libraries has room to end** (.github/workflows/ci.yml): with fat LTO it is slower than the step's 12 minutes, so the cache was never saved and every run was cold; the build is a step of its own with a 30 minute limit, and the cache fills at the first success.

## [0.47.1] - 2026-10-27

### Fixed
- **The native text backend and the accessibility adapter are built with fat LTO** (`native/text`, `native/a11y`, `tools/build_text.ps1`, `tools/build_a11y.ps1`): their crate types listed `rlib` next to `staticlib`, and rustc skips LTO whenever an `rlib` is among them: every dependency stayed a separate unoptimized object (`gt_text.lib` 33.2 MB, now 6.4 MB; `gt_a11y.lib` 16.9 MB, now 4.8 MB). The crates are now plain libraries (an application's Rust library still depends on them) and the scripts ask for the static library alone (`cargo rustc --crate-type staticlib`); they fail if an object of another crate is left in the archive.

## [0.47.0] - 2026-10-27

### Fixed
- **A drag inside the window is shown at the top rate of a variable refresh screen** (`platform.frame_decision`, `Cadence.variable`, `platform.cadence_adopt`): on a variable refresh screen (G-Sync, FreeSync, Windows' dynamic refresh rate, which reports 60 Hz at rest), a `Drag` frame (a splitter, a panel's handle, a tab) is presented at once with two frames queued, still one frame per slot of the top rate, instead of waiting for a refresh at the rate the screen rests at: a splitter dragged at 1 kHz went from 62 to 183 frames a second on a 180 Hz screen reported at 60 Hz. Fixed refresh screens and every other state are unchanged. `cadence_adopt(&c, plan)` takes the plan's slots and screen (instead of `c.slots = plan.slots`).

## [0.46.0] - 2026-10-27

### Added
- **`platform.Event.injected`**: an event made by `inject_event` (a test, a remote control, a macro) says so; an application that reads the pointer's position from the system (a window dragged across the screen) uses the event's own position for these, as the real pointer is elsewhere.
- **`Build_Params.inactive`, `ui.inactive`**: a window that is not the one the user is in is built with `inactive = true`: its focused line and text edits keep the focus but draw no caret and ask for no wake to blink it (an application with several windows no longer blinks a caret in each).

## [0.45.1] - 2026-10-27

### Added
- **Text and bounds in the UI Automation test client** (`uia.document_text`, `uia.text_selection`, `uia.select_text`, `uia.bounds`; `uia_probe text`, `uia_probe select-text --start A --end B`, `uia_probe bounds`): what a text pattern holds, its selection or caret, a selection made as a screen reader does, and where an element is, for end-to-end tests.

## [0.45.0] - 2026-10-27

### Added
- **Accessibility, node by node and several windows**: `platform.a11y_diff_patch` sends a tree's changes from only the nodes that changed (a document that knows its mutations no longer makes its whole tree again); the children a node lost are forgotten with their subtrees, so a node put back goes whole. `ui.a11y_cost(s)` gives the nodes and the milliseconds of the last tree. A `ui.State` built for another window than its last one sends that window a whole tree. `tests/a11y` reads two windows apart through UI Automation and checks that a window a reader has read stays quiet at rest (no wake, no update). docs/accessibility.md lists the known limits (Linux and macOS, the toolkit's tree made again in each build, what grafted documents such as Wren's pages lack: iframes, caret and selection, text bounds, a second window).
- **docs/getting-started.md** and **`examples/hello`**: a new project with the toolkit as a submodule (prerequisites with the pinned Odin, MSVC, the optional Rust libraries; a window in a few lines built with `-collection:gt=...`; the render and text backends, accessibility, tests, versions) and the pitfalls met so far (the output folder, `odin test` deleting its exe, a `render.Surface` in a local, nested builds, keys, `expect_assert` on Windows). `hello --frames=N` runs without showing its window. Checked on a clean clone; `tools/window_shot.ps1` accepts an absolute `-Out`.
- **`flate`**: DEFLATE, zlib and gzip as streams (`Inflater` / `Deflater`: input in chunks of any size, each push gives the output it allows; `inflate` / `deflate` for whole buffers), pure Odin for any platform. Checksums and sizes checked, a bound on the output (`limit`, `Too_Large`). The deflater writes each block in the cheapest of stored, fixed and dynamic Huffman codes (about 17 % smaller than fixed codes on text). Ported from Wren's `src/flate` (same API); docs/flate.md, `tests/flate`.
- **Offscreen readback on the WebGPU backend**: `draw.offscreen_end` gives a `render.Readback_Id` and `render.readback_poll` the picture (straight RGBA8, sRGB values, alpha kept) as under Direct3D 11: the frame copies the target into a buffer, the poll maps it without waiting (`Pending` until the GPU is done). `tests/layers` checks the pixels on both backends.
- **`ui.Build_Params.time_ms`**: the build's clock (caret blink, double and triple clicks, hover delays, timers, toasts), `now_ms()` when 0. A test or a replay passes its own to be deterministic; double clicks and the text selection's clicks now read the build's clock instead of the wall clock.

### Fixed
- **CI**: two tests that failed now and then are deterministic. `tests/ui_robust` (`nested_build_is_refused`) checked an assertion through `testing.expect_assert_message`, whose exception handler on Windows races the system's end of the process: the whole test program ended without a message. The assertion is now caught on a thread of the test's own. `tests/keyboard` (`caret_rect_is_where_the_caret_is_drawn`) depended on the caret's blink phase, i.e. on how long the program had run (a slow WebGPU start blinked it off); it and the double-click tests (`selection`, `panes`) now pass `time_ms`. `tools/test_windowless.ps1` and `tools/test_backends.ps1` print the exit code of a failed package (an access violation, a trap nothing caught).

## [0.44.0] - 2026-10-27

### Added
- **`platform.frame_decision`: the cadence model** (`platform/pacing.odin`, [docs/pacing.md](docs/pacing.md)): a plan from the screen and the application's choices (`cadence_plan`: the top useful rate of a variable refresh screen, `Frame_Slots` strict or loose), a state per frame (`Rest`, `Continuous`, `Drag`, `Input_Answer`, `Resize_Step`, `Resize_Burst`) and one pure decision (`Frame_Decision`: the wait for its slot, whether it waits for the swap chain, whether it is presented at once, the swap chain's latency), plus `cadence_inner_frame`, `cadence_echo` and the frame clock (`frame_clock_advance`, `vblank_at_or_before`). Test: `tests/pacing` (states, transitions, and simulated runs on fixed and variable refresh screens, tearing, a 1 kHz mouse, a resize, a panel dragged, AltSnap); `tests/frame_slots` and `tests/pacing` join the windowless tests of the CI.

## [0.43.0] - 2026-10-26

### Added
- **`platform.Frame_Gate`: the frames of a thread as one state machine** (`platform/frame_gate.odin`, [docs/frame_gate.md](docs/frame_gate.md)): `Idle -> Polling -> Work -> Building -> Drawing -> Presenting`, Full and Light frames, `frame_gate_begin` / `frame_gate_stage` / `frame_gate_end`; a frame asked for where none may begin is deferred, never nested, and a move the machine does not have is counted (a panic with `strict`). The window procedure defers a `WM_PAINT` where no frame may begin; `drag_script` pumps the thread's messages between its steps as the system's drag loop does. Test: `tests/frame_gate`.

## [0.42.3] - 2026-10-26

### Fixed
- **CI**: green again and about 6 minutes instead of 30 to 37. The CHANGELOG step failed on every push (`tools/changelog_test.ps1` ended with the exit code of a command it made fail on purpose; it now exits 0); a test package of a single test counted as failed (`text_backends` printed "The test was successful", not "All tests were successful"; both are accepted now). The jobs run in parallel: build (changelog, examples, shaders), the windowless tests (`tools/test_windowless.ps1`, the step's script moved there) and the WebGPU tests in four groups (`tools/test_backends.ps1 -Group ci1`..`ci4`, checked to hold every package once; `-Group sample` on pull requests) with DXC, a third of the time of FXC on WARP (FXC still runs two packages, `-Define TOOLKIT_WGPU_DX12_COMPILER=fxc`); each job and slow step has a timeout; the Rust libraries, naga's translator, the emoji font and DXC are cached; Odin is set up by `.github/actions/setup-odin`, its archive hashed with .NET rather than `Get-FileHash`. Every push to master keeps its own run (only pull requests cancel the previous one).
- **WebGPU: `render.video_convert`** converts pictures in memory (I420, NV12; P010 and 10-bit I420 when the adapter has `TextureFormat16bitNorm`) with `video.wgsl`, crop, rotation, matrix and range included, as on Direct3D 11: it returned `false` for every picture (`render/wgpu_video.odin`). A decoder's Direct3D 11 texture (`gpu_texture`) is still refused on WebGPU (wgpu-native cannot import it); `tests/video` checks that refusal there instead of calling a Direct3D 11 device the backend does not have (it crashed).
- **WebGPU: Slug text when the device refuses its shaders** draws nothing instead of passing a missing shader module to the pipeline: `r.slug.failed` is honoured by both backends (it was Direct3D 11 only), a refused `slug.wgsl` sets it, a recreated device asks again.

## [0.42.2] - 2026-10-26

### Fixed
- **`tools/fetch_emoji.ps1`, `build_naga.ps1` and `fetch_wgpu.ps1` hash their files the .NET way**, not with `Get-FileHash`: the build step of a CI run (cmd, after the MSVC environment was set) failed with "Get-FileHash is not recognized" as soon as the emoji font had to be fetched again.

## [0.42.1] - 2026-10-26

### Added
- **`render.surface_init(r, &s, hwnd, size, ...) -> ok`** makes a `Surface` in the one the program points to. `surface_create` (which returns it by value) is kept and calls it. A `Surface` is several kilobytes (`Present_State`'s ring of 256 frames): held in a local and copied into a record, `-o:speed -debug` split it into 12 612 values with a debug record each, and LLVM spent more than ten minutes on that module (Wren's development build and its CI did, until it called `surface_init`). The doc of `surface_create` says so.

## [0.42.0] - 2026-10-26

### Added
- **Accessibility: screen readers read the toolkit's windows** (`ui/a11y.odin`, `platform/a11y.odin`, `platform/a11y_diff.odin`, `platform/a11y_accesskit.odin` (Windows), `platform/a11y_stub.odin`, `native/a11y`, `docs/accessibility.md`). Each build turns the boxes into an accessibility tree (boxes with a role or text; layout boxes left out; ids are the boxes' keys; bounds, focus, states, values, actions) and [AccessKit](https://github.com/AccessKit/accesskit) 0.25 exposes it through UI Automation (`WM_GETOBJECT`). Built only once an assistive technology asked for the window; only the nodes that changed are sent (`platform.A11y_Diff`). Every widget gives its role, name and states (buttons, check boxes, radios, switches, sliders, steppers, progress, segmented, chips, dropdowns, tabs, fields and text editors with text runs and caret, lists and virtual lists, menus and menu bars, tooltips, toasts as live regions, modals, splitters, accordions, cards, form rows, title bar and caption buttons, status bar, labels, paragraphs, rich paragraphs with their links). The app names its own boxes with `ui.a11y(info)` (next box) or `ui.a11y_set(box, info)`; `ui.a11y_wanted()`, `ui.a11y_active`, `ui.a11y_tree`, `ui.a11y_find`, `ui.a11y_stats`. Requests of assistive technologies (invoke, toggle, select, expand / collapse, focus, set value, increment / decrement, text selection, scrolling, context menu) arrive as the same signals as input; the others in `ui.a11y_requests()`; `ui.a11y_request(key, action)`, `ui.a11y_numeric_request`, `ui.a11y_inject` (tests). Trees of the app's own (documents) are grafted under a node (`A11y_Info.graft`) and sent with `platform.a11y_send`. `ui.set_window_button_names` (translated caption buttons). Platform: `a11y_state`, `a11y_send`, `a11y_take_request`, `a11y_available`, the update writer (`a11y_node`, `a11y_children`, `a11y_str`...); `Event_Kind.Accessibility`. Compiled in with `-define:A11Y_ACCESSKIT=true` (`tools\build_a11y.ps1` builds `build\a11y\gt_a11y.lib`; `A11Y_NATIVE_LINK=false` when the program's own Rust library carries it). Every update is checked against a mirror of the tree before AccessKit sees it (a broken update is refused, not a crash); text runs and text selections are made safe for AccessKit's text code. `ui.a11y_box_text` (the text a box shows to a reader). `ui.a11y_focus_on(key)`: the readers' focus on a graft node while the app's view has the keyboard (a focus on a graft whose tree is not there yet waits for it in the adapter).
- **`tools/uia`**: a small UI Automation client (COM `IUIAutomation`): elements, control types, names, states, values, invoke / toggle / select / expand / set value / focus. **`tools/uia_probe`**: the same as a command, for end-to-end tests of applications (a hidden window works).
- Tests: `tests/a11y` (the tree, incremental updates, requests; with `-define:A11Y_ACCESSKIT=true`, a hidden window read and driven through UI Automation). CI runs both.

## [0.41.1] - 2026-10-26

### Added
- **`platform.Chrome_Regions.overlays`**: what the app shows over everything (the ui fills it with the open menus' panels). `hit_test_chrome` answers `Client` there before anything else, the resize bands included.

### Fixed
- **An open menu that covers the integrated title bar's resize band takes the pointer there** (`ui` `chrome_collect`): a menu taller than the window starts at its top, and over the band the system showed the resize cursor (diagonal at the top right corner) and resized the window on a press.
- **The open menus are above whatever the app builds at the root after them** (`menus_raise`, in `end_build` before layout): a menu is built where its button is, and a notice, panel or dialog built later at the root was drawn over it and took its pointer. Test: `tests/chrome` open_menu_over_resize_bands_and_later_boxes.
- **`font.glyph` gives the ink box where the ink is with the native text backend** (`native/text` `gt_glyph_box`): read-fonts 0.46 counts a glyph's extents height downward and never negative, and the bottom of the box was put a glyph's height above its top, so the box was twice as high and a glyph centred by it (Wren's tab icons, a chip's icon) was drawn a glyph lower than meant. Test: `tests/text_backends` native_glyph_box_matches_dwrite (`-define:FONT_BACKEND=native`).

## [0.41.0] - 2026-10-26

### Added
- **`ui.post`: calls posted from any thread** (`ui/post.odin`, `ui/post_queue.odin`, `docs/post.md`): `post(state or window, fn, data, word)` runs `fn(data, word)` on the interface's thread at the start of the next `begin_build` (or `drain_posts`), and wakes the window once per drain. `ui.Post_Queue` is a bounded lock-free ring (Vyukov's MPMC queue, no allocation per message); a full ring blocks (default, nothing lost), drops the oldest (`on_drop`), grows into a spill list or fails (`Post_Overflow`); each producer's order holds in every mode. `post_configure` (capacity, overflow, calls per build, `on_drop`), `drain_posts` (bounded; `needs_frame` while calls wait), `post_close`, `post_stats`, `set_post_wake`. Example: `examples/stream` (a thread posting simulated server-sent events). Test: `tests/post`.
- **Notification area icon** (`platform/tray.odin`, Windows `tray_win32.odin` on `Shell_NotifyIconW` version 4, stub elsewhere, `docs/tray.md`): `tray_create`, `tray_set_icon` (PNG) / `tray_set_icon_rgba`, `tray_set_tooltip`, `tray_set_menu` (items, separators, check and radio marks, disabled and default items, submenus; opened by a right click or the menu key), `tray_show_menu`, `tray_notify` (title, body, icon, silent, quiet time), `tray_poll` (clicks, double clicks, right and middle clicks, menu items, notification shown / clicked / timed out / hidden, hover, `Recreated` after the shell restarted: the icons are added again on `TaskbarCreated`), `tray_destroy`; `destroy_window` removes the window's icons. `tray_test_hook` and `tray_inject` for tests. Test: `tests/tray`.
- **Rich clipboard** (`platform/clipboard.odin`, Windows `clipboard_win32.odin`, stub elsewhere, `docs/clipboard.md`): `clipboard_set` (text, HTML with its source URL, image, files in one write), `clipboard_get_image` (PNG, CF_DIBV5, CF_DIB, CF_BITMAP), `clipboard_get_html` (fragment and source URL), `clipboard_get_files` (CF_HDROP), `clipboard_formats`, `clipboard_format_names`, `clipboard_sequence`, `clipboard_watch` / `clipboard_changed`; images are written as PNG + CF_DIBV5 (alpha) + CF_DIB (over white). Pure conversions: `dib_to_rgba` (every DIB header and depth), `rgba_to_dib`, `hdrop_encode` / `hdrop_decode`, `html_format_source_url`; `png_encode` / `png_decode`. Test: `tests/clipboard`.
- **`ui.splitter`** (`ui/split.odin`, `docs/panes.md`): a handle that resizes one pane (logical pixels, or any unit through `unit`) within its limits and the room the other pane keeps, the pane before or after the handle, double click / Enter back to the default, arrow keys and Home / End with the keyboard focus (optional), the resize cursor, a rule drawn in the accent colour while hot or held; `finished` says when to persist; nothing drawn or animated at rest.
- **`ui.accordion`**: a header with a turning chevron that folds the content built in its block, with an animated height (no frame at rest), Enter / Space; the content is not built once folded.
- **`ui/reorder.odin`**: a list reordered by dragging along X or Y, from Wren's tab strip: `reorder_item_size`, `reorder_offset`, `reorder_slot`, `list_move`, `reorder_edge_scroll`, `reorder_moved`, and the drag's state `Reorder` (`reorder_frame`, `reorder_begin`, `reorder_dragging`, `reorder_item_pos`: items slide to their slots, the dragged one follows the pointer).
- Example `examples/panes`; tests `tests/panes`.
## [0.40.1] - 2026-10-26

### Added
- **`ui.building()`**: true between `begin_build` and `end_build` (on this thread, whatever the state). An app whose window procedure makes frames (`on_frame`, inside a loop of the system) asks it before building one.

### Fixed
- **A build begun inside another one is refused with a clear assertion** (`ui: begin_build inside another build`) instead of breaking the one in progress: `begin_build` emptied its parent stack, freed its frame arena and selected another state under it, and the outer build failed later at an unrelated place (Wren's crash of 2026-10-26: a bounds check in `ui.spacer`, after a `TrackPopupMenu` opened during the build painted the window from `WM_PAINT`). Test: `tests/ui_robust` nested_build_test.

## [0.40.0] - 2026-10-26

### Added
- **`ui.rich_paragraph`** (`ui/rich_text.odin`): runs with their face, size, bold / italic, inline code, colour, background, underline, strike and links in one paragraph; lines break at the backend's opportunities on the whole text, "\n" breaks, long words are cut between clusters, `max_lines` ends with "…", `text_align` aligns; links answer hover, click and the keyboard (Tab through them, Enter); layouts are cached by content (thousands of runs laid out once). Geometry: `rich_layout`, `rich_text`, `rich_index_at`, `rich_caret`, `rich_range_rects`, `rich_link_at`; `rich_set_faces`. `Box.measure_y` (a .Text height that follows the width). Theme entries `link`, `code_bg`. Tests: `tests/keyboard` rich_text_test. Example: `examples/markdown`.
- **Selecting text outside fields** (`ui/selection.odin`): `.Selectable` labels, paragraphs and rich paragraphs share one selection across boxes (drag, Shift+click, double / triple click, Shift+arrows, Ctrl+C, Ctrl+A); text cursor, the theme's selection colour; `selected_text`, `has_selection`, `selection_serial`, `selection_changed`, `clear_selection`, `select_box`. Test: `tests/keyboard` selection_test.
- **`font.styled_face`**: the family's own bold / italic face of a system font, else simulated.

### Fixed
- Bold runs of a system font were the regular face with simulated bold (0.02 em: hardly bolder at 24 px): they take the family's bold face now.

## [0.39.0] - 2026-10-26

### Added
- **Simulated bold and oblique in the native backend** (`font/simulate.odin`): as DirectWrite draws them (bold: +upem/50 per inked glyph and emboldened outlines; oblique: 0.33985 shear). `Font.sims` on every platform; `with_simulations` off Windows. Test: `tests/text_backends` simulations_test (widths to 0.01 px, Slug outline boxes).
- **System fonts on Linux (fontconfig) and macOS (CoreText)** (`font/font_system_linux.odin`, `font/font_system_darwin.odin`): `load_system`, `has_system_family`, the per-character fallback and `system_families`; collection faces by PostScript name (`gt_face_postscript_name`, `gt_file_face_count`). Checked with `odin check`, not run on those systems yet.
- `FONT_NATIVE_LINK=false`: a program that builds `native/text` into its own Rust library links no `gt_text.lib` (two Rust static libraries collide).
- `native/text/examples/shape_dump`: HarfRust's shaping of a text, like `hb-shape`.
- `tests/keyboard` text_edit_draw_test: `text_edit_caret_rect` against the drawn caret.

### Changed
- The Hebrew difference between the backends is explained (`docs/font-backend.md`): DirectWrite drops the XPlacement of right-to-left kerning pairs; the native backend applies it, as HarfBuzz does.

## [0.38.3] - 2026-10-26

### Added
- **File dialogs** (`platform/dialogs.odin`, Windows `dialogs_win32.odin`, stub elsewhere): `open_file_dialog`, `save_file_dialog` and `pick_folder_dialog` with a title, filters (`File_Filter`), an "All files" line, the starting folder (`start_dir`, or a `Known_Folder` default), a remembered folder per `remember_id`, the suggested name and default extension, several files, the overwrite question; `Dialog_Result` gives the paths and the type line chosen. Pure helpers: `filter_patterns`, `filter_matches`, `filters_from_accept` (a web page's accept list); `dialog_test_hook` stands for the real dialogs in tests. Doc: `docs/dialogs.md`. Test: `tests/dialogs`.
- **Shell actions**: `open_url`, `open_path`, `reveal_in_folder` (`ShellExecuteExW`; the file manager with the file selected), `known_folder_path`.
## [0.38.2] - 2026-10-26

### Added
- **`ui.text_edit` wraps and grows** (`wrap`, `auto_height`, `min_lines`, `max_lines`): long lines break at the box's width at the font backend's line break opportunities (a word wider than the box between grapheme clusters); Up / Down / Home / End, clicks and drags follow the visual lines, the caret at the end of a wrapped line stays there (`Text_Area.upstream`); the box is as tall as its lines within the limits, then scrolls. `ui.text_visual_lines`, `ui.visual_line_of`, `ui.Visual_Line` (`ui/text_lines.odin`). Tests: `tests/keyboard` (text_edit_wrap_test.odin). Example: the composer of `examples/fidget`.
- **Caret rectangle**: `Edit_Result.caret` (box coordinates, this build) and `ui.text_edit_caret_rect(a)` (the caret and the selection's other end, window coordinates, as last drawn) for completion popovers and input method windows.

## [0.38.0] - 2026-10-26

### Added
- **Native text backend** (`-define:FONT_BACKEND=native`, `font/backend_native.odin`, `native/text`, `tools/build_text.ps1`): Fontations (read-fonts' font model), HarfRust and ICU4X (line breaks with dictionaries, bidi through unicode-bidi) in a static Rust library behind a C ABI, built and pinned like Wren's image decoders. Shapes 2.6 times faster than DirectWrite on the corpus (2.0 µs a word against 5.2, without the word cache). Faces are still opened by the platform; `Settings.backend` picks either backend for one State. `font.native_table`, `font.native_coverage`, `font.native_outline_provider`. See `docs/font-backend.md`.
- **`tools/text_bench`** and **`tests/text_backends`**: the two backends compared on the corpus (equivalence report and timings; logic checks in the tests).

### Changed
- **The `font` package compiles on Linux and macOS** (`odin check font -target:linux_amd64` / `darwin_arm64`): DirectWrite and Direct2D are behind `font_windows.odin`, `raster_windows.odin` and the color files; `font_other.odin` loads faces from files and memory through the native backend (no system fonts yet: TODO fontconfig / CoreText). `load_memory` takes `font.Simulations` (`{.Bold, .Oblique}`) instead of DirectWrite's flags.

### Fixed
- **Kerning under letter-spacing and font-feature-settings** (dwrite backend): an explicit feature list replaced DirectWrite's default features (kern, liga, clig, calt, rclt); they are now kept unless the list sets them.
- `tests/retained` passes with `FONT_TEXT_RENDERER=slug` too (its atlas page assertions follow the renderer).

## [0.37.0] - 2026-10-25

### Added
- **Text backends** (`font/backend.odin`, `docs/font-backend.md`): the `font` package shapes, analyses (scripts, bidi, line breaks) and reads faces (coverage, metrics, glyph boxes, Slug outlines) through `Text_Backend`, a table of procedures, and finds the system's fonts (fallback, `font.system_families`) through `System_Fonts`, the platform's. DirectWrite is the `dwrite` backend (`font/backend_dwrite.odin`, the code moved, not changed: the corpus dump of `tools/text_dump` is byte-identical before and after); other platforms get an "unsupported" system stub (`font/system_other.odin`, TODO fontconfig / CoreText). `Settings.backend` (init only), `font.backend`, `font.backend_available`, `font.face_metrics`.
- **`tools/text_corpus`, `tools/text_dump`**: a multilingual corpus (Latin with ligatures and kerning, Cyrillic, Greek, Arabic, Hebrew, Devanagari, Thai, Lao, Khmer, Myanmar, Chinese, Japanese, Korean, emoji sequences, a variable font, fallback) and a dump of everything the package says about it (glyphs, clusters, widths, metrics, bidi levels, line breaks), to diff two builds.

### Changed
- `Font.features` (cascade features) are `[]Feature` instead of DirectWrite's structure; the system fallback and the script analysis of ASCII text go through the backend.

## [0.36.2] - 2026-10-25

### Added
- **`platform.Frame_Slots` / `frame_slot_wait`** (`platform/frame_slots.odin`, pure): the app's own cap on the cadence of its frames, a grid of slots one period apart that no frame starts before. The swap chain's latency object paces an app only where the system holds frames back until a refresh; on a variable or dynamic refresh display (G-Sync, FreeSync, Windows 11's dynamic refresh rate) it is released at once, and an app woken by a mouse at 1 kHz makes and presents a frame per move (270 to 915 a second measured on a 180 Hz G-Sync monitor). `strict` makes the grid the period itself; a loose one (0.9 of it) is a net a screen that paces the app never reaches, and tightens by itself after 8 delayed frames in a row. A frame that starts an answer to input (`immediate`) is not delayed. Test: `tests/frame_slots` (a loop woken every millisecond on a screen that paces nothing: at most one frame per period).
- **`Display_Info.max_hz`**: the highest rate of the monitor's modes at the current size and orientation. With a dynamic refresh rate the mode and the display path say 60 Hz all the time while the screen is at 180 Hz when something moves; `platform.refresh_is_variable(hz, max_hz)` tells when to aim above `hz`.
- **`platform.display_live_hz(w)`**: the refresh rate the compositor says it runs at right now (`DwmGetCompositionTimingInfo`, `rateRefresh`): with a dynamic refresh rate the one reading that moves with the screen. DWM answers for the primary monitor only and only to a NULL window handle (a handle gives `E_INVALIDARG`), so a window on another monitor has no answer (`ok` false). Its refresh count is no use (it counts the calls of the process).

## [0.36.1] - 2026-10-25

### Added
- **`Box_Flag.Scrollbar_Left`** (`ui/scrollbar.odin`, `ui/events.odin`): the overlay scrollbar of a `.View_Scroll_Y` box sits at its left edge instead of its right one (drawn, hit and dragged there; its grab margin widens toward the content). A panel docked on the left whose right edge joins the content (a tab sidebar whose current tab flows into the page) keeps its scrollbar on the outside. Test: `tests/ui_robust` scrollbar_on_the_left.

## [0.36.0] - 2026-10-25

### Added
- **Window placement, for apps with several windows or a saved layout** (`platform/placement.odin`, `placement_win32.odin`): `platform.get_placement(w)` / `set_placement(w, p)` (`Placement{rect, maximized}`: the outer rectangle in screen pixels where the window is restored to, and whether it is maximized; `set_placement` moves and sizes the window without showing it, on the monitor nearest to the rectangle and inside its work area, and `show_window` then shows it maximized if asked), the pure `fit_rect_to_work(rect, work)`, `outer_rect(w)`, `client_origin(w)` (where the client area starts on the screen: turns a pointer position of a window, captured outside it, into a screen position) and `move_window(w, x, y)`. `tests/placement`. A browser that moves tabs between windows used all of them.

### Fixed
- **`set_placement` asks twice when the window changed monitor**: a window that crosses to a monitor of another DPI is resized by the system for it (640 x 480 became 896 x 672); asked again, now that it is on that monitor, the rectangle is the one wanted. Windows now open on the monitor the user is on (0.35.3), so this is the common case.
- **`ui.init` no longer restarts the toolkit's clock** (`ui/state.odin`): the origin of `ui.now_ms()` was reset by every `init`, so opening a second window (one `ui.State` each) made the time of the first one jump back. It is set by the first `init` only.


## [0.35.3] - 2026-10-25

### Fixed
- **A menu row that the pointer left for a disabled row stayed selected** (`ui/popups.odin`): a disabled row gets no signal, so the selection followed the pointer over enabled rows only and kept the last one while the pointer crossed disabled ones (the burger menu, the dropdown lists). A pointer that moves onto a disabled row now leaves nothing selected. Test: `tests/keyboard` menu_pointer_over_a_disabled_row_selects_nothing.
- **A new window opened on the primary monitor** (`platform/platform_win32.odin`): `CW_USEDEFAULT` puts it there whatever program launched it, so a window started from a program on another monitor had that monitor's refresh rate and DPI wrong until it was dragged. It is now made on the monitor of the foreground window, else the one under the pointer.
- `ui.VERSION` said 0.35.1 in the 0.35.2 release; it follows the changelog again.

## [0.35.2] - 2026-10-25

### Added
- **Offscreen drawing and readback** (`draw/offscreen.odin`, `render/readback.odin`, `docs/draw.md`): `draw.offscreen_begin` / `offscreen_end` draw into a transparent target of their own, never shown and not cut by the window; `render.readback_poll` gives its pixels after the frame (straight RGBA8, sRGB, alpha kept; an `Op_Kind.Read` copies the target where it was recorded). `render.straight_srgb`. Test: `tests/layers` offscreen_draw_and_read_back (both blend spaces, WARP).
- `ui.wake_in_ms` (the timed wake the last build asked for, measured from now) and `ui.wake_due`. `wake_ms` counts from the build: a loop that used it as its wait timeout and as "a frame is wanted" made a frame at every early wake of any message. Measured with Wren's `tools\altdrag_sim.ps1` (AltSnap sends `WM_SIZING` before each step): the extra frame of each step was made for a caret blink not yet due (`Ui_Timer` 882 of 1544 frames of the run); with `wake_due` / `wake_in_ms`, 494 presents for 500 steps.

## [0.35.1] - 2026-10-25

### Added
- **Drag images**: `Drag_Image` is now in `platform/dragdrop.odin` (independent of the system), with `drag_image_valid`, `drag_image_fade` (the translucent ghost of a dragged element) and `drag_image_fit` (scaled down to a size, its hot spot following). `drag_image_held` says what the system's drag image helper holds after `drag_start` (Windows: read back from the data object's `DragImageBits`).
- **The app's own drag back over its window** (`drop_sync_set`, `Drop_Sync`): while `drag_start` blocks, the window asks the app at once for each `Drop_*` instead of queueing them, so the app can handle the drop before `drag_start` returns (a browser fires `drop` before `dragend`).
- **Scripted drags** (`drag_script`, `Drag_Step`, `drag_script_calls`): the next `drag_start` follows given points through the window's own drop target, with the same data object and drag image, never the real mouse (tests, remote control).
- `dragdrop_thread_init`: OLE in a single-threaded apartment on the interface thread, before any library puts it in the multithreaded one (which made `drop_target_enable` and `drag_start` fail).
- **Pointing devices** (`platform/input_devices.odin`): `input_devices` (mouse, pen, touch points; Windows: `GetSystemMetrics`), `touch_max_points`, and the rules of the primary pointer / every pointer (`primary_pointer`, `any_pointer`) as the CSS media features `pointer`, `any-pointer`, `hover`, `any-hover` see them.
- **Touch gestures** (`platform/touch_gesture.odin`, pure): `Touch_Gesture` turns the fingers' positions and times into tap, pan, pinch (scale about the fingers' middle), long press and fling (release speed); `touch_fling` gives the glide's distance and time under exponential friction.
- `Event.pointer.kind` of an emulated `Mouse_*` event says which device the system emulates (touch or pen).
- `render.capture_cancel`: forgets a capture asked for and not read.
- `tests/dragdrop`: drag images, the scripted drag back over the window with `drop_sync_set` (enter, over, drop answered at once, the image held by the system), gestures, device rules.

## [0.35.0] - 2026-10-25

### Added
- **Drag and drop between applications** (`platform/dragdrop.odin`, `dragdrop_win32.odin`, `dragdrop_stub.odin`, `docs/dragdrop.md`): the API is independent of the system; Windows implements it with OLE, other systems answer "not supported". A window becomes a drop target with `drop_target_enable`; a drag over it queues `Drop_Enter` / `Drop_Over` / `Drop_Leave` / `Drop` (position, modifiers, `Event.drop_allowed`) with the data in `drop_data` (`Drag_Data`: files, text, HTML fragment, URL and its title, PNG image, the app's own MIME types); the app answers with `drop_set_effect` (the system is given the last answer). `drag_start` runs a drag of the system with a `Drag_Data` and an optional `Drag_Image`, and returns the effect the target chose. `drop_effect_for` (the Ctrl / Shift / Alt convention), `drag_data_types`, `drag_threshold`, `drop_inject` (tests, remote control), `drop_self_test` (the round trip through the window's own drop target, no mouse). Pure helpers: `drag_custom_encode` / `decode`, `uri_list_first`, `html_format_wrap` / `html_format_fragment` (CF_HTML).
- **Fingers and pens** (`platform/pointer.odin`, `pointer_win32.odin`): `Pointer_Down` / `Pointer_Move` / `Pointer_Up` / `Pointer_Cancel` events with `Event.pointer` (`Pointer_Info`: identifier, touch or pen, primary, pressure, tilt, twist, barrel, eraser, contact size) from `WM_POINTER`. The system's mouse emulation still comes, marked `Event.emulated`. `pointer_buttons`, `pointer_pressure`, `Pointer_State`.
- `Mouse_*` events carry `Event.buttons` (`Mouse_Buttons`: the buttons held after the event), so a move during a drag says which button is held.
- `tests/dragdrop`: the pure helpers, the pointer details, the round trip of every format through the system (hidden window), injected drops.
## [0.34.0] - 2026-10-25

### Fixed
- **Raising then lowering `set_max_frame_latency` no longer leaves the swap chain with two frames in flight for good** (`render/present.odin`, `render/render.odin`, D3D11): the swap chain's frame latency object is a semaphore that the system raises when `MaximumFrameLatency` goes up and does not take back when it goes down. After a 1 -> 2 -> 1 (an app that allows a second frame for a resize step or an input frame, as Wren does) the object held one count more than a slot per round trip: every wait on `frame_waitable` returned at once, `Present` blocked for a whole refresh instead, and the frame on screen was one more frame behind the input, until the program restarted. The surplus is now remembered when the latency is lowered (`Present_State.latency_debt`) and consumed, without waiting, by `frame_waitable` / `wait_for_frame` as soon as the object has the counts to give. Measured on a 60 Hz window (a tab dragged at 1 kHz of pointer moves): wait for the slot 0.1 ms and `Present` 16 ms before, 16 ms and 0.6 ms after, and the time from input to the refresh that showed it, as the frame statistics give it, from 118 ms to 56 ms.

### Added
- `render/latency_object_test.odin`: the surplus of the latency object against a semaphore that stands for it (lowering, raising, taking without waiting, counts that come later).

## [0.33.0] - 2026-10-25

### Fixed
- **A window moved by another program's drag tool is no longer taken for a window in the system's move / size loop** (`platform/size_move.odin`, `platform_win32.odin`): AltSnap (Alt + right button drag) and similar tools resize a window with `SetWindowPos` calls from their own process and POST it `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE`. The window took them for a loop of the system: it painted from `WM_PAINT` inside its own `poll_events` (a frame within the app's frame, two presents per turn) every 16 ms, while the tool waited at every step for its thread. Now the two messages open and close the modal mode only when they arrive inside the window procedure's `DefWindowProc` call, where the system's real loop runs (`size_move_step`, pure); from outside they are ignored and the size change arrives as `WM_SIZE`, drawn by the app's own loop like any other. `WM_ENTERMENULOOP` / `WM_EXITMENULOOP` are unchanged. A move that ended with `WM_EXITSIZEMOVE` from outside still refreshes the display information (another monitor's refresh rate).

### Added
- **`platform.pump_stats(window)`** (`Pump_Stats`): how many frames were made from the window procedure (`paint_frames`, a loop of the system), how many loops of the system were entered (`modal_loops`), how many `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` from outside were ignored (`ignored_size_moves`). For tests and diagnostics of the message loop.
- `tests/size_move`: the decision `size_move_step` (messages inside / outside `DefWindowProc`, nesting, an exit with no loop open); `tests/window` checks that posted and sent `WM_ENTERSIZEMOVE` from outside open no modal mode (the frames-in-a-loop test now uses the menu loop, which a test can enter without the mouse).

## [0.32.1] - 2026-10-25

### Changed
- **The selected row of a menu is a filled, rounded row with no outline** (`ui/theme_default.odin`: `menu_item selected background` accent at 0.30, `menu_item selected border` transparent): it was the generic "selected" look, an opaque accent ring around a row with a 22 % fill, which read as a focus box more than as a highlight (the fill was too faint to see beside the ring). Lists, fields and every other selected item keep their look.

## [0.32.0] - 2026-10-25

### Added
- **Input -> screen latency, stage by stage** (`render/latency.odin`, off by default): `render.set_latency_probe(r, true)` records, for each frame that reached the screen and was built from input, the time waiting for the frame (`wait`: event received -> frame began), building and drawing (`work`), `Present` (`present`) and scan-out (`scan`: Present returned -> the refresh that showed it), then `latency_summary(r)` gives p50 / p95 / max / mean of each, the total in refreshes of the monitor, the share of frames built from input and how many presents the swap chain's statistics count as not yet shown. `latency_reset`, `latency_summarize` (pure), `latency_sample_of`. The application tells when the frame read its input with `render.set_frame_read`. `Displayed_Frame` gained `read`, `drawn` and `call` (when `frame_end` and `Present` were called). Both backends feed it; nothing is recorded or allocated while the probe is off (`render/latency_test.odin`: arithmetic and ring, no clocks).

## [0.31.0] - 2026-10-25

### Fixed
- Menus: the row under the pointer is drawn selected in the frame that sees the pointer on it, and the row it left is released in that same frame. The selection was decided while a row was built, so rows built before the hovered one (and the hovered row itself) showed the previous selection until the next frame: a pointer crossing a menu left two rows lit for a frame, and the new one a frame late (a refresh or two more once the frame had to wait for the screen). `Menu_Item_Info` gained `key` (the row's box): a level reads the hovered row from the previous frame's items when it begins (`tests/states`: `menu_hover_selects_in_the_same_frame`).

## [0.30.1] - 2026-10-25

### Changed
- Timing checks in the tests (durations, CPU and GPU times, frames in a time window) are opt-in: `base.perf_skip` (package `base`, `base/perf.odin`) runs them only with `GUI_PERF=1` or `true`, and never when `CI` is defined. The results are still checked in CI (`tests/colr`, `tests/gpufx`).

## [0.30.0] - 2026-10-25

Fixes from the review of `font`, `ui` and `platform` (0.26.0). 0.29.0 is the version of another branch (render and draw).

### Added
- **Grapheme clusters** (`font/grapheme.odin`): `font.grapheme_next`, `grapheme_prev`, `is_grapheme_boundary`, `grapheme_count` (UAX #29: ZWJ and modifier sequences, flags, tags, keycaps, Hangul, Indic conjuncts, CR LF), a boundary after or before any byte index.
- `font.selection_spans` / `x_spans_of_range`: the stretches of a line that a range of characters occupies on screen (several in bidirectional text).
- `font.raster_size_limit(s)`: the largest size glyphs are rasterized at (half an atlas page).
- `Colr_Params.surface_limit` and `work_limit`, `COLR_MAX_COMPOSITES`, `COLR_SURFACE_LIMIT`, `COLR_WORK_*`: the bounds of the COLR interpreter's memory and work. `gsub_ligate` is bounded by `GSUB_BUDGET`.
- `ui.wake_within(s, ms)`: asks for a wake within `ms`, keeping the soonest of all the requests. `ui.TIMER_KEEP_BUILDS`.
- `tests/window` (windows and messages; needs a desktop, not in CI), `tests/ui_robust` (in CI), `tests/colr/hostile_test.odin` (COLR and GSUB tables built by hand), `tests/text/grapheme_test.odin`.

### Changed
- **`Font_Id` carries a generation** (slot index in the low 20 bits): the slot of an unloaded font is reused by the next one, so loading and unloading no longer runs out of ids at 65 536; the id of an unloaded font reaches nothing, even once its slot is taken. Ids of the first font in a slot are the same numbers as before. Code that stores `Font_Id` as an opaque number is not affected; code that computes with it (index into a table by id) must mask with `1 << 20 - 1`.
- **Caret, arrows, Backspace, Delete, clicks (`hit_index`), the cut of a toast and the line breaks of `wrap_lines` work on grapheme clusters**, not on code points. Word movement keeps its code point steps.
- `platform.poll_events` / `wait_handle` drop only the events they returned before (they used to clear the whole list, losing what a poll of another window had queued for its window).
- `platform`: the mouse stays captured until the last button is up; a lost capture makes the missing `Mouse_Release`. A repaint of a window that is not itself polled, arriving while another window of the thread polls, no longer runs `on_frame` inside that poll: it sets `paint_requested` (`take_paint_request`). A move and a menu now get frames (a 16 ms timer, `WM_ENTERSIZEMOVE` .. `WM_EXITSIZEMOVE`) as the documentation said.
- `platform.open_window` returns nil when the system cannot make the window; `inject_event` of a `Close` sets `is_closed`.
- COLR: a glyph over a bound of memory or work is refused (drawn as its outline); `PaintComposite` nests at most 8 levels; the interpreter draws without the atlas lock. `colr_nests_glyph` answers "nested" for a graph it cannot read to its end (so that it goes to the interpreter, not to Direct2D), `colr_find` keeps a base glyph record whose offset is outside the table as an unreadable graph, `colr_open` accepts any offsets in a v0 header with no records and refuses a table whose base glyph list does not fit; a face with such a table is not drawn in color by Direct2D.
- Atlas: a bitmap bigger than a page makes no page and evicts none; `draw.glyph_run` caps the rasterization size and stretches the bitmap (text over 1024 px per em was invisible). The Direct2D canvas over 1M pixels is given back after use. `Settings.page_size` is documented as read by `init` only.
- `ui.menu_item` closes the menu when its block ends, not in the middle (the items after the chosen one were built as buttons for a frame). `ui.apply_palette` keeps the entries an application added to the theme first (`Theme.palette_at`); `theme_add` copies its tags. `ui.focus_step` keeps to the open modal; `focused_name` is empty for a box not built yet in this build.
- `ui.fuzzy_find` returns positions in the text it was given (a dotted capital I made them one byte off).
- Timers, scrollbar owners and a virtual list's measured heights of rows that are gone no longer grow without end.

### Fixed
- `ui.dropdown` with an empty list or a selection outside it, `ui.tabs` with fewer icons than labels, and `ui.segmented` with no label panicked or drew an infinite rectangle.
- `platform.config_dir` with `%APPDATA%` over 259 characters panicked; the clipboard is read up to the size of its block, freed when it cannot be given to the system, and `GlobalLock` is checked.
- The wake-ups of the caret blink and of a tooltip delay no longer replace each other.

## [0.29.0] - 2026-10-25

Fixes found by the review of `render` and `draw` (branch `fix/render-draw`). 0.30.0 is the font / ui / platform review branch. Each fix has a test that failed before it (`tests/lifecycle` is new).

### Fixed
- **Plane pieces with more than 6 cuts** (`draw/bsp.odin`): a piece bounded by more than `MAX_PLANE_CUTS` cuts had the extra ones thrown away, so it was drawn over its siblings' region at its own rank and covered planes that had to be in front. It is now divided by a chord between two of its corners into convex halves (the chord is one more cut for each), as often as needed: no cut is lost, no limit. Hidden (`skip`) items no longer take part in the crossing tests.
- **`draw.app_shader`** keeps `AppIn.pos`, `size` and `px` in local units under a uniform scale plus translation (DPI, zoom) as `docs/shaders.md` says (they were pixels: a scale was baked into the rectangle); any scale now goes through a transform entry. It returns false for a shader that is not `render.app_shader_ready`.
- **Device loss with several windows** (Direct3D 11): a `Surface` set aside by `surface_use` kept its swap chain, views and capture copy from the old device (undefined behaviour, then a loop of recoveries); and `set_blend_space` gave the new view format to the current window only. The window state carries the device generation and the blend space it was made in, and `surface_use` remakes a stale one (`render.Renderer.swap_gen`, `swap_space`, `space_epoch`; `Surface.gen`, `space_epoch`). `d3d_recover` flushes the old context after releasing its objects (the old HWND swap chain used to keep the window, and `CreateSwapChainForHwnd` crashed). An offscreen renderer notices a device loss at `frame_end`.
- **Captures** belong to their window (`Capture_State` is exchanged with the `Surface`: the next `frame_end` of that window takes it, not whichever window ends a frame first); the staging copy of an old device is released at recovery (a pending copy becomes `Failed`) instead of being used on the new device.
- **`wgpu_destroy`** read the texture table after freeing it. **`wgpu_recover`** without a device (adapter gone) returns false at once instead of creating textures on a null device and dropping the textures and shaders for good. A refused app pipeline on wgpu (the module passed, the pipeline did not) gives the shader up instead of invalidating every frame.
- **App shaders that cannot be remade** after a device loss keep their handle (and name) until `destroy_app_shader`; the handle used to be given to the next shader. `render.app_shader_ready(r, s)` says whether one can be drawn.
- **Kept layers and planes** (`cache_id`) follow `set_text_rendering`, `set_corner_smoothing` and the font atlas settings (they are in the key now), and a result drawn while a color glyph was still pending (`Settings.color_async`) is not kept (the glyph never came in). A masked layer that lost a target is not kept as the masked result.
- `push_plane` inside a recorded picture records nothing (it recorded the content flat, unprojected); `current_clip` is not empty while recording.
- Slug text, when the device refuses the Slug shaders, is not drawn (it was one solid rounded rect per glyph); `d3d_update_texture_r8` checks the handle, the block and the pixels like the other uploads.

### Docs
- `docs/webgpu.md` lists the functions the WebGPU backend does not have; `docs/draw.md` no longer says 3D is unsupported (planes are); `docs/shaders.md`: `app_shader` and `app_shader_ready`.

### Not fixed (reported)
- `bsp` still splits the whole context when one pair crosses, with no limit on the number of pieces, and `Plane_Item.geom` is the texel-aligned rectangle (faces that touch look crossing; Wren works around it); a backdrop of a cut plane is captured once per piece; the hash of an app shader does not cover `APP_BINDINGS` (changing it makes every precompiled blob stale: to be done with the applications' blobs); `Surface` release on a thread, the DirectComposition `Panel` lifetime, canvas source textures never zeroed (to check).

## [0.28.0] - 2026-10-25

0.27.0 is reserved for the fixes of the review branch.

### Added
- **Boxes with leaning sides** (`ui.Box.slant`, `platform.Slant`): a clickable box can say that its left and right edges lean (how far each is moved inwards at its top and at its bottom). Only that trapezoid is hit (`ui.box_contains`; the topmost box under the pointer still wins), and over an integrated title bar it is a *slanted hole* (`platform.Chrome_Regions.slanted`, `platform.Slanted_Region`, `platform.slanted_contains`; `hit_test_chrome` answers `.Client` inside it), so that the corners a trapezoid tab does not cover keep dragging the window. For tab strips drawn with sloped sides. Tests in `tests/chrome`.

## [0.25.0] - 2026-10-24

### Added
- **Application shaders** (`render/app_shader.odin`, `app.wgsl`, `wgpu_app.odin`, `draw/app_shader.odin`, [docs/shaders.md](docs/shaders.md)): `render.create_app_shader(r, {name, wgsl, dxbc, hash})` registers a fragment function the application wrote in WGSL (`fn app_shade(a: AppIn) -> vec4<f32>`, linear light, straight alpha; it reads `app_param(k)` and `app_tex0..3`), and `draw.app_shader(dc, shader, rect, params, textures, blend, radii, tint)` fills a rounded rectangle with it, in order with everything else, under the transform stack, clips, alpha stack, layers and planes (the vertex stage, corner shape and clip coverage are the renderer's). Up to 64 vec4 parameters and 4 textures per draw; blend modes `Normal`, `Add`, `Screen`, `Multiply`. Refuses (returns false, draws nothing) for shader 0, while a picture is recorded, and over the limits. Both backends: WebGPU compiles the module `rect.wgsl` + `app.wgsl` + the application's WGSL; Direct3D 11 embeds the pixel shader precompiled by `odin run tools/shaders -- app <name> <file.wgsl> <dir>` (naga + D3DCompile, `<name>.dxbc` and `<name>.sha256`; the hash of the module is checked when the shader is created, a stale blob is refused with a message).
- **Data textures**: `render.create_texture_data(r, w, h, format = .RGBA8 | .R8, mips = true)` and `update_texture_data` make textures of raw 8-bit values (a normal map, a height map, a mask): no sRGB decoding, no premultiplication, in either blend space; mip chain by `GenerateMips` / `mip.wgsl`; recreated (empty) after a device loss like images.
- `render.renderer_id(r)`: a number no other renderer of the process has had (a renderer destroyed and made again at the same address is another one), for caches of GPU objects keyed by renderer (with `device_generation`).
- `tests/appshaders` (both backends), added to `tools\test_backends.ps1` and CI.

0.24.0 is reserved for another branch; 0.25.0 follows 0.23.0 on purpose.

## [0.26.0] - 2026-10-24

Merge of three branches: the GPU 2D canvas engine, faster image uploads, the window border color. 0.20.0 and 0.21.0 (reserved below for the canvas engine and the uploads) were never released: their content is here.

### Added
- **A 2D canvas engine on the GPU** (`render/canvas.odin`, `canvas_types.odin`, `canvas.wgsl`, module `Canvas` of `tools/shaders`, [docs/canvas.md](docs/canvas.md)), Direct3D 11: `render.canvas_texture_create(r, w, h, target, mips)` makes a canvas (a render target of premultiplied sRGB-encoded RGBA8, kept) or a source of pixels (`canvas_upload`); the owner records its drawing in a `render.Canvas_List` (instances with a geometry, a paint and an operator; commands for clip masks, layers, snapshots, `putImageData`) and `canvas_submit(r, target, &list)` replays it in runs of one draw call per operator / source / clip / scissor. Rectangles, rounded rectangles and ellipses have analytic coverage (exact box filter when axis-aligned), polygons 16 N-rook samples on boundary pixels only with the fill rule per sample (the pieces of a stroke never count twice); solid, linear / radial / conic gradients and images (four filters, wrap modes) as paints; the 11 Porter-Duff operators as blend states and the 15 blend modes from a copy of the backdrop; clip masks, layers with color-matrix and gaussian-blur passes (large blurs on reduced images). `canvas_read` (waits), `canvas_read_begin` / `canvas_read_ready` / `canvas_read_finish` / `canvas_read_cancel` (polled), `canvas_read_mask`, `canvas_clear`, `canvas_set_opaque`, `canvas_supported` (false on WebGPU), `canvas_stats`, `canvas_pool_bytes`. `tests/canvas` (12 pixel tests), in `tools\test_backends.ps1`.
- `platform.set_border_color(w, rgb)`: the color of the 1-pixel border Windows 11 draws around the window (`DWMWA_BORDER_COLOR`), or `nil` for the system's. With an integrated title bar the system's border is half transparent along the top edge: a line of whatever lies behind the window showed above the app's tab strip.
- `tests/textures` (both backends): an unwritten texture is transparent, an opaque upload with a wider stride shows exactly, a translucent one is premultiplied in both spaces, a partial update zeroes the rest, mips follow an opaque upload; `render/premultiply_test.odin` checks the word-at-a-time premultiplication against `(c * a + 127) / 255` for every value. Both in `tools\test_backends.ps1`.

### Changed
- **Faster image textures**: `create_texture_rgba` no longer zeroes a new texture with one `UpdateSubresource` per row (551 driver calls, 1 to 4 ms, for a 735 x 551 photo). The texture is marked unfilled; an update that covers it whole clears the mark, and one still unfilled when the frame is submitted (or hit by a partial update first) is zeroed with a few band-sized calls from one zero buffer (`Renderer.zeros`). Observable behavior is the same: a new texture is transparent. Data textures (`create_texture_data`) and video targets keep their own paths.
- **Faster uploads**: `update_texture_rgba` checks whether the block is opaque (a vectorized AND of the words) and uploads opaque pixels, which is every JPEG and most PNG / WebP / AVIF, straight from the caller's buffer with its own pitch: no conversion pass and no scratch copy. Translucent blocks in the sRGB blend space are premultiplied a word at a time without branches or tables; the linear space keeps its table version. Both backends.

### Fixed
- Windows 11, integrated title bar: a line of what lay behind the window showed above the tab strip, because the system's border is half transparent there. An app now paints it opaque with `platform.set_border_color` (nothing changes until it does).

## [0.23.0] - 2026-10-24

### Changed
- `render.surface_create(r, hwnd, size, transparent = false, fixed_size = {})`: a second window can have a composition swap chain (`transparent`, with the window opened with `platform.open_window(..., transparent = true)`) and a fixed surface (`fixed_size`, as `set_fixed_surface` does for the renderer's own window): resized, it shows its buffers 1:1 clipped by the client area, never stretched. The default stays an opaque HWND swap chain, which stretches the last frame while the window is resized. `surface_destroy` also releases a translucent surface's DirectComposition objects (and goes through `set_teardown_wait`).

## [0.22.1] - 2026-10-24

### Added
- `render.set_teardown_wait(r, ms)`: `destroy` waits at most that long for the swap chain (and a translucent window's DirectComposition objects) to be released, which happens on a thread of its own; past it the release goes on by itself. Releasing a swap chain waits for the system's compositor to let go of the window's surface, and on a machine whose cores are all busy that took seconds in a program that was closing. 0 (the default): `destroy` waits as long as it takes, as before.

## [0.22.0] - 2026-10-23

### Added
- **Synthetic input**: `platform.inject_event(w, event)` queues an event that the next `poll_events` returns after the system's own, through the same path (hover, focus, shortcuts, text input behave as for a real device). For tests, remote control and macros.
- **Reading a frame back without the screen** (`render/capture.odin`): `render.capture_request(r, rect)` marks the next frame, `frame_end` copies that frame's render target (or a part of it) into a staging texture just before presenting, and `render.capture_poll(r)` returns RGBA8 pixels once the GPU is done (it never waits: `Pending` until then). The picture is what the renderer drew: it works with the window covered, off the screen or hidden, and does not depend on the monitor's scale. Nothing is paid until a capture is asked for. Direct3D 11 (swap chain and offscreen); the wgpu backend answers false.

0.20.0 and 0.21.0 were reserved (feat/canvas-gpu and feat/gpu-accel); they were merged into 0.26.0 instead, and those two numbers stay unused.

## [0.19.0] - 2026-10-23

### Added
- `ui.menu_item(..., keep_open = true)`: choosing the item does not close the menu, for the switches of a settings menu (the check mark changes, the menu stays for the next one).
- `ui.set_menu_item_height(em)`: the height of the items of the menus built from then on, in em (default `MENU_ITEM_EM`, 2.2; 0 puts it back). A dense tool panel sets it while it builds its menus.
- `ui.menu_heading(text)`: a small weak title above a group of items of a menu (not an item: the keyboard skips it).
- Fixed: `platform.open_window` kept the window class name in the caller's allocator, so a window opened later (once that memory was reused) failed with "cannot find window class"; the name is a literal now.
- `ui.use(state)`: selects the state the public procedures operate on, for programs that draw several windows with a state each.
- `render.surface_create / surface_use / surface_destroy`: a second window drawn by the same renderer (same device, textures, fonts), as a surface swapped in for the frames drawn to it (Direct3D 11).
- `ui.tooltip_beside()`: `tooltip` placed beside the pointer (its right, or its left when there is no room), centered on it, for the rows of a list or a table, where a tooltip below the pointer hides the rows under it.

## [0.18.0] - 2026-10-23

### Added
- **Video pictures as textures** (`render/video.odin`, `video.wgsl`, `shaders/video.hlsl`): `render.create_video_target(r, w, h)` makes an RGBA texture for a decoded picture and `render.video_convert(r, target, picture)` fills it. A `Video_Picture` is what a decoder hands over: NV12 and P010 surfaces of the device itself (the hardware decoders of Media Foundation / DXVA write into textures of the renderer's device, shared with no copy when the surface allows it), or I420 and 10-bit I420 planes in memory. It carries the crop rectangle, the rotation (0, 90, 180, 270), the matrix (BT.709, BT.601, BT.2020), the range, and the transfer function (SDR, PQ, HLG, tone-mapped to the display's white with `hdr_peak_nits` and `sdr_white_nits`). The result is an ordinary texture to draw with `draw` as any image.
- D3D11 creates its device with `VIDEO_SUPPORT` (dropped again when the software rasterizer refuses it: there is no hardware decoding there anyway); the wgpu backend has the same entry points (`wgpu_video.odin`, `video.wgsl`).
- `tests/video`: the conversion of each format against reference values (colour matrices, ranges, crops, rotations, 10 bits), on D3D11 and wgpu; `tools\test_backends.ps1` runs it.
- `render.set_max_frame_latency(r, n)`: the most frames the swap chain may queue (`IDXGISwapChain2::SetMaximumFrameLatency`); 1 by default, more while a window is resized so a present does not wait behind the previous frame. The wgpu backend has no equivalent (returns false).
- `render.set_fixed_surface(r, max_size)`: one surface size while the window resizes, shown 1:1 and clipped by the client area (composition swap chains only): a window being resized cuts the last frame instead of stretching it, and the newly shown strip stays the background until the next frame paints it. The blend-space change keeps the whole surface presented (`d3d_resize` skips the source region then).

## [0.17.1] - 2026-10-24

### Fixed
- **Direct2D crash on nested PaintGlyph**: Direct2D of Windows 11 24H2 as first released (`d2d1.dll` 10.0.26100.1, the image of GitHub's `windows-2025` runners; a patched 24H2 such as 10.0.26100.8875 draws them) dies with a null read inside `d2d1.dll`, an access violation nothing can catch, when it draws a COLR v1 glyph whose paint graph has a PaintGlyph inside the paint of another PaintGlyph (a clip inside a clip, directly or through transforms, layers, compositions and PaintColrGlyph). With `Color_Engine.System` such glyphs are now drawn by the COLR interpreter (`font.colr_nests_glyph` finds them in the font's own tables, once per glyph and face); every other glyph still goes to Direct2D. `font.colr_avoids_system(state, face, gid)` tells which. Found by the CI of Wren: `tests/colr` interpreter_agrees_with_direct2d died on U+F1400 .. U+F140F of the test font, 16 glyphs, and the process with it.
- `tests/colr`: the comparison with Direct2D leaves out the glyphs Direct2D is no longer given; `nested_glyphs_stay_off_direct2d` checks, without depending on the machine's `d2d1.dll`, that exactly those 16 glyphs are kept off it and are drawn in color by the interpreter.
## [0.17.0] - 2026-10-22

### Added
- **Planes that cut through each other** (`draw/bsp.odin`): `draw.draw_planes(dc, items)` draws the planes of one 3D rendering context in the order they hide each other, and when planes cut through each other (or hide each other in a cycle) splits them along each other's planes by a BSP (as Chromium's `BspTree` / `DrawPolygon`), the pieces ordered back to front for a viewer in front. A piece is the plane's layer drawn again under `Plane_Draw.cuts` (`Plane_Cut`: half-spaces of the space after the perspective divide, at most `MAX_PLANE_CUTS`, tested per pixel on the interpolated plane position in `rect.wgsl`: no seams between pieces). `Plane_Item.parts`: several layers on one plane (a plane and what rides on it) are cut and ordered together.
- **Effects on the composite of a plane**: `Plane_Draw.blend` (mix-blend-mode of the projected quad), `backdrop` + `shape` (backdrop-filter filtered in screen space, shown through the alpha of a layer projected like the plane).
- **Sharp planes**: `Plane_Fx.mips` gives a plane's layer a mip chain (`render.acquire_target_mips`, `render.target_mips_supported`, `Op_Kind.Mips` on D3D11 and wgpu); the projected quad's filter is anisotropic along the long axis of the footprint at the mip level of the short axis (`proj_texel`). `FLAG_PROJECT` instances take a frame rect (the antialiased edge, for a quad that is one piece of a larger plane) and the valid texel range of the layer (`colors[2]`, `colors[3]`). `draw.open_plane_frame` (map a pointer back through a plane exactly).
- `tests/planes`: planes crossing in an X (both orders of drawing give the same picture, with and without perspective), a star of three, blend on a flat and a turned plane, backdrop-filter through a silhouette, mip levels against aliasing; D3D11 and wgpu.
- **A COLR / CPAL interpreter** (`font/colr.odin`, `colr_raster.odin`, `colr_glyph.odin`): `Settings.color_engine = .Builtin` draws COLR v0 and v1 color glyphs (gradients, transforms, the 28 composite modes, clip boxes, text-color paints) on the CPU from the face's own tables, the same on every platform, into the Color atlas pages (so also async, per text color, in pictures). Default `.System` (Direct2D), unchanged. `colr_samples`, `colr_cache_kb`, `colr_counts`, `colr_of`, `colr_dump`; `Colr` / `colr_open` / `colr_render` for the portable core. A graph it refuses (cycle, bad offset) shows the glyph's outline.
- **Built-in emoji**: `font.set_emoji_source(s, path | data)`: an emoji font loaded on first need, used for emoji characters before the system fallback (`font/emoji.odin`, `emoji_data.odin` generated from Unicode 18 `emoji-data.txt` by `tools\gen_emoji_data.ps1`). Tag sequences are formed from the face's GSUB `ccmp` ligatures (`colr_gsub.odin`).
- `tools\fetch_emoji.ps1` (Noto Color Emoji COLR v1, pinned by commit and SHA-256, OT-SVG table dropped: 4.9 MiB), `font/data/NotoColorEmoji-OFL.txt`, `tools/colrcompare` (interpreter against Direct2D), `tools/colrboard` + `tools\emoji_board.ps1` (against Chrome / Edge), `tools/emojiperf`, `tests/colr` (also `tests/color_glyphs -define:COLR_ENGINE=builtin`).

### Changed
- `rect.wgsl`: two more flat varyings (the cuts of a projected quad); HLSL regenerated. `ui.VERSION` and the version constants agree again (they said 0.16.0 and 0.15.0).

## [0.16.0] - 2026-10-22

### Added
- **Planes**: layers drawn through a projective 4x4 transform (CSS Transforms 2: `perspective()`, `rotateX/Y`, `translateZ`, `preserve-3d`). `draw.push_plane` / `pop_plane` / `draw_plane` (`draw/plane.odin`): the content of a rectangle is drawn offscreen in its own frame at a chosen raster scale, then composited as a quad through a column-major 4x4 matrix (`draw.Mat4`, the order of CSS `matrix3d()`), with perspective-correct interpolation, antialiased edges, anisotropic filtering along the long axis of the pixel's footprint (`Plane_Draw.max_taps`), the clips and alpha stack of the moment, and `backface-visibility` (`Plane_Draw.cull_back`, `plane_faces_away`). `pop_plane` hands the layer back so several planes can be sorted before `draw_plane` (preserve-3d). A plane whose content did not change is kept between frames (`Plane_Fx.cache_id` / `cache_key`, the layer cache of `layer_cache.odin`): `push_plane` returns false and only the matrix changes.
- Shader: `FLAG_PROJECT` in `rect.wgsl` (a `KIND_IMAGE` instance whose homography is in two entries of the transform table): the vertex shader writes homogeneous clip positions, so the rasterizer clips against w > 0 and interpolates with perspective. No new pipeline: D3D11 (naga's HLSL, regenerated) and wgpu share it. `tests/planes` (flat plane equals the plain rect, perspective correctness, backface, a plane crossing the eye, kept planes, nested planes), on both backends.

## [0.15.0] - 2026-10-22

### Added
- A WebGPU render backend (experimental), behind the same interface as the Direct3D 11 one: `-define:TOOLKIT_RENDER=wgpu` (default `d3d11`). wgpu-native over Direct3D 12 (or Vulkan with `-define:TOOLKIT_WGPU_BACKEND=vulkan`); the shaders ported to WGSL; translucent windows through a DirectComposition visual; GPU time per step. The pixel tests pass on both backends (`tools\test_backends.ps1`). See `docs/webgpu.md`.
- `tools\fetch_wgpu.ps1` (wgpu-native and DXC pinned by SHA-256), `tools\render_probe`, `tools\ppm_diff.ps1`, `tools\window_shot.ps1`.
- **Shaders written once, in WGSL**: `render/rect.wgsl`, `filter.wgsl`, `slug.wgsl` (the Slug text shaders, ported), `mip.wgsl`. The HLSL of the Direct3D 11 backend is generated from them by naga (`tools/wgsl2hlsl`, naga pinned exactly, Cargo.lock pinned by SHA-256 in `tools\build_naga.ps1`), compiled to DXBC and embedded as before; `odin run tools/shaders` writes both; `tests/shaders` checks the SHA-256 of the sources in the header of each HLSL and the blobs; CI runs `tools/shaders -- -check`. `render/rect.hlsl`, `filter.hlsl`, `slug.hlsl` are gone (generated copies live in `render/shaders/`). D3D11 pixel tests unchanged, GPU time at a held clock and CPU per frame unchanged, first present +0 to +10 ms.`n- `render.backend_name()`, `render.adapter_description()`; `TOOLKIT_RENDER_TRACE=1` prints the time of the first present.

## [0.14.0] - 2026-10-22

### Added
- Slug text: `font.Settings.text_renderer = .Slug` (default `.Atlas`, unchanged) draws glyphs on the GPU from their quadratic Bézier outlines (Eric Lengyel's Slug algorithm, MIT, patent in the public domain; shaders pinned in `font/slug_ref`, credit in NOTICE.md): sharp at any scale, rotation, skew or page zoom, exact subpixel positions, no bitmaps, nothing to re-rasterize when the scale changes (a picture of Slug text is never stale for its scale). Color glyphs (emoji) stay on the atlas path.
  - `font`: outlines come from a provider (`font.Outline_Provider`, `slug_set_provider`; DirectWrite's `GetGlyphRunOutline` on Windows, cubics turned into quadratics within `Settings.slug_tolerance`), `slug_build` makes the curve texels (RGBA16F) and band texels (RG16UI), `slug_glyph` caches them per (face, glyph) in pages of the two textures (`Settings.slug_pages`, least recently used page reused, pictures that drew from it go stale), `slug_sync_page` / `slug_stats`.
  - `render`: `slug.hlsl` (compiled after `rect.hlsl`, which it reuses for transforms, clips and the text correction), `KIND_SLUG` instances in the ordinary instance list drawn by their own pipeline (`Frame_Data.slug_runs`, `Replay.slug_runs`: a batch is drawn in pieces, in order), `create_slug_textures`, `update_slug_page`.
  - `draw`: `glyph_run` uses it when the setting says so; pictures remember their Slug pages.
  - `tools/textcompare`: atlas | Slug | difference images and measurements; `tests/slug`.

## [0.13.1] - 2026-10-21

### Added
- GPU profile steps `Upload`, `Acquire`, `Present` and `Idle` (only while `set_gpu_profile` is on): where a frame's GPU time goes, the swap chain's wait and the present included.

## [0.13.0] - 2026-10-21

### Changed
- Interaction states show at once: hover, press, focus, selection and disabled no longer fade in or out (`hot_t`, `active_t`, `focus_t`, `disabled_t` go from 0 to 1 in the frame that sees the change), and box colours jump to their targets (a selected row, the hovered menu item). A hover change asks for no further frame. A change of palette still cross-fades every colour for `ui.PALETTE_FADE_MS` (160 ms).
- Hover and press fills are visible: the theme's new state entries `hover_fill` / `press_fill` are fractions of the way to the palette's tint (white on dark palettes, black on light ones) in sRGB values, drawn over the surface actually under the box (`ui.box_under`) with the alpha that gives that step in either blend space (`draw.alpha_like_srgb`). Per role: buttons 7 % / 13 %, ghost and icon buttons 8 % / 14 %, accent and danger buttons 10 % / 18 %, list rows 5 % / 9 %, tabs 6 % / 10 %, segments 7 % / 12 %, anything else with `.Draw_Hot_Effects` 7 % / 12 %; menu items show their selection under the pointer (8 % more while pressed). The old tiny overlay (1.4 % / 2 % in linear light) is gone. The tint entry `hover` itself is unchanged.
- Fields: the border of a `line_edit` under the pointer moves 22 % toward the tint (`input hover_border`).
- No press "squish" by default; `Theme.press_squish` (e.g. 0.04) brings it back, at once and without animation.

### Added
- `Theme.transition_ms`: > 0 brings back short cross-fades of the interaction states (default 0); `Theme.serial`, bumped by `theme_add`, `theme_set` and `apply_palette` when a colour changes.
- Selectable `list_row`s have `.Draw_Hot_Effects` (tag `list_row`, built under it only); `segmented` items light up under the pointer (tag `segment`); `tabs` items have the tag `tab`.
- `"<tags> hot text"`: the text colour of a clickable box under the pointer (falls back to the normal one). `remove_button hot text` is the palette's red, `remove_button hover_fill` / `press_fill` a light red step: push the tag `remove_button` around an `icon_button` for a delete cross.
- `Box_Flag.Hot_Within`: a box stays hot (and lit) while the pointer is on a clickable box inside it; selectable `list_row`s have it (a row and its delete button). `ui.hot_within(key)`: the same question while building (last frame's tree), e.g. to show a row's buttons only while the pointer is on it.
- `list_row` keeps a cursor given with `next({cursor = .Hand})` (rows that open something).
- `ui.state_fill(box, name, under)`, `ui.box_under(box)`, `ui.srgb_step(a, b, t)`: the theme's state steps for custom draw procs.
- `draw.alpha_like_srgb`: the inverse of `alpha_like_linear` (the alpha that looks in a blend space as a given alpha blended in sRGB values).
- `tests/states`: instant states, transitions on demand, palette cross-fade, the size of the steps in both blend spaces.
## [0.12.0] - 2026-10-21

### Added
- **Every CSS cursor**: `platform.Cursor` has all the values of CSS Basic User Interface 4 (`none`, `context-menu`, `help`,
  `progress`, `wait`, `cell`, `crosshair`, `vertical-text`, `alias`, `copy`, `no-drop`, `grab`, `grabbing`,
  `all-scroll`, `col-resize`, `row-resize`, the eight one-way resizes, `nesw-resize`, `nwse-resize`, `zoom-in`,
  `zoom-out`) next to the seven it had, which keep their names (`Arrow` = default, `Hand` = pointer, `Resize_H` =
  ew-resize, `Resize_V` = ns-resize). `cursor_from_css` / `cursor_css_name` (`CURSOR_CSS_NAMES`) convert from / to the
  keyword (`-webkit-grab` and the other legacy names too).
- On Windows a cursor is the system's (`IDC_*`: the user's scheme and size) when Windows has it (`cursor_system_id`,
  `cursor_source`); the twelve it lacks (`grab`, `grabbing`, `zoom-in`, `zoom-out`, `cell`, `copy`, `alias`,
  `context-menu`, `no-drop`, `vertical-text`, `col-resize`, `row-resize`) are **drawn by the toolkit**
  (`platform/cursor_shapes.odin`: shapes on a 32-unit grid, signed distances sampled 4 x 4 per pixel, `cursor_draw`) at
  the size of the system's cursors on the window's monitor (`SM_CXCURSOR` at its dpi, `cursor_size_px`), in the colours
  of the user's scheme (white or black pointer, read from the system's arrow: `cursor_scheme`), with the hotspot where
  Windows puts it (an arrow's tip, a hand's palm, a magnifier's lens); made once per size and scheme, again when the
  dpi or the cursor settings change (`WM_SETTINGCHANGE` `SPI_SETCURSORS`), destroyed with the window. `None` hides the
  pointer over the client area.
- **Custom cursors** from an image: `custom_cursor_create(w, rgba, size, hotspot, density, key, max_css)` (hotspot
  clamped into the image; larger than `CUSTOM_CURSOR_MAX_CSS` = 128 CSS pixels, Chromium's limit: `.Too_Large`, the
  caller shows its fallback), shared by `key` with counted references, `custom_cursor_release`,
  `set_cursor_custom(w, cc, fallback, scale)` (the image resized to its CSS size times the scale, `cursor_resample`:
  premultiplied, a tent filter as wide as the reduction; at most four sizes kept per image), `custom_cursor_valid`,
  `custom_cursor_stats`, `custom_cursor_info`.
- `destroy_window`: destroys the window and what it holds (its cursors, events, title bar regions).
- `cursor_info`, `cursor_handle_of`, `shown_cursor`, `cursor_render` (a cursor as the system draws it, for previews and
  tests).
- `examples/cursors`: every cursor in a grid (light and dark tiles, its CSS name, system or drawn), hover a cell to get
  it; the last cell has a custom cursor. `--preview N` draws the previews at N pixels.
- `tests/cursors`: CSS names, system or drawn for each value, the drawn shapes at several sizes and both schemes
  (colours, bounds, hotspots), resampling, and on a hidden window every cursor made at the system's size, custom
  cursors' references, sizes, hotspots, limits and release.

### Changed
- The cursor is shown **at once** when `set_cursor` / `set_cursor_custom` changes it while the pointer is over the
  client area or captured by the window (a drag: no `WM_SETCURSOR` comes during a capture; a page scrolled or changed
  under a pointer that does not move), and `WM_SETCURSOR` over the client area sets the one resolved last (no frame
  needed while the pointer moves over the same thing). The system keeps its own over the frame, the resize bands and
  the caption of an integrated title bar.
- `Native_Window.cursors` is no longer an array of handles (the cursor state of cursors_win32.odin).

## [0.11.1] - 2026-10-20

### Fixed
- `ui.init` makes the state current: getters (`scale`, `font_size`, `focus_key`...) called before the first `begin_build` read a nil state and crashed (Wren crashed at start-up when the pointer was over its window).

## [0.11.0] - 2026-10-20

### Changed
- **Shaders compiled ahead of time**: `render/rect.hlsl` and `render/filter.hlsl` are embedded as DXBC
  (`render/shaders/*.dxbc`, `render.SHADERS`) instead of being compiled by `D3DCompile` when the renderer starts
  (280 ms to 1.5 s of every launch, `rect.hlsl`'s pixel shader dominating). `odin run tools/shaders` writes the blobs
  after an edit of the HLSL; `tests/shaders` fails while one is stale. `-define:RENDER_COMPILE_SHADERS=true` compiles
  at start-up as before. `render.shader_compile(id)`.
- **Resizing without `ResizeBuffers` at every step**: `render.resize` keeps the swap chain's buffers larger than the
  window (rounded up to `set_resize_slack` pixels, default `DEFAULT_RESIZE_SLACK` = 256) and only changes the presented
  region (`IDXGISwapChain2::SetSourceSize`, microseconds) while the window fits in them; they are reallocated once per
  slack crossed, and made smaller when they hold more than twice the pixels shown. `ResizeBuffers` cost 1.6 to 3.5 ms
  a step. `render.buffer_size`. The window's swap chain is created with `DXGI_SCALING_STRETCH` (with `NONE`, DWM showed
  a smaller source region magnified).

## [0.10.1] - 2026-10-20

### Added
- `font.Metrics.line_gap`: the face's line gap, unrounded (a layout rounds ascent, descent and gap one by one, as Blink does).

## [0.10.0] - 2026-10-19

### Added
- **Kept filter results** (`draw/layer_cache.odin`): `Layer_Effects.cache_id`, `cache_key`, `cache_anchor` keep a
  layer's filtered texture from frame to frame (stored once the same key came two frames in a row); while the caller's
  key, the filters run by passes, the transform's linear part, the anchor's fraction and the bounds relative to the
  anchor hold, `push_effects` returns **false** (the content need not be drawn; what is drawn is discarded) and
  `pop_layer` composites the kept result, moved by whole-pixel moves of the anchor. Opacity, blend mode and trailing
  color matrices stay live. A layer up to `max_layer_px` is drawn whole when it is to be kept (scrolling it into view
  keeps it good). `Layer_Effects.cache_under` (blend modes into the opaque frame) keeps the blended pixels: no layer,
  copy or blend while what lies under is the same. `backdrop_capture` / `backdrop` take `cache_id`, `cache_key`
  (what lies under), `cache_anchor`. `set_layer_cache(dc, budget, max_layer_px, idle_frames)`, `layer_cache_stats`,
  `layer_cache_forget`, `layer_cache_clear`.
- **Masked layers are kept too**: `push_mask` takes the same `cache_*` fields and returns false like `push_effects`
  when the kept result stands (the mask is in the kept result: neither the content nor the mask layers are drawn, and
  `mask_layer` does nothing). The caller's `cache_key` must cover the mask layers; the toolkit salts it so that a masked
  and an unmasked layer never share a result. Trailing color matrices stay live only when they commute with the mask
  (no alpha column in the color rows, an alpha row that only scales alpha by [0, 1], as every CSS filter function);
  others run as passes before the mask, as CSS orders them.
- `render.keep_target` / `unkeep_target` (a pooled texture held across frames), `targets_generation`,
  `kept_targets_bytes`, `texture_bpp`, `acquire_target_format`, `Target_Format`.
- **Per-step GPU profile** (`render/gpu_profile.odin`): `set_gpu_profile(r, on, detail)`, `gpu_profile(r)`:
  time, count, pixels and estimated traffic of each kind of step (`Gpu_Step`: draw runs into the frame or a layer,
  clears, copies, color / blur / reduction / shadow / mask passes), render targets bound, the slowest steps; `detail`
  times every draw call (batch, instances, kinds, flags, scissor).
- `render.set_filter_precision(r, .Unorm8 | .Half)`: filter results in sRGB-encoded 8 bits or fp16.
- `render.FLAG_SCALED`, `render.FLAG_MATRIX` for layer composites and backdrops; `Pass.factor`.
- `examples/effects`: `--nocache`, `--half`; `--bench` prints the GPU time by kind of step; the thumbnails and the
  stress cards keep their results. `tests/gpufx`: reduced blurs against the exact gaussian, kept layers / blended
  pixels / backdrops against drawn ones (hits, whole-pixel moves, invalidation), stale texels never read, the profile,
  masked layers kept (against drawn ones, a new mask key redraws, a blur under a mask).
- **Integrated title bar** (`platform`, `ui/window_chrome.odin`): the app's own boxes are the window's title bar, as in
  Edge and Chrome (tabs in the title bar).
  - `platform.open_window(..., integrated_title = true)` or `platform.set_integrated_title(w, on)` at any time: the client
    area covers the title bar (`WM_NCCALCSIZE`); the system's frame stays on the left, right and bottom (invisible resize
    borders, the shadow, Windows 11's rounded corners and border). Maximized, the client area stops at the monitor's
    edge and leaves 2 px along an auto-hidden taskbar so that it still comes up.
  - The app reports its title bar every frame (`platform.set_chrome_regions(w, &Chrome_Regions)`: caption areas, the
    interactive holes in them, the caption buttons); `WM_NCHITTEST` answers from it (`platform.hit_test_chrome`, pure and
    unit-tested): `HTCAPTION` where nothing is interactive (drag, Aero Snap, double-click to maximize, right click for the
    system menu), `HTMINBUTTON` / `HTMAXBUTTON` (Snap Layouts on Windows 11) / `HTCLOSE`, `HTTOP*` along the top edge
    (a band of the frame's thickness, corners at both ends), the system's own answer on the other borders.
  - Over the caption and its buttons, mouse moves come as `Mouse_Move` events (hover follows); a press on a caption button
    is captured and comes as `Mouse_Press` / `Mouse_Release` (the system never draws its own buttons over the app's).
    `Mouse_Leave` only when the pointer leaves the window, not when it goes from the client area to the title bar.
  - `Event_Kind.Activate` and `Window.active`: the window became active or inactive (dimmed caption glyphs).
  - `platform.minimize`, `toggle_maximize`, `request_close`, `is_maximized`, `is_minimized`, `show_system_menu(w, pos)`,
    `set_fullscreen(w, on)` / `is_fullscreen` (the window covers its monitor without frame; back to its placement),
    `needs_top_border` (Windows 10 draws no top edge: the toolkit draws it), `resize_border`, `is_windows_11`,
    `app_icon_rgba(size)` (the exe's icon as RGBA, to draw it in the title bar). Alt+Space opens the system menu.
  - `ui.Build_Params.window`: after each build the toolkit sends the window its title bar: every box with the new
    `.Window_Caption` flag is a caption, every clickable box over it a hole (popups included), `window_buttons` are the
    caption buttons. `ui.title_bar(id)` (a row with `.Window_Caption`), `ui.window_buttons()` (minimize, maximize /
    restore, close: 46 px wide, as tall as the row, glyphs from Segoe Fluent Icons or Segoe MDL2 Assets, else drawn;
    the system's fills: hover / pressed tints, close in red `#c42b1c`, dimmed glyphs while the window is inactive; clicks
    act on the window), `ui.chrome_regions(s)`.
  - fidget: `--integrated` makes its menu bar the title bar.
- **Virtualized list** `ui.vlist(id, &Virtual_List, ids, labels, selectable)` (`ui/vlist.odin`): only the rows in view
  (and a margin) are built, whatever their number. Rows of any height: measured when laid out, kept per row identity and
  per width / scale / font size, the average for rows never seen; the view stays on the row it shows when heights above
  it change. The keyboard of `list` over every row (Up / Down, Page Up / Down, Home / End, type-ahead on `labels`,
  Enter, Escape), the active row scrolled into view at once. `vlist_destroy`, `vlist_invalidate`, `vlist_scroll_to`,
  `vlist_row_extent`.
- **Wrapped text cache**: a paragraph's lines are kept per (text, font, size, width) between builds
  (`wrap_lines_cached`, `wrap_cache_len`); layout and drawing no longer wrap every paragraph twice per frame.
- **Smooth scrolling along a curve** for the toolkit's scroll regions (`ui/scroll_anim.odin`): impulse (default, as
  Edge) or ease-out, a duration per move, sampled at the frame's time (`Build_Params.frame_ms`: a display clock, e.g. the
  vblank the frame is shown at); a new target while moving keeps the speed. `ui.set_scroll_settings(s, {curve, impulse,
  duration_ms})`; `.Exponential` is the former easing. Apps that scroll their own document the same way feel alike.
- `tests/chrome`: hit test (zones, edges, maximized), title bar regions and caption button clicks from a ui tree,
  virtualized list (rows built, measured heights, keyboard over unbuilt rows, view anchoring), wrap cache, scroll curve.

### Changed
- `list`: the keyboard handling and type-ahead are shared with `vlist` (`List_State.virtual`); no change for `list`.
- Wrapped text is drawn at the width layout wrapped it at (`Box.size`), not the rounded rect's.
- Color matrices ending a filter chain are applied by the composite (one pass and one target fewer; a layer with only
  color filters runs no pass).
- Large blurs: the reduction by 2, 4 or 8 is one pass; the result stays reduced and is sampled back by the next pass or
  the composite (no upsampling pass); the variance of the bilinear resampling is taken off the gaussian's.
- Filter passes no longer clear their target: they write a transparent ring of one texel past their region and read no
  further (the mask pass included). Filter chains end in sRGB-encoded values (no conversion pass back to linear).
- `push_effects` and `push_mask` return a bool (see above); existing calls that ignore it are unchanged.
- `Backdrop` holds the chain's trailing matrices and whether its texture is kept.
- A masked layer whose filters end with a large blur applies its mask at scale 1 over the reduced result (sampled back
  bilinearly, as the composite would).

### Tests
- `tests/chrome` and `tests/keyboard` take a lock around each test (they drive the global UI state): they no longer need `-define:ODIN_TEST_THREADS=1`, without which `tests/chrome` used to hang the test runner.

## [0.9.3] - 2026-10-19

### Color glyphs in every format
- **Direct2D draws color glyphs** (`font/color.odin`, bindings in `font/d2d.odin`): COLR v1 paint trees (linear,
  radial and sweep gradients with their extend modes, transforms, PaintComposite modes, clip boxes, PaintColrGlyph),
  COLR v0 layers, sbix / CBDT / PNG bitmaps and OT-SVG (plain or gzip) are drawn on a private WARP device into a
  bitmap read back into the atlas' Color pages. Windows 11 22H2 and later: `ID2D1DeviceContext7::DrawGlyphRunWithColorSupport`;
  Windows 10 1607 and later: the runs of `TranslateColorGlyphRun` drawn by the call of their format (no paint trees:
  v0 layers or the outline); without Direct2D: COLR v0 layers composited on the CPU as before. Whether a glyph is a
  color glyph comes from `IDWriteFactory8::TranslateColorGlyphRun` (paint trees) or `IDWriteFactory4`'s.
- **Text-color layers** (palette entry 0xFFFF, COLR v1 foreground paints, SVG `currentColor`) take the text color: a
  color glyph is drawn in two colors once to find whether it depends on it; such glyphs are kept once per text color.
  `font.glyph_image` gains an `fg` parameter (sRGB, default black); `draw.glyph_run` passes the run's color.
  `Glyph_Image.uses_fg`.
- `font.color_renderable(s, id)`: false for a face whose only color format the system cannot draw (COLR v1 before
  Windows 11 22H2): a cascade should take those characters elsewhere rather than show outlines.
- Faces with only COLR v1 (`DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE`) count as color faces. Whether a COLR v1 glyph
  uses the text color comes from its paint attributes (`IDWriteFontFace7::CreatePaintReader`), of a COLR v0 glyph from
  its layers; only SVG glyphs are drawn twice to find out.
- **Off the drawing thread** (`Settings.color_async`, off by default): a complex color glyph costs milliseconds (a
  Segoe UI Emoji COLR v1 emoji: about 4 ms on WARP). The first lookup queues it and returns a pending image
  (`Glyph_Image.pending`); one thread draws the queue, puts the bitmaps in the atlas and calls
  `font.set_color_ready_callback`'s callback (ask for a frame there). `font.color_ready_generation`,
  `font.color_pending`, `font.color_wait`. A picture recorded while one of its glyphs was pending is stale once the
  ready generation moves (`Picture.glyphs_pending`, `pending_ready`; checked before the empty-picture cull).
  `unload` drops a face's queued requests and waits for the one in flight; `destroy` stops the thread.
- `tests/color_glyphs`: Google's COLR v1 test glyphs (gradient ends and middle, sweep quadrants, radial, composite,
  rotate / skew / transform, foreground paints in two text colors), Twemoji sbix / OT-SVG / OT-SVGZ smileys, the
  ChromaCheck CBDT glyph, color glyphs off, and the same glyphs drawn through the draw layer (WARP).

### Masks
- `draw.push_mask(dc, bounds, fx)`, `draw.mask_layer(dc, mode, op)`, `draw.pop_mask(dc)` (`draw/mask.odin`): content
  drawn into a layer, multiplied by the coverage of mask layers drawn after it, each by its alpha or its luminance
  (`Mask_Mode`), composited with the layers below it by `Mask_Op` (add, subtract, intersect, exclude: CSS
  mask-composite); then filters, opacity and blend mode as `push_effects`. Mask layers draw in sRGB. Without a render
  target (or in a picture) the content is drawn unmasked and the mask layers are cut away. CSS mask-image and
  background-clip: text are drawn with it.
- `render.Pass_Mode.Mask` (`render/filter.hlsl`), `PASS_MASK_LUMINANCE`, `PASS_MASK_DEST`, `PASS_MASK_APPLY`,
  `MASK_OP_SHIFT`, `render.Mask_Op`. `pop_layer` closes a mask too.
- `tests/masks` (both blend spaces): alpha and luminance coverage, the four operators, a gradient mask under opacity
  and a clip, no mask layer, text as a mask (background-clip: text), the fallback inside a picture.

## [0.9.2] - 2026-10-19

### Added
- **Frame pacing at the monitor's rate** (`platform/display_win32.odin`, `render/present.odin`):
  - `platform.display_info(w)`: the refresh rate of the monitor the window is on, exact (`Display_Info.hz` 59.94,
    143.998, 180: the rational rate of the display path from `QueryDisplayConfig`, else the current mode, else DWM's
    composition rate, else 60), its `source`, the monitor and a `serial` that changes with any of them. Cached; read again
    after `WM_DISPLAYCHANGE`, `WM_DPICHANGED`, a move or size loop, or when the window is on another monitor.
    `display_invalidate(w)`.
  - `platform.wait_handle(w, handle, timeout_ms)`: waits for a handle (the swap chain's latency object, a timer) while
    taking the window's keyboard and mouse messages as they arrive; they are kept for the next `poll_events`.
  - `Event.stamp`: when the window procedure received the event (input latency).
  - `platform.take_paint_request(w)`: a `WM_PAINT` that came during the app's own `poll_events` (see Changed).
  - `render.set_present_mode(r, .Vsync | .Tearing)` (tearing: for variable refresh displays, the app paces its frames;
    the swap chain is created with `ALLOW_TEARING` when `tearing_supported(r)`), `present_mode`, `set_sync_interval(r, n)`
    (every n-th refresh), `set_expected_refreshes(r, x)` (app-timed frames), `frame_waitable(r)`.
  - Frame statistics after every present: `take_displayed(r)` returns each frame once it reached the screen
    (`Displayed_Frame`: present number, the input it was built from (`set_frame_input`, or `mark_input`), when Present
    returned, the vblank it was shown at, refreshes since the previous one and refreshes it came late for in a run of
    continuous frames (`set_frame_continuous`)). `present_totals`, `measured_refresh_hz` (vblank interval measured from
    the statistics), `vblank_grid` (the last vblank and the period: the grid frames land on), `qpc_to_tick`.
  - `Renderer.swap_buffers` (set before `init`): back buffers of the swap chain (default 2).
  - `-define:D3D_DEBUG=false` turns the Direct3D debug layer off in a `-debug` build (profiling with true GPU times).
- `render.wait_for_frame(r, timeout_ms)` takes a timeout and says whether the swap chain was ready.

### Changed
- `WM_PAINT` during the app's own `poll_events` no longer runs a nested frame (it presented twice in one turn of the
  loop and waited twice for the swap chain, breaking the cadence): the frame being built repaints, and
  `take_paint_request` says one was asked for. Inside a loop of the system (live resize, move, menus:
  `WM_ENTERSIZEMOVE` / `WM_ENTERMENULOOP`) `on_frame` is still called from `WM_PAINT`.
- `RENDER_PROBE` prints frames presented / shown / missed, input-to-screen latency and the measured rate from the new
  statistics.
- `stepper`: holding a button wakes the loop at the next repeat instead of drawing a frame at every refresh.

## [0.9.1] - 2026-10-19

Merge of 0.9.0 (DirectWrite text, retained glyph runs) with 0.8.1 (status bar, frame graph) and 0.8.2 (named palettes).

## [0.9.0] - 2026-10-19

Text on DirectWrite (shaping, fallback, bidi, color glyphs, atlas pages) merged with retained drawing (0.7.0).

### Retained text
- **Glyph runs record into pictures**: `draw.glyph_run` (and `text` / `text_ex` on top of it) records shaped glyphs
  (positions from the shaper, subpixel positions, color glyphs) like direct drawing; text is rasterized for the
  picture's `raster_scale` times the slot's scale (within `TEXT_RASTER_TOLERANCE` the bitmap is stretched), baked only
  at the picture's own scale. Batches switch between gray and color pages inside a picture as in a frame.
- **Staleness per atlas page**: a picture remembers the pages its glyphs are on and their epoch (`font.Page_Ref`,
  `Picture.pages`); it is `.Stale` when one of them was reused for other glyphs, or when the rendering settings changed
  (`font.atlas_settings_generation`), not on every eviction. A replayed picture marks its pages as used by the current
  frame (`font.atlas_pages_hold`): they are not reused under it. `Batch_Bounds.gray` / `.color`: the pages a picture
  batch samples, bound to the replaying context's textures (a picture can be replayed by another context).
- **Device loss**: the atlas pages upload again whole from their CPU copy (same texture handles); pictures with text
  stay valid and replay without recording (before: the atlas was reset and every picture with text went stale).
- `font.Glyph_Image.epoch`, `font.Page_Ref`, `font.atlas_pages_hold`, `font.atlas_settings_generation`.
- `tests/retained`: the scene has color emoji and shaped Arabic (system fallback) next to Latin text, rotated glyphs
  with an emoji; a page reuse with tiny pages makes only the picture on it stale while a picture drawn every frame
  keeps its page and replays exactly; new rendering settings and `clear_atlas` make a picture stale; after a device
  loss a picture with text replays identically without recording.

### Changed (retained text)
- `font.set_settings` with new rendering settings (subpixel steps, rendering mode, grid fit, color glyphs) forgets the
  cached bitmaps (they were made with the old settings; with other subpixel steps their keys meant other positions)
  and bumps the settings generation.
- Text under a GPU transform at its layout size (rotation, skew) is placed at subpixel positions in local units, as
  text at a uniform scale: a picture recorded at its own scale and replayed rotated draws what direct drawing draws.
- `Picture.atlas_generation` and `font.reset_atlas` are gone (`font.clear_atlas` clears the pages: pictures on them go
  stale).

### Fixed (merge)
- `font.shape` of one right-to-left run of several words (`one_run`, a layout fragment) left its clusters in visual
  word order: the caret of the logical end and hit testing landed inside the text. Clusters are sorted back to logical
  order (`O(n log n)`).

### Changed
- **`font` is rebuilt on DirectWrite** (stb_truetype is gone): faces from the system collection
  (`font.load_system`, `font.has_system_family`), files (`load_from_file`) and memory (`load_memory`,
  `load_from_memory`, `load_embedded`: a custom font file loader, keys never reused). Same `Font_Id`, `metrics`,
  `text_width`, `x_from_index`, `index_from_x`, `glyph` (now outline metrics) and `kern` (a pair shaped together minus
  apart) as before, so existing callers get fallback and shaping unchanged. See [docs/text.md](docs/text.md).
- `font.Metrics` gains `x_height`, `cap_height`, `underline_offset` / `_thickness`, `strike_offset` / `_thickness`.
- `draw.text` shapes (fallback, ligatures, kerning, bidi in the string's direction) and draws through `draw.glyph_run`;
  it moved to `draw/text.odin` with `TEXT_RASTER_TOLERANCE`. `draw.Context.glyphs` holds the textures of the atlas
  pages; `draw.init` / `begin_frame` / `end_frame` / `destroy` call into it (text.odin).
- `font.State` no longer has `pending` / `pending_pixels` / `glyphs` / `fonts`: the atlas is in pages uploaded per
  draw context (`font.atlas_sync_page`).

### Added
- **Cascades**: `font.cascade(entries, features, no_system_fallback)`: per-character fallback through the entries
  (`ranges` = CSS `unicode-range`), then the **system fallback** (`IDWriteFontFallback::MapCharacters`); clusters stay
  in one face (marks, selectors, ZWJ emoji sequences). OpenType `features` on every face.
- `font.with_simulations` (synthetic bold / oblique), `font.axes`, `font.with_variations` (variable fonts),
  `font.unload`, `font.valid`, `font.primary_face`, `font.set_settings`, `font.clear_atlas`, `font.clear_word_cache`.
- **Shaping**: `font.shape` -> `Shaped{glyphs (visual order), clusters (logical order), width}` (`Glyph_Pos`,
  `Cluster`), `Shape_Options{direction, one_run, letter_spacing, word_spacing, justify}`, `font.measure`,
  `font.caret_x`, `font.hit_index`, `font.shaped_destroy`. Words shaped once and cached (sharded, bounded, per-thread
  front cache): measuring is thread-safe without a global lock.
- **Analyses**: `font.bidi_levels`, `bidi_runs`, `runs_of_levels`, `visual_order`, `reorder` (UAX #9);
  `font.line_breaks` (UAX #14, dictionaries for Thai...); `font.maybe_rtl`, `font.first_strong_rtl`.
- **Glyph bitmaps**: `font.glyph_image` (grayscale, `Settings.subpixel_steps` horizontal positions, rendering mode and
  grid fitting from `Settings`), **color glyphs** (COLR / CPAL layers composited to RGBA, drawn as images: emoji),
  atlas pages of both kinds with LRU reuse that never clears a page a current frame uses (`atlas_begin_frame`,
  `atlas_remove_user`, `atlas_page_count`, `atlas_page_info`, `atlas_evictions`).
- `draw.glyph_run(dc, size, pos, color, glyphs)` (the painter's entry point), `draw.text_ex(..., opts)`.
- `font.Settings` / `font.DEFAULT_SETTINGS` (`font.init(s, settings)`).
- `tests/text`: faces, memory faces, fallback (U+2190 in a Latin font), ligatures and kerning, Arabic joining,
  Devanagari, bidi, line breaks, color emoji pixels, atlas stress with a tiny atlas, measuring from 8 threads, and a
  WARP pixel test of drawn text.

### Fixed
- A full atlas no longer resets in the middle of a frame (glyphs drawn earlier in the frame showed the glyphs
  rasterized over them: "20 ☒ 7 minutes").

## [0.8.2] - 2026-10-19

### Added
- The palettes of fidget are built in: `PALETTE_GRAPHITE`, `PALETTE_NORD`, `PALETTE_DRACULA`, `PALETTE_AMBER`, `PALETTE_AERO`,
  `PALETTE_BOOTSTRAP`, the `NAMED_PALETTES` table (with Midnight and Daylight) and `palette_named(name)`. fidget uses the table.

## [0.8.1] - 2026-10-19

### Added
- **Status bars and frame statistics** (`ui/status.odin`): `status_bar(id)` (a bar along the bottom of a window, theme
  tags "bar", text a little smaller), `status_fill(id)` (the flexible part of the bar: takes the room left, clips its
  items), `status_item(id, tone, mono, clickable, width)`, `status_separator()`.
- `Frame_History`: a ring of `History_Sample`s (up to `HISTORY_SERIES` = 8 stacked values, a time, an app tag):
  `history_init` / `history_destroy` / `history_resize` (keeps the newest) / `history_clear` / `history_push` /
  `history_at` / `history_last` / `history_find_tag` (complete a sample later: GPU times arrive a few frames late) /
  `sample_total`; `history_stats(h, since_ms, budget)` (n, mean, min, max, p50, p95, p99, over budget, per-series mean
  and max, span) and `history_rate(h, now_ms, window_ms)` (samples per second).
- `frame_graph(id, &history, Frame_Graph_Opts)`: one stacked bar per sample, newest at the right; per-series colors,
  `series` (draw more series than the history counts, e.g. a GPU time over the CPU phases), `bars`, a dashed `budget`
  line, `scale` / `max_scale` (the top fits most bars; a rare spike is cut and marked instead of flattening the rest),
  `warn` / `bad` cap marks, `highlight`. The result is the box's signal plus the history index of the bar under the
  pointer. `graph_scale` gives the top it uses. Nothing asks for frames.
- `stat_row(id, label, value, width, mono, swatch_color, tone)`, `stat_heading`, `swatch`: rows of detail panels and
  graph legends.
- `popover(id, anchor, width, side, align_right)`: a floating panel above or below a widget (the other side when it
  does not fit, clamped to the window), open as long as the app builds it; `popover_rect(id)` for input the app routes
  itself.
- `render.set_gpu_timing(r, on)`: the GPU time of each `frame_submit` measured at run time, without
  `-define:GPU_TIMING` (timestamp queries in a ring, read back later: the CPU never waits); `gpu_timing_enabled`,
  `gpu_next_frame` and `gpu_result` (the time and the index of the submit it measured, to attribute it to its frame).
- `render.texture_memory(r)`: GPU memory of the renderer's textures by kind (glyph atlases, images with their mips,
  layer targets).
- `examples/fidget`: its status bar uses them (build and draw time per frame, stacked, with a tooltip per frame).

## [0.8.0] - 2026-10-19

### Added
- **Menus** rebuilt (`popups.odin`): any depth of submenus (`menu_submenu`, opens on click, after
  `MENU_HOVER_MS` of hover, or with Right / Enter / Space; to the right of its item, or the left when there is no room),
  `menu_separator`, disabled items (`menu_item(..., enabled = false)` or a `disabled` scope: muted, skipped by the
  keyboard), automatic width (`ctx_menu(key)` with width 0: as wide as the widest item), placement that stays on screen
  (flips to the other side of the point or anchor rect, then clamps), `ctx_menu_open_rect` (below a button, above when
  there is no room), `ctx_menu_open(..., from_keyboard = true)` (first enabled item selected), `menu_select`,
  `menu_depth`, `menu_rect`. An open menu owns the keyboard (key presses and typed text, in order): Up / Down / Home /
  End over enabled items (wrapping), Right / Left through submenus, Enter / Space choose, Escape closes one level, a
  letter selects the next item starting with it. Levels the app stops building close.
- **Keyboard lists** (`list.odin`): `list(id, &List_State)` + `list_row(&st, i, label, selectable)`: one Tab stop with
  an active row; Up / Down / Page Up / Page Down / Home / End (skipping non-selectable rows such as group headers),
  Enter or double click (`activated`), Escape (`cancelled`), type-ahead (`LIST_TYPEAHEAD_MS`), the active row kept in
  view; rows drawn with "selected" / "weak_selected" tags. `list_select`, `list_state_destroy`.
- **Wrapped text**: `Box_Flag.Text_Wrap` (a `.Text` height is that of all the lines at the width the X pass gave),
  `paragraph(id)`, `wrap_lines`.
- **Line edit history and commands**: Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z (typing and deleting merge into steps,
  `FIELD_UNDO_STEPS`), Ctrl+Insert / Shift+Insert / Shift+Delete; `field_undo`, `field_redo`, `field_can_undo`,
  `field_can_redo`, `field_cut`, `field_copy`, `field_paste`, `field_delete`, `field_insert`, `field_select_all`,
  `field_has_selection`, `field_selection` (for context menus).
- `tab_stops(on)` scopes (widgets left out of the Tab order), `tab_direction(s)` and `focus_step(s, from, dir)` (an app
  handing the focus to its own content and back), `tabs(..., right_clicked, middle_clicked)`.
- `ui.destroy(s)` frees the state. `platform.Key.Menu` (the application key), `Num_Add`, `Num_Subtract` (Ctrl+keypad
  plus / minus zoom), keypad digits as `N0`..`N9`.
- `tests/keyboard`: menus (keyboard, submenus, Escape by level, placement, press outside), lists (moves, headers,
  type-ahead, kept in view, Enter / Escape), line edit history and clipboard, wrapped text, without a window.
- fidget: View menu with submenus.

### Changed
- `ctx_menu` (`width` now optional) pads its panel; `State.ctx_menu_key`, `menu_sel`, `menu_width`... are replaced by
  `State.menus` (the stack of open levels). Dropdowns open below their button (above without room) and from the
  keyboard (Down, Alt+Down, F4) with the current value selected.

## [0.7.0] - 2026-10-19

### Added
- **Retained drawing**: `draw.Picture`, `picture_begin` / `picture_end` (record what is drawn between them instead of
  drawing it), `replay(dc, pic, m)` (`Replay_Result`: `Drawn`, `Culled`, `Stale`), `picture_destroy`,
  `picture_release`, `picture_bounds`, `picture_stale`, `picture_size`, `recording`. Transforms pushed while
  recording are **slots** (`current_slot`, `push_slot`, `picture_set_slot`, `picture_slot`): their matrices change
  without recording again (one GPU range rewritten). Clips pushed while recording are mapped at replay (an exact
  scissor under a uniform scale + translation, as `push_clip`). A replay draws under the current transform, alpha
  stack and clips, in the order of the frame (immediate drawing and replays mix). Pictures that would show text at
  another raster size, or whose glyphs were evicted from the atlas, report `Stale`.
- Persistent GPU heaps for pictures (`render.Heap_Kind`, `heap_alloc`, `heap_free`, `heap_write`, `heap_bytes`,
  `heaps_reset`, `Slot_Data`, `Replay`, `Batch.replay`, `Frame_Data.replays`): first-fit ranges, growth by
  GPU copy. `draw.set_retained_budget` / `retained_bytes`: pictures not drawn in the current frame are evicted
  (least recently drawn first) past the budget and uploaded again from their recording when drawn.
- **Device loss**: `render.recover` recreates the device, the swap chain or offscreen target, the pipeline and every
  texture under the same handle (contents cleared: `device_generation` changes); `frame_begin` and
  `draw.begin_frame` recover on their own (`Present` failures and `GetDeviceRemovedReason` are watched);
  `device_lost`, `simulate_device_loss` (tests). The glyph atlas is reset, the heaps emptied (`heap_generation`).
- **Gradients** evaluated per pixel: `draw.gradient(dc, rect, Gradient, radii, tint)`; `Gradient_Kind` (linear,
  radial, conic), repeating, stop positions, transition hints, `Gradient_Space` (sRGB, linear, Oklab, Oklch, Lab,
  Lch, HSL, HWB), `Hue_Method`, tiles (size, repeat per axis, spacing: CSS background-size / repeat / space),
  dithering. `render.KIND_GRADIENT`, gradient tables (`Frame_Data.grads`, `GRAD_*`).
- **Box shadows**: `draw.box_shadow` (outer, optionally cut out of a rounded rect) and `draw.inset_shadow`: the
  exact gaussian blur of a rounded rect with per-corner radii (erf along x, the corner arcs integrated over their
  angle), `render.KIND_SHADOW`, `SHADOW_INSET`, `SHADOW_HOLE`.
- `Rect_Inst.aux`, `Clip_Data.xform`, `CLIP_SCISSOR`, `Batch.shape`.
- Tests: `tests/retained` (replay identical to direct drawing, slots, z order, partial recording, culling, budget,
  device loss, in both blend spaces), `tests/gradients`, `tests/shadows` (against a numeric convolution).
- `examples/transforms --retained` (with `--stress=N`).

### Changed
- `Clip_Data` is 96 bytes; `render.init` and `init_offscreen` are split (`create_swapchain`,
  `create_offscreen_target`) so that `recover` can rebuild them.
- `push_effects` / `push_layer` while recording fall back to the alpha (a picture holds no offscreen layer);
  `backdrop_capture` returns nothing.
## [0.6.0] - 2026-10-19

### Added
- **Blend spaces**: `render.Blend_Space` (`Linear`, `Srgb`): where colors mix (blending, antialiased edges,
  interpolation, image filtering and mips, layer composites). `Srgb` composites like web browsers (CSS Color 4 /
  Compositing 1: `rgba(0, 0, 0, .5)` over white is 128). `render.init(..., space)`, `render.init_offscreen(..., space)`,
  `render.set_blend_space` (at run time: frame view, translucent swap chain format and color space, pooled targets),
  `render.blend_space`. Per layer: `draw.Layer_Effects.space` (`draw.Layer_Space`), `draw.blend_space(dc)`;
  `render.Layer.space`, `render.Image_Ref.space`.
- `draw.set_interpolation(dc, .Target | .Srgb | .Linear)` (`draw.Interpolation`): where corner colors interpolate
  (`render.FLAG_LERP_SRGB`, `FLAG_LERP_LINEAR`), e.g. CSS gradients in sRGB whatever the frame's space.
- RGBA textures stored in the renderer's space when created (`render.texture_space`; `R8G8B8A8_UNORM` premultiplied on
  sRGB values in `Srgb`), converted by the shader when drawn into a target of the other space (`render.FLAG_TEX_SRGB`).
- **Text correction**: `render.Text_Rendering` (`curve`: `None`, `Srgb`, `Power`; `gamma`, `contrast`,
  `coverage_exponent`), `render.set_text_rendering`, `render.text_rendering`, `render.text_rendering_default`,
  `TEXT_RENDERING_LINEAR` (the historical look), `TEXT_RENDERING_SRGB` (Chromium on Windows: Skia's sRGB curve,
  contrast 1.0). Skia's `SkMaskGamma` computed per glyph in the vertex shader; same text weight in both spaces.
- `draw.alpha_like_linear`, `ui.tuned`: translucent colors tuned for linear light keep their look in an sRGB frame;
  `ui.apply_palette(t, p, space)`; the UI interpolates its gradients in linear light in both spaces.
- `render.linear_to_srgb`, `render.srgb_to_linear`.
- `tests/blend_space` (WARP pixel tests of both spaces); `tests/layers` and `tests/effects` run in both spaces.
- Examples: `effects --srgb`, `transforms --srgb`, fidget's Settings > Blending (and `--blending=srgb|linear`).

### Changed
- Corner colors are interpolated **premultiplied** (a transparent corner no longer darkens a gradient).
- The glyph atlas holds raw coverage (`font.GLYPH_GAMMA` is gone): the 0.8 exponent is now
  `Text_Rendering.coverage_exponent`, applied by the shader (same look in `Linear`).
- The constant buffer of `rect.hlsl` is 48 bytes (target space, text parameters).
- A translucent window's swap chain color space is set explicitly (`SetColorSpace1`).

## [0.5.0] - 2026-10-19

### Added
- **Filters** on layers: `draw.push_effects(dc, bounds, Layer_Effects{alpha, filters, blend})` (then `pop_layer`).
  `Filter` / `Filter_Kind` / `Color_Matrix`; constructors `filter_blur`, `filter_drop_shadow`, `filter_brightness`,
  `filter_contrast`, `filter_grayscale`, `filter_sepia`, `filter_saturate`, `filter_hue_rotate`, `filter_invert`,
  `filter_opacity`, `filter_matrix`; `filter_is_identity`, `filters_outset`. Chains run as GPU passes
  (`render/filter.hlsl`): color matrices fused (up to 8, clamped between), separable gaussian blur with bilinear tap
  pairs and power-of-two reductions above `render.set_blur_sigma_limit`, drop shadows. Colors are filtered in sRGB as
  browsers do.
- **Blend modes**: `Blend_Mode` (the 16 modes of CSS Compositing 1, plus `Plus_Darker` / `Plus_Lighter`) on
  `Layer_Effects.blend`; the composite reads a copy of what lies under it (`render.FLAG_BLEND`, `Batch.backdrop`).
- **Backdrops**: `draw.backdrop(dc, r, radii, filters)`, `backdrop_capture` / `backdrop_draw` (CSS backdrop-filter,
  frosted glass), `render.FLAG_SCREEN`.
- **Clip shapes**: `draw.push_clip_ellipse`, `draw.push_clip_polygon` (nonzero / even-odd), antialiased.
- Renderer: `render.Frame_Data`, `render.Op` (clear, copy, filter pass), `render.Pass`, `render.Image_Ref`,
  `render.acquire_snapshot`, `render.release_target`, `render.blur_taps`.
- `tests/effects`: pixel tests of every filter and blend mode against the specifications' formulas, blur energy /
  symmetry / profile (full resolution and reduced), drop shadows, ellipse and polygon clip coverage, backdrops,
  target reuse.
- `examples/effects` (`build.bat effects`): demo, `--stress=N`, `--bench=N`. Screenshot in `docs/screenshots`.

### Changed
- Frames run their steps **in recording order** (layers are no longer drawn before the frame): `frame_submit(r,
  Frame_Data)` replaces the positional arguments; `Batch` gains `backdrop` and `op`; `Layer.done` is gone.
- Inside a layer the clip stack restarts at the layer's rect; the clip shapes around it cut its composite.
- Pooled targets are handed back as soon as their last reader is recorded: a frame with many layers uses a few
  textures.
- `Clip_Data` is 80 bytes (`kind`, `first`, `count`, `flags`); `CLIP_CIRCLE` moved from `parent` to `flags`.

## [0.4.2] - 2026-10-18

### Added
- `draw.set_circular_corners(dc, on) -> previous`: rounded rects, images and rounded clips drawn while it is on use
  circular arcs whatever `render.set_corner_smoothing` says (the squircle suits the UI; web content and other
  specifications need circles). Per primitive: `render.FLAG_CIRCLE`, `render.CLIP_CIRCLE` (or-ed into
  `Clip_Data.parent`). Reset by `begin_frame`. Pixel test in `tests/layers`.

## [0.4.1] - 2026-10-18

### Added
- **Layers (group opacity)**: `draw.push_layer(dc, bounds, alpha)` / `draw.pop_layer` draw into an offscreen render
  target composited once with `alpha`, so overlapping primitives of the group do not show through each other (CSS
  `opacity`). Transforms, rounded / rotated clips, images, text and nested layers work inside. Falls back to
  `push_alpha` when the layer would be empty or too large. `draw.layer_depth`.
- Renderer support: `render.Layer`, `Batch.target`, `frame_submit(..., layers)`, a pool of fp16 render targets
  (`render.acquire_target`, `release_targets`, `targets_bytes`), `render.FLAG_LAYER` (texel-exact composite).
- **Offscreen renderer**: `render.init_offscreen(r, size, warp)` (no window; WARP software rasterizer available) and
  `render.read_pixels`. `render.destroy` releases every GPU object.
- `tests/layers`: pixel tests (group opacity vs. per-primitive alpha, opaque layer = no layer, nested layers with a
  rotated rounded clip, target pooling, fallback).
- `examples/transforms`: the orbiting planet fades as one group (`push_layer`).

### Changed
- The shader constant buffer is 32 bytes (adds `target_origin`). `init` is split into device creation and pipeline
  setup (shared with `init_offscreen`); `frame_end` and `resize` do nothing for an offscreen renderer.

## [0.4.0] - 2026-10-18

### Added
- **2D affine transforms** in `draw`: `Affine` (CSS `matrix(a, b, c, d, e, f)` convention), `push_transform` /
  `pop_transform`, `current_transform`, and the helpers `affine_mul`, `affine_translate`, `affine_scale`,
  `affine_rotate`, `affine_skew`, `affine_around`, `affine_apply`, `affine_apply_vector`, `affine_inverse`,
  `affine_bounds`, `affine_determinant`, `affine_scale_factor`, `affine_is_identity`, `affine_is_scale_translate`,
  `affine_from_xform`. Rects (rounded, borders, shadows), gradients, text and images follow the transform; rotated and
  skewed shapes are evaluated in local space in the pixel shader (exact corners, 1 px antialiasing). Scaled text is
  re-rasterized at its on-screen size.
- **Rounded / transformed clips**: `draw.push_clip_rounded(dc, r, radii)` (per-pixel, antialiased, nests up to 8
  deep); `push_clip` under rotation or skew clips the exact rect. `draw.current_clip`.
- **Images**: `render.create_texture_rgba`, `update_texture_rgba` (sRGB, straight alpha in; stored premultiplied in
  linear light), `destroy_texture`, `texture_size`, `max_texture_size`; mip chains regenerated after updates.
  `draw.image`, `draw.image_corners` (rounded corners, sub-rectangles, tint) and `draw.image_tiled` (seamless
  repeat). Images and glyphs share batches.
- `examples/transforms` (`build.bat transforms`): animated demo, `--stress=N` / `--bench=N` load test.
- `-define:GPU_TIMING=true` + `render.gpu_ms`: GPU time of the frame (timestamp queries).
- Unit tests for the affine helpers: `odin test tests/affine`.
- [docs/draw.md](docs/draw.md): transforms, clips, images, costs and limits.

### Changed
- `render.Rect_Inst` is 144 bytes (adds `xform`, `clip`, `flags`); `use_tex` takes `KIND_SHAPE` / `KIND_GLYPH` /
  `KIND_IMAGE`. `render.Batch` gains `image`; `render.frame_submit` takes the optional transform and clip tables.
- `draw.Context.clips` holds `draw.Clip` (scissor + shape) and `xforms` holds `draw.Transform` (an `Affine`).
  `push_scale` / `pop_xform` keep their behaviour; the existing examples render pixel-identical to 0.3.2.
- Soft shapes (`soft > 1`) drawn under `push_scale` scale their blur with the rest of the shape.

## [0.3.2] - 2026-10-15

### Fixed
- Wine (and any system without DirectComposition): `render.init(transparent = true)` fell over on
  `CreateSwapChainForComposition`; it now falls back to an opaque window (`render.is_transparent` tells which).
- fidget: removing one of the initial tags crashed (it deleted a string literal).
- fidget: a clicked or dragged sticky note went to the back instead of the front.
## [0.3.1] - 2026-10-15

### Changed
- **Self-contained exes**: the icon font is compiled in (`ui.ICON_FONT_DATA`, `font.load_embedded`); nothing has to
  sit next to the exe any more.
- Text fonts: Segoe UI and Consolas are read from the Windows font folder (`platform.system_font_path`); when they
  are missing (Wine, trimmed installs) the exe falls back to Roboto and Inconsolata compiled into it
  (`font.load_system_or_embedded`, `font.FALLBACK_UI_DATA`, `font.FALLBACK_MONO_DATA`). fidget: `--embedded_fonts`
  forces the fallbacks.
## [0.3.0] - 2026-10-15

### Added
- **Arrow-key focus navigation**: once a widget that does not use arrows has the focus, the arrows move it to the
  nearest Tab stop in that direction (trapped inside modals, scrolled into view). Sliders, text fields and open
  menus keep their arrows.
- **Scrollbars**: every `View_Scroll_Y` box gets an overlay scrollbar (drag the thumb, click the track to jump);
  `text_edit` has vertical and horizontal bars.
- **Wrapping rows**: `ui.flow(gap)` and the `Wrap` box flag place children left to right and start a new line when
  the row is too narrow. Chips and the fidget button / tag / swatch rows use it.
- **Corner rounding**: `ui.set_rounding` (0 = square, 1 = default, up to 2) scales box radii and widget chrome;
  `ui.rad` for custom draws. Radio buttons stay round, and so do boxes with the new `Fixed_Radius` flag.
  Rounded rects can use squircle corners (`render.set_corner_smoothing`), which removes the visible kink where an
  arc meets a straight edge. At rounding 0 the Windows 11 window corners go square (`platform.set_square_corners`).
- **Density**: `ui.set_density` / `ui.dense` (Comfortable or `DENSITY_COMPACT`): row heights, vertical gaps and
  paddings shrink, the text keeps its size.
- **Disabled and muted scopes**: `if ui.disabled(cond) { ... }` disables everything built inside (no clicks, hover or
  focus) with a neutral look and a fade; `button_icon(disabled = ...)` uses it. `if ui.muted() { ... }` dims
  secondary content that stays interactive.
- **Finishes**: `Palette.finish` paints raised surfaces `Flat`, `Gradient` (Bootstrap 2: vertical gradient, top
  highlight, embossed text, focus glow) or `Glass` (Windows 7 Aero: glossy top half, bottom glow, white rim).
  `ui.paint_rect` gives custom draws the same finish. Palettes can also set a bar colour.
- **Translucent windows**: `render.init(transparent = true)` presents through DirectComposition with a linear fp16
  (scRGB) swap chain, so translucent pixels compose correctly; `platform.set_backdrop` shows the Windows 11 acrylic
  backdrop behind them.
- **Selection outline**: selected rows, menu items and palette entries get a crisp accent border over a light fill.
- fidget: Aero and Bootstrap themes (8 themes; Graphite is now the default), Settings for rounding, corner shape and
  density, an "Enabled" switch that disables a card, a grouped data table (collapsible department groups with
  totals, two-line headers with column totals, right-aligned numbers, column separators, alternating rows),
  `--bench=N` (CPU time per frame), `--compact`, `--size=WxH`, `--long_text`.
- `tools/keyboard_test.ps1`: 33 checks (arrow navigation, menus closing on a click outside).

### Changed
- A box with `Draw_Border` keeps its border out of the layout (like CSS border-box): its children sit inside it, so a
  border never hides a child's own outline.
- Disabled boxes no longer get a dimming overlay: they switch to neutral colours and fade as a whole.

### Fixed
- Context menus and dropdowns now close on a click anywhere outside, not only on clickable boxes.
- Rects ignored the alpha stack (`draw.push_alpha`): only text faded.
- The page and the menu bar inherited the default radius, leaving dark pixels in the window corners.
- The sort arrow and resize lines of the table header were not aligned with the column separators.
## [0.2.0] - 2026-10-15

### Added
- **Multi-line editor** `ui.text_edit` with `ui.Text_Area`: selection (keyboard and mouse, double-click word),
  Up / Down keep the column, Home goes to the first non-blank character, Ctrl+Home / End, Page Up / Down,
  word moves and deletes, Enter keeps the indentation, clipboard (CRLF and tabs normalized), undo / redo
  (Ctrl+Z, Ctrl+Y or Ctrl+Shift+Z; edits grouped per second), wheel scrolling, optional line numbers,
  optional Tab-indents mode, Ctrl+Enter = committed, Escape leaves the field.
- **Keyboard focus navigation**: Tab / Shift+Tab move through the Tab stops in build order (wrapping), the
  focused widget is scrolled into view and gets a focus ring; Enter / Space activate buttons, checkboxes, radios,
  switches, segmented items, chips, tabs and dropdowns; sliders take arrows, Page Up / Down, Home / End.
  Inside a modal, Tab cycles through the dialog only, and the page loses the focus when the dialog opens.
- **Context menus and dropdowns from the keyboard**: Up / Down select, Enter / Space choose.
- `ui.focused_name()` (id of the focused box), new box flags `Text_Input` and `Scroll_Self`.
- fidget: a multi-line editor card, more shortcuts in the cheat sheet, `--state_title` for scripted tests.
- `tools/keyboard_test.ps1`: 28 checks with real keystrokes and modifiers (Ctrl+A/C/V, Tab, Space, Ctrl+Z/Y,
  Ctrl +/-/0, Ctrl+K, Ctrl+, and a dropdown driven from the keyboard), only sent while fidget is in front.
- New logo: a white switch and slider on a cobalt rounded square (`tools/make_logo.ps1`), also the icon of `todo.exe`.

### Fixed
- `icon_button` registered its box under a key it then replaced: the button could not hold the keyboard focus.
- A focused widget no longer steals Enter / Space from an open context menu.

## [0.1.0] - 2026-10-15

First release.

### Toolkit
- **platform** (Win32): per-monitor DPI aware window sized from the monitor DPI, events (keys, text with UTF-16
  surrogates, mouse, wheel with modifiers), clipboard, cursors, dark title bar, OS "show animations" setting,
  `wait_event` / `poll_events` (re-entrancy safe during live resize), app icon from resource id 1.
- **render** (Direct3D 11): one instanced-quad pipeline for SDF rounded rects, borders, soft shadows and glyphs;
  sRGB target (linear blending); waitable swap chain with one frame in flight for low input latency
  (~47 ms input-to-scan-out at 60 Hz, measured); `RENDER_PROBE` latency / frame-gap probe.
- **font**: TrueType via `stb_truetype`, glyph cache, shelf-packed atlas, text measurement and caret mapping.
- **draw**: rects (per-corner colors and radii), text, clip / alpha / scale stacks, sRGB / hex / HSV helpers.
- **ui**: box tree with keyed persistence (`##` / `###` id rules), style / tag / parent scopes using
  `@(deferred_none)`, five-pass layout (pixels, text, percent, children-sum, strictness, floating, cross-axis
  alignment, scrolling), signals (hover, press, click, double / right / middle click, drag, wheel), animations
  that follow the OS setting, tag-based themes with cross-fades and two built-in palettes, built-in zoom
  (Ctrl+wheel, Ctrl +/-/0).
- **Widgets**: label, button (+icon), icon button, checkbox, radio, switch, slider, range slider, stepper,
  segmented control, chips, rating, progress (determinate / indeterminate), dropdown, tabs, key caps, cards, form rows,
  single-line text field (selection, word moves, clipboard, mouse), scroll region, context menu, menu bar, tooltips,
  toasts (8 positions), modal dialogs, color pickers, fuzzy matching with highlighted labels, custom-draw boxes.

### Examples
- **fidget**: widget gallery (Controls, Inputs, Data with a 20,000-row virtualized table, Playground), command
  palette, menu bar, Settings and About dialogs, six themes, persisted settings.
- **todo**: a todo app with persistence, filters, search, context menu, light / dark theme.
- **smoke**: renderer, font and draw layers without the UI.

### Tooling
- `build.bat`, embedded exe icons, scripted interaction tests (`tools/fidget_test.ps1`, `tools/ui_test.ps1`),
  screenshot generator (`tools/screenshots.ps1`), icon generator (`tools/make_icon.ps1`).

[0.2.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.2.0
[0.1.0]: https://github.com/sachahjkl/gui_toolkit/releases/tag/v0.1.0
