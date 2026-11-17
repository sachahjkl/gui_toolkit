package tk_toolbox

import "core:fmt"
import "core:os"
import "core:strings"

// The ECMAScript test suite, at the commit QuickJS-ng 0.17.0 runs (its submodule), as a GitHub archive.
TEST262_COMMIT :: "5ef1e5723be95296f36afb0386676fed0205869c"
TEST262_SHA256 :: "d67ff29d7bcee3493f38b3ef54db068ea5ad6d5a67b67b3f505dfee581dd3879"
// QuickJS-ng's release source, unpatched: only its runner's configuration is used (which features run, which tests it
// fails). One pin for every runner of the suite, so that they judge against the same reference.
TEST262_QJS_VERSION :: "0.17.0"
TEST262_QJS_SHA256 :: "559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9"
// The files of QuickJS-ng's source that a run reads beside the suite.
TEST262_CONF_FILES :: [?]string{"test262.conf", "test262-fast.conf", "test262_errors.txt"}

// What a test262 run reads, in `dir`, each kept when it is as pinned: `dir`/test262 (the suite, stamped by its COMMIT
// file), `dir`/test262.conf, test262-fast.conf and test262_errors.txt (QuickJS-ng's). The archives and QuickJS-ng's
// source stay in `dir` between runs. Returns "" when all is there, else why not.
test262_fetch :: proc(dir: string, log := "") -> (why: string) {
	if os.make_directory_all(dir) != nil && !os.is_dir(dir) { return fmt.tprintf("%s cannot be made", dir) }
	tar := system_program("tar")
	suite := fmt.tprintf("%s/test262", dir)
	stamp := fmt.tprintf("%s/COMMIT", suite)
	known, err := os.read_entire_file(stamp, context.temp_allocator)
	if err != nil || strings.trim_space(string(known)) != TEST262_COMMIT {
		tarball := fmt.tprintf("%s/test262-%s.tar.gz", dir, TEST262_COMMIT)
		if why = download_pinned(fmt.tprintf("https://codeload.github.com/tc39/test262/tar.gz/%s", TEST262_COMMIT), tarball, TEST262_SHA256, log); why != "" { return why }
		_ = os.remove_all(suite)
		if !run({tar, "-xzf", tarball, "-C", dir}, {log = log}) { return fmt.tprintf("%s not unpacked", tarball) }
		if os.rename(fmt.tprintf("%s/test262-%s", dir, TEST262_COMMIT), suite) != nil { return "the test262 archive has not its usual folder" }
		// (written last: an unpacking cut short is fetched again)
		if os.write_entire_file(stamp, TEST262_COMMIT) != nil { return fmt.tprintf("%s cannot be written", stamp) }
	}
	source := fmt.tprintf("%s/quickjs-%s", dir, TEST262_QJS_VERSION)
	if !os.exists(fmt.tprintf("%s/run-test262.c", source)) {
		tarball := fmt.tprintf("%s/quickjs-ng-v%s.tar.gz", dir, TEST262_QJS_VERSION)
		if why = download_pinned(fmt.tprintf("https://github.com/quickjs-ng/quickjs/archive/refs/tags/v%s.tar.gz", TEST262_QJS_VERSION), tarball, TEST262_QJS_SHA256, log); why != "" { return why }
		if !run({tar, "-xzf", tarball, "-C", dir}, {log = log}) { return fmt.tprintf("%s not unpacked", tarball) }
	}
	for f in TEST262_CONF_FILES {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", source, f), context.temp_allocator)
		if rerr != nil { return fmt.tprintf("no %s in %s", f, source) }
		// (written only when it differs: two runs at once, Wren's interpreter and its JIT, read it while the other fetches)
		to := fmt.tprintf("%s/%s", dir, f)
		if have, herr := os.read_entire_file(to, context.temp_allocator); herr == nil && string(have) == string(data) { continue }
		if os.write_entire_file(to, data) != nil { return fmt.tprintf("%s cannot be written", to) }
	}
	return ""
}
