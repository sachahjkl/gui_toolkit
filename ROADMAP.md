# Roadmap

## Now

- **Wren on the toolkit's palette and views.** Wren is the last program with a palette and dialogs of its own: its
  command registry feeds the toolkit's palette (its tabs under `@`, its history and bookmarks under `/`, its vault
  under `$`, `about:config` under `:`), and its bookmark, vault and security-key dialogs become views. Intents:
  [src/md/features/palette.md](src/md/features/palette.md), [src/md/features/views.md](src/md/features/views.md)
  (sections 1 and 7).

## Next
- **What's new in every program.** papier, classeur, inspecteur, cliche and opencode native give their changelog to
  the settings (`Page_Options.changelog`) and call `changelog_after_update` at start: after an update, a message that
  stays opens the page of what changed.
- **Wren's tab strip on a strip.** Wren's tabs scroll with the toolkit's arrows when they are too many, as `ui.tabs`,
  the views' and the dock's stacks and classeur's tabs do; today they scroll in their own way. Intent:
  [src/md/features/strip.md](src/md/features/strip.md).
- **No program blocks its interface's thread.** Each program's tests run its windows with the toolkit's blocking check
  on and fail when a disk, process or D-Bus call happens in a build, so the CI finds it.
- **The last settings that programs copy.** opencode native drops `advanced.frame_rate` for the toolkit's
  `rendering.frame_rate` (`Standard_Targets.pacer`, since 0.269), and Wren its `browser.frame.*`; Wren drops its own
  text backend, emoji and renderer settings. (The
  desktop's and the motion's are the standard `Session` and `Appearance` sets; the window's place and the rows' look are
  the toolkit's since 0.265; an FPS display is opencode native's alone, so it stays its own.)
- **opencode native on the toolkit's pieces.** Its branch `toolkit-0.266` takes the toolkit's JSON, rich paste
  (`ui.paste_answer`: its menu's Paste attaches an image as Ctrl+V does), kept zooms (`store.Kept`), context menus
  (`ui.context_take`), window place and standard folders in place of its own; it waits for its merge and release.
- **WebP on Windows in every program.** cliche, papier, classeur and inspecteur add `toolbox.Feature.Webp` to their
  Project, so their Windows packages ship `gt_webp.dll` and cliche's WebP export and every program's WebP pictures work
  there. Intent: [src/md/features/image-decode.md](src/md/features/image-decode.md).
- **One image decoder.** opencode native decodes pictures with the toolkit's `gt:image` instead of its Rust crate:
  `gt:image` reads GIF now. The switch is written (`ocn-views/build/gt-image-only.patch`) and waits for WebP on
  Windows, which the Rust crate reads today. Intent: [src/md/features/image-decode.md](src/md/features/image-decode.md).
- **Wren logs through `gt:log`.** Wren writes its log through the toolkit, as the other programs do.
- **One native crate.** One native library with features replaces the toolkit's three native libraries, so no program
  links with multiple-definition flags.
- **Platforms that plug in and out, toward macOS.** The toolkit's packages compile for macOS in its CI (`tk ci`,
  `-check:darwin_arm64`), and every portable file names the system's facts, not the system (`SYSTEM_DIRECT3D`,
  `font.SYSTEM_RASTERIZER`); what is left: the programs' packages checked for macOS too, and the native libraries' links
  (`font/backend_native.odin`, `mermaid.odin`), which stay beside their `foreign` blocks until one native crate.
- **Colours by intent in opencode native.** Its 85 `HEX_*` constants become the theme's intents and hues, so a theme
  changes them all, as cliche's graph colours do since its 0.8.

## Later

- **Image nodes for a second program.** cliche's node catalogue of image transformations moves next to `gt:flowgraph`
  when papier or classeur gets workflows of its own; the graph's add palette (`ui.flow_palette`, a right click, a link
  dropped in the void) is the toolkit's already.

- **Personal keys and aliases for every program.** Classeur's keys of one's own (Ctrl+Enter in its palette) and its
  aliases typed whole become the toolkit's, so a person sets a key or an alias for a command in any program, the same
  way. Intent: [src/md/features/palette.md](src/md/features/palette.md), "Decisions".
- **Plugins in JavaScript.** A plugin builds its own screens and views, runs commands and reads settings through a
  dynamic API over the whole toolkit, with the JavaScript engine that Wren already embeds moved into the toolkit
  (`gt:js`). Notes: [src/md/features/plugins.md](src/md/features/plugins.md).
- **Demo states injected.** A demo mode that injects states that need an account (an unlocked vault, a PIN asked), so
  a capture needs no temporary code change.
- **A reduced wgpu-native, only if it comes ready-made.** Studied and declined: WGSL and Vulkan only save about 1 MB for
  a harder build. Revisit only if gfx-rs publishes a reduced build.
