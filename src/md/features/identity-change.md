# A program that changes its name

A program can take another name: opencode native becomes Tower (its title, slug, app id, install folder, settings
folder, update product and repository). The people who installed it under its earlier name keep their install, their
settings and their updates. The how-to is in [docs/setup.md](../../../docs/setup.md#an-earlier-name) and
[docs/update.md](../../../docs/update.md#a-product-that-changes-its-name).

## The change is a move

An identity change is a move between two identities, as a change of scope is a move between two scopes
([install-scope.md](install-scope.md)): the new install first, then the earlier one goes, then the new integration is
written again.

- The earlier install goes by the earlier identity's own names and marks (`Earlier.identity`). Each system's removal
  already deletes only what carries a program's mark: the Start menu's shortcut, the record, the Run value, the PATH
  entry and its console launcher, the ProgIDs and verbs, the `.desktop` file, the icons, the link in `~/.local/bin`, the
  autostart entry, the lines of `mimeapps.list`. The files go by the earlier install's manifest, never through a folder
  that is a link (`desktop.files_remove`): the manifest and the folder are the person's to write, and the removal now
  runs at a start that nobody clicked.
- The parts are the program's (`Setup_Options.prepare`): the two identities differ by their names and marks only. The
  choices of the earlier install come along: a box tied to parts is on when the earlier install has them
  (`choices_from_facts`), and the desktop shortcut when it had one.
- Last, the new integration is written again: a name that the two identities share (a thumbnail provider's CLSID, a
  line of `mimeapps.list`) is the new one's at the end, whatever the removal took.
- A user install in a folder of the person's choice (Windows records it) moves to a folder of the same parent, under the
  new name. Else the new install goes to its default folder.
- Refused: a rename of the install folder. Windows renames no folder that holds a running program, and the program
  that adopts runs from that folder (the update bridge, below). The move copies the program, then removes the
  earlier files; what runs is deleted when this process ends (`cleanup_later`), as an Uninstall from the installed copy
  does.

## Only the bridge installs

The install moves only when the running program is the earlier install's own file: the update bridge placed it there
(below). The person had the program installed, and an update brought the new name: nothing is asked of them.

- Another copy (a download, a portable copy, a build) moves the folders and installs nothing (`Offer`, the record says
  `Pending`). The setup's facts say "not installed" and its dialog offers the install as for any copy. Once the new
  install is there, the next start removes the earlier one (`Remove_Earlier`).
- Refused: a copy that installs itself because an earlier install exists. A person who tries a portable copy, or a
  developer who runs a build, would lose the installed program and get that copy in its place, against the "standalone"
  answer of the dialog.

## When

`adopt_earlier(o)` runs at the start, before the log, the settings and any window. It moves the folders that the log and
the settings read: after them, the program would start with empty folders, and the next start would find two. The
setup's facts would also say "not installed" for a program installed under its earlier name, and the setup would offer
to install it again.

- It runs on the main thread before an interface exists: there is no interface thread to block yet. Its waits are
  bounded (`ADOPT_WAIT`, 10 s, and twice that for another start), and they happen only when something is to be done.
- Refused: a task after the window opens. The settings are read by then.
- Refused: a step of the setup dialog. The person did not ask for anything: the program they had runs under a new name.

## One start at a time

A lock (`fsx.file_lock`: flock, LockFileEx) on `<record>.lock`, beside the record, is held during the whole adoption. Two
starts at once (the bridge and a second click, two clicks on a menu entry) would otherwise both move, both install, and
each write the whole record over the other's.

- A start that waits more than twice `ADOPT_WAIT` for the lock ends (`Busy`): it says that another start takes over the
  program, and the person starts it again. It never goes on beside the first: it would read folders half moved and make
  new ones.
- The record is read once the lock is held, so a start that waited reads what the first one did.
- The system lets the lock go when a process ends, crashed or not. The lock file stays: removing it while another
  process opens it gives two holders.

## The steps

1. **The earlier program runs.** A process of another copy runs an earlier program (its file, its `.old` name after an
   update on Windows, its `(deleted)` name after an update on Linux). The start waits for it to end, at most
   `ADOPT_WAIT`: after an update, the earlier process is still ending when the new one starts. If it still runs, nothing
   is done (`Running`): Windows renames no folder in which a process holds a file open, and the earlier program would
   write its settings again where they were. The program says it and ends (`stop`); the next start adopts. A start whose
   only step left is the install's offer does not wait: it removes nothing.
2. **The folders.** Each kind (configuration, data, state, cache) is one rename of the earlier folder to the new one,
   in the same volume: it is done or not done. `platform.user_dirs_move` has the same rule.
   - The new folder exists already: the new one stays, the earlier one stays where it is, and the result names it
     (`Kept_Both`). Refused: a merge. The two folders hold the same files, and which one wins is a choice per file;
     a wrong choice loses what the person set.
   - A rename that fails is tried again until `ADOPT_WAIT` ends: on Windows a scanner or the search indexer often holds
     a file that the ending process just wrote, for a moment.
   - A rename that still fails ends the start (`Failed`, `stop`): the settings stay where they are, and the program
     says to start it again. The program must not go on: its log and settings would make the new folders, the next
     start would find both, and the person's settings would stay behind for good. The record counts these starts.
   - After `ADOPT_TRIES` (3) such starts, the next one copies the folder: a whole copy into a sibling
     (`<new>.adopting`), then one rename into place; the earlier folder stays (`Copied`), and the result names it. A
     failure that lasts (another volume under the earlier folder, a folder Windows keeps open) does not keep the program
     from starting for ever. An interruption leaves the sibling, never half a new folder: the next try deletes the
     sibling and begins again. A link in the folder is copied as a link, never followed.
   - Refused: a copy then a delete of the earlier folder. An interruption leaves two halves, and nothing tells which
     half is complete. The copy keeps the earlier folder whole.
   - A copy that fails too ends the start again. The program starts once the folder moves or copies: the person frees
     the space or closes what holds it.
3. **The install** (`adopt_plan`, pure; its facts read again after the wait and after the folders):

   | The earlier install | What happens |
   |---|---|
   | none | nothing |
   | for the person, this copy is its file (the bridge), the new one not there | `Move`: the new install with the same choices, then the earlier one goes |
   | for the person, another copy runs, the new one not there | `Offer`: nothing; the setup offers the install (`Pending`) |
   | for the person, the new one there too | `Remove_Earlier`: the earlier one goes |
   | only what an install left (a launcher, the record) | `Remove_Earlier` |
   | for everyone | `Administered`: nothing; an administrator installs the new program for everyone and uninstalls the earlier one |
   | this copy runs from the Nix store | `Managed`: nothing; the Nix package is renamed by Nix |

   The machine half of an install for everyone is written only by the elevated verb, after a person asked for it
   ([install-scope.md](install-scope.md)). A start asks for nothing: no prompt opens by itself. Its updates are an
   administrator's too, so the update bridge never reaches it.

   An earlier install inside one of its own earlier folders (an old version installed in its data folder) goes first;
   then the folder moves without it. Else the folder's rename would carry the program into the new data folder.
4. **The hand-off.** When this copy runs from the earlier install's folder, the result gives `relaunch`: the adopted
   program. The program starts it and ends, before any window; the lock is let go before. On Windows the earlier files go
   when this process ends; Linux deletes a running file at once. The adopted copy says the news, and moves a folder
   that is left.

All the paths of the running program come from `exe` (default: this process's file): the facts, the copy that is
installed, the removal. A test gives the bridge's file and a download's path, and each step sees the same program.

## Interrupted

Each step is safe to run again. Its rule reads the disk: a folder moves only when the earlier one is there and the new
one is not; a copy is installed only when the new install is not there; the earlier install goes only when it is there.

The record makes the result last. `<state base>/<program_folder>.adoption` (for example
`~/.local/state/FromentSoftware/Tower.adoption`) holds, per earlier slug, each step's state: `Begun`, then its outcome,
whether it was said, and the folders' failed starts.

- The record is beside the program's state folder, not in it. In it, the record would make the new folder before the
  move, and the move would find a new folder there.
- A step begun before an interruption whose rule now finds nothing to do was done by that start: its outcome is `Done`.
  A copy begun before an interruption is there beside the earlier folder: its outcome is `Copied`. No other start can
  have made the new folder meanwhile: each one ended, or waited for the lock.
- A step with a final outcome (`Done`, `Copied`, `Kept_Both`, `Administered`, `Managed`, nothing) is not run again.
  `Failed` and `Pending` are run again at the next start. `Running` and `Busy` write no outcome.
- Each step's result is said once (`Adoption.news`), when it is final: the folders at one start, the install at a later
  one when it waited for the offer. A failed install is said at each start. With a hand-off, the copy that adopted says
  nothing: the adopted copy reads the record at its start and says it.
- The state base, not the configuration's: on Windows `%APPDATA%` roams to the person's other computers, where the
  earlier install is still there.

## What the adoption does not see

- **An earlier program that runs from another place**: a Nix package of the earlier name, a portable copy. The wait
  looks for the earlier install's file only; finding every copy would mean reading every process's file and guessing
  which ones are the earlier program. Such a process still writes the earlier folders: on Linux the rename succeeds
  under it, and what it saves after goes to an earlier folder made again, which no start adopts (the folders' step is
  done). On Windows the rename fails while it holds a file, and the folders' step ends the start as above.
- **An earlier program started after the wait**, during the adoption (a click on the earlier menu entry, a few seconds
  long): the same. Its menu entry is gone at the end of the adoption.
- What it saves in that session is the person's to copy by hand. The case is rare: a person runs one of the two names.

## What Windows does not let a program change

- **A pin on the taskbar.** The taskbar keeps the pins in its own data. Windows lets no program pin, unpin or
  retarget a pin; a changed shortcut in `User Pinned\TaskBar` shows only after Explorer restarts, if at all. A pin of
  the earlier program starts nothing once its file is gone. Decided: the adoption finds a pin that runs the earlier
  program (`desktop.taskbar_pinned`), and the result asks the person to pin the new program again.
- **What Windows keeps per AppUserModelID**: the jump list, the notification settings, the grouping. The new id starts
  with none.
- **The console command.** The launcher is named after the program's file: the earlier command goes with the earlier
  install. The result says the new command.

On Linux, a dock pins an entry by its id (GNOME's `favorite-apps`, Plasma's launchers). The earlier id is gone with
its `.desktop` file, and the dock drops it. The adoption does not read each desktop's settings to say it.

## The updates of an install several versions late

An install that has not updated for months checks the earlier product's manifest at the earlier URL, with the earlier
key and context. It must still arrive.

- **Decided: the earlier feed.** The earlier URLs keep serving the earlier product's manifest
  (`update-<platform>[-<channel>].json`, product `opencode-native`, signed with the earlier context). That manifest
  names the newest program, copied under the earlier file name (`opencode-native-<version>-<platform>`). Every version
  that ever shipped understands it: nothing new is asked of the installed programs. The updater places the new program
  over the earlier one, in the earlier folder; its next start adopts.
- `toolbox.update_earlier` writes that copy and its signed manifest at each release. One hop: every earlier install
  arrives at the newest program.
- **The key.** The same key pair signs both feeds: the key is the publisher's, not the name's. The earlier product
  keeps its own context, so a signature of one product is never valid for the other.
- **The versions.** The new program's versions continue above the earlier ones. An earlier updater takes only a newer
  version (`check_newer`); a new name that starts again at `0.1.0` is never offered. `update_earlier` takes the last
  earlier version (`last_earlier`) and refuses a version that is not above it: the release fails, instead of a feed that
  every earlier install ignores. Decided: a parameter, not the manifest found in the output folder. A release writes
  into an empty folder, where there is nothing to compare.
- **Where.** The earlier feed stays at the earlier URLs. GitHub redirects the URLs of a renamed repository to the new
  one, and both feeds then have the same file names in one folder. So either the repository keeps its earlier name and
  the new product publishes elsewhere, or a repository is made again under the earlier name after the rename, which
  ends the redirect, and holds the earlier feed.
- **How long.** As long as its cost is small. After that, the earlier feed is frozen at its last release and never
  deleted: an install older than the freeze arrives in two hops (the frozen release, then the new product's own
  updater). Deleting it strands every install that has not run since.
- Refused: a `moved` field in the manifest, naming the new product's manifest. Only versions built after the field
  follow it, so the earlier feed is needed anyway for every version before it. Following it also means that the
  earlier key vouches for another product's key, context and folder: a second path of trust in every program, for one
  rename.
- Refused: the first release of the new name published only under the earlier product. It is the frozen feed from its
  first day: every later install takes two hops, and nothing is gained.
