// Log explorer, run by gt-runtime: `gt-runtime examples/js/logs`. A quarter of a million lines in a lazy list: the
// program asks only for the rows on screen. The search and the level switches filter every line in this plugin's own
// process, while the window stays fluid. Its commands are in the palette (Ctrl+K).
import { commands, toast, views } from "gt";
import { COUNT, LEVELS, SERVICES, generate, filter, levelOf, message, clock, fmt } from "./lib/logs.js";

const data = generate();
let query = "";
let shown = [true, true, true];
let found = filter(data, query, shown);
let version = 1;   // the rows change with each filter: the list drops the ones it has
let open = -1;     // the line shown in detail

function refilter() {
	found = filter(data, query, shown);
	version += 1;
}

function line(i) {
	const at = found.rows[i];
	return {
		kind: "row",
		children: [
			{ kind: "text", text: clock(data, at), weak: true },
			{ kind: "text", text: LEVELS[levelOf(data, at)].toUpperCase() },
			{ kind: "text", text: SERVICES[data.svc[at]], weak: true },
			{ kind: "text", text: message(data, at) },
			{ kind: "space", size: "fill" },
			{ kind: "button", key: "open", label: "Open", look: "ghost", size: "small", onClick: () => { open = at; } },
		],
	};
}

function render() {
	return {
		kind: "column",
		children: [
			{ kind: "heading", text: "Log explorer" },
			{ kind: "text", key: "summary", weak: true, text: `${fmt(found.rows.length)} of ${fmt(COUNT)} lines` },
			{
				kind: "row",
				key: "levels",
				children: LEVELS.map((name, level) => ({
					kind: "switch", key: `level-${name}`, label: `${name} · ${fmt(found.counts[level])}`, on: shown[level],
					onChange: (on) => { shown[level] = on; refilter(); },
				})),
			},
			{
				kind: "field", key: "query", value: query, placeholder: "Search every line: a word, a service, a number",
				onChange: (text) => { query = text; refilter(); },
			},
			open >= 0 && {
				kind: "card",
				key: "detail",
				title: `Line ${fmt(open + 1)} · ${LEVELS[levelOf(data, open)]} · ${SERVICES[data.svc[open]]} · ${clock(data, open)}`,
				children: [
					{ kind: "text", key: "detail-message", text: message(data, open) },
					{ kind: "button", key: "close", label: "Close", onClick: () => { open = -1; } },
				],
			},
			{ kind: "list", key: "lines", count: found.rows.length, version, rowHeight: 1.6, visibleRows: 14, row: line },
		],
	};
}

export function activate() {
	views.register("main", render);
	commands.on("errors", () => {
		shown = [false, false, true];
		refilter();
		views.update("main");
		toast.show(`${fmt(found.rows.length)} errors`, { kind: "bad" });
	});
	commands.on("everything", () => {
		query = "";
		shown = [true, true, true];
		refilter();
		views.update("main");
	});
	commands.on("newest", () => {
		for (let i = COUNT - 1; i >= 0; i--) {
			if (levelOf(data, i) === 2) { open = i; break; }
		}
		views.update("main");
	});
}
