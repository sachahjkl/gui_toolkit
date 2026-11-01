type: Changed

**`tests/examples`**: `examples/fidget` and `examples/todo` are tested in the test's process with no window and no input of the machine (`tools/keyboard_test.ps1`, `tools/fidget_test.ps1`, `tools/ui_test.ps1` are gone, so is fidget's `--state_title`); the examples have `open` and `close`, and a settings folder of their own for a test. Esc in fidget's command palette closes it, as its foot says, instead of only leaving its field.
