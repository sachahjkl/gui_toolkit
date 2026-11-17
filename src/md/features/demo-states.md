# Demo states: a screen that needs an account, entered by a tool

A program's documentation pictures are taken by its tool, which drives the program over the devtools channel
(`TOOLKIT_DEVTOOLS`, [docs/devtools.md](../../../docs/devtools.md)). Some screens exist only after an account action:
Wren's password vault unlocked, a PIN prompt, a licence active, a sync signed in. A tool cannot reach them with clicks
and keys, because the step needs a secret, a server or a second device. Before demo states, a person changed the code
for the time of the capture, then took the change back.

## The irreducible parts

- A name per state, stable across versions, that a script can hold: `vault.unlocked`, `pin.asked`.
- A procedure of the program that puts its in-memory state in that screen. Only the program knows its own state.
- A way for the tool to ask for a state by name, and to learn which names exist.
- The procedure runs on the interface thread, between two builds, as every change of the program's state does.
- None of it in a build that ships to people.

## Decisions

- **The program registers its states on its server.** `devtools.demo_state(srv, name, enter, user)`, once, after
  `start_from_env`. The registry is a field of `devtools.Server`, not a global: the server already is the program's
  devtools state, a test that serves an application in its own process (`start_local`) has its own registry, and two
  tests that run at once never see each other's states. A nil server (no `TOOLKIT_DEVTOOLS`) registers nothing, so the
  calls stay in the program's code unconditionally.
- **Compiled out with the rest.** The body of `demo_state` is under `when TOOLKIT_DEVTOOLS`: a release build without the
  define keeps no name and no procedure pointer, as it keeps none of the server.
- **One name, one state.** A name registered again replaces the first entry: the program that serves a new server
  (a test's `start_local`) registers again without a special path. The names keep their order of registration, which is
  the order `Toolkit.demoStates` lists them.
- **The procedure runs where commands run.** `service` carries out the inbox on the interface thread before
  `poll_events` and `begin_build`; `Toolkit.demoState` calls the procedure there, then answers. The build that follows in
  the same frame shows the state, so the tool waits for its box (`wait_name`) or for rest (`wait_idle`) as after a click.
- **An unknown name is an error that lists the names.** A script with a typo fails at its step and says what exists,
  instead of taking a picture of the wrong screen.
- **The procedure sets memory, never files.** A demo state is a picture's setting: it never writes the person's vault,
  preferences or licence, and it never calls a server. The toolkit cannot check this; the program's author keeps it so.
  A tool runs the program with empty settings folders all the same (`toolbox.Program_Session`), so a mistake stays in
  that folder.
- **No leave.** A state is entered once, before a picture; the program then ends. A procedure to go back would double
  every program's work for a use no tool has.
- **A script step.** `demo <name>` in a script (`cdp.act`): `tk cdp`, `tk cdp play`, timelines and the tools of the
  programs share one line for it.

## Refused

- A define or a command-line flag per state: each program would parse its own, and a state could not be entered after
  the start, in the middle of a script.
- A global registry: two servers in one process (tests run at once) would share and replace each other's procedures.
- Faking the account at its source (a fake vault file, a fake licence server): it writes files or needs a server, and
  each program would build its own.
