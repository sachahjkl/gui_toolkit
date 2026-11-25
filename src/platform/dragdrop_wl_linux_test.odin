#+build linux
package platform

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"

@(test)
toplevel_drag_offset_scales_by_dpi :: proc(t: ^testing.T) {
	testing.expect_value(t, wl_toplevel_drag_offset({60, 16}, 1.0), [2]i32{60, 16})
	testing.expect_value(t, wl_toplevel_drag_offset({120, 32}, 2.0), [2]i32{60, 16})
	testing.expect_value(t, wl_toplevel_drag_offset({45, 15}, 1.5), [2]i32{30, 10})
	testing.expect_value(t, wl_toplevel_drag_offset({10, -10}, 0), [2]i32{10, -10})
	testing.expect_value(t, wl_toplevel_drag_offset({-30, -15}, 1.5), [2]i32{-20, -10})
}

@(private = "file")
Fake_Drag_Event :: enum u8 {
	Get_Toplevel_Drag,
	Attach,
	Start_Drag,
	Destroy_Toplevel_Drag,
	Destroy_Data_Source,
}

@(private = "file")
Fake_Drag_Reply :: enum u8 {
	Cancel,
	Drop_Move,
}

@(private = "file")
Fake_Wl_Server :: struct {
	listener:            posix.FD,
	advertise_tdm:       bool,
	reply:               Fake_Drag_Reply,
	events:              [16]Fake_Drag_Event,
	event_count:         int,
	attach_toplevel_id:  u32,
	attach_x, attach_y:  i32,
	expected_toplevel:   u32,
}

@(private = "file")
fake_record :: proc(s: ^Fake_Wl_Server, ev: Fake_Drag_Event) {
	if s.event_count < len(s.events) {
		s.events[s.event_count] = ev
		s.event_count += 1
	}
}

@(private = "file")
fake_put_u32 :: proc(buf: []u8, at: ^int, v: u32) {
	buf[at^ + 0] = u8(v)
	buf[at^ + 1] = u8(v >> 8)
	buf[at^ + 2] = u8(v >> 16)
	buf[at^ + 3] = u8(v >> 24)
	at^ += 4
}

@(private = "file")
fake_get_u32 :: proc(buf: []u8, at: int) -> u32 {
	return u32(buf[at]) | u32(buf[at + 1]) << 8 | u32(buf[at + 2]) << 16 | u32(buf[at + 3]) << 24
}

@(private = "file")
fake_send_msg :: proc(fd: posix.FD, obj: u32, opcode: u16, words: []u32) {
	buf: [128]u8
	at := 0
	size := u32(8 + len(words) * 4)
	fake_put_u32(buf[:], &at, obj)
	fake_put_u32(buf[:], &at, (size << 16) | u32(opcode))
	for w in words { fake_put_u32(buf[:], &at, w) }
	posix.send(fd, &buf[0], uint(at), {})
}

@(private = "file")
fake_send_global :: proc(fd: posix.FD, registry_id, name: u32, iface: string, version: u32) {
	buf: [128]u8
	at := 0
	slen := u32(len(iface) + 1)
	padded := int((slen + 3) &~ 3)
	size := u32(8 + 4 + 4 + padded + 4)
	fake_put_u32(buf[:], &at, registry_id)
	fake_put_u32(buf[:], &at, (size << 16) | 0) // wl_registry.global
	fake_put_u32(buf[:], &at, name)
	fake_put_u32(buf[:], &at, slen)
	copy(buf[at:], iface)
	at += padded
	fake_put_u32(buf[:], &at, version)
	posix.send(fd, &buf[0], uint(at), {})
}

@(private = "file")
fake_wl_server_proc :: proc(data: rawptr) {
	s := (^Fake_Wl_Server)(data)
	c := posix.accept(s.listener, nil, nil)
	if c < 0 { return }
	defer posix.close(c)

	registry_id: u32
	compositor_id, ddm_id, dd_id, xdg_base_id, tdm_id: u32
	data_source_id, td_id: u32
	// Map up to 4 surfaces to their xdg_surface + xdg_toplevel so commit triggers configure.
	Surface_Role :: struct { surface, xdg_surface, xdg_toplevel: u32, configured: bool }
	roles: [4]Surface_Role
	role_count := 0

	for {
		head: [8]u8
		if posix.recv(c, &head[0], 8, {.WAITALL}) != 8 { break }
		obj := fake_get_u32(head[:], 0)
		w1 := fake_get_u32(head[:], 4)
		opcode := u16(w1 & 0xffff)
		size := int(w1 >> 16)
		body: [512]u8
		if size > 8 {
			if size - 8 > len(body) { break }
			if int(posix.recv(c, &body[0], uint(size - 8), {.WAITALL})) != size - 8 { break }
		}

		switch {
		case obj == 1 && opcode == 0: // wl_display.sync(callback)
			cb := fake_get_u32(body[:], 0)
			fake_send_msg(c, cb, 0, {0})     // wl_callback.done
			fake_send_msg(c, 1, 1, {cb})     // wl_display.delete_id
		case obj == 1 && opcode == 1: // wl_display.get_registry(registry)
			registry_id = fake_get_u32(body[:], 0)
			fake_send_global(c, registry_id, 1, "wl_compositor", 4)
			fake_send_global(c, registry_id, 2, "wl_seat", 5)
			fake_send_global(c, registry_id, 3, "wl_data_device_manager", 3)
			fake_send_global(c, registry_id, 4, "xdg_wm_base", 4)
			if s.advertise_tdm {
				fake_send_global(c, registry_id, 5, "xdg_toplevel_drag_manager_v1", 1)
			}
		case obj == registry_id && opcode == 0: // wl_registry.bind(name, iface, ver, id)
			name := fake_get_u32(body[:], 0)
			slen := fake_get_u32(body[:], 4)
			padded := int((slen + 3) &~ 3)
			new_id := fake_get_u32(body[:], 8 + padded + 4)
			switch name {
			case 1: compositor_id = new_id
			case 3: ddm_id = new_id
			case 4: xdg_base_id = new_id
			case 5: tdm_id = new_id
			}
		case obj == ddm_id && opcode == 0: // create_data_source(id)
			data_source_id = fake_get_u32(body[:], 0)
		case obj == ddm_id && opcode == 1: // get_data_device(id, seat)
			dd_id = fake_get_u32(body[:], 0)
		case obj == xdg_base_id && opcode == 2: // get_xdg_surface(id, surface)
			if role_count < len(roles) {
				roles[role_count] = {surface = fake_get_u32(body[:], 4), xdg_surface = fake_get_u32(body[:], 0)}
				role_count += 1
			}
		case tdm_id != 0 && obj == tdm_id && opcode == 1: // xdg_toplevel_drag_manager_v1.get_xdg_toplevel_drag(id, source)
			td_id = fake_get_u32(body[:], 0)
			fake_record(s, .Get_Toplevel_Drag)
		case td_id != 0 && obj == td_id && opcode == 1: // xdg_toplevel_drag_v1.attach(toplevel, x, y)
			s.attach_toplevel_id = fake_get_u32(body[:], 0)
			s.attach_x = i32(fake_get_u32(body[:], 4))
			s.attach_y = i32(fake_get_u32(body[:], 8))
			fake_record(s, .Attach)
		case td_id != 0 && obj == td_id && opcode == 0: // xdg_toplevel_drag_v1.destroy
			fake_record(s, .Destroy_Toplevel_Drag)
			fake_send_msg(c, 1, 1, {td_id})
			td_id = 0
		case dd_id != 0 && obj == dd_id && opcode == 0: // wl_data_device.start_drag(source, origin, icon, serial)
			fake_record(s, .Start_Drag)
			switch s.reply {
			case .Cancel:
				fake_send_msg(c, data_source_id, 2, {}) // wl_data_source.cancelled
			case .Drop_Move:
				fake_send_msg(c, data_source_id, 5, {WL_DND_ACTION_MOVE}) // wl_data_source.action
				fake_send_msg(c, data_source_id, 3, {})                  // wl_data_source.dnd_drop_performed
				fake_send_msg(c, data_source_id, 4, {})                  // wl_data_source.dnd_finished
			}
		case data_source_id != 0 && obj == data_source_id && opcode == 1: // wl_data_source.destroy
			fake_record(s, .Destroy_Data_Source)
			fake_send_msg(c, 1, 1, {data_source_id})
			data_source_id = 0
		case:
			// Check xdg_surface.get_toplevel and wl_surface.commit for role configuration.
			for &r in roles[:role_count] {
				if obj == r.xdg_surface && opcode == 1 {
					r.xdg_toplevel = fake_get_u32(body[:], 0)
					s.expected_toplevel = r.xdg_toplevel
				} else if obj == r.surface && opcode == 6 && r.xdg_toplevel != 0 && !r.configured {
					r.configured = true
					fake_send_msg(c, r.xdg_toplevel, 0, {0, 0, 0}) // xdg_toplevel.configure(0, 0, empty states)
					fake_send_msg(c, r.xdg_surface, 0, {1})        // xdg_surface.configure(serial=1)
				}
			}
		}
		_ = compositor_id
	}
}

@(private = "file")
Fake_Client_Run :: struct {
	carry_self:  bool,
	dpi_scale:   f32,
	grab:        [2]int,
	supported:   bool,
	drag_ok:     bool,
	drag_effect: Maybe(Drop_Effect),
	frame_calls: int,
}

@(private = "file")
run_fake_wayland_drag :: proc(t: ^testing.T, advertise_tdm: bool, reply: Fake_Drag_Reply, carry_self: bool, dpi_scale: f32, grab: [2]int) -> (srv: Fake_Wl_Server, cli: Fake_Client_Run) {
	path := fmt.tprintf("/tmp/gt_xtd_%d_%d", posix.getpid(), advertise_tdm ? (carry_self ? 2 : 1) : 0)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	posix.unlink(cpath)
	defer posix.unlink(cpath)

	sock := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, sock >= 0, "unix socket created") { return }
	defer posix.close(sock)

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	if !testing.expect(t, posix.bind(sock, (^posix.sockaddr)(&addr), size_of(addr)) == .OK, "unix socket bound") { return }
	if !testing.expect(t, posix.listen(sock, 2) == .OK, "unix socket listening") { return }

	srv = Fake_Wl_Server{listener = sock, advertise_tdm = advertise_tdm, reply = reply}
	server := thread.create_and_start_with_data(&srv, fake_wl_server_proc)

	old_wl := posix.getenv("WAYLAND_DISPLAY")
	old_copy := old_wl != nil ? strings.clone(string(old_wl), context.temp_allocator) : ""
	had_old := old_wl != nil
	posix.setenv("WAYLAND_DISPLAY", cpath, true)
	defer {
		if had_old {
			posix.setenv("WAYLAND_DISPLAY", strings.clone_to_cstring(old_copy, context.temp_allocator), true)
		} else {
			posix.unsetenv("WAYLAND_DISPLAY")
		}
	}

	cli = Fake_Client_Run{carry_self = carry_self, dpi_scale = dpi_scale, grab = grab}
	client := thread.create_and_start_with_data(&cli, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		c := (^Fake_Client_Run)(data)
		src := open_window("drag source", {300, 200})
		if src == nil { return }
		show_window(src)
		c.supported = drag_carry_supported(src)
		carried := src
		if !c.carry_self {
			carried = open_window("drag carried", {300, 200})
			if carried == nil { destroy_window(src); return }
		}
		carried.dpi_scale = c.dpi_scale
		d := Drag_Data{text = "tab"}
		carry := Drag_Carry{
			window = carried,
			grab = c.grab,
			frame = proc(u: rawptr) { (^Fake_Client_Run)(u).frame_calls += 1 },
			user = c,
		}
		c.drag_effect, c.drag_ok = drag_start(src, d, {.Move}, carry = carry)
		if !c.carry_self { destroy_window(carried) }
		destroy_window(src)
		if wlc.display != nil {
			wl.display_roundtrip(wlc.display)
			wl.display_disconnect(wlc.display)
			wlc.display = nil
		}
		wlc.link = .Lost
		delete(wlc.windows)
		delete(wlc.outputs)
		delete(wlc.toplevels)
		drag_data_destroy(&wlc.drag.data)
		wlc = {}
		mem.free_all(context.temp_allocator)
	})

	thread.join(client)
	thread.destroy(client)
	thread.join(server)
	thread.destroy(server)
	return srv, cli
}

// Verifies xdg-toplevel-drag-v1 wire order (get -> attach with DPI-scaled grab -> start_drag -> destroy toplevel drag
// strictly before destroy data source) for both cancel and drop, single-tab carry_self, and fallback without the global.
@(test)
toplevel_drag_protocol_and_fallback_over_fake_wayland :: proc(t: ^testing.T) {
	if !wayland_lib().ok { return }

	// 1. Compositor advertises xdg_toplevel_drag_manager_v1; hidden carried window at 2x DPI; drag cancelled.
	srv1, cli1 := run_fake_wayland_drag(t, true, .Cancel, false, 2.0, {120, 32})
	testing.expect(t, cli1.supported, "drag_carry_supported is true when global is advertised")
	testing.expect(t, cli1.drag_ok && cli1.drag_effect == nil, "cancelled drag returns ok=true, effect=nil")
	testing.expect(t, cli1.frame_calls >= 1, "carry.frame runs while drag is active")
	want1 := []Fake_Drag_Event{.Get_Toplevel_Drag, .Attach, .Start_Drag, .Destroy_Toplevel_Drag, .Destroy_Data_Source}
	testing.expectf(t, slice.equal(srv1.events[:srv1.event_count], want1), "cancel wire order: got %v, want %v", srv1.events[:srv1.event_count], want1)
	testing.expect_value(t, srv1.attach_x, i32(60))
	testing.expect_value(t, srv1.attach_y, i32(16))
	testing.expect(t, srv1.attach_toplevel_id != 0 && srv1.attach_toplevel_id == srv1.expected_toplevel, "attached toplevel matches carried window")

	// 2. Compositor advertises global; source window carries itself (single-tab drag) at 1.5x DPI; dropped as Move.
	srv2, cli2 := run_fake_wayland_drag(t, true, .Drop_Move, true, 1.5, {45, 15})
	testing.expect(t, cli2.supported)
	testing.expect(t, cli2.drag_ok && cli2.drag_effect == .Move, "dropped drag returns Move")
	want2 := []Fake_Drag_Event{.Get_Toplevel_Drag, .Attach, .Start_Drag, .Destroy_Toplevel_Drag, .Destroy_Data_Source}
	testing.expectf(t, slice.equal(srv2.events[:srv2.event_count], want2), "drop wire order: got %v, want %v", srv2.events[:srv2.event_count], want2)
	testing.expect_value(t, srv2.attach_x, i32(30))
	testing.expect_value(t, srv2.attach_y, i32(10))

	// 3. Compositor does NOT advertise xdg_toplevel_drag_manager_v1: graceful fallback to normal drag_start.
	srv3, cli3 := run_fake_wayland_drag(t, false, .Cancel, false, 1.0, {60, 16})
	testing.expect(t, !cli3.supported, "drag_carry_supported is false without global")
	testing.expect(t, cli3.drag_ok && cli3.drag_effect == nil, "fallback drag completes cleanly")
	want3 := []Fake_Drag_Event{.Start_Drag, .Destroy_Data_Source}
	testing.expectf(t, slice.equal(srv3.events[:srv3.event_count], want3), "fallback wire order: got %v, want %v", srv3.events[:srv3.event_count], want3)
}
