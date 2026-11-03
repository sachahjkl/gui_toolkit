type: Added

**`tests/canvas`**: the asynchronous read-back (`canvas_read_begin` / `_ready` / `_finish`) gives the bytes drawn, the same as `canvas_read`; one cancelled gives nothing and keeps nothing (its staging texture and query released, a finish after it writes nothing); a block out of the canvas is refused at the start; a block read across the canvas's corner is transparent beyond it.
