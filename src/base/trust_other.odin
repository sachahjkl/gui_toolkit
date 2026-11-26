#+build !windows
#+build !linux
package gt_base

// No process of another account here to be careful of (wasm, macOS for now): nothing is elevated, every start is the
// user's own.
@(private)
elevation_query :: proc() -> bool { return false }

trusted_program :: proc(program: string) -> bool { return true }

dll_search_restrict :: proc() {}
