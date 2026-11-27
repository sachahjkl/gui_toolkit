# A test never reaches the person

A test, and a program that a tool of the toolkit runs (a screenshot, a probe, a bench, a timeline), runs on the
machine of a person who is working. It must never open a window on that person's desktop, never speak on their session
bus, and never load the driver of their graphics card. Before this, the tools did it one by one (the program sessions
on a sway of their own, lavapipe for their programs), and a test started by hand took what its shell had: a window on
the person's Wayland desktop, their bus, NVIDIA's EGL driver through libglvnd.

## The constraint, reduced

Three resources reach the person: the display server (`DISPLAY`, `WAYLAND_DISPLAY`), the session bus
(`DBUS_SESSION_BUS_ADDRESS`, and its default in `XDG_RUNTIME_DIR`), and the GPU drivers (Vulkan's loader, libglvnd's
EGL, VA-API). Each is found through the environment. So the toolkit rewrites the environment, once, with one policy.

## Decisions

- **One policy, `base.isolated_env`.** From an environment it makes the isolated one:
  - the displays go, unless they name a server that the test or the tool started itself (`GT_TEST_DISPLAY`: X11's
    `DISPLAY`, or the Wayland socket's path, since a person's `wayland-1` and a session's `wayland-1` differ only by
    `XDG_RUNTIME_DIR`);
  - the session bus is the test's own (`GT_TEST_BUS`), else an address where nothing answers: always set, so the
    default in `XDG_RUNTIME_DIR` is never tried;
  - Vulkan's drivers are lavapipe's manifest alone and the implicit layers are off (NVIDIA's optimus layer loads its
    driver into every Vulkan program); EGL's vendor is Mesa's file alone; VA-API finds no driver (`gt:h264` then
    encodes in software). A setting that already narrows is kept: a test of a machine without a driver names files
    that do not exist, and an isolation that widened it would give it Mesa.
  `gpu` (a demo a person watches, `Program_Options.gpu`) keeps the drivers and still isolates the display and the bus.
- **A test process isolates itself before its main** (`base`'s `@(init)`, when `ODIN_TEST`). `base` is in every
  test of the toolkit, whatever started it: `run_tests`, `odin test` by hand, a test's own child (`tests/no_graphics`
  starts itself again in a sway). Refused: the runner alone setting the environment of its children. A test started by
  hand, from a shell of the person's desktop, then escaped it.
- **A tool isolates the programs it starts.** `toolbox.program_session_start` (on its own sway, which names itself in
  `GT_TEST_DISPLAY`) and `tk`'s `start_program` (shots, theme shots, the timeline test) pass the isolated environment.
  `tk desktop_tests` names its Xvfb, Xorg and sway in `GT_TEST_DISPLAY`, and its test binary keeps them.
- **A test that needs a display or a bus starts its own**: `tk desktop_tests`, `toolbox.sway_start`, the dbus-daemons
  of `tests/notify`, `tests/taskbar` and `tests/file_request`. A bus set after the start (`setenv` in the test) is the
  test's affair: the policy runs once, before main.
- **lavapipe's lookup moved to `base`** (`software_vulkan.odin`), beside Mesa's EGL lookup: the policy needs them and
  `base` needs nothing else.

## Subtle points

- On Linux only. Windows runs its tests on a desktop of their own (`run_tests`) and draws them on WARP.
- No display at all is no window: the platform connects to Wayland only when `WAYLAND_DISPLAY` is set, so libwayland's
  default socket (`wayland-0` in the person's runtime folder) is never tried.
- `tk film` draws its films in its own process, on the GPU, for a person to watch; it is not isolated.

## The test that breaks it

`tests/isolation`, started with `DISPLAY` set to a server standing for the person's and `DBUS_SESSION_BUS_ADDRESS` set to
the person's bus: `platform.open_window` gives no window and `dbus.connect_bus(.Session)` no connection. `base`'s tests
check each rule of the policy, and that a test process is already as the policy says when its tests start.
