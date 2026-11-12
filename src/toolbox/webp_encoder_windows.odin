package tk_toolbox

import "core:fmt"
import "core:os"

// libwebp's own build for Windows, pinned: Windows gives no cwebp.
@(private = "file") WEBP_VERSION :: "1.6.0"
@(private = "file") WEBP_URL     :: "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-" + WEBP_VERSION + "-windows-x64.zip"
@(private = "file") WEBP_SHA256  :: "48886f506b21f62e4661f0f4cbfca19800897c385128e8902542d29a950c93f1"

// cwebp.exe, fetched into `dir` (a project's build folder) the first time and checked by its SHA-256.
webp_encoder :: proc(dir: string) -> (encoder, why: string) {
	zip := fmt.tprintf("%s/libwebp-%s-windows-x64.zip", dir, WEBP_VERSION)
	encoder = fmt.tprintf("%s/libwebp-%s-windows-x64/bin/cwebp.exe", dir, WEBP_VERSION)
	if os.exists(encoder) { return encoder, "" }
	if why = download_pinned(WEBP_URL, zip, WEBP_SHA256, quiet = true); why != "" { return "", why }
	if !run({system_program("tar"), "-xf", zip, "-C", dir}) { return "", fmt.tprintf("%s not unpacked", zip) }
	return encoder, ""
}
