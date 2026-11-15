#+build linux
package platform

// The desktop's appearance preferences on Linux: light / dark and "reduce motion". The authoritative source is the
// XDG Settings portal (org.freedesktop.portal.Settings, the org.freedesktop.appearance namespace) over D-Bus; reading
// it needs a D-Bus round trip. To keep the binary free of a hard libdbus link, this reads the cheap signals first —
// the environment the desktop sets and the GTK settings file — and leaves the live portal read to dialogs_linux.odin's
// D-Bus client when it is wired for a session bus. These heuristics match what most toolkits fall back to.

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "../ascii"
import base "../base"

// Whether the user asked to reduce animations (GNOME "Reduce Animation", KDE "animation speed: instant"). Read from the
// GTK settings file's gtk-enable-animations, else false (animations on). os_animations_enabled negates this.
reduce_motion_preferred :: proc() -> bool {
	if v, ok := gtk_setting("gtk-enable-animations"); ok { return v == "0" || v == "false" }
	return false
}

// Whether the user prefers a dark theme. The XDG appearance portal is authoritative (org.freedesktop.appearance
// color-scheme) and gives a live value; the GTK settings are the fallback when the portal is absent. An app that calls
// set_dark_title follows this, and watch_color_scheme (portal_linux.odin) tells it when the user flips it at run time.
// The value is read once a process (a D-Bus round trip, files: it waits on the system) and kept; the portal's
// SettingChanged gives the new one (color_scheme_watch), so a frame that asks again waits on nothing.
dark_mode_preferred :: proc(loc := #caller_location) -> bool {
	switch sync.atomic_load(&scheme_dark) {
	case SCHEME_DARK:  return true
	case SCHEME_LIGHT: return false
	}
	base.blocking("platform.dark_mode_preferred", loc)
	dark := dark_mode_read()
	sync.atomic_store(&scheme_dark, dark ? SCHEME_DARK : SCHEME_LIGHT)
	return dark
}

@(private = "file")
dark_mode_read :: proc() -> bool {
	if dark, ok := portal_dark_mode(); ok { return dark }
	if v, ok := gtk_setting("gtk-application-prefer-dark-theme"); ok && (v == "1" || v == "true") { return true }
	if t := posix.getenv("GTK_THEME"); t != nil && strings.contains(string(t), "dark") { return true }
	if v, ok := gtk_setting("gtk-theme-name"); ok && ascii.contains_fold(v, "dark") { return true }
	return false
}

// The preference last read or told by the portal (atomic): not read yet, dark, light.
@(private = "file") SCHEME_UNKNOWN :: 0
@(private = "file") SCHEME_DARK :: 1
@(private = "file") SCHEME_LIGHT :: 2
@(private) scheme_dark: i32

// The portal's SettingChanged, once: it keeps the new value and bumps color_scheme_serial.
@(private) scheme_watched: bool

@(private)
color_scheme_watch :: proc() {
	if scheme_watched { return }
	scheme_watched = true
	watch_color_scheme(proc(dark: bool) {
		sync.atomic_store(&scheme_dark, dark ? SCHEME_DARK : SCHEME_LIGHT)
		color_scheme_bump()
	})
}

// A value from the GTK 3 settings.ini ($XDG_CONFIG_HOME/gtk-3.0/settings.ini), under [Settings]. Cheap and widely set
// by the desktop. ok = false when the file or the key is absent.
@(private)
gtk_setting :: proc(key: string) -> (value: string, ok: bool) {
	dir := user_dir(.Config, "", context.temp_allocator)
	if dir == "" { return "", false }
	path := strings.concatenate({dir, "/gtk-3.0/settings.ini"}, context.temp_allocator)
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil { return "", false }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, key) { continue }
		rest := strings.trim_space(l[len(key):])
		if !strings.has_prefix(rest, "=") { continue }
		return strings.clone(strings.trim_space(rest[1:]), context.temp_allocator), true
	}
	return "", false
}
