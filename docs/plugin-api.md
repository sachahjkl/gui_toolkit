# The plugin API

Made by `odin run tools/tk -- plugin_api` from `src/plugin_api/api.odin`: do not edit. This toolkit gives level 1 of the API and accepts plugins written for levels 1 to 1. How a program turns plugins on: [plugins.md](plugins.md).

A plugin imports the API as an ES module, and its entry file exports `activate(context)`:

```js
import { commands, toast } from "gt";

export function activate(context) {
	commands.on("hello", () => toast.show("Hello from " + context.name));
}
```

The types are in `plugin-api/gt.d.ts`; each level's are in `plugin-api/level-<n>.d.ts`.

## commands

### `commands.on(id, handler)`

Registers the handler of one of the manifest's commands: choosing the command in the palette calls it. A second call for the same command replaces the handler.

Level 1. Permission: none.

| Argument | Type | |
|---|---|---|
| `id` | `string` | The command's id, as the manifest's `commands` declares it. |
| `handler` | `() => void | Promise<void>` | Called with no argument when the command is chosen. It may return a promise. |

## toast

### `toast.show(text, options?)`

Shows a message to the person: a toast of the window, or the system's notification when the program says its messages there.

Level 1. Permission: none.

| Argument | Type | |
|---|---|---|
| `text` | `string` | What it says. |
| `options` | `Toast_Options`, optional |  |

## Types

### `Toast_Kind`

How a toast looks.

One of `"info"`, `"good"`, `"warn"`, `"bad"`.

### `Toast_Options`

A toast's options.

| Field | Type | |
|---|---|---|
| `kind` | `Toast_Kind`, optional | Its look ("info" when absent). |
| `title` | `string`, optional | A line in bold above the text. |

### `Activate_Context`

What the entry file's activate(context) is given (gt:plugins makes it: plugins/runtime.odin, context_object).

| Field | Type | |
|---|---|---|
| `id` | `string` | The plugin's id, as plugin.json says it. |
| `name` | `string` | Its name. |
| `version` | `string` | Its version ("" when plugin.json says none). |
| `api` | `number` | The level of the API this program gives. |
