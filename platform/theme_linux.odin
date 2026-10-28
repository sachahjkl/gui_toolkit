#+build linux
package platform

// The desktop's appearance preferences on Linux: light / dark and "reduce motion". The authoritative source is the
// XDG Settings portal (org.freedesktop.portal.Settings, the org.freedesktop.appearance namespace) over D-Bus; reading
// it needs a D-Bus round trip. To keep the binary free of a hard libdbus link, this reads the cheap signals first —
// the environment the desktop sets and the GTK settings file — and leaves the live portal read to dialogs_linux.odin's
// D-Bus client when it is wired for a session bus. These heuristics match what most toolkits fall back to.

import "core:os"
import "core:strings"
import "core:sys/posix"

// Whether the user asked to reduce animations (GNOME "Reduce Animation", KDE "animation speed: instant"). Read from the
// GTK settings file's gtk-enable-animations, else false (animations on). os_animations_enabled negates this.
reduce_motion_preferred :: proc() -> bool {
	if v, ok := gtk_setting("gtk-enable-animations"); ok { return v == "0" || v == "false" }
	return false
}

// Whether the user prefers a dark theme. Read from the GTK theme name (a "-dark" suffix, or gtk-application-prefer-dark-theme),
// else from $GTK_THEME, else false. An app that calls set_dark_title follows this.
dark_mode_preferred :: proc() -> bool {
	if v, ok := gtk_setting("gtk-application-prefer-dark-theme"); ok && (v == "1" || v == "true") { return true }
	if t := posix.getenv("GTK_THEME"); t != nil && strings.contains(string(t), "dark") { return true }
	if v, ok := gtk_setting("gtk-theme-name"); ok && strings.contains(strings.to_lower(v, context.temp_allocator), "dark") { return true }
	return false
}

// A value from the GTK 3 settings.ini ($XDG_CONFIG_HOME/gtk-3.0/settings.ini), under [Settings]. Cheap and widely set
// by the desktop. ok = false when the file or the key is absent.
@(private)
gtk_setting :: proc(key: string) -> (value: string, ok: bool) {
	dir := config_dir(context.temp_allocator)
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
