type: Fixed

**The CI's cold build of the Rust libraries has room to end** (.github/workflows/ci.yml): with fat LTO it is slower than the step's 12 minutes, so the cache was never saved and every run was cold; the build is a step of its own with a 30 minute limit, and the cache fills at the first success.
