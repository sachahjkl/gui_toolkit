type: Fixed

**A child started on Linux gets the default signals**: `process.start` and `process.run` no longer pass on the signals that the starting thread blocks, nor the ignored `SIGPIPE` of the toolkit, so a child such as `yes | head` ends at a closed pipe as it does from a shell.
