#+build !linux
#+build !windows
package process_start_test

import "core:os"

// (elsewhere the start is os.process_start's, which passes on what is inheritable: not tested)
@(private)
make_inheritable :: proc(f: ^os.File) -> bool { return false }
