type: Added

**A setup logo given later, and the views' palette commands kept**: `setup.set_logo(&d, logo)` gives the setup dialog its logo after it opened (a logo made from a task's answer), shown from the next frame. `ui.View_Commands` with `ui.views_commands_update` keeps the views' palette commands in memory of their own, made again only when a view opens, closes, moves or changes its title, or the language changes: the palette holds its table while it is open, which temporary memory did not allow.
