type: Changed

**A child started on Windows opens no console window**: `process.start`, `process.run` and `process.tree_start` start it with `CREATE_NO_WINDOW`, so a program with a window that runs git or node flashes no console.
