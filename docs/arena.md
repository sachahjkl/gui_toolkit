# arena: lifetime and ownership primitives

`import "gui_toolkit/arena"` (or the relative path of the submodule). Pure Odin (`core:mem`, `core:mem/virtual`), any
target. Two primitives an application builds its object graph on: a scope tree and a generational handle pool.

## Scope: an arena and a cleanup list, in a tree

A `Scope` owns a growing virtual-memory arena plus a list of cleanups, and may have child scopes. Closing a scope closes
its children (newest first), runs its cleanups (newest first), then releases the arena in one go. An application is a tree:

```
process ── window ── view ── (timers, async work, subsystems, ...)
```

so "close the view" cancels every in-flight piece of work and frees everything without any subsystem keeping a list of what
belongs to whom.

```odin
s := arena.scope_make("view", parent)          // a child of parent (closed when parent closes)
buf := make([]byte, n, arena.scope_allocator(s)) // lives exactly as long as the scope
id := arena.on_close(s, proc(d: rawptr) { ... }, user)  // run (newest first) when the scope closes
arena.forget_cleanup(s, id)                      // the resource was released early
arena.rebind_cleanup(s, id, new_fn, new_user)    // a replacement keeps the replaced one's place in the order
arena.run_cleanup(s, id)                          // run it now and unregister it
arena.scope_close(s)                              // close children, run cleanups, free the arena; the pointer is dead
```

Scopes are single-threaded objects: worker threads never touch them. `name` must outlive the scope (a literal) and only
serves diagnostics.

## Pool: generational handles that can never dangle

A `Handle` (a `distinct u64`: generation in the high 32 bits, slot index in the low 32) is what an application hands across
a boundary — to a script, a serialized reference, a foreign API. Removing an object bumps the slot's generation, so any
copy of the old handle fails to resolve instead of silently reaching whatever reused the slot. Handle 0 is always invalid,
so a zeroed field or an uninitialized global is safe.

```odin
p: arena.Pool(Node)
h, ptr := arena.pool_insert(&p, node)   // O(1); ptr stays valid until this object is removed (chunks never move)
ptr = arena.pool_get(&p, h)             // nil when the handle is invalid, stale or never issued
ok := arena.pool_valid(&p, h)
val, ok := arena.pool_remove(&p, h)     // returns the value so the caller can release what it owns
it: u32                                  // iterate live objects (removing the current one is allowed)
for h, v in arena.pool_next(&p, &it) { ... }
arena.pool_destroy(&p)
```

Objects live in fixed-size chunks that never move, so a `^T` from `pool_insert` / `pool_get` stays valid until that object
is removed, however much the pool grows. Insert and remove are O(1) and there is no per-object allocation.
