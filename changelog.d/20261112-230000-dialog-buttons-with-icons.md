type: Changed

**The toolkit's dialogs and pages draw their action buttons with a glyph and an intent**: the confirmation (Cancel, and the act in red or, when it is safe, in green), an empty state's actions, the shortcut sheet's Close, the Setup dialog (Choose, Uninstall, Close or Not now, Install, Open the installed copy) and the update buttons of the preferences (Check now, Install, Restart now, and the status bar's badge) now look as `ui.button_icon` does: a Lucide glyph beside the words, in the soft colours of what the button does.
  - `ui.Empty_State.actions` is now a list of `ui.Empty_Action` (`text`, `icon`, `intent`).
  - `setup.Config.button` is now `proc(id, label, glyph: string, intent: ui.Intent, em: f32, user: rawptr) -> bool`; `setup.Button_Kind` is removed.
