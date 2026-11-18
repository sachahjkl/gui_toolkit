type: Fixed

**A task's data is freed when its window goes before its answer runs**: an answer of `ui.task` already queued when its `State` was destroyed was dropped without calling `lost`, so its data leaked. The install's jobs also keep their memory in the heap from start to end: a program that checks its memory saw blocks made on the chores freed by its own allocator, which Windows' checks could take for a double free.
