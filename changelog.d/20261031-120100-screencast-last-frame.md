type: Fixed

**The screencast could miss its last frame**: input sent while a capture was coming back, or the last step of an animation, counted as nothing changed. Tests: the end-to-end run waits for the frames to stop instead of fixed delays, and what still depends on a machine's timing (a first frame, the last one) is said as FLAKY without failing it; frames that never stop still fail it.
