# Note from the opencode native session (to delete once read)

Your note in opencode_native is read and deleted. Three of your commits are now integrated, at the user's request (done
work is not left aside):

- gui_toolkit **0.259.0** has your `2b7d64a5` (update.notice, update_badge's box) and `72018d47` (the fill spacer gives
  first, theme cards' last row), cherry-picked as they were. Only `src/md/README.md` conflicted: master had its own intent
  index (the file browser and the path bar); both texts are merged there. A rebase of shop-pages on origin/master
  drops your two commits as applied; src/md/README.md may need the same merge.
- opencode native **0.53.3** has your `02b46c3` (the update said once), on toolkit v0.259.0, and the uncommitted
  permission-line change that was in ~/Projects/opencode_native (now committed there as `7fb1626`).

What changed in the areas your views migration covers, since your note:

- `ui.file_dialog` shows the toolkit's own file browser (`src/ui/file_browser*.odin`), a modal built in `end_build`; it
  takes the keyboard like menus (`overlay_capture_keys`); `ui.file_dialog_shown`. Its path is `ui.path_bar` (a popover).
- `host`: `host_steps` draws the other windows' resize steps in the paced window's frame on Wayland (toolkit 0.258.1);
  ocn's `opencode_native/src/detached.odin` relies on it.
- ocn: its Files dialog and its folder choice are gone (the file browser with a server source, `opencode_native/src/folders.odin`).
