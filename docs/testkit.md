# testkit: reusable building blocks for an application's tests

`import "gui_toolkit/testkit"` (or the relative path of the submodule). The parts of a test harness that are pure Odin and
not tied to any one application: a block of test-server ports, and a reader of the process's memory and handle counts.
The package carries no product name — an application passes in its own environment variable and defaults.

The package is named `tk_testkit` (the directory is `testkit`): import it as `testkit` unless the application keeps a
package of its own by that name.

## A block of test-server ports

Several worktrees (or several agents on one machine) run the end-to-end tests at once. Each wants its own ports. The tests
write one fixed set of ports and pass every address through `url`, which moves it to the run's block:

```odin
PORTS := testkit.Ports{base_env = "MYAPP_TEST_BASE_PORT", default_base = 8765, span = 5}

addr := testkit.url(&PORTS, "http://127.0.0.1:8765/a")   // the run's block, or unchanged on the default one
p2   := testkit.port(&PORTS, 2)                           // the port 2 past the base (a second origin)
base := testkit.base_port(&PORTS)                         // MYAPP_TEST_BASE_PORT, else default_base
```

The block's ports share their first three digits and differ only in the last (8765 ..< 8770): `url` scans for
`":876<d>"` after a host character — not inside a longer number, not a path — and rewrites `d` to the run's block. On the
default block it returns its argument unchanged. Results are interned (kept for the life of the process), so the same
address is rewritten once and may be handed to anything that keeps it. `test_all` gives each run its base port through the
environment; a test harness in another language writes the default ports and lets the running tool rewrite them.

## The process's state

For endurance and leak tests that watch what an allocation tracker cannot see (native libraries, arenas, GPU memory):

```odin
s := testkit.process_state()
//   s.resident      in physical memory now        (Windows: working set; Linux: VmRSS)
//   s.private        the process's own memory      (Windows: private commit; Linux: RssAnon + VmSwap)
//   s.handles        open kernel handles           (Windows: GetProcessHandleCount; Linux: /proc/self/fd)
//   s.gdi_objects    GDI objects   (Windows only)
//   s.user_objects   USER objects  (Windows only)

m := testkit.memory_split()   // Windows only (zero elsewhere): where the private bytes are
//   m.heap_allocated / m.heap_committed   the process heaps (Odin, Rust and C libraries all allocate from them)
//   m.vm_rw / m.vm_exec                    private committed pages outside the heaps, read-write vs executable
```

`memory_split` shows a private-bytes number split into what the heaps hold against what they have committed, and the
private committed virtual memory outside the heaps by kind — the quickest way to tell a heap leak from arena growth from
code pages.
