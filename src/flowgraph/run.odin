package tk_flowgraph

// A run of a graph: pure, on one thread (the interface's), tested without a window. The program starts it (run_init),
// takes the nodes that are ready (run_next), does each one's work where its kind says (a job of a worker, the interface,
// a person), and gives back how it ended (run_finish, run_cancel, run_skip). The run is over when every node is decided
// (run_over).
//
// Each node of a run is a small state machine (node_step):
//
//   Waiting -> Running   its inputs came: run_next gives it to the program
//   Waiting -> Skipped   an input it waits for will never come (dry run: an effect)
//   Running -> Done | Failed | Cancelled   its work ended so (run_finish; run_cancel: a person gave up)
//   Running -> Skipped   the program declined it (run_skip)
//
// A node waits until every node linked into it is decided. It runs when each value input has a value (one that takes
// several: at least one) and each action input that is linked has fired; else it is Skipped, and so is what waits on it.
// An action output fires when its node ends as its port says (Port_Def.on): "done" on Done, "cancelled" on Cancelled. So
// a node linked to an editor's "done" runs only when the person confirmed, and one linked to its "cancelled" only when
// they gave up. An action input left unlinked asks for nothing.
//
// Values are shared, read only: fan-out gives each branch the same value; a node that changes it makes a new one. A
// value's payload is counted (value_hold, value_release): the last release frees it with the program's procedure. A
// transient kind's value (Kind_Def.transient) is let go as soon as every node that reads it is decided.

import "core:strings"
import "core:sync"

Node_State :: enum u8 { Waiting, Running, Done, Failed, Skipped, Cancelled }

NODE_STATE_DECIDED :: bit_set[Node_State]{.Done, .Failed, .Skipped, .Cancelled}

// What happens to a node of a run.
Node_Event :: enum u8 {
	Start,       // its inputs came: it is given to the program
	Skip,        // it will not run
	Finished,    // its work is done
	Failed,      // its work failed
	Cancelled,   // its work was given up (a person closed the editor)
}

// The state after `e` in `s`. ok false: `e` means nothing in `s` (a late result), and `s` stays.
node_step :: proc(s: Node_State, e: Node_Event) -> (next: Node_State, ok: bool) {
	#partial switch s {
	case .Waiting:
		#partial switch e {
		case .Start: return .Running, true
		case .Skip:  return .Skipped, true
		}
	case .Running:
		#partial switch e {
		case .Finished:  return .Done, true
		case .Failed:    return .Failed, true
		case .Cancelled: return .Cancelled, true
		case .Skip:      return .Skipped, true
		}
	}
	return s, false
}

////////////////////////////////
// Values

// A program's data (a picture, a text), shared by the values that hold it. `refs` is atomic: a job on a worker may
// release its hold there; `free` must then be safe on that thread.
Payload :: struct {
	data: rawptr,
	free: proc(data: rawptr),
	refs: i32,
}

// What flows on a link: a kind and a counted payload (nil: none).
Value :: struct {
	kind:    Port_Kind,
	payload: ^Payload,
}

// A value of `kind` holding `data` (one reference, the caller's); `free` frees `data` at the last release (nil: nothing).
value_make :: proc(kind: Port_Kind, data: rawptr, free_data: proc(data: rawptr)) -> Value {
	p := new(Payload)
	p^ = {data = data, free = free_data, refs = 1}
	return {kind = kind, payload = p}
}

// Another reference to `v`'s payload, the caller's to release.
value_hold :: proc(v: Value) -> Value {
	if v.payload != nil { sync.atomic_add(&v.payload.refs, 1) }
	return v
}

// The caller's reference given back; the last one frees the payload.
value_release :: proc(v: ^Value) {
	p := v.payload
	v.payload = nil
	if p == nil { return }
	if sync.atomic_sub(&p.refs, 1) > 1 { return }
	if p.free != nil { p.free(p.data) }
	free(p)
}

// The payload's data as a `^T` (nil: none).
value_data :: proc(v: Value, $T: typeid) -> ^T {
	return v.payload != nil ? (^T)(v.payload.data) : nil
}

////////////////////////////////
// A run

Output :: struct {
	value: Value,
	made:  bool,   // the node gave it (a branch gives one of its outputs); stays when a transient value is let go
}

Run_Node :: struct {
	state:   Node_State,
	outputs: [PORTS_MAX]Output,
	message: string,   // why it failed, was cancelled or skipped (owned)
}

Run_Options :: struct {
	id:  u64,    // the program's (a run among others)
	dry: bool,   // the effects are off: a node whose kind is an effect is Skipped (a preview)
}

Run :: struct {
	id:      u64,
	dry:     bool,
	graph:   Graph,       // a copy (owned): the person may change the graph while it runs
	catalog: ^Catalog,
	nodes:   []Run_Node,  // in the order of graph.nodes
}

// A value that comes into a node: its input port, and the value (the run's: run_finish may let it go; value_hold what a
// job keeps).
Input :: struct {
	port:  u32,
	value: Value,
}

// A node ready to run. `inputs`: its values, by port then link order (temp allocator).
Task :: struct {
	node:   int,      // its place in Run.nodes
	id:     u64,
	kind:   int,
	inputs: []Input,
}

// How a node's work ended (taken by run_finish).
Result :: struct {
	outcome: Outcome,
	message: string,               // why it failed (copied)
	outputs: [PORTS_MAX]Value,     // Done: each value output's value, by port (payload nil: not made); taken
}

// A run of `g` (copied) against `cat` (kept: it must outlive the run), made in `run`. Every node waits.
run_init :: proc(run: ^Run, g: Graph, cat: ^Catalog, o: Run_Options = {}) {
	run^ = {id = o.id, dry = o.dry, catalog = cat}
	run.graph = graph_clone(g)
	run.nodes = make([]Run_Node, len(run.graph.nodes))
}

run_destroy :: proc(run: ^Run) {
	for &rn in run.nodes {
		for &o in rn.outputs { value_release(&o.value) }
		delete(rn.message)
	}
	delete(run.nodes)
	graph_destroy(&run.graph)
	run^ = {}
}

// The nodes that became ready, now Running: the program does each one and ends it (run_finish, run_cancel, run_skip).
// What the run decides itself (a skip) is done here, until nothing more changes. Temp allocator.
run_next :: proc(run: ^Run) -> []Task {
	tasks := make([dynamic]Task, 0, 4, context.temp_allocator)
	for changed := true; changed; {
		changed = false
		for &rn, i in run.nodes {
			if rn.state != .Waiting { continue }
			n := &run.graph.nodes[i]
			inputs, readiness := run_inputs(run, i)
			switch readiness {
			case .Pending:
				continue
			case .Missing:
				run_set(run, i, .Skip, "nothing comes in")
				changed = true
			case .Ready:
				def := node_def(run.catalog, n)
				if run.dry && def != nil && def.effect {
					run_set(run, i, .Skip, "off in a dry run")
					changed = true
					continue
				}
				run_set(run, i, .Start, "")
				append(&tasks, Task{node = i, id = n.id, kind = n.kind, inputs = inputs})
			}
		}
	}
	return tasks[:]
}

// How node `node` ended. False: it was not running (a late result: `r`'s values are released).
run_finish :: proc(run: ^Run, node: int, r: Result) -> bool {
	r := r
	if node < 0 || node >= len(run.nodes) || run.nodes[node].state != .Running {
		for &v in r.outputs { value_release(&v) }
		return false
	}
	rn := &run.nodes[node]
	switch r.outcome {
	case .Done:
		def := node_def(run.catalog, &run.graph.nodes[node])
		for &v, port in r.outputs {
			// (an action output is the run's to fire; a port the kind lacks takes nothing)
			if def == nil || port >= len(def.outputs) || def.outputs[port].kind == ACTION || v.payload == nil {
				value_release(&v)
				continue
			}
			if v.kind == ACTION { v.kind = def.outputs[port].kind }
			rn.outputs[port] = {value = v, made = true}
		}
		run_set(run, node, .Finished, "")
	case .Failed:
		for &v in r.outputs { value_release(&v) }
		run_set(run, node, .Failed, r.message)
	case .Cancelled:
		for &v in r.outputs { value_release(&v) }
		run_set(run, node, .Cancelled, r.message)
	}
	run_let_go(run)
	return true
}

// The work of node `node` was given up (a person closed the editor): it is Cancelled; its "cancelled" actions fire, and
// what needs its values or its "done" is Skipped.
run_cancel :: proc(run: ^Run, node: int, message: string) -> bool {
	return run_finish(run, node, {outcome = .Cancelled, message = message})
}

// The program declines node `node`, which run_next gave it: it is Skipped, and what needs it too.
run_skip :: proc(run: ^Run, node: int, message: string) -> bool {
	if node < 0 || node >= len(run.nodes) || run.nodes[node].state != .Running { return false }
	run_set(run, node, .Skip, message)
	run_let_go(run)
	return true
}

// Every node is decided: nothing runs, nothing waits.
run_over :: proc(run: ^Run) -> bool {
	for rn in run.nodes { if rn.state not_in NODE_STATE_DECIDED { return false } }
	return true
}

// Whether a node's work is under way (a worker's job, a person).
run_busy :: proc(run: ^Run) -> bool {
	for rn in run.nodes { if rn.state == .Running { return true } }
	return false
}

// The first value that came into input `port` of `t` (ok false: none).
task_input :: proc(t: Task, port: u32) -> (v: Value, ok: bool) {
	for in_ in t.inputs { if in_.port == port { return in_.value, true } }
	return {}, false
}

// Whether action output `port` of node `node` fired: its node ended as the port says.
action_fired :: proc(run: ^Run, node: int, port: u32) -> bool {
	def := node_def(run.catalog, &run.graph.nodes[node])
	if def == nil || int(port) >= len(def.outputs) || def.outputs[port].kind != ACTION { return false }
	#partial switch run.nodes[node].state {
	case .Done:      return def.outputs[port].on == .Done
	case .Failed:    return def.outputs[port].on == .Failed
	case .Cancelled: return def.outputs[port].on == .Cancelled
	}
	return false
}

////////////////////////////////
// Inside a run

@(private = "file")
Readiness :: enum u8 { Pending, Ready, Missing }

// The values that come into node `i`, and whether it can run: Pending while a node linked into it is not decided;
// Missing when a value input has no value, or a linked action input did not fire.
@(private = "file")
run_inputs :: proc(run: ^Run, i: int) -> (values: []Input, readiness: Readiness) {
	n := &run.graph.nodes[i]
	def := node_def(run.catalog, n)
	if def == nil { return nil, .Missing }
	out := make([dynamic]Input, 0, 2, context.temp_allocator)
	missing := false
	for p, port in def.inputs {
		linked, got := 0, 0
		for l in run.graph.links {
			if l.to_node != n.id || l.to_port != u32(port) { continue }
			from := graph_node_index(&run.graph, l.from_node)
			if from < 0 { continue }
			linked += 1
			src := &run.nodes[from]
			if src.state not_in NODE_STATE_DECIDED { return nil, .Pending }
			if p.kind == ACTION {
				if action_fired(run, from, l.from_port) { got += 1 }
			} else if src.state == .Done && int(l.from_port) < PORTS_MAX && src.outputs[l.from_port].made {
				append(&out, Input{port = u32(port), value = src.outputs[l.from_port].value})
				got += 1
			}
		}
		// (an unlinked action input asks for nothing; a value input always needs one)
		if got == 0 && (p.kind != ACTION || linked > 0) { missing = true }
	}
	if missing { return nil, .Missing }
	return out[:], .Ready
}

@(private = "file")
run_set :: proc(run: ^Run, i: int, e: Node_Event, message: string) {
	rn := &run.nodes[i]
	next, ok := node_step(rn.state, e)
	if !ok { return }
	rn.state = next
	if message != "" {
		delete(rn.message)
		rn.message = strings.clone(message)
	}
}

// The transient values no node will read any more are let go: an output whose readers are all decided.
@(private = "file")
run_let_go :: proc(run: ^Run) {
	for &rn, i in run.nodes {
		if rn.state != .Done { continue }
		n := &run.graph.nodes[i]
		def := node_def(run.catalog, n)
		if def == nil { continue }
		for port in 0 ..< min(len(def.outputs), PORTS_MAX) {
			o := &rn.outputs[port]
			if o.value.payload == nil { continue }
			kind := def.outputs[port].kind
			if int(kind) >= len(run.catalog.kinds) || !run.catalog.kinds[kind].transient { continue }
			needed := false
			for l in run.graph.links {
				if l.from_node != n.id || int(l.from_port) != port { continue }
				to := graph_node_index(&run.graph, l.to_node)
				if to >= 0 && run.nodes[to].state not_in NODE_STATE_DECIDED { needed = true }
			}
			if !needed { value_release(&o.value) }
		}
	}
}
