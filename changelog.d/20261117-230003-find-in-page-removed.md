type: Removed

**The marks' filter and the find in page's own calls**: `ui.scroll_marks_shown`, `ui.scroll_marks_query` and the marks'
filter field are gone (the find bar and its scopes do it); so are `ui.find(needle, scope)`, `ui.find_set_current`,
`ui.find_sweep`, `ui.find_all`, `ui.find_progress`, `ui.find_refresh` and `lazy_begin`'s `sweep` (a lazy column's rows are
counted by their text, never built for a sweep): a program opens the find over its view and calls `ui.find_bar`.
