#+build !windows
package tk_toolbox

// cwebp as the system gives it (nix libwebp, Debian webp): on the path. `dir` is Windows'.
webp_encoder :: proc(dir: string) -> (encoder, why: string) { return "cwebp", "" }
