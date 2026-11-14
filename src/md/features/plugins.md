# Plugins in JavaScript (not designed yet)

Asked by the user on 2026-11-14, for after the views. These are the notes taken then; the design is still to write.

## Purpose

Expose the whole toolkit through a dynamic API, so that a plugin builds its own screens and views, runs commands, and
reads and writes settings, from JavaScript, in every program.

## What exists already

Add no engine from outside. Wren already embeds two:

- QuickJS-ng 0.17, compiled to WebAssembly and run in a sandbox that protects the host from the engine's bugs
  (`wren/native/js`, `src/tools/buildjs`);
- its own JavaScript engine written in Odin: the compiler (`src/engine`, `docs/engine/frontend.md`) and the runtime
  (`docs/engine/runtime.md`), for Windows, Linux and Wasm, with no dependency on the system.

It also has a bindings generator (`native/js/odin/bindings_gen.odin`, from Web IDL). The plan: move the engine out of
Wren into a toolkit package, `gt:js`, with one API for Wren and for the plugins of every program.

## To design before writing

- Bindings generated from the toolkit's Odin declarations (one source of truth), and a `.d.ts` for plugin authors.
- Immediate mode in JavaScript: the build runs at every frame, so the cost per frame and lazy lists matter.
- No blocking work on the interface thread: a plugin's disk and network access goes through the toolkit's tasks, as
  promises.
- Security: a plugin has only the capabilities it is given (files, network, clipboard), as in Wren's sandbox.
- A versioned API for plugins, while the toolkit's Odin API keeps changing freely.
- The size added to the binary, and reloading a plugin while the program runs.
