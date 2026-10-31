type: Fixed

**A device lost on one renderer no longer fails the read-backs of another** (`draw.offscreen_end`, `render.readback_poll`), and the table of read-backs is safe when renderers live on several threads.
