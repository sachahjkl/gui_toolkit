# Changelog

All notable changes to gui_toolkit. The project follows [semantic versioning](https://semver.org); while the version is
`0.x`, a minor bump may change the API. The version is also available in code as `ui.VERSION`.

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
