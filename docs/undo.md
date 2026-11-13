# undo: the undo and redo steps of a model

`gt:undo` (package `tk_undo`, `import undo "gt:undo"`) keeps the steps of a model as snapshots: a text field's text
(`ui.Line_Edit`, `ui.Text_Edit`), a graph (`flowgraph.Graph`), a drawing. The owner says what a snapshot is, how it is
made and how it is freed; the stack keeps them in order.

```odin
history: undo.Stack(flowgraph.Graph)

// before a change
undo.push(&history, flowgraph.graph_clone(app.graph), 100, flowgraph.graph_destroy)

// Ctrl+Z
if undo.can_undo(&history) {
	back, _ := undo.undo(&history, app.graph)   // the graph as it is goes to the redo steps
	app.graph = back
}
```

| Procedure | What it does |
|---|---|
| `push(s, before, limit, free_step)` | `before` (taken) is the step undo goes back to; the oldest steps past `limit` go (0: no limit), and the redo steps |
| `forget_redo(s, free_step)` | a change that merges with the last step (typing goes on): no new step, the redo steps go |
| `undo(s, now) -> (back, ok)` | the last step, the caller's now; `now` (taken), the model as it is, goes to the redo steps. ok false: none, and `now` is not taken |
| `redo(s, now) -> (again, ok)` | the same, the other way |
| `drop_last(s, free_step)` | the last step pushed goes: the change was refused after all |
| `can_undo(s)`, `can_redo(s)` | whether there is a step |
| `reset(s, free_step)` | every step freed: another document |
| `destroy(s, free_step)` | every step freed, and the stack's memory |

A step is taken whole and given back whole: the stack frees one (with `free_step`, nil: nothing to free) only when it
drops it. When a change merges with the last step is the owner's rule: a text field merges the characters typed within
`Feel.undo_merge_ms`, `ui.node_inspector` says `new_step` when another parameter changes.

The text fields keep their steps in `Line_Edit.history` and `Text_Edit.history` (`ui.Edit_History`, a stack of
`Edit_Snapshot`); a step's text is zeroed when it is freed, as a field may hold a secret.

## Tests

`src/undo/undo_test.odin`: undo and redo through the steps, a change after an undo, the limit, a step dropped.
`tests/scenarios/node_inspector_test.odin` undoes a node's parameters, and the text tests the fields' history.
