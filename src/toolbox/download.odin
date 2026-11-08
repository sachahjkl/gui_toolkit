package tk_toolbox

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// How often and how far apart curl tries a failed download again (--retry, --retry-delay in seconds): GitHub's release downloads
// answer 503 and 504 at times, and the SHA-256 says whether what came is the file.
DOWNLOAD_RETRIES :: "5"
DOWNLOAD_RETRY_DELAY_S :: "10"

// `path` as pinned: kept when its SHA-256 is `sha256`, else downloaded from `url` (curl, with retries; a file of a GitHub release
// through GitHub's API when its download fails) and checked. A file that does not match is removed. `log`: where curl's output
// and the lines said go ("": this process's output); `quiet`: no line but curl's errors. Returns "" when the file is there and
// as pinned, else why not.
download_pinned :: proc(url, path, sha256: string, log := "", quiet := false) -> (why: string) {
	if got, ok := sha256_file(path); ok && got == sha256 { return "" }
	if dir := filepath.dir(path); dir != "" && !os.is_dir(dir) { _ = os.make_directory_all(dir) }
	if !quiet { say(log, fmt.tprintfln("downloading %s", url)) }
	curl := system_program("curl")
	fetched := run({curl, "-fsSL", "--retry", DOWNLOAD_RETRIES, "--retry-delay", DOWNLOAD_RETRY_DELAY_S, "--retry-all-errors", "-o", path, url}, {log = log})
	if !fetched { fetched = download_through_api(url, path, log, quiet) }
	if !fetched {
		_ = os.remove(path)
		return fmt.tprintf("downloading %s failed", url)
	}
	got, _ := sha256_file(path)
	if got != sha256 {
		_ = os.remove(path)
		return fmt.tprintf("%s: SHA-256 mismatch (%s, expected %s)", filepath.base(path), got, sha256)
	}
	return ""
}

// A file of a GitHub release (https://github.com/<owner>/<repo>/releases/download/<tag>/<name>) through GitHub's API: its release
// downloads answered 504 for over an hour while the API served the same files. GH_TOKEN or GITHUB_TOKEN, when set, is sent (a
// CI's: more requests allowed). False: not such a file, or the API did not give it either. (The caller checks the SHA-256.)
download_through_api :: proc(url, path: string, log := "", quiet := false) -> bool {
	PREFIX :: "https://github.com/"
	if !strings.has_prefix(url, PREFIX) { return false }
	parts := strings.split(url[len(PREFIX):], "/", context.temp_allocator)
	if len(parts) != 6 || parts[2] != "releases" || parts[3] != "download" { return false }
	owner, repo, tag, name := parts[0], parts[1], parts[4], parts[5]
	curl := system_program("curl")
	token := os.get_env("GH_TOKEN", context.temp_allocator)
	if token == "" { token = os.get_env("GITHUB_TOKEN", context.temp_allocator) }
	if !quiet { say(log, fmt.tprintfln("the release download failed: %s through GitHub's API", name)) }

	ask := make([dynamic]string, context.temp_allocator)
	append(&ask, curl, "-fsSL", "--retry", DOWNLOAD_RETRIES, "--retry-delay", DOWNLOAD_RETRY_DELAY_S, "--retry-all-errors")
	if token != "" { append(&ask, "-H", fmt.tprintf("Authorization: Bearer %s", token)) }
	release := slice_with(ask[:], fmt.tprintf("https://api.github.com/repos/%s/%s/releases/tags/%s", owner, repo, tag))
	answer, code := capture(release)
	if code != 0 { return false }
	id := release_asset_id(answer, name)
	if id == "" { return false }
	asset := slice_with(ask[:], "-H", "Accept: application/octet-stream", "-o", path, fmt.tprintf("https://api.github.com/repos/%s/%s/releases/assets/%s", owner, repo, id))
	return run(asset, {log = log})
}

// The id of the asset named `name` in a release as GitHub's API says it ("": none).
release_asset_id :: proc(release_json, name: string) -> string {
	v, err := json.parse_string(release_json, allocator = context.temp_allocator)
	if err != nil { return "" }
	root, _ := v.(json.Object)
	assets, _ := root["assets"].(json.Array)
	for a in assets {
		o, _ := a.(json.Object)
		if n, _ := o["name"].(json.String); n != name { continue }
		#partial switch id in o["id"] {
		case json.Integer: return fmt.tprintf("%d", id)
		case json.Float:   return fmt.tprintf("%d", i64(id))
		}
	}
	return ""
}

@(private)
slice_with :: proc(head: []string, tail: ..string) -> []string {
	out := make([dynamic]string, 0, len(head) + len(tail), context.temp_allocator)
	append(&out, ..head)
	append(&out, ..tail)
	return out[:]
}
