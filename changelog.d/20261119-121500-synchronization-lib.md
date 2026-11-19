type: Fixed

**A DLL that links the native library links on Windows.** Every package that links `gt_native.lib` also names `Synchronization.lib`: Rust's standard library waits with `WaitOnAddress`, which a program got from elsewhere and a DLL (a thumbnail provider) did not.
