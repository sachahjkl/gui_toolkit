// A todo list run by gt-runtime: `gt-runtime examples/js/todo`. Its view is the toolkit's widgets, built from what
// render returns; its two commands are in the palette (Ctrl+K). The tasks live as long as the run (no file: the
// capabilities slice gives a plugin its data folder).
import { commands, toast, views } from "gt";

let tasks = [
	{ id: 1, title: "Read the plugin API", done: true },
	{ id: 2, title: "Write a view in JavaScript", done: false },
];
let next = 3;
let draft = "";

function add() {
	const title = draft.trim();
	if (title === "") return;
	tasks.push({ id: next++, title, done: false });
	draft = "";
}

function render() {
	const left = tasks.filter((t) => !t.done).length;
	return {
		kind: "column",
		children: [
			{ kind: "heading", text: "Tasks" },
			{ kind: "text", key: "left", weak: true, text: left === 1 ? "1 task left" : `${left} tasks left` },
			{
				kind: "row",
				children: [
					{ kind: "field", key: "draft", value: draft, placeholder: "What needs doing?", onChange: (v) => { draft = v; }, onSubmit: add },
					{ kind: "button", key: "add", label: "Add", intent: "primary", disabled: draft.trim() === "", onClick: add },
				],
			},
			{ kind: "separator" },
			...tasks.map((t) => ({
				kind: "row",
				key: `task-${t.id}`,
				children: [
					{ kind: "check", key: `done-${t.id}`, label: t.title, checked: t.done, onChange: (on) => { t.done = on; } },
					{ kind: "space", size: "fill" },
					{ kind: "button", key: `remove-${t.id}`, label: "Remove", intent: "danger", onClick: () => { tasks = tasks.filter((o) => o !== t); } },
				],
			})),
			tasks.length === 0 && { kind: "text", key: "empty", weak: true, text: "Nothing here yet." },
		],
	};
}

export function activate() {
	views.register("main", render);
	commands.on("clear-done", () => {
		const before = tasks.length;
		tasks = tasks.filter((t) => !t.done);
		views.update("main");
		toast.show(`${before - tasks.length} removed`, { kind: "good" });
	});
	commands.on("all-done", () => {
		for (const t of tasks) t.done = true;
		views.update("main");
	});
}
