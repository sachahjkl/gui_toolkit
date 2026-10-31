type: Fixed

**`devtools`**: `Page.stopScreencast` while a frame was being read back no longer leaves the renderer unable to capture: `Page.captureScreenshot` answered "the renderer cannot capture now" for good and a later screencast sent nothing.
