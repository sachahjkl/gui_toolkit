type: Fixed

**`render.canvas_read_ready` and `canvas_read_finish`** on a read begun before a device loss: ready at once, and the finish says it failed. They used the old device's objects on the new context.
