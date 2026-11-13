package tk_flowgraph

// The catalog the tests run on: a screenshot tool's node kinds, a few of each sort (a source, transforms, a branch, a
// person's step with its actions, effects, a node that takes anything).

PICTURE :: Port_Kind(1)
TEXT    :: Port_Kind(2)
ADDRESS :: Port_Kind(3)
FILE    :: Port_Kind(4)
ANY     :: Port_Kind(5)

Sample :: enum { Capture, Resize, Blur, Branch, Editor, Copy_Image, Save, Read_Qr, Copy_Text, Notify, Reveal }

SAMPLE := Catalog{
	kinds = {
		{name = "action"},
		{name = "picture", transient = true},
		{name = "text", accepts = {ADDRESS, FILE}},
		{name = "address"},
		{name = "file"},
		{name = "anything", any = true},
	},
	nodes = {
		{name = "capture", title = "Capture", group = "Source", outputs = {{name = "picture", kind = PICTURE}}, max_count = 1, min_count = 1},
		{name = "resize", title = "Resize", group = "Geometry", inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "picture", kind = PICTURE}}, params = {
			{name = "mode", title = "By", type = .Choice, choices = {"Percent", "Largest size"}},
			{name = "percent", title = "Scale", type = .Float, lo = 1, hi = 400, step = 1, unit = "%", default_number = 50},
			{name = "filter", title = "Filter", type = .Choice, choices = {"Sharp", "Smooth", "Fast"}},
		}},
		{name = "blur", title = "Blur", group = "Filters", inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "picture", kind = PICTURE}}, params = {
			{name = "radius", title = "Radius", type = .Float, lo = 0.5, hi = 64, step = 0.5, unit = "px", default_number = 4},
		}},
		{name = "branch", title = "Condition", group = "Flow", inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "yes", kind = PICTURE}, {name = "no", kind = PICTURE}}, params = {
			{name = "width", title = "Wider than", type = .Int, lo = 0, hi = 16384, step = 1, unit = "px", default_number = 100},
		}},
		{name = "editor", title = "Edit", group = "Interactive", inputs = {{name = "picture", kind = PICTURE}}, outputs = {
			{name = "picture", kind = PICTURE},
			{name = "done", kind = ACTION, on = .Done},
			{name = "cancelled", kind = ACTION, on = .Cancelled},
		}},
		{name = "copy_image", title = "Copy image", group = "Outputs", inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "picture", kind = PICTURE}}, effect = true},
		{name = "save_file", title = "Save file", group = "Outputs", inputs = {{name = "picture", kind = PICTURE}, {name = "when", kind = ACTION}}, outputs = {{name = "file", kind = FILE}}, effect = true, params = {
			{name = "folder", title = "Folder", type = .Folder, placeholder = "The default folder"},
			{name = "name", title = "File name", type = .Text},
			{name = "format", title = "Format", type = .Choice, choices = {"PNG", "JPEG", "WebP", "WebP, lossless"}},
			{name = "quality", title = "Quality", type = .Int, lo = 1, hi = 100, step = 1, unit = "%", default_number = 90},
			{name = "tint", title = "Tint", type = .Color, default_color = {0, 0, 0, 255}},
			{name = "open", title = "Open it after", type = .Bool},
			{name = "host", title = "Host", type = .List, placeholder = "The default host"},
		}},
		{name = "read_qr", title = "Read QR code", group = "Outputs", inputs = {{name = "picture", kind = PICTURE}}, outputs = {{name = "text", kind = TEXT}}},
		{name = "copy_text", title = "Copy text", group = "Outputs", inputs = {{name = "text", kind = TEXT}}, outputs = {{name = "text", kind = TEXT}}, effect = true},
		{name = "notify", title = "Notify", group = "Outputs", inputs = {{name = "what", kind = ANY, multiple = true}, {name = "when", kind = ACTION}}, effect = true},
		{name = "show_in_folder", title = "Show in folder", group = "Outputs", inputs = {{name = "file", kind = FILE}}, effect = true},
	},
}

// A picture of the tests: its size, and a count its free raises.
Pic :: struct {
	size:  [2]int,
	freed: ^int,
}

pic_free :: proc(data: rawptr) {
	p := (^Pic)(data)
	if p.freed != nil { p.freed^ += 1 }
	free(p)
}

pic_value :: proc(w, h: int, freed: ^int = nil) -> Value {
	p := new(Pic)
	p^ = {size = {w, h}, freed = freed}
	return value_make(PICTURE, p, pic_free)
}

text_free :: proc(data: rawptr) {
	s := (^string)(data)
	delete(s^)
	free(s)
}

text_value :: proc(kind: Port_Kind, text: string) -> Value {
	s := new(string)
	s^ = clone_text(text)
	return value_make(kind, s, text_free)
}

clone_text :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

// A graph of `kinds`, linked port 0 to port 0 by `links` (places in `kinds`). The node ids are the places plus one.
sample_graph :: proc(kinds: []Sample, links: [][2]int) -> (g: Graph) {
	for k, i in kinds { node_add(&g, &SAMPLE, int(k), {f32(i) * 200, 0}) }
	for l in links { link(&g, &SAMPLE, {u64(l[0] + 1), 0, u64(l[1] + 1), 0}) }
	return
}

task_ids :: proc(tasks: []Task) -> []u64 {
	out := make([]u64, len(tasks), context.temp_allocator)
	for t, i in tasks { out[i] = t.id }
	return out
}

// A node's work done with one value on output 0.
done_with :: proc(run: ^Run, node: int, v: Value) -> bool {
	r := Result{outcome = .Done}
	r.outputs[0] = v
	return run_finish(run, node, r)
}

// The run started and its first node, the Capture, given a picture of `w` × `h`.
start_with_capture :: proc(run: ^Run, g: Graph, w, h: int, opts: Run_Options = {}, freed: ^int = nil) {
	run_start(run, g, &SAMPLE, opts)
	for t in run_next(run) {
		if Sample(t.kind) == .Capture { done_with(run, t.node, pic_value(w, h, freed)) }
	}
}
