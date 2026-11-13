# The common settings of every program

Each setting of the toolkit that changes how a program looks or answers is a preference the toolkit declares, beside
the code that uses it, with today's default. Every program inherits them: `prefs_page.standard_register` registers
them, the settings page ([prefs_page.md](prefs_page.md)) shows them grouped, and `prefs_page.standard_watch` applies
them. Nothing is blocked: a technical setting is advanced (shown under the page's folded **Advanced** part, found by a
search), never hidden. Each program keeps its own values, in its own file ([config.md](config.md)); they share the
definitions, not the values.

The columns: the name (what the file holds), the set that registers it (`Standard_Set`), its default, its range or
choices, and what applies it. "Program" in the Default column is the program's own (`Standard_Defaults`). "Start":
read at the next start (`Def.restart`). "Advanced": under the folded part. `tests/prefs_page` checks that this page
names every standard preference.

## General (`Session`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `general.menu` | Program (`true`) | | `desktop.apply` |
| `general.autostart` | Program (`false`) | | `desktop.apply` |
| `general.messages` | `system` | `system`, `window`, `off` | `messages_mode`, `ui.Announcer` |
| `general.language` | `system` | a language tag | the program, at the start (i18n to come) |

## Appearance (`Appearance`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `appearance.theme` | Program | the program's themes | `appearance_read`, `ui.theme_show` |
| `appearance.mode` | Program (`system`) | `system`, `dark`, `light` | `ui.theme_show` |
| `appearance.finish` | Program (`machined`) | `machined`, `edged`, `flat`, `gradient`, `glass` | `ui.theme_show` |
| `appearance.glow` | Program (1) | 0 to 1 | `ui.theme_show` (`Theme_Choice.glow`) |
| `appearance.font_size` | Program (14 px) | 10 to 24 px | the program's base style |
| `appearance.zoom` | 1 | 0.5 to 3 | `ui.set_zoom` |
| `appearance.density` | 1 | 0.6 to 1.2 | `ui.set_density` |
| `appearance.rounding` | 1 | 0 to 2 | `ui.set_rounding` |
| `appearance.corner_smoothing` | 1 | 0 to 1 | `render.set_corner_smoothing` |
| `appearance.animations` | `system` | `system`, `on`, `off` | `ui.set_animations` |

## Window (`Appearance`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `window.system_title` | Program (`false`) | | the program, at the start (`platform.open_window`'s `integrated_title`) |
| `window.toast_position` | `top_right` | the eight `ui.Toast_Position` | `ui.set_toast_position` |

## Text and fonts (`Text`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `appearance.text.ui_font` | "" (the program's) | a family | the program, at the start |
| `appearance.text.mono_font` | "" | a family | the program, at the start |
| `appearance.text.prose_font` | "" | a family | the program, at the start (`ui.set_family`) |
| `appearance.text.emoji_font` | "" | a font file | the program, at the start (`font.set_emoji_source`) |
| `appearance.text.system_fallback` | `true` | | `font.Settings.system_fallback` |
| `appearance.text.color_emoji` | `true` | | `font.Settings.color_glyphs` |
| `appearance.text.subpixel` | `off` | `off`, `rgb`, `bgr` | `font.Settings.subpixel_text` |
| `appearance.text.gamma` | 1.2 | 0.25 to 4 | `render.Text_Rendering.gamma` |
| `appearance.text.contrast` | 0 | 0 to 1 | `render.Text_Rendering.contrast` |
| `appearance.text.coverage_exponent` | 0.8 | 0.1 to 4 | `render.Text_Rendering.coverage_exponent` |
| `appearance.text.curve` | `none` | `none`, `srgb`, `power` | Advanced; `render.Text_Rendering.curve` |
| `appearance.text.blend_space` | `linear` | `linear`, `srgb` | Advanced; `render.set_blend_space` |
| `appearance.text.subpixel_steps` | 4 | 1 to 4 | Advanced; `font.Settings.subpixel_steps` |
| `appearance.text.grid_fit` | `default` | `default`, `enabled`, `disabled` | Advanced; `font.Settings.grid_fit` |
| `appearance.text.renderer` | `atlas` (Windows only) | `atlas`, `slug` | Advanced; `font.Settings.text_renderer` |
| `appearance.text.rendering` | `natural_symmetric` (Windows only) | `natural_symmetric`, `natural`, `gdi_classic`, `aliased` | Advanced; `font.Settings.rendering` |
| `appearance.text.slug_tolerance` | 0.244 ‰ em | 0.015 to 15.6 ‰ em | Advanced; `font.Settings.slug_tolerance` |
| `appearance.text.color_async` | `false` | | Advanced; `font.Settings.color_async` |
| `appearance.text.atlas_pages` | 4 | 1 to 64 | Advanced; `font.Settings.max_gray_pages` |
| `appearance.text.color_pages` | 2 | 1 to 64 | Advanced; `font.Settings.max_color_pages` |
| `appearance.text.page_size` | 2048 px | 256 to 8192 px | Advanced; start (`font.Settings.page_size`) |
| `appearance.text.word_cache` | 32768 | 0 to 1048576 | Advanced; `font.Settings.word_cache` |
| `appearance.text.slug_pages` | 128 | 1 to 2048 | Advanced; `font.Settings.slug_pages` |

## Scrolling (`Scrolling`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `scrolling.smooth` | `follow` | `follow`, `on`, `off` | `ui.set_smooth_scroll` |
| `scrolling.duration` | 180 ms | 0 to 1000 ms | `ui.Scroll_Settings.duration_ms` |
| `scrolling.wheel_lines` | 3 | 1 to 20 | `ui.Feel.wheel_lines` |
| `scrolling.autohide_scrollbars` | `false` | | `ui.set_scrollbar_autohide` |
| `scrolling.scrollbar_arrows` | `false` | | `ui.set_scrollbar_arrows` |
| `scrolling.curve` | `impulse` | `impulse`, `ease_out`, `exponential` | Advanced; `ui.Scroll_Settings.curve` |
| `scrolling.impulse` | 5 | 1 to 20 | Advanced; `ui.Scroll_Settings.impulse` |
| `scrolling.fling_stop_speed` | 20 px/s | 0 to 1000 px/s | Advanced; `ui.Feel.fling_stop_speed` |
| `scrolling.autoscroll.enabled` | `true` | | `ui.set_autoscroll_enabled` |
| `scrolling.autoscroll.toggle` | `true` | | `ui.Autoscroll_Settings.toggle` |
| `scrolling.autoscroll.dead_zone` | 12 px | 0 to 100 px | Advanced; `ui.Autoscroll_Settings.dead_zone` |
| `scrolling.autoscroll.max_speed` | 15000 px/s | 100 to 50000 px/s | Advanced; `ui.Autoscroll_Settings.max_speed` |
| `scrolling.autoscroll.full_dist` | 300 px | 10 to 2000 px | Advanced; `ui.Autoscroll_Settings.full_dist` |
| `scrolling.autoscroll.doubling` | 60 px | 1 to 500 px | Advanced; `ui.Autoscroll_Settings.doubling` |
| `scrolling.autoscroll.tap` | 250 ms | 0 to 2000 ms | Advanced; `ui.Autoscroll_Settings.tap_ms` |
| `scrolling.autoscroll.tap_slop` | 4 px | 0 to 50 px | Advanced; `ui.Autoscroll_Settings.tap_slop` |

## Input (`Input`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `input.key_repeat_delay` | 600 ms | 0 to 2000 ms | `ui.Feel.key_repeat_delay_ms` |
| `input.key_repeat_rate` | 25 /s | 0 to 100 /s | `ui.Feel.key_repeat_rate` |
| `input.button_repeat_delay` | 420 ms | 0 to 2000 ms | `ui.Feel.repeat_delay_ms` |
| `input.button_repeat_interval` | 55 ms | 1 to 1000 ms | `ui.Feel.repeat_interval_ms` |
| `input.undo_steps` | 200 | 1 to 10000 | `ui.Feel.undo_steps` |
| `input.undo_merge` | 1000 ms | 0 to 10000 ms | `ui.Feel.undo_merge_ms` |
| `input.typeahead` | 900 ms | 0 to 5000 ms | `ui.Feel.typeahead_ms` |
| `input.zoom_step` | 1.1 | 1.01 to 2 | `ui.Feel.zoom_step` |
| `input.step_shift` | 10 | 1 to 1000 | Advanced; `ui.Feel.step_shift` |
| `input.step_ctrl` | 100 | 1 to 10000 | Advanced; `ui.Feel.step_ctrl` |
| `input.step_alt` | 0.1 | 0.001 to 1 | Advanced; `ui.Feel.step_alt` |
| `input.step_page` | 10 | 1 to 100 | Advanced; `ui.Feel.step_page` |

## Delays and menus (`Timing`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `timing.tooltip_delay` | 500 ms | 0 to 5000 ms | `ui.Feel.tooltip_delay_ms` |
| `timing.menu_hover` | 280 ms | 0 to 2000 ms | `ui.Feel.menu_hover_ms` |
| `timing.menu_item_height` | 1.9 em | 1.2 to 4 em | `ui.Feel.menu_item_em` |
| `timing.palette_fade` | 160 ms | 0 to 2000 ms | `ui.Feel.palette_fade_ms` |

## Updates (`Update`)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `update.auto` | Program (`true`) | | the program's `update.Updater`; the page shows its state under it |
| `update.channel` | Program ("") | a channel | start; the program's `update.Updater` |
| `update.base_url` | Program ("") | an address | Advanced; start |

## Rendering (`Rendering`, all advanced)

| Name | Default | Range, choices | Applied by |
|---|---|---|---|
| `rendering.present` | `vsync` | `vsync`, `tearing` | `render.set_present_mode` |
| `rendering.max_frame_latency` | 1 | 1 to 3 | `render.set_max_frame_latency` |
| `rendering.partial_redraw` | `false` | | `host.Host.partial_redraw`, else `ui.set_partial_redraw` |
| `rendering.blur_sigma_limit` | 8 px | 2 to 40 px | `render.set_blur_sigma_limit` |
| `rendering.filter_precision` | `half` | `half`, `unorm8` | `render.set_filter_precision` |

## The page's own

`prefs_page.sidebar_width` (hidden, 14 ems, 9 to 30): the width of the settings' sidebar, which the user sets with its
handle. No page shows it, and the JSON, TOML and INI exports leave it out.
