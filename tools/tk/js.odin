// gt:js's own automation: its Unicode tables from the pinned character database, and test262 on the native judge.
package tk

import "core:fmt"
import "core:os"
import toolbox "../../src/toolbox"

// The Unicode release of gt:js's tables: QuickJS-ng 0.17's, so that the identifier, case and property data agree with
// the reference engine the judges compare against.
JS_UNICODE_VERSION :: "17.0.0"
JS_UNICODE_BASE :: "https://www.unicode.org/Public/" + JS_UNICODE_VERSION
JS_UNICODE_CACHE :: "build/ucd/" + JS_UNICODE_VERSION
JS_UNICODE_TABLES :: "src/js/unicode/tables_generated.odin"

// A file of the Character Database: where it is under the release's folder, where it is cached, its pinned SHA-256.
// The tables are made from the authoritative source, never copied from QuickJS's libunicode-table.h. Wren's IDNA
// tables read the joining types and Bidi classes from the same cache: they are pinned here, with the rest.
Js_Ucd_File :: struct { url, cached, sha256: string }
@(rodata) JS_UCD_FILES := [?]Js_Ucd_File{
	{"ucd/UnicodeData.txt", "UnicodeData.txt", "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"},
	{"ucd/DerivedCoreProperties.txt", "DerivedCoreProperties.txt", "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08"},
	{"ucd/PropList.txt", "PropList.txt", "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd"},
	{"ucd/Scripts.txt", "Scripts.txt", "9f5e50d3abaee7d6ce09480f325c706f485ae3240912527e651954d2d6b035bf"},
	{"ucd/ScriptExtensions.txt", "ScriptExtensions.txt", "ec2107e58825a1586acee8e0911ce18260394ac8b87e535ca325f1ccbeb06bc6"},
	{"ucd/CaseFolding.txt", "CaseFolding.txt", "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"},
	{"ucd/SpecialCasing.txt", "SpecialCasing.txt", "efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588"},
	{"ucd/DerivedNormalizationProps.txt", "DerivedNormalizationProps.txt", "71fd6a206a2c0cdd41feb6b7f656aa31091db45e9cedc926985d718397f9e488"},
	{"ucd/extracted/DerivedGeneralCategory.txt", "extracted/DerivedGeneralCategory.txt", "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e"},
	{"ucd/extracted/DerivedJoiningType.txt", "extracted/DerivedJoiningType.txt", "f39ebe974825d6736aee15582250307aa532b2cfab3caf3f86bd23fddc9c5c4d"},
	{"ucd/extracted/DerivedBidiClass.txt", "extracted/DerivedBidiClass.txt", "4867b4b7f0731ed1bfcd34cc6251211ff1542541fce0734b6fbda139ee80b3a4"},
	{"ucd/emoji/emoji-data.txt", "emoji/emoji-data.txt", "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b"},
	{"emoji/emoji-sequences.txt", "emoji-seq/emoji-sequences.txt", "12cc8267dc33cbd11ed32bcf6fc5dc2ad9c7a77bae1bdfba2f41b1b9b3ead8dd"},
	{"emoji/emoji-zwj-sequences.txt", "emoji-seq/emoji-zwj-sequences.txt", "5b25441daed2322b068c5e70cda522946a4f0274df864445a1965a92e5fc5cad"},
}

// The judge's main stack: the engine may use 48 MiB of it (tools/js_judge, JUDGE_STACK_BYTES). The link flags and the
// raise of the limit are each system's (js_stack_*.odin).
JS_JUDGE_STACK_BYTES :: 64 << 20
// test262 is fetched into JS_TEST262_DIR/run (the judge's default -dir) and its results written to JS_TEST262_DIR.
JS_TEST262_DIR :: "build/test262"

// gen_js_unicode [-force]: the pinned UCD files (each kept when its SHA-256 holds; -force: downloaded again), then
// tools/js_unicode_gen -> src/js/unicode/tables_generated.odin. The tables are committed: a build needs no network.
run_gen_js_unicode :: proc(args: []string) -> string {
	root := toolkit_root()
	cache := join({root, JS_UNICODE_CACHE})
	for u in JS_UCD_FILES {
		path := join({cache, u.cached})
		if toolbox.has_flag(args, "force") { _ = os.remove(path) }
		if why := toolbox.download_pinned(fmt.tprintf("%s/%s", JS_UNICODE_BASE, u.url), path, u.sha256); why != "" { return why }
	}
	// (the generator stamps the release into the tables and into the unicode.version preference)
	if os.write_entire_file(join({cache, "VERSION"}), JS_UNICODE_VERSION) != nil { return fmt.tprintf("%s/VERSION cannot be written", cache) }
	generator := join({root, "build", fmt.tprintf("js_unicode_gen%s", EXE)})
	if !toolbox.run({"odin", "build", join({root, "tools", "js_unicode_gen"}), fmt.tprintf("-out:%s", generator), "-o:speed"}) { return "building tools/js_unicode_gen failed" }
	tables := join({root, JS_UNICODE_TABLES})
	if !toolbox.run({generator, cache, tables}) { return "tools/js_unicode_gen failed" }
	fmt.printfln("wrote %s", tables)
	return ""
}

// js_test262 [-filter:t] [-stride:k] [-jobs:n]: test262 on gt:js, natively. The suite and QuickJS-ng's configuration
// (toolbox.test262_fetch), tools/js_judge built with a 64 MiB main stack, then its test262 command, with the rules of
// QuickJS-ng's test262.conf. Results: build/test262/jsrt_errors.txt and jsrt_table.md.
run_js_test262 :: proc(args: []string) -> string {
	root := toolkit_root()
	out := join({root, JS_TEST262_DIR})
	run_dir := join({out, "run"})
	if why := toolbox.test262_fetch(run_dir); why != "" { return fmt.tprintf("test262: %s", why) }
	judge := join({root, "build", fmt.tprintf("js_judge%s", EXE)})
	build := make([dynamic]string, context.temp_allocator)
	append(&build, "odin", "build", join({root, "tools", "js_judge"}), fmt.tprintf("-out:%s", judge), "-o:speed", gt_collection(root))
	append(&build, ..JS_JUDGE_LINK_FLAGS)
	if !toolbox.run(build[:]) { return "building tools/js_judge failed" }
	js_judge_stack_raise()
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, judge, "test262", "-dir", run_dir, "-out", out, "-stride", toolbox.flag_value(args, "stride", "1"))
	if filter := toolbox.flag_value(args, "filter"); filter != "" { append(&cmd, "-filter", filter) }
	if jobs := toolbox.flag_value(args, "jobs"); jobs != "" { append(&cmd, "-j", jobs) }
	// (the judge reports and exits 0 whatever failed: the failures are in jsrt_errors.txt, to compare with a former run)
	if !toolbox.run(cmd[:], {dir = root}) { return "tools/js_judge test262 failed" }
	return ""
}
