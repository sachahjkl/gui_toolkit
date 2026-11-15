# Window alpha

A window opened `transparent` gives its frames to a compositor that reads their alpha: DirectComposition on Windows
(every `host` window), a see-through surface on WebGPU (an overlay, a DirectComposition panel). That is what lets a
translucent theme show the desktop's backdrop through its page. It also means any pixel of alpha < 1 is a hole: the
desktop or the window behind shows there.

## The decision

A frame is opaque when its ground is: `frame_opaque(clear)`, the alpha of `render.frame_begin`'s colour is 1
(`src/render/window_alpha.odin`). The clear is the only ground. The interface paints none of its own (`ui.draw_tree`),
a translucent theme's page is a clear of alpha < 1 (`Palette.translucent`: `bg` has alpha < 1, `host.background` takes it),
and an overlay is cleared to transparent. So the renderer needs no word from the theme, the host or the program: the
colour it is given at each frame says it.

An opaque frame's alpha carries nothing. Every blend that draws into the frame keeps alpha at 1 over an opaque pixel
(`ONE, INV_SRC_ALPHA` for alpha, in every pipeline). So an opaque frame is presented with its alpha ignored:

- Direct3D 11: the composition swap chain is made with `DXGI_ALPHA_MODE_IGNORE` (`composition_alpha_mode`).
- WebGPU: the surface is configured `.Opaque` when it offers it (`wgpu_window_alpha`). A window composited opaque anyway
  (every non-overlay window on X11 and Wayland) stays so.

A translucent frame keeps `PREMULTIPLIED`. With this, no stray alpha (a pass that writes less than 1, a value a driver
gets wrong, a region not written) can make a hole in an opaque theme's window, whatever its cause. Holes were reported on
Windows in the machined finish with partial redraw, and the code reading found no pass that lowers alpha over an opaque
clear. This makes the question moot instead of guessing at it.

Refused:

- A flag a program sets (`render.set_opaque`, `host.opaque`): a second source of the same fact, which can disagree with
  the clear it gives.
- Reading `Palette.translucent` in the renderer: the renderer does not know themes, and an overlay or a program's own clear
  would need another path.
- Forcing alpha to 1 in a last pass: a full-frame pass every frame, and it hides nothing a compositor that ignores alpha
  does not hide for free.

## Changing mode

The mode follows the frames at `frame_begin`, before anything is drawn. It changes only when the frames go from opaque to
translucent or back (a theme switch, a cross-fade into a translucent theme): the fact is kept per window
(`Window_Target.opaque_frames`, which moves with `surface_use`), and a swap chain or surface remade (a recovery, a
surface refreshed) takes the last mode.

- Direct3D 11: a chain's alpha mode is fixed when it is made, and `ResizeBuffers` keeps it. `composition_remake` makes a
  chain with the old one's description (its buffers' size: the monitor's for a fixed surface; its format: the blend
  space's) and the new mode, and the frame is drawn into it. The visual keeps showing the old chain until the new one is
  presented: `composition_show`, after the frame's present, sets it as the visual's content and commits, then the old one
  goes. So no frame without content is shown. A frame that would skip its present (a partial frame of an empty region)
  presents anyway: the kept target of partial redraw is not the chain's, and it was copied whole into the new chain. The
  waitable object and the present statistics are the new chain's; the frame latency asked is kept.
- WebGPU: the surface is reconfigured with the new alpha mode, before the frame's texture is taken, as for a new present
  mode. The surface's format does not follow the alpha mode (`wgpu_frame_formats` asks the translucent one), so the
  pipelines and the kept target stay as they are. The modes the surface offers are asked only at a change.

A frame that flips between opaque and translucent at every frame would make a chain at every frame. No theme does: a
cross-fade sets the clear once, at the switch.
