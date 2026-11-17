type: Fixed

**A compositor that stops answering no longer holds a capture for good (Wayland).** Each round trip of `gt:capture` waits two seconds at most. Without an answer, the session's connection is given up and the next call opens another. A program's worker waited forever before, and every capture after it with it.
