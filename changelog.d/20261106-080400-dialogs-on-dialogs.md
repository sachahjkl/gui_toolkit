type: Fixed

**Dialogs on dialogs**: with two open, the one underneath took the focus away at every frame, so a field of the top one could not keep the keyboard, and Tab went through both. Each dialog now knows where it stands among those of the last build: the top one has the keyboard, the others wait.
