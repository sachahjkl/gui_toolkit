package tk_desktop

import "core:strings"

// The names of the roots roots_from_env reads, after the identity's prefix.
ROOT_NAMES :: [?]string{"MENU_DIR", "DESKTOP_DIR", "ENVIRONMENT_ROOT", "INSTALL_DIR", "REGISTRY_ROOT", "APPLICATIONS_DIR", "ICONS_DIR", "BIN_DIR", "AUTOSTART_DIR", "CONFIG_DIR", "THUMBNAILERS_DIR", "MACHINE_DIR", "IMAGE_OPTIONS_ROOT"}

// The roots a test (or a script that wants a dry run in a scratch place) sets in the environment, each named
// `Identity.env_prefix` + one of ROOT_NAMES. Any of them given also turns the system notification off: nothing outside
// the scratch roots is told anything.
//     <prefix>MENU_DIR          <prefix>REGISTRY_ROOT     (Windows)
//     <prefix>DESKTOP_DIR       <prefix>ENVIRONMENT_ROOT  (Windows: the Desktop folder; the key that stands for HKCU\Environment)
//     <prefix>APPLICATIONS_DIR  <prefix>ICONS_DIR         (Linux)
//     <prefix>BIN_DIR                                     (Linux: where the PATH part puts its link)
//     <prefix>AUTOSTART_DIR                               (Linux: where the autostart entry goes)
//     <prefix>CONFIG_DIR                                  (Linux: $XDG_CONFIG_HOME, where mimeapps.list is)
//     <prefix>THUMBNAILERS_DIR                            (Linux: where the Thumbnails part puts its .thumbnailer)
//     <prefix>MACHINE_DIR       <prefix>IMAGE_OPTIONS_ROOT (Windows: the Task_Manager part's machine copy; a key under
//                                                         HKCU that stands for HKLM's Image File Execution Options)
//     <prefix>INSTALL_DIR                                 (where the installed copy is)
// An identity without a prefix reads nothing.
roots_from_env :: proc(o: ^Integration_Options, lookup: proc(name: string) -> string) {
	prefix := o.identity.env_prefix
	if prefix == "" { return }
	dsts := [len(ROOT_NAMES)]^string{&o.menu_dir, &o.desktop_dir, &o.environment_root, &o.install_dir, &o.registry_root, &o.applications_dir, &o.icons_dir, &o.bin_dir, &o.autostart_dir, &o.config_dir, &o.thumbnailers_dir, &o.machine_dir, &o.image_options_root}
	names := ROOT_NAMES
	scratch := false
	for name, i in names {
		if v := lookup(strings.concatenate({prefix, name}, context.temp_allocator)); v != "" { dsts[i]^ = v; scratch = true }
	}
	if scratch { o.notify_system = false }
}
