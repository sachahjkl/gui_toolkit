type: Fixed

**`devtools`**: `frameMs` (`Toolkit.metrics`, `Toolkit.frames`, timelines) is taken before a capture is read back, and a capture's conversion to RGBA moved to the encoding thread: a frame that reads a picture back no longer reads as late, with the next one early, although no refresh was missed.
