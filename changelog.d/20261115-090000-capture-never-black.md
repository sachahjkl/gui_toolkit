type: Fixed

**A capture on Windows is never black.** A new screen duplication can first give a frame with only the pointer, over a surface not drawn yet; on a screen that did not change, that black surface was taken now and then. The capture now waits for a frame with a picture, else reads the screen through GDI.
