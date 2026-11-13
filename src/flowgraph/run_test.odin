package tk_flowgraph

import "core:slice"
import "core:testing"

@(test)
nodes_run_in_the_order_of_their_links :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Resize, .Save}, {{0, 1}, {1, 2}})
	defer graph_free(&g)
	run: Run
	start_with_capture(&run, g, 4, 4)
	defer run_free(&run)
	testing.expect_value(t, run.nodes[0].state, Node_State.Done)

	tasks := run_next(&run)
	testing.expect_value(t, len(tasks), 1)
	testing.expect_value(t, Sample(tasks[0].kind), Sample.Resize)
	testing.expect_value(t, run.nodes[1].state, Node_State.Running)
	testing.expect_value(t, run.nodes[2].state, Node_State.Waiting)
	testing.expect(t, done_with(&run, 1, pic_value(2, 2)))

	tasks = run_next(&run)
	testing.expect_value(t, len(tasks), 1)
	testing.expect_value(t, Sample(tasks[0].kind), Sample.Save)
	v, has := task_input(tasks[0], 0)
	testing.expect(t, has)
	testing.expect_value(t, value_data(v, Pic).size, [2]int{2, 2})
	// (the Capture's picture is read by none now: a transient value, it is let go; that it was made stays)
	testing.expect(t, run.nodes[0].outputs[0].value.payload == nil)
	testing.expect(t, run.nodes[0].outputs[0].made)
	testing.expect(t, !run_over(&run))
	testing.expect(t, run_busy(&run))
	testing.expect(t, done_with(&run, 2, text_value(FILE, "/tmp/a.png")))
	testing.expect_value(t, len(run_next(&run)), 0)
	testing.expect(t, run_over(&run))
	testing.expect(t, !run_busy(&run))
	// (a file is no transient kind: the program reads it after the run)
	testing.expect_value(t, value_data(run.nodes[2].outputs[0].value, string)^, "/tmp/a.png")
}

@(test)
fan_out_gives_each_branch_the_same_value :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Copy_Image, .Save, .Blur}, {{0, 1}, {0, 2}, {0, 3}})
	defer graph_free(&g)
	run: Run
	start_with_capture(&run, g, 3, 3)
	defer run_free(&run)
	tasks := run_next(&run)
	testing.expect_value(t, len(tasks), 3)
	for task in tasks { testing.expect(t, task.inputs[0].value.payload == run.nodes[0].outputs[0].value.payload) }
	// (one reference: the Capture's output; the branches read it, none holds a copy)
	testing.expect_value(t, run.nodes[0].outputs[0].value.payload.refs, 1)
}

// A branch is the program's work like any node's: it gives its value on one output, and what hangs on the other is
// Skipped.
@(test)
a_branch_sends_the_value_one_way :: proc(t: ^testing.T) {
	g: Graph
	defer graph_free(&g)
	cat := &SAMPLE
	capture := node_add(&g, cat, int(Sample.Capture), {})
	branch := node_add(&g, cat, int(Sample.Branch), {})
	yes := node_add(&g, cat, int(Sample.Copy_Image), {})
	no := node_add(&g, cat, int(Sample.Save), {})
	after_no := node_add(&g, cat, int(Sample.Reveal), {})
	link(&g, cat, {capture, 0, branch, 0})
	link(&g, cat, {branch, 0, yes, 0})
	link(&g, cat, {branch, 1, no, 0})
	link(&g, cat, {no, 0, after_no, 0})

	decide :: proc(run: ^Run) {
		for task in run_next(run) {
			if Sample(task.kind) != .Branch { continue }
			v, _ := task_input(task, 0)
			wider := value_data(v, Pic).size.x > param_int(run.catalog, &run.graph.nodes[task.node], "width")
			r := Result{outcome = .Done}
			r.outputs[wider ? 0 : 1] = value_hold(v)
			run_finish(run, task.node, r)
		}
	}
	{
		run: Run
		start_with_capture(&run, g, 200, 10)
		defer run_free(&run)
		decide(&run)
		testing.expect(t, slice.equal(task_ids(run_next(&run)), []u64{yes}))
		testing.expect_value(t, run.nodes[1].state, Node_State.Done)
		testing.expect_value(t, run.nodes[3].state, Node_State.Skipped)
		testing.expect_value(t, run.nodes[4].state, Node_State.Skipped)
	}
	{
		run: Run
		start_with_capture(&run, g, 50, 10)
		defer run_free(&run)
		decide(&run)
		testing.expect(t, slice.equal(task_ids(run_next(&run)), []u64{no}))
		testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
	}
}

@(test)
a_failure_skips_what_follows_it :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Resize, .Save, .Reveal, .Copy_Image}, {{0, 1}, {1, 2}, {2, 3}, {0, 4}})
	defer graph_free(&g)
	run: Run
	start_with_capture(&run, g, 4, 4)
	defer run_free(&run)
	testing.expect_value(t, len(run_next(&run)), 2)   // (Resize and Copy image)
	testing.expect(t, run_finish(&run, 1, {outcome = .Failed, message = "too small"}))
	testing.expect_value(t, len(run_next(&run)), 0)
	testing.expect_value(t, run.nodes[1].state, Node_State.Failed)
	testing.expect_value(t, run.nodes[1].message, "too small")
	testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
	testing.expect_value(t, run.nodes[3].state, Node_State.Skipped)
	// (the other branch goes on)
	testing.expect_value(t, run.nodes[4].state, Node_State.Running)
	testing.expect(t, !run_over(&run))
	testing.expect(t, run_finish(&run, 4, {outcome = .Done}))
	testing.expect(t, run_over(&run))
	// (a late result is refused, and its values released)
	testing.expect(t, !done_with(&run, 1, pic_value(1, 1)))
}

// The conditions between nodes: Save waits for the editor's "done" and saves the captured picture only then; Notify
// waits for its "cancelled". Done: Save runs, Notify is Skipped. Cancel: Save is Skipped, Notify runs.
@(test)
a_condition_waits_for_the_editor :: proc(t: ^testing.T) {
	g: Graph
	defer graph_free(&g)
	cat := &SAMPLE
	capture := node_add(&g, cat, int(Sample.Capture), {})
	editor := node_add(&g, cat, int(Sample.Editor), {})
	save := node_add(&g, cat, int(Sample.Save), {})
	notify := node_add(&g, cat, int(Sample.Notify), {})
	_, ok := link(&g, cat, {capture, 0, editor, 0})
	testing.expect(t, ok)
	_, ok = link(&g, cat, {capture, 0, save, 0})
	testing.expect(t, ok)
	_, ok = link(&g, cat, {editor, 1, save, 1})     // done -> when
	testing.expect(t, ok)
	_, ok = link(&g, cat, {editor, 2, notify, 1})   // cancelled -> when
	testing.expect(t, ok)
	_, ok = link(&g, cat, {capture, 0, notify, 0})
	testing.expect(t, ok)
	{
		run: Run
		start_with_capture(&run, g, 4, 4)
		defer run_free(&run)
		// (Save has its picture, but waits for the editor)
		testing.expect(t, slice.equal(task_ids(run_next(&run)), []u64{editor}))
		testing.expect_value(t, run.nodes[2].state, Node_State.Waiting)
		testing.expect(t, done_with(&run, 1, pic_value(5, 5)))
		tasks := run_next(&run)
		testing.expect(t, slice.equal(task_ids(tasks), []u64{save}))
		v, _ := task_input(tasks[0], 0)
		testing.expect_value(t, value_data(v, Pic).size, [2]int{4, 4})   // (the captured picture: its input is the Capture's)
		testing.expect_value(t, len(tasks[0].inputs), 1)                   // (an action brings no value)
		testing.expect_value(t, run.nodes[3].state, Node_State.Skipped)
		testing.expect(t, done_with(&run, 2, text_value(FILE, "/tmp/a.png")))
		testing.expect(t, run_over(&run))
	}
	{
		run: Run
		start_with_capture(&run, g, 4, 4)
		defer run_free(&run)
		_ = run_next(&run)
		testing.expect(t, run_cancel(&run, 1, "closed without Done"))
		testing.expect_value(t, run.nodes[1].state, Node_State.Cancelled)
		testing.expect_value(t, run.nodes[1].message, "closed without Done")
		tasks := run_next(&run)
		testing.expect(t, slice.equal(task_ids(tasks), []u64{notify}))
		testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
		// (the captured picture is kept for Notify, which still reads it)
		v, has := task_input(tasks[0], 0)
		testing.expect(t, has && v.payload != nil)
		testing.expect(t, run_finish(&run, 3, {outcome = .Done}))
		testing.expect(t, run_over(&run))
		testing.expect(t, !run_cancel(&run, 1, ""))   // (decided: a second cancel means nothing)
	}
}

// The editor's picture is a value too: when the editor is cancelled, what reads its picture is Skipped, nothing fails.
@(test)
a_cancelled_node_gives_no_value :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Editor, .Save}, {{0, 1}, {1, 2}})
	defer graph_free(&g)
	run: Run
	start_with_capture(&run, g, 4, 4)
	defer run_free(&run)
	testing.expect(t, slice.equal(task_ids(run_next(&run)), []u64{2}))
	testing.expect(t, run_cancel(&run, 1, ""))
	testing.expect_value(t, len(run_next(&run)), 0)
	testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
	testing.expect(t, run_over(&run))
	for rn in run.nodes { testing.expect(t, rn.state != .Failed) }
}

// A dry run (a preview) skips the effects; the program may decline a node too (run_skip).
@(test)
a_dry_run_skips_the_effects :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Blur, .Save, .Read_Qr}, {{0, 1}, {1, 2}, {0, 3}})
	defer graph_free(&g)
	run: Run
	start_with_capture(&run, g, 4, 4, {id = 7, dry = true})
	defer run_free(&run)
	testing.expect_value(t, run.id, 7)
	tasks := run_next(&run)
	testing.expect(t, slice.equal(task_ids(tasks), []u64{2, 4}))
	testing.expect(t, done_with(&run, 1, pic_value(4, 4)))
	testing.expect_value(t, len(run_next(&run)), 0)
	testing.expect_value(t, run.nodes[2].state, Node_State.Skipped)
	testing.expect_value(t, run.nodes[2].message, "off in a dry run")
	testing.expect(t, run_skip(&run, 3, "nothing to read"))
	testing.expect_value(t, run.nodes[3].state, Node_State.Skipped)
	testing.expect(t, run_over(&run))
}

@(test)
two_runs_go_on_side_by_side :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Editor, .Copy_Image}, {{0, 1}, {1, 2}})
	defer graph_free(&g)
	a, b: Run
	start_with_capture(&a, g, 4, 4, {id = 1})
	start_with_capture(&b, g, 6, 6, {id = 2})
	defer { run_free(&a); run_free(&b) }
	_ = run_next(&a)
	_ = run_next(&b)
	// (the first waits on the editor while the second goes on)
	testing.expect(t, done_with(&b, 1, pic_value(6, 6)))
	testing.expect(t, slice.equal(task_ids(run_next(&b)), []u64{3}))
	testing.expect_value(t, a.nodes[1].state, Node_State.Running)
	testing.expect_value(t, a.nodes[2].state, Node_State.Waiting)
	testing.expect(t, run_cancel(&a, 1, ""))
	_ = run_next(&a)   // (what followed the editor is decided: skipped)
	testing.expect(t, run_over(&a))
	testing.expect_value(t, a.nodes[2].state, Node_State.Skipped)
	testing.expect(t, !run_over(&b))
}

@(test)
a_run_copies_its_graph :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Copy_Image}, {{0, 1}})
	defer graph_free(&g)
	run: Run
	start_with_capture(&run, g, 2, 2)
	defer run_free(&run)
	// (the person changes the graph while it runs: the run keeps what it started with)
	gone := [1]u64{2}
	nodes_delete(&g, &SAMPLE, gone[:])
	testing.expect_value(t, len(run_next(&run)), 1)
}

// A value is freed once, at its last release: the run's own reference and a job's hold each count.
@(test)
a_value_is_freed_at_its_last_release :: proc(t: ^testing.T) {
	g := sample_graph({.Capture, .Blur}, {{0, 1}})
	defer graph_free(&g)
	freed := 0
	run: Run
	start_with_capture(&run, g, 4, 4, {}, &freed)
	tasks := run_next(&run)
	v, _ := task_input(tasks[0], 0)
	job := value_hold(v)   // (a worker's job keeps the picture while it works)
	testing.expect(t, done_with(&run, 1, pic_value(2, 2, &freed)))
	testing.expect_value(t, freed, 1)   // (the Blur's picture: nothing reads it, it went at once)
	value_release(&job)
	testing.expect_value(t, freed, 2)   // (the Capture's: the job's hold was the last)
	testing.expect(t, job.payload == nil)
	run_free(&run)
	testing.expect_value(t, freed, 2)
}

@(test)
a_node_moves_only_as_its_table_says :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, s: Node_State, e: Node_Event, want: Node_State, ok: bool, loc := #caller_location) {
		next, done := node_step(s, e)
		testing.expect_value(t, done, ok, loc = loc)
		testing.expect_value(t, next, want, loc = loc)
	}
	check(t, .Waiting, .Start, .Running, true)
	check(t, .Waiting, .Skip, .Skipped, true)
	check(t, .Waiting, .Finished, .Waiting, false)   // (a result for a node that never started)
	check(t, .Running, .Finished, .Done, true)
	check(t, .Running, .Failed, .Failed, true)
	check(t, .Running, .Cancelled, .Cancelled, true)
	check(t, .Running, .Skip, .Skipped, true)
	check(t, .Done, .Failed, .Done, false)
	check(t, .Cancelled, .Finished, .Cancelled, false)
	check(t, .Skipped, .Start, .Skipped, false)
}
