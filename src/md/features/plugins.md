# Plugins in JavaScript

Asked by the user on 2026-11-14, for after the views. Designed on 2026-11-16; nothing is written yet.

## Purpose

A person adds to a program without a new build of it: a plugin, in JavaScript, adds commands to the palette, shows
toasts, has its own settings, builds its own views, and reads files or a server when the person allows it. One
mechanism for every program of the toolkit; a program adds its own objects to the API.

**The aim behind it (the user's): the toolkit as a runtime.** An agent writes a screen on the fly, as a plugin, and the
program shows it at once, as fast as a screen written in Odin: a dashboard of a session's work in opencode native, a
form for one task, a view of some data, made for the moment and thrown away after. This decides several points below:

- **The screen is the toolkit's own widgets, not a web page.** The display list's nodes are the toolkit's widgets
  (rows, cards, list cards, fields, tables, graphs), so what an agent makes looks and behaves as the program does, on
  the spacing scale and in the theme, with no layout of its own to get wrong.
- **Loading takes no install step and no restart.** An agent hands the program a plugin (a folder, a path, or its text
  through the program's own channel) and the view opens; a second version replaces the first in place.
- **Fast without care.** The replay of a list costs the interface no JavaScript; lazy lists and tables keep a large
  data set cheap whatever the agent writes. The cost is bounded by the toolkit, not by the agent's skill.
- **The API is described for a machine too.** The `.d.ts` and a short text of what each node and call does are what an
  agent reads before it writes a plugin: both are generated, so they never lag the API.

Three constraints shape everything below:

- The interface's thread runs no plugin code. A plugin that loops, collects its garbage or builds a large screen costs
  the interface no frame.
- A plugin has no authority of its own. It reaches only the procedures of a declared API, and each one checks what the
  person granted.
- The toolkit's Odin API keeps changing freely. The plugins see another, smaller API with a level of its own.

## What Wren has (corrected)

The first notes said Wren embeds two engines. It embeds one. QuickJS-ng's C is no longer compiled:

- `wren/src/engine` is a JavaScript engine in Odin: `frontend` (source to QuickJS-ng 0.17 bytecode), `jsrt` (the
  runtime: values, shapes, a precise mark-and-sweep collector, promises, modules; 99.92 % of test262, every directory
  at 100 % of what QuickJS-ng passes), and the leaf libraries `bigint`, `datetime`, `numconv`, `regexp`, `unicode`.
  About 74 000 lines. It imports `base:`, `core:math`, `core:mem` and `gt:config` only: no system call, no libc.
- It builds for `windows_amd64`, `linux_amd64` and `freestanding_wasm32`. Wren ships the wasm32 build inside
  Wasmtime: "the Wasm sandbox" is Wasmtime around this engine, not a second engine.
- `jscapi` gives the engine the QuickJS C API, for Wren's web glue (`native/js/odin`, 90 000 lines) only.
- `native/js/odin/bindings_gen.odin` is generated from Web IDL, for the web platform's objects. The plugins do not use
  it. What they take from Wren is the newer mechanism, `native/js/odin_abi`: an API declared as Odin procedure types,
  whose bridges the compiler instantiates, with a tool that reads the declarations for the documentation.

## Measures

Taken on 2026-11-15 on Linux x86-64, with a probe that embeds `jsrt` natively (`engine_new`, `context_new`, one
native function, `eval_source`, `call_function`).

| | native, in the program | wasm32 in Wasmtime (what Wren ships) |
|---|---|---|
| size added to a program | 2.1 MB stripped (`-o:size`), 2.5 MB (`-o:speed`) | about 12 MB for Wasmtime (Wren's own figure; `libwasmtime.a` is 75 MB) plus the engine's image |
| a runtime and its realm | 1.5 ms | preinitialised image; not measured outside Wren |
| the first script compiled and run | 0.3 ms | |
| one call from JavaScript to a host procedure | 30 to 60 ns | a Wasm import call plus the checks of its addresses |
| a retained tree made in JavaScript | 0.5 to 0.9 µs per row of 4 objects | |
| an engine bug | reaches the program | loses the realm only |
| build | Odin only | Rust static library, a pinned download, a second linker step |

For scale: `papier` is 30 MB and `classeur` 28 MB unstripped; Wasmtime alone adds a third to each.

Two defects showed in the native build, and both break a plugin on its first day:

- `engine_new(context.allocator)` aborts with `jsrt: out of memory` (`gc.odin`, `chunk_table_add`). The table of
  chunks covers the range of addresses from the lowest chunk to the highest; in Wasm's linear memory that range is
  small, on a native heap it is not. On one reserved block the engine runs.
- An allocation that fails is a `panic`, which ends the process. In Wasm it is a trap that loses a realm.

Also found: the test262 judge does not build on Linux (`prof_start` exists for Windows only).

## Decisions

### 1. The engine: Wren's Odin engine, native, one copy

- **`gt:js` is Wren's engine, moved.** `src/engine/{frontend,jsrt,bigint,datetime,numconv,regexp,unicode}` become
  `src/js` and its sub-packages; its docs become intent files here; its test262 judge becomes a `tk` command. Wren
  deletes `src/engine` and imports `gt:js` in the same piece of work. Wren's build of the engine to wasm32
  (`buildjs`) compiles the toolkit's packages: one source, two targets, no copy.
- **`jscapi` stays in Wren.** Only the web glue is written against the QuickJS C API. The plugins use the embedding
  interface (`jsrt/embed.odin`), which becomes the public face of `gt:js`.
- **The toolkit runs it natively, not in Wasm.** Wasmtime stays in Wren and does not enter the toolkit. A web page is
  hostile code that runs without consent: Wren needs the memory sandbox. A plugin is code a person chose and
  granted: its risk is what it may call, and that is closed by the API (decision 4), not by a memory sandbox.
  12 MB and a Rust library in every program is the price refused.
- **The native build keeps Odin's bounds checks, always.** An out-of-range index in the engine is then a panic, not a
  write. This does not cover every engine bug (a use after a collection). See "What this does not protect from".
- **Each runtime lives in one reserved block of addresses** (`virtual.reserve`, committed as it grows). This fixes the
  chunk table, gives the plugin's memory a hard limit (`Host_Config.malloc_limit`, 64 MB by default), and frees a
  stopped plugin in one call.
- **An allocation that fails raises the engine's uncatchable error**, on every path. The remaining `panic` sites of
  `jsrt` (15 today) are read one by one during the move; each becomes an error or keeps a written reason.
- **The loop JIT stays out of the native build.** It emits Wasm and already compiles only for wasm32.

Refused:

- **QuickJS-ng in C.** Wren no longer has it. It adds a C compiler to every program's build, and a second engine to
  keep at the same level of conformance.
- **Both engines, or both targets, behind one API in the toolkit.** Two ways to run a plugin are two sets of bugs. The
  boundary of decision 2 is made of messages, so that the isolation can change later without a change of the API.
- **Wasmtime in the toolkit now.** See the table.
- **A plugin host in another process now.** It contains every crash, and it is the next step if strangers' plugins
  become a goal. It needs a protocol, a start per system and a second binary: too much for the first slices.

### 2. The interface: a display list, replayed each frame

Neither of the two options of the notes is taken.

- **A plugin runs on a thread of its own**, one runtime per plugin, started at its first use. It waits on one queue of
  messages. It never touches `ui` (whose state is the interface thread's, `thread_local`).
- **A plugin's `render` returns a tree of plain objects. The bridge writes it as a display list**: one flat buffer of
  nodes (kind, key, properties, children's count), in the serialised form of the declarations. The plugin posts the
  list to the interface's thread. `render` runs when the plugin says its state changed (`view.update()`), and after
  each of its event handlers; never per frame.
- **The interface's thread replays the last list at each build**, as ordinary immediate calls (`ui.button`,
  `ui.row`...). The toolkit stays immediate: the box ids come from the nodes' keys, so hover, focus, scroll and
  animation live in the toolkit as for any widget. **No diff exists**: an immediate-mode build is already the
  reconciliation, and a new list simply replaces the old one between two builds.
- **An event is a message.** The replay sees `clicked` and posts `(view, node key, event, value)` to the plugin. Its
  handler runs, `render` runs, a new list comes. The person sees it one or two frames later.
- **A lazy list is a node `list` with a count, a row height and a version.** The host asks for the rows in view plus a
  margin (`rows(first, last)`), keeps the answers by index, and draws a placeholder row until an answer comes. An
  answer carries the serial of its question; an answer for another version is dropped (the palette's rule,
  [palette.md](palette.md)). The cost follows the rows in view, never the count.

The cost:

- Per frame, on the interface's thread: one pass over the buffer, one toolkit call per node. No JavaScript, no
  allocation of the engine, no collection.
- Per change, on the plugin's thread: `render` and the write of the list. Measured at 0.5 to 0.9 µs per row of four
  objects, so about 0.3 ms for a screen of 300 nodes.
- A plugin that changes nothing costs nothing.

Refused:

- **Immediate calls from JavaScript at each frame.** The call is cheap (30 to 60 ns), but the JavaScript then runs on
  the interface's thread, 60 times a second, with its collections. A loop in a plugin freezes the window, and the
  interrupt only ends it after a deadline that the person feels. It breaks the first rule of the toolkit.
- **A retained tree kept by the host and patched by a diff.** It needs a tree, a diff and patch messages, to give
  what the replay gives with none of them.
- **Plugin code on the chores' pool.** A plugin that runs long takes a worker from every program's readings.

### 3. The API: declared in Odin, a level, a `.d.ts`

- **One package of declarations, `gt:plugin_api`**, in the form of Wren's `api_decl`: a declaration is a procedure
  type (arguments, results), plus one constant entry that names its module, its JavaScript name, the capability it
  needs and the level that added it. The bridges (JavaScript value to Odin value, the capability check, the promise)
  are instantiated by the compiler from these types. No bindings file is generated.
- **`tk plugin_api` reads the declarations** (`core:odin/parser`) and writes `plugin-api/gt.d.ts` and the reference
  page. `tk ci` fails when the committed files differ from the declarations.
- **The plugin API is a facade, not `ui`.** A change of `ui.button`'s arguments changes the replay, not the API.
- **The level is one integer.** The manifest says `"api": 3`. The toolkit has `PLUGIN_API_LEVEL` and
  `PLUGIN_API_OLDEST`. A level only adds. A removal or a change raises `PLUGIN_API_OLDEST`; a plugin under it is
  refused with a sentence that says so. No shim keeps an old behaviour alive.
- **A snapshot per level is committed** (`plugin-api/level-3.d.ts`). `tk ci` checks that every snapshot from
  `PLUGIN_API_OLDEST` on is still a subset of the current declarations: a change that breaks a plugin does not pass
  by accident.
- **The shape for an author**: ES modules. `import { commands, toast } from "gt"`; the entry file exports
  `activate(context)`. Every call that waits returns a promise. A program adds its own module (`from "app"`) with the
  same declarations mechanism, and its own level.

Exposed, in the order of the slices: commands and the palette; toasts; settings; files, the network and the clipboard
as promises; a view; then palette sources, menu and tool bar entries.

Never exposed:

- the build procedures of `ui`, the `State`, the renderer, the draw lists, the fonts' internals, the platform's
  windows;
- `gt:process` (starting a program), `gt:secrets`, `gt:update`, `gt:setup`, `gt:licence`, the crash reports;
- the keymap's writes, the program's settings outside the plugin's own group, another plugin's data or messages;
- any synchronous disk or network call, any native code, any module from outside the plugin's folder.

Refused:

- **Bindings generated from the whole toolkit by reflection.** Every public procedure of `ui` becomes a promise kept
  to plugins; the toolkit's API then stops changing freely.
- **Semantic versions for the API.** A plugin asks one question: "does this program have what I was written for?" One
  integer answers it.

### 4. Capabilities

- **The realm has no ambient authority.** The engine makes no system call; a script reaches only the host procedures
  of the declarations.
- **Each declaration names its capability**, `.None` included: a declaration without one does not compile. The bridge
  makes the check before the call, in one place. An author of a host procedure cannot forget it.
- **The manifest asks; the person grants.** `"permissions"` lists what the plugin needs. A plugin is off until the
  person turns it on; turning it on shows what it asks, in words. The grant is kept by the program, outside the
  plugin's reach, with the set it was given for. A new version that asks more asks again; one that asks the same or
  less does not.
- **A call without its grant rejects with `PermissionError`.** The procedure exists either way: a plugin can do less
  instead of failing to load.
- **Files.** A plugin's own data folder needs no permission. Elsewhere: a file or a folder the person picked in the
  file dialog (a grant by the gesture, for that path, kept until revoked), or a named folder of the person
  (`documents`, `downloads`) asked in the manifest. The path is resolved on the chore (links and `..`), compared with
  the grant, then opened without following a last link.
- **Network.** By origin (scheme, host, port), through `gt:http` only. Each hop of a redirection is checked. The
  machine's own addresses and the local network need their host named in the manifest. No raw socket.
- **Clipboard.** `clipboard.write` and `clipboard.read` are two permissions. A read also needs to run inside the
  handling of a person's action (a command, a click in the plugin's view).

#### What this does not protect from

The sandbox is one of capabilities, not of memory. A bug of the engine that a script can reach (a use after a
collection) can corrupt the program, and a plugin written to exploit it escapes its grants. Accepted while plugins are
code a person installs by hand. If a program offers strangers' plugins, the plugin host moves into another process;
the API does not change, since every exchange is already a message or a display list.

### 5. On disk, loading, reloading, containment

- **A plugin is a folder**: `<data>/<vendor>/<Title>/plugins/<id>/` (`user_dir(.Data, APP_FOLDER)`), with
  `plugin.json`, its entry file and its modules. An update replaces the folder whole.
- **Its data is elsewhere**: `<data>/<vendor>/<Title>/plugin-data/<id>/`. An update or a removal of the code does not
  lose it; "Remove with its data" deletes both.
- **What the person decided** (on or off, the grants) is one file in the program's configuration folder,
  `plugins.toml`.
- **The manifest** is JSON (`gt:json`): `id` (the alphabet of `Command.id`), `name`, `version`, `api`, `main`,
  `program` (absent: any program), `permissions`, and the contributions: `commands` (id, label, group, keys, icon,
  tags), `settings` (the fields of `config.Def`), `views` (id, title, first place).
- **Contributions are data.** At start a chore reads the folder and the manifests and posts the result; the commands,
  the settings and the views are registered at the next build. No JavaScript runs. A plugin's thread and runtime start
  at its first use (a command chosen, a view shown). Ten plugins that are not used cost ten manifests.
- **Names.** A plugin's command is `plugin.<plugin id>.<command id>`; its settings are under `plugins.<plugin id>.`.
  The person's keys and aliases apply to them as to any command ([keymap.md](keymap.md)): a key kept for a plugin that
  is off or gone stays, inert.
- **Reloading.** "Reload plugins" is a command. With the developer setting on, a chore compares the folders' dates when
  the window takes the focus. A reload stops the runtime, reads the manifest, registers the contributions again and
  keeps the views' records; an open view shows its new first list. The JavaScript state is lost: a plugin that wants
  it back keeps it in its data.

The states of a plugin, kept in one enum and shown in the settings' Plugins page:

```
Found -> Refused        (manifest, level, program)
Found -> Off -> Ready   (turned on, granted; contributions registered, no runtime)
Ready -> Starting -> Running -> Ready      (stopped, reloaded)
Running -> Not_Responding -> Ready         (stopped by the person or by the bound)
Running -> Failed                          (activate threw, memory limit)
any -> Suspended                           (the program ended badly inside it)
```

Containment:

- **An exception** that nothing catches is written to the plugin's log, shown once as a toast; the plugin goes on.
- **A hang** never stops the interface: the plugin is on its own thread. An event with no answer after a bound makes
  the plugin `Not_Responding`; its views say so, with Stop. Stop sets a flag that the engine's interrupt hook reads at
  loop back edges and calls: an uncatchable error unwinds the script. Host procedures never wait (every wait is a
  promise), so the flag is always read.
- **Memory**: the reserved block is the limit; over it the plugin is `Failed` and its block is released.
- **A crash of the program inside a plugin** (an engine panic): the plugin's thread writes the plugin's id in the
  session file when it enters the engine and clears it when it leaves ([crash-sessions.md](crash-sessions.md)). The
  next start finds the id, makes the plugin `Suspended` and says so in the crash bar. The program crashes once, not at
  every start.

Refused:

- **A plugin folder shared by all of a vendor's programs.** The grants are per program, and a plugin with no
  program's objects does little. Revisit when a second program has plugins.
- **Running `activate` at start.** Every plugin then costs a runtime and a start time, used or not.
- **A file watcher for reloads.** The focus check gives the same to an author with no watcher per system.

### 6. The slices

**The first slice: one palette command, one toast.** A plugin folder with a manifest that declares a command; the
command appears in the palette of the `plugins` example; choosing it starts the plugin, whose handler calls
`toast.show`. It contains:

1. the engine moved to `gt:js`, Wren migrated, the reserved block, the failed allocation as an error;
2. `gt:plugins`: the folder read on a chore, the manifest (`id`, `name`, `version`, `api`, `main`, `commands`), the
   states, the thread, the queue, Stop;
3. `gt:plugin_api` at level 1: `commands.on(id, handler)`, `toast.show(text, options)`; `tk plugin_api` and the
   committed `gt.d.ts`;
4. a Plugins page in the standard settings: each plugin, its state, its switch (off at first), Stop, Reload;
5. the suspended state after a crash.

No capability is exposed, so no grant dialog is needed yet.

Then, in this order:

2. **Settings**: the manifest's `settings` in the settings page; `settings.get`, `settings.onChange`.
3. **Capabilities and tasks**: the grant dialog, the plugin's data folder, files, `fetch` by origin, the clipboard.
4. **A view**: the display list, a first set of nodes (text, button, row, column, field, check box, switch), in the
   four presentations of [views.md](views.md).
5. **Lazy lists**, then the nodes that the first real plugins ask for.
6. **A program's own module** (`from "app"`), in the first program that wants plugins.
7. **Palette sources, menu and tool bar entries** from a plugin; texts in the person's language.

## Subtle points

- **A text field in a plugin's view.** The host owns the field's text and its caret; the plugin hears each change with
  a serial. A list that sets the field's value says the last serial its plugin had seen; the replay ignores a value
  older than the field's last change. Without it, a slow plugin erases what the person typed after the event it
  answers.
- **A list that arrives during a build** is taken at the start of the next one. A build reads one list from its first
  node to its last.
- **The same key twice in a list** is the plugin's error: the second node is dropped and the error logged, as a
  duplicate box id would otherwise cross two widgets' states.
- **Strings of a list live in the list's buffer.** The replay keeps the buffer until the next list has been replayed
  once: a widget can hold a string for a frame.
- **A handler that returns a promise** holds its command "running" until it settles; the bound of `Not_Responding`
  counts the time without a turn of the plugin's queue, not the promise's time. A long download is not a hang.
- **Stop while a chore of the plugin runs**: the chore ends on its own; its result finds a runtime's serial that
  changed and is dropped.
- **Two windows of a program** share a plugin's runtime: a plugin is one per program, a view's list is one per view
  instance.
- **The engine's stack.** `Host_Config.max_stack_bytes` must fit the plugin thread's stack, which the toolkit sets
  when it starts the thread; the default of 640 KiB assumes 1 MiB.
- **`eval` and `Function` stay.** They run in the same realm with the same grants: they add nothing.
- **Wren keeps its submodule on a tagged toolkit**: an engine change for Wren is from now on a toolkit version.

## The first test that breaks the design

Headless, in `tests/plugins`: a plugin whose command handler is `for (;;) {}`.

1. Choose the command in the palette.
2. The window still builds: wait, with a bound, for 30 more builds.
3. Wait, with a bound, for the state `Not_Responding`. Stop it. Wait for `Ready`.
4. Choose the plugin's second command; wait, with a bound, for its toast.

It fails if any plugin code runs on the interface's thread, if a host procedure can wait, if the interrupt is not
read, or if a stopped runtime leaves something behind. A second test, in `gt:js`, makes a runtime on the process heap
and on a reserved block, then allocates past its limit: no abort, an error. That one fails today.

## Decided with the user

- **A plugin is installed from a link or a path; no catalogue for now.** A plugin can thus come from anyone: the
  plugin host moves to a process of its own before the capabilities slice (slice 3), not after. A catalogue is later.
- **opencode native has plugins first.** Its objects (sessions, messages, the composer) make the first `app` module
  and decide the first nodes of a view.
- **The engine lives in the toolkit** (`gt:js`): an engine change for Wren is a toolkit version.
- **Only a program that turns plugins on pays for them**: `gt:plugins` is imported by those programs alone (not cliche
  for now), so the 2.1 MB stay out of the others.
- **The engine moves first, alone**: `gt:js` with Wren on it, the reserved block and the failed allocation as an
  error, ships one toolkit version before the first slice.

Still open: a plugin folder shared by all the vendor's programs (refused for now).
