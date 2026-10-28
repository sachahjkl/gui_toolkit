# D-Bus client (`dbus` package)

`dbus` is a small D-Bus client written in Odin, for the toolkit's Linux desktop services. It speaks the wire protocol
itself over the bus's Unix socket — there is **no libdbus link** — so a binary built for Linux starts on a machine that
does not have the library and simply reports the bus unreachable. On any non-Linux system the package compiles (the
type system is pure) but every call answers "unsupported".

It is the foundation for the tray icon (StatusNotifierItem), notifications, the file-chooser and appearance portals,
the ScreenSaver idle inhibitor and the AT-SPI accessibility bridge — all under `platform`.

## What it does

- **Connects** to the session or system bus (`connect_bus`), or to a bus named by its address (`connect_bus_address`,
  for the AT-SPI bus). The session address comes from `DBUS_SESSION_BUS_ADDRESS`, else `$XDG_RUNTIME_DIR/bus`; the
  system bus from `DBUS_SYSTEM_BUS_ADDRESS`, else `/var/run/dbus/system_bus_socket`. It authenticates with **SASL
  EXTERNAL** (the uid as hex, the credentials NUL byte, `AUTH` / `BEGIN`) and does the `Hello` handshake to learn its
  unique name.
- **Marshals and unmarshals** the whole type system (`marshal.odin`, pure and testable): the basic types, strings,
  object paths, signatures, arrays, structs, dict entries and variants, with the per-type alignment and the byte order
  the spec requires (it writes little-endian, reads either). `message.odin` frames an outgoing message's header and
  parses an incoming one.
- **Calls methods**, synchronously (`call`, a bounded wait) or asynchronously (`call_async` + a `Reply_Handler`), and
  fire-and-forget (`call_noreply`). Replies (`reply_return` / `reply_error`) and signals (`emit_signal`) go out the same
  way.
- **Subscribes to signals** (`subscribe` / `unsubscribe`, through the bus's `AddMatch` / `RemoveMatch`) and routes each
  to its handler.
- **Exports objects** (`export_object`): a service the toolkit runs (the StatusNotifierItem and its
  `com.canonical.dbusmenu`) answers method calls the bus routes to a path. `request_name` claims a well-known name.
- **Folds into the window loop**: `conn_fd` gives the socket to the program's own `poll(2)`, and `dispatch` drains
  whatever arrived without blocking. `platform_linux.odin` watches the bus fd alongside the window's connection and
  calls `dispatch` each pump, so async replies and portal / theme signals arrive promptly on the UI thread.

## Threading

A connection is driven from **one thread** (the UI thread, as the window is). A worker that must block on a call (a
file dialog runs on the blocking pool) uses its **own short-lived connection** on that thread — this is what the portal
file dialog does — never the shared UI-thread bus.

## Writing a call

```odin
w := dbus.body_writer()                 // a Writer on the temp allocator
dbus.w_string(&w, "org.freedesktop.appearance")
dbus.w_string(&w, "color-scheme")
msg, ok := dbus.call(conn, "org.freedesktop.portal.Desktop",
    "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "ReadOne", "ss", w.buf[:])
if ok {
    r := dbus.msg_reader(&msg)
    scheme := dbus.read_variant_u32_nested(&r)   // 0 none, 1 dark, 2 light
}
```

A dictionary `a{sv}` is written with `arg_dict_begin` / `arg_dict_entry` / `arg_variant_*` / `arg_dict_end`; arrays
with `w_array_begin` / `w_array_end` at the element's alignment; raw array bytes (an icon pixmap) with `w_bytes`.

## Layout

- `dbus.odin` — the public types (`Conn`, `Message`, `Bus_Kind`, the handler types) and the per-message scratch arena.
- `marshal.odin` — the pure `Writer` / `Reader` and the type system; `message.odin` — the header build / parse.
- `args.odin` — the common body shapes and small readers (variants, dict alignment).
- `conn_linux.odin` — the socket transport, SASL EXTERNAL, Hello. `call_linux.odin` — calls, dispatch, subscriptions.
  `export_linux.odin` — exported objects, `request_name`, the generic Peer interface.
- `conn_stub.odin` — the non-Linux stub (no bus).

## Known limits (for the lead)

- **No Unix-fd passing.** Auth skips `NEGOTIATE_UNIX_FD`; the tray sends its icon inline as an ARGB pixmap, and the
  portals that would pass an fd are not used that way here. A service that needs `UnixFD` (some notification servers for
  large images) would need the fd-passing `sendmsg` path added.
- **One match-rule granularity.** `subscribe` pre-filters on interface / member / path in the handler; the bus's own
  `AddMatch` carries the same, so a very chatty bus still wakes us only for our rules.
- The synchronous `call` keeps the reply in a single static slot for the duration of the return; do not hold a
  `Message` from `call` across another `call` / `dispatch`.
