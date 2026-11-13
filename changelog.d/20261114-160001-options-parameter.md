type: Changed

**The parameter of a struct of options is `o`**: a call that names it changes, `h264.open(w, h, fps, options = {...})` → `h264.open(w, h, fps, o = {...})`; the same for `gif.begin`, `ocr.recognize`, `mux.mp4_open_*` and `mux.webm_open_*`, `capture.stream_open` (`options`), `font.shape`, `font.measure`, `draw.text_ex`, `ui.dock_begin`, `ui.table_header`, `ui.flow_nodes_make`, `ui.node_inspector`, `ui.pane_limits`, `ui.splitter_limits` (`opts`), `instance.send`, `instance.acquire`, `markdown.view`, `markdown.code_block` (`cfg`), and the procedures of `release` and `setup` (`c`).
