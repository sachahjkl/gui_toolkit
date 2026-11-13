# crash_bar: the last run's crash, said at the start

`import crash_bar "gt:crash_bar"` (the package is `tk_crash_bar`). When the last run of a program ended abnormally,
[gt:crash](crash.md) left a report; the next start shows this bar across the window, under its title bar or toolbar, the
same in every program:

- what happened, from the report's name and its `reason:` line: "Papier stopped unexpectedly last time (segmentation
  fault…)", "… did not close normally last time: the system or another program ended it" (`unclean-`), "… ended
  unexpectedly last time" (`exit-`);
- **Open the report**: the file with the system's program;
- **Copy**: the whole report on the clipboard;
- **Report on GitHub** (with `Options.repository`): the whole report on the clipboard, and a new issue of the program's
  repository opened in the browser, its title "<name> <version> stopped unexpectedly", the report in its body (cut on a line
  so that the address stays under `ISSUE_URL_MAX`: GitHub refuses longer ones; the person pastes the whole if it was cut);
- a cross that dismisses it.

It takes a row of the window while it is there and nothing else: no focus, no dialog. Nothing is sent anywhere unless the
person sends the issue.

```odin
crash.install({program = APP_NAME, version = APP_VERSION, log_tail = {tk_log.tail, logger.data}})
crash.begin_session()
if path, ok := crash.last_report(context.temp_allocator); ok { crash_bar.init(&app.crash_bar, path) }   // before the loop
// each frame, at the top of the window's content
crash_bar.bar(&app.crash_bar, {name = "Papier", version = APP_VERSION, repository = "sachahjkl/papier"})
// at the end
crash_bar.destroy(&app.crash_bar)
crash.end_session()
```

| | |
|---|---|
| `init(b, path)` | the report of the last run (copied); "" nothing |
| `bar(b, o) -> bool` | the bar while there is a report; true while it is shown. Its first build reads the report on a task (`ui.task`): Copy and Report wait for it |
| `destroy(b)` | frees it (the cross does it too) |
| `kind_of(path)`, `reason_of(text)`, `words(b, name)` | the kind from the name; the header's `reason:`; the sentence |
| `issue_url(repository, title, report)`, `url_escape(s)` | the new issue's address |

Keep the `Bar` where it is as long as the `ui.State` it is built in: the task's answer comes there.
