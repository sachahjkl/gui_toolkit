type: Fixed

**A command to the DevTools server could wait until something else woke the window**: its wake could be taken by the frame already starting, and the window slept with the command in its inbox. The ticker now wakes it for as long as a command waits.
