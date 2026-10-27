type: Fixed

**The `text` test package runs on one thread** in `tools/test_windowless.ps1`: its first test (`atlas_stress`) crashed with a signal on a CI runner, about once in five runs, with and without the fat LTO. The tests of the package share something that two of them must not use at once; the race itself is not found yet.
