# instance: one running copy of an application per named resource

`import "gui_toolkit/instance"` (or the relative path of the submodule). One running copy of an application per name (a
profile, a document set). The first process to start with a name owns it; a second start with the same name does not open a
second copy on the same state: it hands an opaque message to the first one, which comes to the front, and ends.

The package is named `tk_instance` (the directory is `instance`): import it as `instance` unless the application keeps a
package of its own by that name.

The interface is platform-neutral: a name, an optional identity, an opaque message (`[]byte`: the package never looks inside
it), and a handler the owner runs on the thread that pumps its messages. No window handle, no executable semantics and no
Windows type cross the boundary. Under it: on Windows a named mutex and a message-only window with WM_COPYDATA; on POSIX a
`flock` lock file and a Unix socket in `$XDG_RUNTIME_DIR` (`instance_windows.odin`, `instance_linux.odin`); other platforms
let every start own its name (`instance_other.odin`).

## At the start

```odin
name := instance.key("myapp.release", profile_dir)   // "myapp.release.<16 hex of a hash of the path>"
message := my_encode(what_to_open)                     // the application's own bytes (paths, flags, ...)
outcome, owner := instance.acquire(
    {name = name, identity = exe_path, wait_ms = 3000}, message)
switch outcome {
case .First:           // this process owns the name: carry on, call owner_start once a loop exists
case .Forwarded:       // the owner took the message: os.exit(0) (or just stop)
case .Other_Instance:  // the owner has a different identity: carry on by yourself, owning nothing
case .Unresponsive:    // the owner did not answer in time: carry on by yourself, and say so
}
```

- **`key(prefix, path)`** builds a name from a prefix (a channel: release and development never meet) and a path (two runs
  on the same path get the same name). Letters, digits and dots only — a name is a kernel object name and a window title.
  On Windows the case and the slash direction of the path do not matter.
- **`identity`** is a trust token the owner checks: it hands over only to a sender with the same identity (an executable
  path, a version), so a different copy of the application (an update just downloaded, another folder) starts on its own.
  `""` trusts any sender.
- **`wait_ms`** is how long `acquire` keeps trying while the owner is starting (no window / socket yet) or closing. A silent
  owner (busy or hung) ends the wait at once: a second start never waits for ever and never loses its message.

## Being the owner

```odin
// once a message loop exists, on the thread that will pump it:
instance.owner_start(&owner, proc(user: rawptr, message: []byte) {
    m := my_decode(message)   // the bytes a second start gave acquire / send, nothing added
    // ... open what m asks, then raise your own window:
    instance.raise_window(rawptr(my_window_handle))
}, user)

for running {
    instance.pump_messages()   // the owner's messages arrive here (WM_COPYDATA on Windows, the socket on POSIX)
    // ... the rest of the frame ...
}

instance.owner_closing(&owner)   // when the loop ends: later starts wait (the window / socket goes, the name is still ours)
instance.owner_stop(&owner)      // the very end: the name is free (a waiting start becomes the owner)
```

The handler runs on the thread that called `owner_start`, inside `pump_messages`, with a message valid only during the call
(copy what is kept). It must be quick: the sender waits for it. **`raise_window(handle)`** brings a window forward (restore
if minimized, foreground, with a taskbar-flash fallback when the foreground cannot be taken); `handle` is an opaque window
handle (a HWND on Windows; on POSIX raising is the window system's job and this does nothing).

## Pinging without owning

```odin
outcome := instance.send({name = name, identity = exe_path, wait_ms = 500}, message)
```

`send` hands a message to the owner without trying to become the owner: a pure "there is a running copy, tell it this".
Returns `Forwarded`, `Other_Instance`, or `Unresponsive` (no owner, a different identity refused, or no answer).

## Elevation (Windows)

`instance.is_elevated()` tells whether the process runs with an elevated token. An elevated owner lets a WM_COPYDATA
through from a normal sender (UIPI) so a link clicked in a normal program still reaches it; a normal owner keeps the default,
which refuses processes of a lower integrity.
