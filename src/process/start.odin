package tk_process

// Children: one started (start), one run to its end with its output (run), a pipe for a child (pipe). Starting a
// process is not safe from two threads at once. Linux's fork copies the memory while another thread can hold a lock the
// child then needs. Windows' CreateProcess gives the child every inheritable handle of the process, a pipe end made for
// another child too, and that child's reader then never sees its end. So every start holds one lock of the package, and
// only around the spawn: a child that runs for minutes never holds up another start. The intent:
// src/md/features/child-processes.md.

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import base "../base"

@(private = "file") start_lock: sync.Mutex

// What run gives a child besides its command.
Run_Options :: struct {
	dir:   string,     // its working folder ("": this process's)
	env:   []string,   // its whole environment, "NAME=value" (nil: this process's)
	input: string,     // written to its standard input, which then closes ("": an empty input)
}

// What a child said and how it ended.
Ran :: struct {
	started: bool,    // it started (false: stderr says why)
	ok:     bool,     // it started and exited with 0
	code:   int,      // its exit code; -1 when it did not start or did not exit
	stdout: string,   // what it wrote on its standard output
	stderr: string,   // what it wrote on its standard error; when it did not start, why
}

// Starts a child, the lock held around the spawn only. The ends of desc.stdin, stdout and stderr are inherited by this
// child alone (Windows: they are inheritable during the spawn, then as they were). A blocking call: never on the
// interface's thread.
start :: proc(desc: os.Process_Desc, loc := #caller_location) -> (p: os.Process, err: os.Error) {
	base.blocking("process.start", loc)
	ends := [3]^os.File{desc.stdin, desc.stdout, desc.stderr}
	sync.lock(&start_lock)
	defer sync.unlock(&start_lock)
	before := ends_inherit(ends)
	p, err = os.process_start(desc)
	ends_restore(ends, before)
	return
}

// A pipe whose two ends no child inherits until start gives one of them to a child (os.pipe's are inheritable on
// Windows: any child started meanwhile took them). Made under the start's lock, so no start sees it half made.
pipe :: proc() -> (r, w: ^os.File, err: os.Error) {
	sync.lock(&start_lock)
	defer sync.unlock(&start_lock)
	r, w, err = os.pipe()
	if err != nil { return }
	not_inherited(r)
	not_inherited(w)
	return
}

// Runs `command` and waits for its end: its output in `allocator`, its exit code. Its standard output and error are read
// at once, each on its own (a child that fills one never waits for the other to be read), and `o.input` is written on a
// thread of its own (a child may answer before it reads all of it). A blocking call: never on the interface's thread.
run :: proc(command: []string, o := Run_Options{}, allocator := context.allocator, loc := #caller_location) -> (r: Ran) {
	base.blocking("process.run", loc)
	r.code = -1
	if len(command) == 0 {
		r.stderr = fmt.aprint("no command", allocator = allocator)
		return
	}
	out_r, out_w, e1 := pipe()
	if e1 != nil {
		r.stderr = fmt.aprintf("%s cannot start: no pipe (%v)", command[0], e1, allocator = allocator)
		return
	}
	err_r, err_w, e2 := pipe()
	if e2 != nil {
		os.close(out_r); os.close(out_w)
		r.stderr = fmt.aprintf("%s cannot start: no pipe (%v)", command[0], e2, allocator = allocator)
		return
	}
	in_r, in_w: ^os.File
	if o.input != "" {
		e3: os.Error
		in_r, in_w, e3 = pipe()
		if e3 != nil {
			os.close(out_r); os.close(out_w); os.close(err_r); os.close(err_w)
			r.stderr = fmt.aprintf("%s cannot start: no pipe (%v)", command[0], e3, allocator = allocator)
			return
		}
		// (a child that ends before it read its input: the write fails, the process goes on)
		broken_pipe_ignore()
	}
	child, serr := start({command = command, working_dir = o.dir, env = o.env, stdin = in_r, stdout = out_w, stderr = err_w})
	// (the child's ends are the child's: this process sees the end of its output when the child's ends go)
	if in_r != nil { os.close(in_r) }
	os.close(out_w)
	os.close(err_w)
	if serr != nil {
		if in_w != nil { os.close(in_w) }
		os.close(out_r); os.close(err_r)
		r.stderr = fmt.aprintf("%s cannot start: %v", command[0], serr, allocator = allocator)
		return
	}

	r.started = true
	Input :: struct { file: ^os.File, text: string }
	writer: ^thread.Thread
	if in_w != nil {
		writer = thread.create_and_start_with_poly_data(Input{in_w, o.input}, proc(i: Input) {
			_, _ = os.write_string(i.file, i.text)
			os.close(i.file)
		})
		if writer == nil {
			_, _ = os.write_string(in_w, o.input)   // (no thread to be had: a child that reads all of it first still works)
			os.close(in_w)
		}
	}
	Errors :: struct { file: ^os.File, bytes: [dynamic]u8 }
	errors := new(Errors)
	errors^ = {file = err_r}
	reader := thread.create_and_start_with_poly_data(errors, proc(e: ^Errors) { read_to_end(e.file, &e.bytes) })
	out := make([dynamic]u8, allocator)
	read_to_end(out_r, &out)
	if reader == nil {
		read_to_end(err_r, &errors.bytes)
	} else {
		thread.join(reader)
		thread.destroy(reader)
	}
	if writer != nil { thread.join(writer); thread.destroy(writer) }
	os.close(out_r)
	os.close(err_r)
	r.stdout = string(out[:])
	r.stderr = string(clone_bytes(errors.bytes[:], allocator))
	delete(errors.bytes)
	free(errors)

	state, werr := os.process_wait(child)
	if werr == nil && state.exited { r.code = state.exit_code }
	r.ok = werr == nil && state.exited && state.exit_code == 0
	return
}

// Frees what run gave.
ran_destroy :: proc(r: ^Ran, allocator := context.allocator) {
	delete(r.stdout, allocator)
	delete(r.stderr, allocator)
	r^ = {}
}

@(private = "file")
read_to_end :: proc(f: ^os.File, into: ^[dynamic]u8) {
	buf: [4096]u8
	for {
		n, err := os.read(f, buf[:])
		if n > 0 { append(into, ..buf[:n]) }
		if err != nil || n <= 0 { return }
	}
}

@(private = "file")
clone_bytes :: proc(b: []u8, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}
