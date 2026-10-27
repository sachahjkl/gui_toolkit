# Getting started: gui_toolkit in a new project

From an empty folder to a window, then the choices a project makes (render backend, text backend, accessibility), the
tests, the versions, and the pitfalls met so far. Every command below was run as written on a clean clone (Windows 11,
PowerShell 5.1).

## 1. Prerequisites

| What | Version | Needed for |
|---|---|---|
| Windows 10 or 11, x64 | | everything (Win32, Direct3D 11; no Linux or macOS backend yet) |
| [Odin](https://github.com/odin-lang/Odin/releases/tag/dev-2026-10) | **`dev-2026-10`** (`odin version` says `dev-2026-10-nightly:84bc3fc`) | everything. The CI pins this archive by SHA-256 (`.github/actions/setup-odin/action.yml`); another nightly may not build the toolkit |
| MSVC: Visual Studio 2022 or its Build Tools, workload "Desktop development with C++" (MSVC x64 and a Windows 10/11 SDK) | | Odin links with `link.exe` and finds it by itself (no developer prompt needed); `rc.exe` for an exe icon (`-resource:`) |
| PowerShell 5.1 or 7 | | the scripts of `tools\` |
| Rust, the stable toolchain of [rustup](https://rustup.rs) (`x86_64-pc-windows-msvc`) | stable | only for the two optional native libraries (section 4: native text, accessibility) |

Nothing else: the default build (Direct3D 11, DirectWrite, no accessibility) uses only Odin's `core:` and `vendor:` and
the system. The fonts it falls back to (Roboto, Inconsolata, the icon font) are compiled into the exe.

## 2. A new project with the toolkit as a submodule

```powershell
mkdir myapp; cd myapp
git init
git submodule add https://github.com/sachahjkl/gui_toolkit libs/gui_toolkit
git -C libs/gui_toolkit tag -l                # the published versions
git -C libs/gui_toolkit checkout vX.Y.Z       # the latest (examples/hello is in every version after 0.43.0)
mkdir src, build                              # (odin does not create the output folder: "don't have access to write")
```

The smallest application is `examples/hello` (a label, a text field, a button that counts its clicks). Copy it, with
the toolkit's packages imported through a collection named `gt`:

```powershell
(Get-Content libs\gui_toolkit\examples\hello\main.odin) -replace '"\.\./\.\./', '"gt:' -replace '^package hello', 'package myapp' | Set-Content src\main.odin
odin build src -collection:gt=libs/gui_toolkit -vet -out:build/myapp.exe -subsystem:windows
build\myapp.exe                  # the window
build\myapp.exe --frames=3       # three frames of the hidden window, prints "hello: 3 frames, 11 boxes", exits 0
```

`import "gt:ui"`, `"gt:draw"`, `"gt:render"`, `"gt:font"`, `"gt:platform"` (and `"gt:flate"`, `"gt:base"`) are the
packages; they import each other by relative paths, so any collection name works. `-o:speed` for a release build
(about 9 s for hello), `-debug` for a debugger (and the Direct3D debug layer: `D3D_DEBUG` follows `-debug`).
`-subsystem:windows` gives no console: what the program prints is lost unless it is redirected
(`Start-Process build\myapp.exe -RedirectStandardOutput out.txt -Wait`); leave it out while developing to see it.

What the loop of `examples/hello/main.odin` does, in order (every example has the same):

1. `font.init`, `platform.open_window`, `render.init(&r, win.hwnd, win.size)`, a UI font
   (`font.load_system_or_embedded(..., platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)`),
   `draw.init`, `ui.apply_palette` + `ui.init`;
2. `win.on_frame`: the frame procedure, also called from inside the system's loops (live resize, menus) by `WM_PAINT`;
3. each frame: `render.wait_for_frame` -> `platform.poll_events` -> `render.resize` -> `ui.begin_build` ->
   your widgets -> `ui.end_build` -> `draw.begin_frame` -> `render.frame_begin` -> `ui.draw_tree` -> `draw.end_frame` ->
   `render.frame_end` -> `free_all(context.temp_allocator)`;
4. between frames: `platform.wait_event(win, ui.wake_in_ms(&s))` unless `ui.needs_frame(&s)` (an animation): 0 % CPU
   at rest, woken by input or by the interface's own timers (caret blink, tooltip).

The widgets are calls in `build` (`ui.label`, `ui.button(...).clicked`, `ui.line_edit`, `if ui.row() { ... }`):
README.md ("What it looks like", "Features") and `examples/fidget` (the gallery of every widget) show the rest.

## 3. What `build.bat` does

`build.bat <example> [debug]` (in the toolkit's folder) is `odin build examples/<example> -out:build/<example>.exe
-o:speed -vet -subsystem:windows` (or `-debug` instead of `-o:speed`), with `-resource:examples/<example>/<example>.rc`
when the example has an icon. It builds the examples only; your project calls `odin build` itself as above.

## 4. Choices made when compiling (`-define:`)

| Define | Values | What it needs |
|---|---|---|
| `TOOLKIT_RENDER` | `d3d11` (default), `wgpu` | wgpu: `powershell -File libs\gui_toolkit\tools\fetch_wgpu.ps1 -Dest build` once (checks the `wgpu_native` library Odin ships, puts DXC's `dxcompiler.dll` + `dxil.dll` next to the exe; without them shaders compile with FXC, about 2.5 s more at start). Ship the DLLs of `build\` with the exe |
| `FONT_BACKEND` | `dwrite` (default), `native` | native: `powershell -File libs\gui_toolkit\tools\build_text.ps1` (cargo, about 45 s the first time) -> `libs\gui_toolkit\build\text\gt_text.lib` |
| `A11Y_ACCESSKIT` | `false` (default), `true` | `powershell -File libs\gui_toolkit\tools\build_a11y.ps1` (cargo, about 20 s) -> `libs\gui_toolkit\build\a11y\gt_a11y.lib` |
| `FONT_TEXT_RENDERER` | `atlas` (default), `slug` | nothing (Slug: glyphs drawn from their outlines on the GPU; also per `font.State` at run time) |
| `TOOLKIT_WGPU_DX12_COMPILER` | `auto` (default), `dxc`, `fxc` | |

The three scripts are independent (any order; each does nothing when its output is current: a `STAMP` file next to it).
They write into the toolkit's own `build\` folder, where its packages link them from (`foreign import
"../build/text/gt_text.lib"`). `fetch_emoji.ps1` (the color emoji font of `tests/colr`) and `build_naga.ps1` (the WGSL
to HLSL translator, for whoever edits the shaders) are for the toolkit's own work, not for an application.

- **Render backend.** Direct3D 11 is the default and the complete one. wgpu (WebGPU over Direct3D 12) has the same
  interface and passes the same pixel tests, but no second windows (`render.surface_create`), no GPU canvas engine, no
  `capture_request`, no fixed surface nor frame latency setting: [webgpu.md](webgpu.md). Choose Direct3D 11 unless
  you need WebGPU itself.
- **Text backend.** DirectWrite is the default on Windows: system fonts, shaping, fallback. `native` (Fontations,
  HarfRust, ICU4X in Rust) gives the same results without DirectWrite, for the platforms to come and for comparisons:
  [font-backend.md](font-backend.md), [text.md](text.md).
- **Accessibility.** Without `A11Y_ACCESSKIT=true` screen readers see an empty window. With it, every widget is read
  through UI Automation, and the tree costs nothing until a reader asks: [accessibility.md](accessibility.md). A program
  with a Rust library of its own builds `native/a11y` (and `native/text`) into it instead and adds
  `-define:A11Y_NATIVE_LINK=false` (`FONT_NATIVE_LINK=false`): one Rust standard library per program.

## 5. Tests

In the toolkit's folder (the CI runs the same: `.github/workflows/ci.yml`):

```powershell
odin test tests/flate -vet                                         # one package
odin test tests/keyboard -vet -define:ODIN_TEST_THREADS=1           # packages that build interfaces: one test at a time
powershell -NoProfile -File tools\test_windowless.ps1              # every package that needs no window of its own (needs cargo)
powershell -NoProfile -File tools\test_backends.ps1 -Backend wgpu  # the pixel tests on WebGPU (after fetch_wgpu.ps1)
```

Pixel tests draw on an offscreen renderer on WARP (`render.init_offscreen(&r, size, warp = true)`: software, the same
pixels on every machine, no window). Timing assertions only run with `GUI_PERF=1` and never in CI (`base.perf_skip`).
A test of your own interface builds it with `ui.begin_build` and synthetic `platform.Event`s, no window needed (see
`tests/keyboard`); give it `Build_Params.time_ms` (a clock of its own, e.g. 16 ms more each frame) so that the caret
blink, double clicks and delays do not depend on how fast the machine runs.

## 6. Versions and changes

Semantic versioning, `ui.VERSION`, git tags `vX.Y.Z` with a GitHub release each; while `0.x` a minor version may change
the API (CHANGELOG.md says how). Pin the submodule to a tag and read the CHANGELOG's section before moving it. A change to
the toolkit itself follows [CONTRIBUTING.md](../CONTRIBUTING.md): a fragment in `changelog.d/`, never an edit of
`CHANGELOG.md` or `ui/version.odin`.

## 7. Pitfalls

- **The output folder must exist**: `odin build ... -out:build/x.exe` fails with "Error(013): don't have access to write"
  when `build\` is missing.
- **`odin test` deletes its exe** after the run. To run a test program several times (to chase an unstable test):
  `odin build tests/<name> -build-mode:test -out:build/<name>_test.exe`, then run the exe.
- **A `render.Surface` (second window) in a local variable**: it is several kilobytes; with `-o:speed -debug` LLVM spent
  more than ten minutes on the module that copied one. Make it where it lives: `render.surface_init(&r, &app.surface,
  hwnd, size)`, not `s, ok := render.surface_create(...)`.
- **One interface build at a time per thread, one thread of interface**: `ui.begin_build` inside another build (a frame
  made from `WM_PAINT` while a menu's loop runs inside your build) asserts; check `ui.building()` at the top of the
  frame procedure (hello does). The `ui` package keeps the State being built in a global: two threads must not build
  interfaces at the same time (tests of interfaces run with `-define:ODIN_TEST_THREADS=1`, or behind a mutex).
- **Several windows**: give each window a `ui.State` of its own and pass `Build_Params.inactive = true` when building a
  window that is not the one the user is in: its focused text fields keep their focus but show no caret and ask for no
  wake to blink it (`ui.inactive()` tells a widget of your own), as every desktop does.
- **Keys**: widgets are found again from frame to frame by their id. `"Label"` alone uses the text as the id: two
  buttons labelled "OK" collide and a label whose text changes loses its state. Use `"Text###stable_id"` (the part after
  `###` is the key) for anything whose text changes, as hello does for the counter.
- **Free the frame's temporaries**: `free_all(context.temp_allocator)` at the end of each frame (the `fmt.tprintf`
  strings of labels live there). `ui.field_destroy` the `Text_Field`s you made.
- **`expect_assert` in tests**: on Windows the test runner's handling of an assertion races the system's end of the
  process; a test program can end without a word. Catch an expected assertion on a thread of your own
  (`tests/ui_robust/nested_build_test.odin`).
- **wgpu at start-up**: without DXC's DLLs next to the exe, every shader compiles with FXC (seconds). `fetch_wgpu.ps1
  -Dest <exe folder>` puts them there.
- **Rust libraries out of date**: after updating the submodule, run `build_text.ps1` / `build_a11y.ps1` again (they
  rebuild only when the sources changed); an old `gt_a11y.lib` with new Odin code fails at link or at run time.
- **Console output of a `-subsystem:windows` exe is lost**: redirect it, or build without the flag while developing.
