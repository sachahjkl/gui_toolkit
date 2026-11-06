type: Fixed

**`devtools` input and recordings**: two `Toolkit.click` of one batch are two clicks; a drag cut by `Toolkit.stopRecording` gets its `up`, a second button no longer breaks a recorded drag, and a right drag replays as one (`down` and `up` of `tools/cdp.mjs` take `--button right`). `CSS.setStyleTexts` does all of its edits or none, a `;` in a string or a comment no longer ends a declaration, and a frame of a screencast that ended no longer touches the one that took its place.
