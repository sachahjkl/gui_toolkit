type: Changed

**gt:js: two runtimes run at once**: each runtime keeps its own state, so several run in one process, each on its own
thread, and a contextless entry point (the members of a lazy object) allocates through the runtime's allocator, not
the process heap. The embedding API changes:
  - The hooks are `Host_Config` fields, set at `engine_new` or later in `rt.config`: `date_now_hook`,
    `timezone_offset_proc`, `clock_hook`, `span_hook`, `poll_hook`, `stack_move_hook`, `native_stack_low_hook`,
    `auto_init_getter`. They were package globals (`js.date_now_hook = ...`, `jsdate.timezone_offset_proc = ...`).
  - The poll word is `rt.poll_word`; the JIT's settings `rt.jit_cfg`; `jit_configure(rt, ...)` and `jit_stat(rt, which)`
    take the runtime; `-define:JSRT_TRACE_LAST_OP` writes `rt.trace`.
  - `gt:js/datetime`: `get_date_fields`, `set_date_fields`, `parse` and `parse_bytes` take the time zone, a
    `Timezone_Offset`, as their last argument (nil: UTC).
