type: Removed

**Wayland: the primary-selection listeners**: the toolkit bound `zwp_primary_selection_device_manager_v1`, made a device and tracked its offers, but never read one nor offered a selection (no source was ever made): the protocol tables, the listeners and their state are gone. On X11 a copy still owns `PRIMARY`.
