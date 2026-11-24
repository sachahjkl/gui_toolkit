type: Fixed

**A program that imports `gt:process` no longer runs a test's code at its start.** The child mode of `gt:process`'s own test (an `@(init)` that read an environment variable) was built into every program that imports the package; that test is now a test package of its own, and the toolkit's checks refuse an `@(init)` in a test file of the library.
