# What a build holds

A program's executable holds the toolkit's code that the program reaches, and nothing else: the Odin compiler emits no
procedure that nothing calls. Some parts are reached by every program, through calls that stay in a release build or
data that a widget loads; each of these is behind a define, and a program's tool chooses them once in
`toolbox.Project.features` ([toolbox.md](toolbox.md), "Features").

## What the compiler leaves out by itself

Measured with Odin `dev-2026-11` on Linux, `-o:speed` (2026-11-12):

- A procedure that nothing reaches is not in the executable. An `import` whose package nothing uses costs 0 bytes and no
  measurable compile time (the type check of the whole toolkit takes about 0.1 s).
- A `foreign import` none of whose procedures is reached is not given to the linker: the library is not linked.
- Data loaded with `#load` that nothing reads is not in the executable.
- Kept whatever is reached: an `@(init)` procedure of any package that is imported (the toolkit has none), and what
  `@(require)` names.

Splitting a package in two (syntax out of ui, notifications out of platform) therefore makes no executable smaller.

## The parts behind a define

Sizes measured on Linux, `-o:speed`, 2026-11-13. Each row adds its option to the row above it. "Stripped" is the
executable after `strip`, as `release.package_` ships it on Linux.

| examples/whatsnew | Executable | Stripped |
|---|---|---|
| Before (the endpoint in every build) | 29,059,992 | 21,550,336 |
| Release default: no devtools endpoint (`TOOLKIT_DEVTOOLS` false) | 28,708,200 (−351,792) | 21,211,728 (−338,608) |
| `LUCIDE_SUBSET`: 25 icons, 10 KB instead of 917 KB | 27,802,984 (−905,216) | 20,306,512 (−905,216) |
| `FONT_EMBED_FALLBACK=false` | 27,557,224 (−245,760) | 20,060,752 (−245,760) |

| examples/fidget | Executable | Stripped |
|---|---|---|
| Before (the endpoint in every build) | 29,431,320 | 21,914,128 |
| Release default: no devtools endpoint | 29,098,752 (−332,568) | 21,593,056 (−321,072) |
| `LUCIDE_SUBSET` (the same 25 icons: fidget names none itself) | 28,193,536 (−905,216) | 20,687,840 (−905,216) |
| `FONT_EMBED_FALLBACK=false` | 27,947,776 (−245,760) | 20,442,080 (−245,760) |

The three options together: about 1.5 MB less. Stripping: about 7.5 MB less. Without the endpoint, a release build of
whatsnew takes 20.4 s instead of 23.5 s, fidget 23.9 s instead of 26.9 s (one build each).

| Define | Default | What it leaves out | Who needs it |
|---|---|---|---|
| `TOOLKIT_DEVTOOLS` | `ODIN_DEBUG \|\| ODIN_TEST` | the CDP server of `devtools.start_from_env` ([devtools.md](devtools.md)) | a tool that drives a release build over CDP: `Feature.Devtools`; `tk build` gives it to the examples |
| `LUCIDE_SUBSET` | `""`: the whole font | the Lucide icons the sources do not name ([lucide.md](lucide.md)) | every program: `Feature.Lucide_Subset` |
| `FONT_EMBED_FALLBACK` | `true` | Roboto (159 KB) and Inconsolata (85 KB), `font.FALLBACK_UI_DATA` and `font.FALLBACK_MONO_DATA` | a program that loads its fonts itself: `Feature.No_Fallback_Fonts`. Not one that opens its windows with `host.host_open` on Linux, where Roboto is the interface font |
| `FONT_BACKEND` | `dwrite` on Windows, `native` elsewhere | the native text library on Windows | ([font-backend.md](font-backend.md)) |

## What is not done

- **One Rust library.** The native text backend, Mermaid and AccessKit are three static libraries (`native/text`,
  `native/mermaid`, `native/a11y`), each with its own copy of Rust's standard library; on Linux they link with
  `--allow-multiple-definition` (`toolbox.LINUX_LINK_FLAG`). One crate with a cargo feature per part would remove the
  copies (about 0.4 MB for a program that links two of them), but changes the libraries that programs with a Rust library of
  their own build into it (`A11Y_NATIVE_LINK=false`, `FONT_NATIVE_LINK=false`). `toolbox.build_native` already builds what
  the features need, one library each.
- **wgpu-native with WGSL and Vulkan only.** About 1 MB less on Linux, for a build of wgpu-native of our own (with
  bindgen and libclang) to maintain: not done.
