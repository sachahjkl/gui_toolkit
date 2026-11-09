package tk_desktop

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
Wakes :: struct {
	count: int,          // atomic
	sema:  sync.Sema,
}

@(private = "file")
count_wake :: proc(user: rawptr) {
	w := (^Wakes)(user)
	sync.atomic_add(&w.count, 1)
	sync.sema_post(&w.sema)
}

// Waits for a wake after `before` (bounded: a watcher that misses the change fails the test, it does not hang it).
@(private = "file")
woke_after :: proc(w: ^Wakes, before: int) -> bool {
	deadline := time.tick_now()
	for sync.atomic_load(&w.count) <= before {
		if time.tick_since(deadline) > 10 * time.Second { return false }
		_ = sync.sema_wait_with_timeout(&w.sema, 10 * time.Second)
	}
	return true
}

// Places that do not exist yet are followed through their ancestors: the install folder made later wakes the program,
// then what changes in it, then its removal and its making again; the Desktop that appears too.
@(test)
watch_follows_places_that_come_and_go :: proc(t: ^testing.T) {
	root := fmt.aprintf("%s/tk_watch_%d", os.get_env("TMPDIR", context.temp_allocator) != "" ? os.get_env("TMPDIR", context.temp_allocator) : "/tmp", time.now()._nsec)
	defer delete(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)
	o := Options{
		identity = test_identity(),
		applications_dir = fmt.tprintf("%s/share/applications", root), icons_dir = fmt.tprintf("%s/share/icons/hicolor", root),
		bin_dir = fmt.tprintf("%s/bin", root), autostart_dir = fmt.tprintf("%s/config/autostart", root),
		desktop_dir = fmt.tprintf("%s/Desktop", root), install_dir = fmt.tprintf("%s/programs/sample", root),
	}
	wakes: Wakes
	w := watch_start(&o, count_wake, &wakes)
	testing.expect(t, w != nil)
	if w == nil { return }
	defer watch_stop(w)

	// the install folder is made, two levels down from what exists
	n := sync.atomic_load(&wakes.count)
	testing.expect(t, os.make_directory_all(o.install_dir) == nil)
	testing.expect(t, woke_after(&wakes, n), "the install folder that came")
	// a file in it
	n = sync.atomic_load(&wakes.count)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sample_install.txt", o.install_dir), transmute([]byte)string("x")) == nil)
	testing.expect(t, woke_after(&wakes, n), "a file written in the install folder")
	// removed, then made again: followed again through the ancestor
	n = sync.atomic_load(&wakes.count)
	testing.expect(t, os.remove_all(o.install_dir) == nil)
	testing.expect(t, woke_after(&wakes, n), "the install folder removed")
	n = sync.atomic_load(&wakes.count)
	testing.expect(t, os.make_directory_all(o.install_dir) == nil)
	testing.expect(t, woke_after(&wakes, n), "the install folder made again")
	n = sync.atomic_load(&wakes.count)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sample", o.install_dir), transmute([]byte)string("x")) == nil)
	testing.expect(t, woke_after(&wakes, n), "a file in the install folder made again")
	// the Desktop
	n = sync.atomic_load(&wakes.count)
	testing.expect(t, os.make_directory_all(o.desktop_dir) == nil)
	testing.expect(t, woke_after(&wakes, n), "the Desktop that came")
}

// The name of the next directory toward a place, below a watched ancestor.
@(test)
watch_next_component :: proc(t: ^testing.T) {
	testing.expect_value(t, next_component("/a", "/a/b/c"), "b")
	testing.expect_value(t, next_component("/a/", "/a/b"), "b")
	testing.expect_value(t, next_component("/", "/home/x"), "home")
	testing.expect_value(t, next_component("/a", "/ab/c"), "")
	testing.expect_value(t, next_component("/a/b", "/a/b"), "")
}
