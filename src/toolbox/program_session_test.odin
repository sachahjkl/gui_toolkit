package tk_toolbox

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import testkit "../testkit"

// The port free_port gives is one a listener can take now.
@(test)
a_free_port_can_be_listened_on :: proc(t: ^testing.T) {
	// (a few tries: a test running beside this one can take the port between its choice and the listen, as it did on
	// the Linux CI; a port no listener could ever take fails every try)
	port: int
	l: net.TCP_Socket
	err: net.Network_Error
	for _ in 0 ..< 5 {
		ok: bool
		port, ok = free_port()
		testing.expect(t, ok, "the system gives a port")
		if !ok { return }
		testing.expect(t, port > 0 && port < 65536, "a port")
		l, err = net.listen_tcp({address = net.IP4_Loopback, port = port})
		if err == nil { break }
	}
	testing.expect(t, err == nil, "a listener takes it")
	if err != nil { return }
	defer net.close(l)
	// (a second session while the first one's program listens: never the same port)
	other, got := free_port()
	testing.expect(t, got && other != port, "a second run gets another port")
}

// A session with no command does not start, and its stop is safe: a tool's `defer program_session_stop` runs on every path.
@(test)
a_session_without_a_command_does_not_start :: proc(t: ^testing.T) {
	s: Program_Session
	why := program_session_start(&s, "build/program_session_test", {})
	testing.expect(t, why != "", "it says why")
	testing.expect_value(t, program_session_stop(&s), -1)
	_, cwhy := program_session_connect(&s)
	testing.expect(t, cwhy != "", "nothing to connect to")
}

// A program a tool starts draws on lavapipe: its Vulkan drivers are lavapipe's manifest alone, whatever the person's
// environment names (NVIDIA's), and no implicit layer loads another driver. Asked for the GPU, the environment stays.
@(test)
a_program_draws_on_lavapipe_unless_it_asks_for_the_gpu :: proc(t: ^testing.T) {
	desktop := []string{"HOME=/h", "VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json", "VK_ICD_FILENAMES=/n.json", "VK_ADD_DRIVER_FILES=/m.json"}
	lvp := "/mesa/share/vulkan/icd.d/lvp_icd.x86_64.json"
	value :: proc(env: []string, name: string) -> (v: string, n: int) {
		for e in env {
			if strings.has_prefix(e, name) && len(e) > len(name) && e[len(name)] == '=' { v, n = e[len(name) + 1:], n + 1 }
		}
		return
	}
	env := program_env(desktop, 4242, {env = {"A=1"}}, lvp)
	v, n := value(env, "VK_DRIVER_FILES")
	testing.expect_value(t, v, lvp)
	testing.expect_value(t, n, 1)
	v, _ = value(env, "VK_LOADER_LAYERS_DISABLE")
	testing.expect_value(t, v, "~implicit~")
	_, n = value(env, "VK_ICD_FILENAMES")
	testing.expect_value(t, n, 0)
	_, n = value(env, "VK_ADD_DRIVER_FILES")
	testing.expect_value(t, n, 0)
	v, _ = value(env, "TOOLKIT_DEVTOOLS")
	testing.expect_value(t, v, "4242")
	v, _ = value(env, "A")
	testing.expect_value(t, v, "1")

	gpu := program_env(desktop, 4242, {gpu = true}, "")
	v, _ = value(gpu, "VK_DRIVER_FILES")
	testing.expect_value(t, v, "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json")
	_, n = value(gpu, "VK_LOADER_LAYERS_DISABLE")
	testing.expect_value(t, n, 0)
	_, n = value(gpu, "VK_ICD_FILENAMES")
	testing.expect_value(t, n, 1)
}

// lavapipe's manifest is found among the others of an icd.d folder, for this architecture; a VK_DRIVER_FILES that names
// it alone is kept; one that names another driver is not taken.
@(test)
lavapipe_is_found_among_the_drivers :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "icd")
	other := fmt.tprintf("%s/other", dir)
	icd := fmt.tprintf("%s/icd.d", dir)
	for d in ([]string{other, icd}) { testing.expect(t, os.make_directory_all(d) == nil, "a folder") }
	names := []string{"nvidia_icd.json", "lvp_icd.i686.json", "radeon_icd.x86_64.json", fmt.tprintf("lvp_icd.%s.json", SOFTWARE_VULKAN_ARCH)}
	for name in names { testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", icd, name), "{}") == nil, "a manifest") }
	want := fmt.tprintf("%s/lvp_icd.%s.json", icd, SOFTWARE_VULKAN_ARCH)

	path, ok := software_vulkan_find("", {fmt.tprintf("%s/none", dir), other, icd})
	testing.expect(t, ok, "found")
	testing.expect_value(t, path, want)
	path, ok = software_vulkan_find(fmt.tprintf("%s/nvidia_icd.json", icd), {icd})
	testing.expect_value(t, path, want)   // (the person's NVIDIA driver is not taken)
	path, ok = software_vulkan_find(want, nil)
	testing.expect(t, ok && path == want, "VK_DRIVER_FILES naming lavapipe is kept")
	_, ok = software_vulkan_find(fmt.tprintf("%s/nvidia_icd.json", icd), {other})
	testing.expect(t, !ok, "no lavapipe: none, never another driver")
	testing.expect(t, !software_vulkan_is("lvp_icd.i686.json"), "another architecture's")
	testing.expect(t, software_vulkan_is("/a/b/lvp_icd.json"), "a manifest with no architecture")
}
