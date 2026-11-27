type: Fixed

**A watched folder removed and made again is watched again.** `fsx.Watch` on Linux kept the dead watch of a removed folder, so a folder made again at its path (a build folder cleaned) was never followed; it is now watched again at the next `watch_set`. A `watch_set` during a change's quiet time no longer reports paths it had freed.
