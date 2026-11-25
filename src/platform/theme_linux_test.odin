#+build linux
package platform

import "core:sync"
import "core:testing"
import "../dbus"

@(private = "file")
make_variant_u32_msg :: proc(v: u32, nested: bool) -> dbus.Message {
	w := dbus.writer_make(context.temp_allocator)
	if nested { dbus.w_signature(&w, "v") }
	dbus.w_signature(&w, "u")
	dbus.w_u32(&w, v)
	return dbus.Message{type = .Method_Return, body_bytes = w.buf[:]}
}

@(private = "file")
make_setting_changed_u32 :: proc(ns, key: string, v: u32) -> dbus.Message {
	w := dbus.writer_make(context.temp_allocator)
	dbus.w_string(&w, ns)
	dbus.w_string(&w, key)
	dbus.w_signature(&w, "u")
	dbus.w_u32(&w, v)
	return dbus.Message{type = .Signal, body_bytes = w.buf[:]}
}

@(private = "file")
make_setting_changed_str :: proc(ns, key, val: string) -> dbus.Message {
	w := dbus.writer_make(context.temp_allocator)
	dbus.w_string(&w, ns)
	dbus.w_string(&w, key)
	dbus.arg_variant_string(&w, val)
	return dbus.Message{type = .Signal, body_bytes = w.buf[:]}
}

// ReadOne (v(u)) and Read (v(v(u))) both parse 0/2 as light, 1 as dark, and reject unknown or non-integer values.
@(test)
portal_color_scheme_message_parsing :: proc(t: ^testing.T) {
	for nested in ([?]bool{false, true}) {
		m0 := make_variant_u32_msg(0, nested)
		dark, ok := portal_parse_color_scheme_msg(&m0)
		testing.expectf(t, ok && !dark, "nested=%v scheme 0 -> light", nested)

		m1 := make_variant_u32_msg(1, nested)
		dark, ok = portal_parse_color_scheme_msg(&m1)
		testing.expectf(t, ok && dark, "nested=%v scheme 1 -> dark", nested)

		m2 := make_variant_u32_msg(2, nested)
		dark, ok = portal_parse_color_scheme_msg(&m2)
		testing.expectf(t, ok && !dark, "nested=%v scheme 2 -> light", nested)

		m99 := make_variant_u32_msg(99, nested)
		_, ok = portal_parse_color_scheme_msg(&m99)
		testing.expectf(t, !ok, "nested=%v scheme 99 -> unknown", nested)
	}

	// Non-integer variant must fail instead of returning 0 (light).
	w := dbus.writer_make(context.temp_allocator)
	dbus.arg_variant_string(&w, "dark")
	ms := dbus.Message{type = .Method_Return, body_bytes = w.buf[:]}
	_, ok := portal_parse_color_scheme_msg(&ms)
	testing.expect(t, !ok, "string variant is rejected")

	// Empty / truncated body must fail instead of returning 0 (light).
	empty := dbus.Message{type = .Method_Return}
	_, ok = portal_parse_color_scheme_msg(&empty)
	testing.expect(t, !ok, "empty body is rejected")
}

@(private = "file")
cb_state: struct {
	calls:        int,
	last_dark:    bool,
	pref_in_cb:   bool,
}

@(private = "file")
test_theme_cb :: proc(dark: bool) {
	cb_state.calls += 1
	cb_state.last_dark = dark
	cb_state.pref_in_cb = dark_mode_preferred()
}

// SettingChanged updates scheme_dark + color_scheme_serial AND fires the app's watch_color_scheme callback,
// without color_scheme_watch clobbering the app callback.
@(test)
portal_setting_changed_updates_state_and_callback :: proc(t: ^testing.T) {
	saved_scheme := sync.atomic_load(&scheme_dark)
	saved_serial := sync.atomic_load(&scheme_serial)
	saved_cb := session.theme_changed
	saved_sub := session.theme_sub
	defer {
		sync.atomic_store(&scheme_dark, saved_scheme)
		sync.atomic_store(&scheme_serial, saved_serial)
		session.theme_changed = saved_cb
		session.theme_sub = saved_sub
		cb_state = {}
	}

	// Pretend a bus subscription is active so color_scheme_watch / watch_color_scheme do not touch a live D-Bus.
	session.theme_sub = 1
	cb_state = {}
	color_scheme_apply(true)

	testing.expect(t, watch_color_scheme(test_theme_cb))
	// Calling color_scheme_watch (as color_scheme_serial / os_animations_enabled do) must not overwrite session.theme_changed.
	color_scheme_watch()
	testing.expect(t, session.theme_changed == test_theme_cb, "color_scheme_watch preserves app callback")

	// Signal: 0 (no preference -> light)
	serial0 := sync.atomic_load(&scheme_serial)
	sig0 := make_setting_changed_u32("org.freedesktop.appearance", "color-scheme", 0)
	portal_setting_changed(nil, &sig0)
	testing.expect_value(t, cb_state.calls, 1)
	testing.expect(t, !cb_state.last_dark, "scheme 0 notifies light")
	testing.expect(t, !cb_state.pref_in_cb, "dark_mode_preferred is already updated inside callback")
	testing.expect(t, !dark_mode_preferred(), "scheme_dark is light")
	testing.expect_value(t, sync.atomic_load(&scheme_serial), serial0 + 1)

	// Signal: 1 (prefer dark)
	sig1 := make_setting_changed_u32("org.freedesktop.appearance", "color-scheme", 1)
	portal_setting_changed(nil, &sig1)
	testing.expect_value(t, cb_state.calls, 2)
	testing.expect(t, cb_state.last_dark, "scheme 1 notifies dark")
	testing.expect(t, cb_state.pref_in_cb, "dark_mode_preferred is dark inside callback")
	testing.expect(t, dark_mode_preferred(), "scheme_dark is dark")
	testing.expect_value(t, sync.atomic_load(&scheme_serial), serial0 + 2)

	// Signal: unknown value (99) and malformed string are ignored
	sig_bad := make_setting_changed_u32("org.freedesktop.appearance", "color-scheme", 99)
	portal_setting_changed(nil, &sig_bad)
	sig_str := make_setting_changed_str("org.freedesktop.appearance", "color-scheme", "light")
	portal_setting_changed(nil, &sig_str)
	testing.expect_value(t, cb_state.calls, 2)
	testing.expect(t, dark_mode_preferred(), "malformed signals do not change state")
	testing.expect_value(t, sync.atomic_load(&scheme_serial), serial0 + 2)

	// Clearing the app callback keeps internal tracking active
	_ = watch_color_scheme(nil)
	sig2 := make_setting_changed_u32("org.freedesktop.appearance", "color-scheme", 2)
	portal_setting_changed(nil, &sig2)
	testing.expect_value(t, cb_state.calls, 2)
	testing.expect(t, !dark_mode_preferred(), "internal tracking still updates after clearing callback")
	testing.expect_value(t, sync.atomic_load(&scheme_serial), serial0 + 3)
}
