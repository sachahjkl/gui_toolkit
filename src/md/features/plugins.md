# Plugins in JavaScript

Asked by the user on 2026-11-14, for after the views. Designed on 2026-11-16. Slice 1 written on 2026-11-17 (see "The
state of slice 1"); then the views (slice 4), `gt-runtime` and the settings (slice 2): see "As built: views, gt-runtime,
settings". The site's explorer reads `plugin-api/api.json`; the site's page is not written.

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
  - As built: the block holds the **cells' chunks** (`Host_Config.reserve_bytes`, 8 GiB of addresses natively when 0;
    none in Wasm). The chunks are never given back before the runtime ends, so a bump is the whole allocator of the
    block. A block larger than 64 KiB (an array's values, a long string) still comes from the embedder's allocator: a
    general heap inside the block was refused (`core:mem` has only a buddy allocator, whose search is linear), and
    those blocks do not reach the chunk table. The limit is `malloc_limit`, counted over both.
  - The 64 MB default is the plugin host's (`gt:plugins`), not `js.DEFAULT_CONFIG`'s, which stays unlimited: Wren's
    pages run on it.
- **An allocation that fails raises the engine's uncatchable error**, on every path. The remaining `panic` sites of
  `jsrt` (15 today) are read one by one during the move; each becomes an error or keeps a written reason.
  - As built: four sites were left after the move, all allocations. The last eighth of the block is a **spare**: a
    chunk past the block's soft end, or a block the allocator refused, is served from the spare and raises the
    uncatchable "out of memory" at the next poll (`Runtime.memory_failed`; the poll comes within a few thousand back
    edges or calls). The caller writes the memory at once, so a nil was never an option. Only a spent spare is still a
    panic, with its reason written: a script would have to allocate a gigabyte between two polls.
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
  margin, by range, keeps the answers by index, and draws a placeholder row until an answer comes. An answer carries
  the serial of its question; an answer for another version is dropped (the palette's rule, [palette.md](palette.md)).
  The cost follows the rows in view, never the count. As built (slice 5): the node's `row(i)` gives one row, see
  "As built: lazy lists".

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
any -> Suspended                           (its process crashed three times in a run)
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

Decided on 2026-11-17:

- **The toolkit as a runtime: `gt-runtime`.** A small program shipped with each toolkit release, beside the demos, that
  hosts one plugin as an application: `gt-runtime <folder or main.js>`. The window, the theme, the palette, the
  settings and the toasts are the toolkit's; the application brings only its JavaScript. It is the same host and the
  same API as a program's plugins (`gt:plugins`, `gt:plugin_api`): no second mechanism. A bare `main.js` is a plugin
  whose manifest is implied (its id from the file's name, the current level, no permission).
  - **Its grant rule**: the first start of an application shows what its manifest asks, in words, once. The person's
    yes is kept in gt-runtime's own `plugins.toml`, keyed by the folder's path and the set of permissions asked. Later
    starts with the same or a smaller set start at once; a larger set asks again (decision 4's rule). A manifest that
    asks nothing starts at once, the first time too. Refused: granting on the command line (`--allow net`): a link
    that a person clicks would carry its own grant.
- **An API explorer on the toolkit's site**, generated from the declarations so that it never lags: `tk plugin_api`
  writes `plugin-api/gt.d.ts`, the snapshot of each level, the reference page `docs/plugin-api.md`, and
  `plugin-api/api.json`: the modules, their calls with their arguments and results, the nodes (from slice 4), the
  level that added each, and its capability. The site renders the JSON; it reads nothing else.
  - **As built**: `tk site_build` writes `plugins/api/` (tools/tk/site_explorer.odin) from the JSON, before the pages
    get their shared tags, and copies `api.json` and `gt.d.ts` beside it. One static page, a small script for the
    search; no framework. Each call's anchor is its JavaScript name (`#views.register`), each node's `#node.<kind>`,
    each type's `#type.<name>`, each level's `#level.<n>`: a doc or an agent links them. A field tagged `state` in the
    declarations (a field's value, a box's state: the host keeps it, the serial rule) is `"state": true` in the JSON.
    A missing or malformed file fails the build, with where it is wrong: the site never ships a stale explorer.
    Refused: reading `api.odin` from the site's build (a second reader of the declarations), and rendering in the
    browser from the JSON (a page without JavaScript would be empty, and a search engine would see nothing).
- **JavaScript demos** run by gt-runtime, beside the Odin demos: the plugins of `examples/plugins` first, each a folder
  that `gt-runtime` opens as it is.

## As built in slice 1

These points were open in the design and are decided by the code:

- **A declaration is the struct of its arguments, not a procedure type.** Odin cannot call a procedure type with
  arguments made at run time, and a compile-time bridge needs polymorphism over a procedure's parameters, which the
  language does not give. So `gt:plugin_api` declares `Toast_Show :: struct { text: string, options: Toast_Options
  \`optional\` }`, an entry names its module, JavaScript name, capability, level and result. The one bridge
  (`plugin_api.bridge`) reads the struct's fields by reflection, converts each argument (a string, a number, a
  boolean, an enum by its name, a nested struct from an object, a `Handler` from a function), checks the
  capability, then calls the host's implementation, typed by `plugin_api.implement($A, proc(^Call, ^A) -> Value)`.
  `tk plugin_api` reads the same structs with `core:odin/parser`.
- **The module `gt` is compiled from text** that the declarations generate: `const g = import.meta.gt; export const
  commands = g.commands; ...`. The host's `import_meta` hook gives `import.meta.gt` to that module alone: no global
  of the realm holds the API, so a plugin reaches it only through `import`.
- **The entry is started by a module of the host** (`gt:boot`), which imports the manifest's `main` dynamically and
  calls `activate(context)`: a syntax error, a missing export and a throw in `activate` all end in one place, the
  promise's rejection, and make the plugin `Failed`.
- **Modules are the plugin's files only**: `gt`, and specifiers that start with `./` or `../` and stay inside the
  plugin's folder. Each module is read once (a map by its name), on the plugin's thread.
- **The Plugins page is `gt:plugins`'s** (`plugins.page_info`), a `prefs_page.Page_Info` that a program puts in its
  `Page_Options.pages`. In `prefs_page` itself it would make every program with settings link the engine.
- **The commands are a palette source** (`plugin`, prefix `>`, listed), not rows of the program's command table: the
  table is a program's constant array, and its indices are the program's `Cmd` enum. An item's id is
  `plugin.<plugin id>.<command id>`; the source's `act` sends the command to the plugin. Keys for them through the
  keymap come with slice 7.
- **`plugins.toml`** is the program's configuration folder's, written on a chore, read with the folder: a table
  `[enabled]` of `<id> = true`. A plugin absent from it is off.
- **The marker of a crash inside a plugin** (`<state>/plugins/inside-<pid>-<id>.txt`) was removed when the plugin
  host moved to a process of its own: a crash of the engine no longer ends the program (see "The plugin host in its own
  process").
- **The plugin's log** is `<state>/plugins/<id>.log`, appended on the plugin's thread.
- **Not_Responding** is read on the interface's thread from one atomic word, the time its thread took its message
  (0: waiting). When a message goes, a chore is timed for the bound and posts a call that wakes the window: a plugin
  that hangs is said so even when nothing else draws.

### The state of slice 1

1. Done: the reserved block, the spare, the failed allocation as the engine's error (`src/js/chunk_block.odin`), with
   `tests/js` `past_the_memory_limit`. The move of the engine was done before.
2. Done: `gt:plugins` (`src/plugins`): the folder on a chore, the manifest, the states, a thread and a runtime per
   plugin at first use, the queue, Stop, the bound, the log and one toast per run, `plugins.toml`, the palette
   source, the marker and `Suspended`.
3. Done: `gt:plugin_api` level 1, `tk plugin_api`, the committed `plugin-api/` files.
4. Done: the Plugins page (`plugins.page_info`).
5. Done: the suspended state. It is said by a toast at the start, not yet in the crash bar: the crash bar names a
   report of `gt:crash`, and a plugin's suspension writes none.

Left for later slices, known: a plugin's command has no key of its own yet (the keymap's entries for
`plugin.<id>.<command>` come with the palette sources of slice 7); a handler's promise does not hold its command
"running"; the plugin's time zone is UTC (`timezone_offset_proc` is not set); `examples/plugins` is not among the
shipped demos (its folder `sample/` would have to go in the archive with it: with `gt-runtime`).

## As built: views (slice 4, API level 2), gt-runtime, settings (slice 2, API level 3)

Asked by the user on 2026-11-17: the view and gt-runtime first, then the settings. So the levels follow the order of
the work, not the order of the slices: views are level 2, settings level 3.

### Views

- **The API is two calls**: `views.register(id, render)` and `views.update(id)`. A view is declared in the manifest
  (`views`: `id`, `title`, `place`: `internal` by default, `dialog`, `panel`, `window`), as a command is. A render
  takes nothing and returns the tree. Refused: a view object with `update()` returned by `register`: a call's
  result would need objects made by the bridge; an id is what the rest of the API already uses.
- **A node's handlers are functions in the tree** (`onClick`, `onChange`, `onSubmit`), as a web author writes them.
  The writer gives each to the plugin's side by the node's key and the field's name, retained until the next render
  of the view replaces them; an event finds its handler there. No function crosses to the interface's thread.
- **The nodes are declared as the calls are**: a struct per kind and one entry of `NODES` (its JavaScript name, its
  struct, whether it has children, its level). The writer (`plugin_api/display.odin`) fills a node's struct with the
  bridge's `fill`, so a node's fields are checked as a call's arguments are, and `tk plugin_api` writes their types
  and the `Node` union from the same text.
- **The list is one arena**: an array of nodes in the order of a walk (kind, key, children's count, the person's last
  change the plugin had heard of, a pointer to its struct), the structs and their strings in the same arena. The
  interface's thread frees it whole.
- **Keys.** A node without a key is keyed by its place under its parent (`/0/2`). A key with `#` (the toolkit's id
  syntax) or a leading `/` is refused for the place's. A key given twice: the second node and its children are
  dropped, and the plugin's log says so. A child that is `null`, `undefined` or `false` is skipped (`cond && node`).
- **What the host owns.** A field's text, a check box's and a switch's state are the host's (`Control`), with the
  number of changes the person made. A node gives its state only through a field tagged `state` (`value`, `checked`,
  `on`); without it, the host's state stays whatever the plugin renders (a field read on submit only). With it, the
  replay shows the plugin's value unless the person changed it since the change the plugin last heard of: the rule of
  "A text field in a plugin's view", for boxes too.
- **The replay adds the layout's gaps** between a container's children (`CONTROL_GAP` across, `LINE_GAP` down), and none
  next to a `space` node. A plugin needs no spacing to look as the program does.
- **A view's record outlives its plugin's reloads**: the window's views keep their id (`plugin.<plugin id>.<view id>`),
  and an open view shows its new first list. When its plugin's thread ends, the last list stays, with a line that says
  why (Not responding with Stop, Stopped with Start, the failure).
- **A view in a program's own layout**: `view_body` builds it in the box being built, never as one of the window's
  views. gt-runtime's window is one.
- One instance per view: two windows of a program that open the same view share its list.

### gt-runtime

- **A program of the toolkit's, `apps/gt-runtime`**, built by `tk build gt-runtime`, checked by `tk ci`, shipped in the
  release as `gt-runtime-windows-x64.zip` with the JavaScript demos (`examples/js`, as `js/<demo>`). The release job
  runs on Windows: no Linux archive yet.
- **One plugin, by `Host_Options.single`**: a folder with its `plugin.json`, or a lone `.js` file whose manifest is
  implied (its id and name from the file's name, this toolkit's level, one view `main`). It is on from the start: the
  program was started to run it. A suspension still holds it, with "Run it again".
- **The window**: the plugin's first view in the page's margins (`view_body`), the palette with its commands (Ctrl+K),
  the settings (Ctrl+,) with the look, the plugin's settings and the Plugins page.
- **The grant rule waits for slice 3**: no call needs a permission yet, so there is nothing to show. When one does, the
  rule of "Decided on 2026-11-17" applies, kept in gt-runtime's own `plugins.toml`.

### Settings

- **A setting is a preference of the program**, `plugins.<plugin id>.<setting id>`, registered when the folder is read
  (`Host_Options.prefs`). The program's settings show it (`settings_pages`: one page per plugin), its file keeps it,
  the registry checks it. The manifest's `settings`: `id`, `title`, `description`, `kind` (`bool`, `int`, `float`,
  `string`), `default`, `min` and `max`, `choices`; a default out of its bounds or its choices is refused at the read,
  since the registry asserts on a bad definition.
- **The plugin's thread never reads the registry** (the interface thread's). It gets the values when it starts, then
  each change as a message (`config.watch` on `plugins.`); `settings.get` answers from that copy at once, and
  `settings.onChange`'s handlers run on the message, then the open views render again.
- **A definition is the registry's for its life**: the registry has no unregister, so its strings are kept for the
  process (a few bytes per setting ever declared). A setting declared again with another kind keeps the first until the
  program's next start.

### The state of slices 4 and 2

Written on 2026-11-17: the views with their tests (`tests/plugins/views_test.odin`: a click round trip, a slow
plugin's field, a key twice, a handler that never returns, a lone file), gt-runtime with `examples/js/counter` and
`examples/js/todo`, the settings (`tests/plugins/settings_test.odin`). Left: lazy lists (slice 5), the nodes the first
real plugins ask for, capabilities (slice 3, with the plugin host in its own process first), a program's `app`
module, palette sources and menus.

## As built: the plugin host in its own process

Decided with the user: a plugin comes from a link or a path, so the host moves to a process of its own before the
capabilities. Written on 2026-11-18.

- **One process per plugin, started at its first use.** A crash, a hang that only a kill ends, memory taken: each is
  one plugin's, and Stop's kill ends that plugin alone. The cost is a process per plugin in use (a few MB, a start of a
  few ms on Linux, tens on Windows); a plugin that is not used costs its manifest, as before. Refused: one process for
  every plugin of a program: a crash of one is every plugin's crash, and a kill to end one hang ends them all.
- **The program's own executable, started again with a hidden argument** (`--gt-plugin-host`). An `@(init)` of
  `gt:plugins` sees it before the program's `main`, runs the one plugin the first frame names, and ends the process:
  the program's window, settings and files are never opened there. So a program needs no line in its `main`, a test
  program is a plugin host too (the tests cross a real process boundary), and there is no second binary to ship, sign
  and install. The start is the system's (an executable of 30 MB is mapped, not read) plus the toolkit's `@(init)`s,
  which build constant tables. Refused: a small dedicated executable: one more file per program and per platform, kept
  at the program's version, and a test program could not host its plugins.
- **The child's standard input and output are the channel** (`os.pipe`, `os.process_start`: the same calls on both
  systems). No socket: nothing has a name another process can find, no port, no path to clean. A frame is a magic word,
  a length, a kind and its bytes (`wire.odin`): the start, a message, an event. A display list crosses node by node, its
  structs field by field by the declarations (`plugin_api/wire.odin`), and the reader checks every count and every
  enum's value before the replay sees it. The standard error stays the program's, for a panic's words.
- **Two threads of the program per process**: a sender, which starts the process (`os.process_start` is not safe on two
  threads at once: `start_lock`) and writes the plugin's queue; a reader, which posts the events as the plugin's thread
  did and reads the process's end. The interface's thread pushes messages and reads atomics, as before.
- **Not_Responding counts from the write of a message to its Turn_Done.** A message written while none waits starts the
  time; each Turn_Done starts it again for the next one, or ends it. The start is the exception: the child's first
  word (Alive, as soon as it read its Start) starts the time again. The system's start of a process took more than the
  bound on a busy Windows machine, and a plugin was said not to respond before any of its code ran.
- **Stop**: the child's reader raises the interrupt flag at once (it reads while the plugin's thread runs a script);
  a child whose runtime has not ended `STOP_BOUND_MS` (1 s) later is killed. A kill after a Stop makes the plugin Ready,
  not Failed: the person asked for its end.
- **A crash** (the process's output ends with no `Ended`, or a frame that cannot be read) makes the plugin Failed with
  the exit code; its views say so with Restart (`restart`). Three crashes in one run make it Suspended, kept in
  `plugins.toml` until the person turns it on. The markers of slice 1 went: they told a crash of the whole program
  inside a plugin, which cannot happen any more; a program killed takes its children with it (their input ends), which
  is no plugin's fault.
- **Tests' hooks**: `test_crash` panics in the child's runtime (what an engine's bug does), `test_hang` waits there
  where no interrupt is read.
- **What this does not do**: the child runs with the person's rights, as the program does. Since slice 3 every call
  that reaches files, the network or the clipboard is the program's broker's (see below), so what the API reaches is
  closed; on Linux the system's sandbox takes the rest away ("As built: the sandbox"); Windows and macOS are next
  (ROADMAP).

## As built: capabilities (slice 3, API level 4)

Written on 2026-11-18. Decided with the user: the work runs in the program, not in the child.

- **The program is the broker.** The grants live in the program (`plugins.toml`); a check made in the child is one the
  plugin's own process could skip if the engine were exploited. So a call of `files`, `http` or `clipboard` makes a
  promise in the child and sends a request (a call id, the operation, its arguments). The program checks the grant on
  its interface's thread (in memory: no wait), does the work on the chores (a file, a request, a dialog: system calls,
  never the interface's thread), and answers with the call id; the child resolves or rejects the promise. The answer is
  a message like the others, a turn: the promise's continuations run then. The child's bridge refuses a call without
  its grant at once too (a rejected promise), only to answer sooner: the broker checks again whatever it said.
- **Ids of calls are unique across a plugin's processes** (the process's serial in the high bits): an answer meant for
  a process that ended never settles a call of the next one.
- **The manifest's `permissions` are words**: `files`, `folder:documents`, `folder:downloads`, `clipboard.read`,
  `clipboard.write`, `net:*`, `net:<origin>`. Each is read into one form (an origin in lower case without its default
  port), so a grant compares by text. A word that is no permission refuses the manifest.
- **The grant.** A plugin that asks is off until the person turns it on; turning it on opens a dialog that says each
  permission in words, with Allow and Not now. Allow keeps the set in `plugins.toml` (`[granted]`) and turns it on. A
  later version whose set is not inside the granted one is off again, and its line in the Plugins page says what it
  asks; one that asks the same or less starts as before. "Take back its permissions" clears the set and the files
  picked. gt-runtime's plugin asks at its start (Host_Options.single): the program was started to run it.
- **A person's act** is the program's to say, not the process's: the program keeps the turns it wrote, in their
  order, each marked when it is a command or a node of a view used (`Queue.turns`); its reader stamps each request with
  the turn running when the request was read. `clipboard.read` and `files.pick` need one. A promise's continuation runs
  in the answer's turn: no act any more.
- **Files.** A relative path is in the plugin's own data folder (`<data>/<program>/plugin-data/<id>/`: no permission,
  kept when the code is replaced); `~documents/...` and `~downloads/...` need their permission; an absolute path must be
  a file the person picked, or under a folder they picked (`files.pick`, a grant by the gesture kept in `[picked]`
  until taken back). The path is resolved on the worker, component by component under its folder: `..` and a link
  anywhere are refused, never followed. A write is atomic (a new file renamed over the name), so a link put there since
  the check is replaced, not followed. A read follows a link put between the check and the read: the gap is a
  `stat` and an `open`, closed when the toolkit opens files without following links (an `O_NOFOLLOW` of `fsx`).
- **The network.** By origin, through `gt:http`, which now follows no redirect when asked (`Request.no_redirects`): the
  worker checks each hop's origin before it goes there, ten hops at most, a 303 (and a 301 or 302 after a POST) going
  on as a GET. `net:*` reaches any public host; the machine's own and the local network's (localhost, `*.local`, the
  loopback, the private and link ranges) only an origin named for them. By the host's text only: a public name whose
  system's answer is a private address is not seen (a DNS rebinding), noted for the sandbox's step.
- **The clipboard.** A write is the window's (`platform.set_clipboard`); a read asks the window as a paste does
  (`ui.paste_request`, answered in a later build): one waits at a time, a newer one replaces it.
- **Errors.** A refusal is a `PermissionError`; a file's failure a `FileError`; a request's a `NetworkError`. The
  explorer shows each call's permission as the manifest's word (`api.json`'s `permission`).

Refused:

- **The work in the child, checked there.** Simpler (no request, no answer), but the check is the plugin's own.
- **Granting each call when it comes** (a prompt per request, as a browser's): a plugin's view would block on dialogs;
  the manifest says what it needs, once, in words.
- **A synchronous call that waits for the broker** (`files.readSync`): host procedures never wait (decision 5), or
  Stop could not reach a plugin waiting for an answer.

Still open: a plugin folder shared by all the vendor's programs (refused for now).

## As built: the sandbox (Linux)

Written on 2026-11-18.

- **The threat.** A plugin written by a stranger, or a bug of the engine that a plugin's script exploits, runs code
  of its own in the plugin's process with the person's rights. The broker closes what the API reaches; the process could
  still open a file, a socket or another program by its own system calls. The sandbox takes those away from the
  process itself, so that what it reaches is its two pipes and the program's broker.
- **Where.** In the child (`child_main`), right after it reads its Start and says Alive, before any of the plugin's
  code runs and before its second thread starts: Landlock binds the calling thread and the threads it makes later, so
  the child checks that it is alone (`/proc/self/stat`) and refuses to call itself isolated when another thread ran
  first (an `@(init)` of a package that started one).
- **The child opens no file after it.** It needs two things of the disk: its modules and its log.
  - **The modules are read before the restriction**: every `.js` and `.mjs` file of the plugin's folder (links not
    followed, 2 000 files and 64 MB at most, 8 MB a file), kept by their path in the folder. An `import()` later finds
    its source there. Refused: a read-only rule for the plugin's folder. It is one line, but it leaves the process a
    path to reach, and a folder that grows (a `node_modules`) is the plugin's to keep small, said in its log.
  - **The log is the program's to write**: a line is an event (`Log`) that the program's reader thread appends to the
    plugin's log (a thread of the program, never the interface's). The Start no longer carries the log's path.
- **Landlock** (`landlock_create_ruleset`, ABI 1 or later): a rule set that handles every access right of the file
  system the kernel knows (execute, read, write, the makes and removes; refer from ABI 2, truncate from 3, the devices'
  ioctl from 5), with no rule: no path is allowed. From ABI 4 it handles TCP's bind and connect, with no port allowed;
  from ABI 6 it scopes abstract Unix sockets and signals, so the process cannot signal the program nor another process
  of the person's. Landlock also forbids the process to ptrace a process out of its domain. `PR_SET_NO_NEW_PRIVS`
  comes first: neither layer can be set without it, and a set-uid program cannot be used to leave them.
- **seccomp-bpf** (by hand, nine instructions or so): `socket`, `socketpair` and `io_uring_setup` give `EPERM`;
  everything else is allowed. Landlock's network rights cover TCP only (UDP, raw, netlink and Unix sockets are not
  theirs); the child needs no socket at all, so none is made. `io_uring` goes too: its ring can make a socket without
  the `socket` call. The filter checks `seccomp_data.arch` first and kills the process when it is not the one the
  child was built for (a 32-bit call on a 64-bit system has other numbers), and on x86_64 refuses the x32 numbers.
- **`Host_Options.sandbox`**: `If_Available` (the default, gt-runtime's), `Required`, `Off`. With `If_Available` a
  child that cannot isolate itself (no Landlock: an old kernel, or one that did not enable it) runs as before and says
  so once in its log. `Required` makes the plugin Failed: "this system cannot isolate a plugin's process". `Off` is
  for a program's own debugging. Isolated means both layers: Landlock alone leaves the sockets, seccomp alone the files.
- **The seam for the other systems.** Two procedures, one file per system: `sandbox_spawn` (the program starts the
  child: Linux and the others start it as before; Windows will start it in an AppContainer or with a restricted token,
  which only the parent can give) and `sandbox_enter` (the child, after its Start: Landlock and seccomp on Linux;
  nothing elsewhere, and it says so). `sandbox_other.odin` is the rest, `#+build !linux`.

What it does not stop:

- **The processor and the memory.** A loop is Stop's (the bound, then the kill); the memory is the engine's limit. A
  child that allocates outside the engine (a bug of its own) is bound by nothing but the system.
- **What the broker does for it.** A grant is a grant: a `net:*` plugin reaches any public host, and a public name
  whose system's answer is a private address (DNS rebinding) is still reached through the broker (capabilities, "The
  network").
- **What the system shows without a file**: the metadata of a path (`stat`), the process list's numbers, the time.
  Landlock restricts opening, not looking.
- **A kernel's bug.** The sandbox is the kernel's; an exploit of the kernel leaves it.
- **Signals before ABI 6**: on a kernel with Landlock 1 to 5, the child can still signal the person's processes.

The test (`tests/plugins/sandbox_test.odin`) is the ROADMAP's condition: `test_escape` makes the child read a file the
test made, create one in the test's folder and open a TCP socket; with the sandbox none succeeds, with `Off` all
three do. It is skipped where the kernel has no Landlock.

## As built: lazy lists (slice 5, API level 5)

Written on 2026-11-18; the Fenwick tree of the rows' places the same day.

- **The node.** `{ kind: "list", count, version, rowHeight, visibleRows, row: (i) => node }`. `count` is at most
  1 000 000 (the host keeps 8 bytes a row: the virtual list's ids). `rowHeight` is in lines of text, the height of a
  row before it is measured; `visibleRows` the list's height in rows (10 when absent, 100 at most). The list is a box of
  its own that scrolls inside the view.
- **`row(i)` and not `rows(from, to)`.** The plugin says what one row is; the process calls it for each row of an ask.
  So the plugin never handles a range, never returns an array of the wrong length, and each row is keyed and checked
  on its own (a row that gives `null` is an empty row). The function is kept as the node's handler (its field's name,
  `row`), as an `onClick` is: it is the one of the last render, and no new call of the API exists.
- **The program's side is the toolkit's virtual list** (`ui.vlist`): it says which rows are built (the view and its
  margin), measures each row's height and keeps the view on its row when heights change above it. A row's identity is
  its index; a new version forgets the heights (`vlist_invalidate`). The host wants the rows built and as many again
  on each side; the answers with none of those rows are let go of (freed two builds later: a widget may hold their
  strings for one build), and with them the state of their fields and boxes.
- **One ask waits at a time per list**: the first rows wanted and not answered, those in view first, 200 at most
  (`ROWS_MAX_PER_ASK`). A plugin that is slow gets no more work than it can do; the window builds the placeholders and
  scrolls meanwhile. An ask with no answer within the bound (Host_Options.bound_ms) lets one more go, for the rows
  wanted then; the plugin is Not responding by then, as for any turn (an ask is a turn). The ask carries its number
  and the list's version; the answer echoes them, and the host drops it when it is not the ask that waits (a later
  ask, or a version changed since) or when none of its rows is wanted now.
- **Keys.** A row is one column node keyed `<list>~<row>`, and the row's node under it; the program builds its own
  row box in its place (the virtual list's name for the row) and replays the children. A row's keys are under its
  column's: `<list>~<row>/0/2` by place, `<list>~<row>~<own>` for the plugin's own key. So two rows never share a key,
  and a click in a row reaches the handler of that row. `~` is no longer allowed in a plugin's own key.
- **Handlers of rows** live with their list in the process, by key, until the program lets go of the row (each ask
  says the rows it keeps). A render that no longer has the list lets go of all of them.
- **A new render keeps the rows** when the version is the same: the plugin changes `version` when what the rows show
  changes. Rows are asked again then; the placeholders show until they come.
- **The rows' places are a Fenwick tree** (`src/ui/fenwick.odin`, the find bar's too). The virtual list kept the top of
  every row in an array, made again whenever a row was measured at a new height: a lazy list of a million rows went
  over all of them at each scroll that laid out new rows. Now a measure is a point update and a top, the total and the
  row at a place are each a logarithm of the rows; every row is placed again only when the ids change (here: the
  count) or the heights are forgotten (a new version, a new width). The tree keeps per row its measured height and
  whether it was measured, not the estimate: the estimate is the average of the heights measured and moves with each
  measure, so it is applied when a top is asked, else a new average would rewrite every row never measured. The sums
  are f64: a million f32 heights added up keep their exact value. The view's anchor keeps its index too: with the same
  ids it is found at once, and the search over the rows runs only in a build whose new ids were placed anyway. A map
  from id to row was refused: some 30 MB and a hash per row at each change of a million ids, to save a pass that a
  change of the ids already makes.

Refused:

- **A list the plugin fills by itself** (`views.rows(id, from, items)`): the plugin would have to know what is in view.
- **The rows in the render's display list** (all of them, or a window the plugin picks): the cost follows the count.
- **A list inside a row of a list**: each row of the outer one would ask for rows of its own; such a node is dropped
  and said in the log.

Still open: the keyboard's active row and Enter are the virtual list's and are not sent to the plugin (a row's own
button is); the rows of a list have one look (no selection drawn).
