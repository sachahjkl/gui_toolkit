type: Changed

**`winrt.event_handler_make`**: the callback receives the sender and the arguments of the event (`callback(user, sender, args)`), and an optional `done(user)` runs when the last reference goes; **`winrt.typed_event_handler_iid`** and **`SIG_INSPECTABLE`** give the IDs of `TypedEventHandler<S, T>`.
