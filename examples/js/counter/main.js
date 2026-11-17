// A counter, the smallest application gt-runtime runs: `gt-runtime examples/js/counter/main.js`. A lone file: its
// manifest is implied (its name, one view "main").
import { views } from "gt";

let count = 0;

export function activate() {
	views.register("main", () => ({
		kind: "column",
		children: [
			{ kind: "heading", text: "Counter" },
			{ kind: "text", key: "count", text: `The count is ${count}.` },
			{
				kind: "row",
				children: [
					{ kind: "button", key: "less", label: "−1", onClick: () => { count -= 1; } },
					{ kind: "button", key: "more", label: "+1", intent: "primary", onClick: () => { count += 1; } },
					{ kind: "space", size: "fill" },
					{ kind: "button", key: "reset", label: "Reset", disabled: count === 0, onClick: () => { count = 0; } },
				],
			},
		],
	}));
}
