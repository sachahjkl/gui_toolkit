#+build linux
package platform

// open_path and open_url("file://...") on Linux must run xdg-open rather than sending file:// to
// org.freedesktop.portal.OpenURI.OpenURI (which rejects file: URIs while call_noreply hides the rejection).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

@(test)
open_path_uses_xdg_open_not_openuri_portal :: proc(t: ^testing.T) {
	sync.mutex_guard(&env_lock)
	dir := fmt.tprintf("%s/gt_open_path_%d", os.temp_dir(context.temp_allocator), os.get_pid())
	_ = os.remove_all(dir)
	if !testing.expect(t, os.make_directory_all(dir) == nil, "make temp dir") { return }
	defer _ = os.remove_all(dir)

	out_file := fmt.tprintf("%s/opened.txt", dir)
	bin := fmt.tprintf("%s/xdg-open", dir)
	script := fmt.tprintf("#!/bin/sh\nprintf '%%s\\n' \"$1\" >> '%s'\n", out_file)
	if !testing.expect(t, os.write_entire_file(bin, transmute([]u8)script) == nil, "write mock xdg-open") { return }
	if !testing.expect(t, os.chmod(bin, {.Read_User, .Write_User, .Execute_User}) == nil, "chmod mock xdg-open") { return }

	old_path, had_path := os.lookup_env("PATH", context.allocator)
	defer {
		if had_path {
			_ = os.set_env("PATH", old_path)
			delete(old_path)
		} else {
			_ = os.unset_env("PATH")
		}
	}
	new_path := had_path ? fmt.tprintf("%s:%s", dir, old_path) : dir
	_ = os.set_env("PATH", new_path)

	target := fmt.tprintf("%s/my photo.png", dir)
	testing.expect(t, open_path(target), "open_path launches xdg-open")
	file_uri := fmt.tprintf("FILE://%s", target)
	testing.expect(t, open_url(file_uri), "open_url with file: URI launches xdg-open")

	// launch_detached runs xdg-open in the background; wait with a bound for both lines to land.
	deadline := time.tick_add(time.tick_now(), 2 * time.Second)
	got := ""
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if data, err := os.read_entire_file(out_file, context.temp_allocator); err == nil {
			s := string(data)
			if strings.count(s, "\n") >= 2 { got = s; break }
		}
		time.sleep(5 * time.Millisecond)
	}
	expected := fmt.tprintf("%s\n%s\n", target, file_uri)
	testing.expect_value(t, got, expected)
}
