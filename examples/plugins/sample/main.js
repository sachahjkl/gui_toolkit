// The sample plugin of examples/plugins: one command shows a toast, the other never returns, so that Stop and
// "Not responding" can be seen. The window goes on drawing while it loops: the plugin runs on its own thread.
import { commands, toast } from "gt";

export function activate(context) {
	let hellos = 0;
	commands.on("hello", () => {
		hellos += 1;
		toast.show(`Hello from ${context.name} (${hellos})`, { kind: "good", title: "Sample" });
	});
	commands.on("spin", () => {
		for (;;) {}
	});
}
