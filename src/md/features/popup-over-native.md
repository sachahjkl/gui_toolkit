# Popups over native child views

A program can embed a native child window inside a toolkit layout (for example, a Windows WebView2 child HWND in Tower's Preview panel). On Windows, DirectComposition places the window's main visual tree either wholly above (`topmost = TRUE`) or wholly below (`topmost = FALSE`, `under_children = true`) child HWNDs. Putting the main surface below child HWNDs makes the child visible, but also buries tooltips, menus, toasts, text-reveal bubbles, floating views, and modal dialogs underneath the child HWND.

## Design

Separate the visual layer from the input layer on Windows, driven by one toolkit declaration:

1. **Declaration (`ui.native_child(b)`).** During a build, the program calls `ui.native_child(b)` on the box whose rectangle hosts a native child window. At `end_build` (after `menus_raise`, `toasts_build`, and `layout`), `ui` walks each registered box up to its direct child of `s.root` (`host_root`) and records the last such root child as the split point (`native_split`).
   - If the native child is docked in the main page, `native_split` is the page box, so every floating overlay (tooltips, menus, toasts, text-reveal bubbles, floating views, modals, drag previews) sits strictly after `native_split`.
   - If the native child lives inside a floating view (`###internal_*`), `native_split` is that floating view, so the floating view itself stays on the base layer and never covers its own native child; only overlays stacked after it move above.
2. **Above-children visuals (`topmost = TRUE` DirectComposition target on the same HWND).** DirectComposition allows one `topmost = FALSE` target and one `topmost = TRUE` target on the same `HWND` simultaneously, sandwiching child HWNDs between them:
   - `render.set_under_children(r, true)` switches the main surface to `topmost = FALSE` and keeps `r.under_children` through device recovery and swap-chain remakes.
   - When any visible root child strictly after `native_split` (padded by drop-shadow reach) intersects a registered native child rectangle, `host` lazily creates a `composition_only` `render.Surface` on the same `HWND` with `under_children = false` (`topmost = TRUE`), draws `ui.draw_tree_base` on the main surface (preserving partial redraw), and draws `ui.draw_tree_overlay` on the `topmost = TRUE` surface cleared to transparent `{0, 0, 0, 0}`.
   - Because both targets attach to the same `HWND`, they share DWM z-order, move and resize in lockstep with zero drag lag, keep full per-pixel premultiplied alpha and unclipped drop shadows across the child boundary, and never block mouse input to the child HWND.
   - When overlays close (`has_native_overlay` turns false), `host` presents one empty transparent frame on the overlay surface to clear it, then stops presenting until an overlay overlaps a native child again.
3. **Interactive input shield (`platform.set_native_input_shield`).** DirectComposition visuals do not intercept mouse messages headed for cross-process child HWNDs (such as WebView2's `Chrome_WidgetWin_0`), and `WM_NCHITTEST` `HTTRANSPARENT` only skips windows on the same thread.
   - `ui.native_input_rects` computes the exact physical client rectangles where pointer input must reach the owner window instead of the native child:
     - When a menu or modal is open, every registered native child rectangle (so hovering/clicking items over the child works, and clicking the child outside a menu or dialog dismisses it).
     - Otherwise, only the intersection of each interactive overlay (boxes with `.Clickable`, `.Scroll_Self`, `.View_Scroll_X`, `.View_Scroll_Y`, `.Text_Input`, or `.Selectable` in their subtree: toasts, floating views, text-reveal bubbles, find bars) with each native child rectangle.
     - Non-interactive overlays (tooltips, pending chord bubbles, drag drop previews) contribute zero input rectangles.
   - On Windows, `platform.set_native_input_shield` maintains an invisible owned `WS_POPUP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_NOREDIRECTIONBITMAP` window with no swap chain and no GDI paint, clipped by `SetWindowRgn` to those exact rectangles (and hidden when empty). It forwards mouse move, button, wheel, and cursor messages to the owner `Window`, returns Win32 keyboard focus to the owner on press, and suppresses spurious `WM_MOUSELEAVE` across the owner/shield seam.
   - Because the shield only covers parts of the native child rectangle, the owner's normal UI, integrated title bar, and caption buttons never sit behind the shield.

## Subtleties

- **No opaque fallback for the overlay surface.** `render.surface_init(..., composition_only = true)` refuses to fall back to `CreateSwapChainForHwnd` if DirectComposition is unavailable; an opaque HWND swap chain would cover the window.
- **Shadow reach.** A tooltip or menu placed just outside a native child can cast its drop shadow into the child's rectangle. Overlap detection pads overlay bounds by `(DROP_SHADOW_SPREAD_PX + DROP_SHADOW_OFFSET_PX + DROP_SHADOW_SOFT_PX) * scale`.
- **Single-pass parity.** On headless/offscreen sessions and on Linux (where no Win32 child HWND exists), `ui.draw_tree` draws the full tree in one pass, while `ui.draw_tree_base` and `ui.draw_tree_overlay` remain callable so tests verify both layers and their composite headlessly on every platform.
- **Zero cost when unused.** Windows that never call `ui.native_child` keep `under_children = false`, allocate no second swap chain, and create no input shield.

## Refused

- **WebView2 `CompositionController` visual hosting.** Ties the toolkit to one browser API, forces every program to reimplement mouse, wheel, keyboard, cursor, IME, focus, and drag-and-drop forwarding in Rust/C++, and still requires the toolkit to split base and overlay drawing.
- **Single owned `WS_POPUP` window for both visuals and input.** `SetWindowRgn` hard-clips drop shadows and rounded corners; `WM_NCHITTEST -> HTTRANSPARENT` does not pass clicks through to cross-process child HWNDs like WebView2; and an owned window lags its owner by a frame during window drags.
- **Hiding the native child whenever any popup opens.** Breaks tooltips and toasts (cannot flash a web page away on hover) and makes menus, dropdowns, and dialogs blank out the page behind them.
