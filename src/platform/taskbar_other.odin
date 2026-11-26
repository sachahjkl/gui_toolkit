#+build !windows
#+build !linux
package platform

// The taskbar button on the systems that have no backend yet (taskbar.odin has the API): the window keeps its state and
// nothing is shown. macOS's port draws it on the dock tile (NSDockTile.badgeLabel, a progress view as its content view)
// and asks requestUserAttention: src/md/features/taskbar.md.

@(private) taskbar_apply :: proc(w: ^Window, parts: Taskbar_Parts) {}
@(private) taskbar_detach :: proc(w: ^Window) {}
