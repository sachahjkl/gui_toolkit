type: Fixed

**`instance` on Linux**: `acquire` and `send` never block past their timeout, with a large message or a full backlog, and an owner that wakes after a sender gave up no longer handles its message as well.
