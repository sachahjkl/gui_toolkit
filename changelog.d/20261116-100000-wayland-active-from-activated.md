type: Fixed

**Wayland: a window knows it is in front without a keyboard.** `Window.active` and `focused` also follow the compositor's `activated` state of the toplevel, not only the keyboard's enter and leave. On a seat with no keyboard (a headless session, a touch screen) a window in front was never `active`, and a program that hides its window only when it is in front kept bringing it forward instead.
