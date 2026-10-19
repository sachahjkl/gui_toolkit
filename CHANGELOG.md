# Changelog

All notable changes to gui_toolkit. The project follows [semantic versioning](https://semver.org); while the version is
`0.x`, a minor bump may change the API. The version is also available in code as `ui.VERSION`.

## [Unreleased] - branch feat/ui-keyboard

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
