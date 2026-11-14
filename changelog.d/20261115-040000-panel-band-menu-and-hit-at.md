type: Fixed

**A panel's menu no longer replaces its body's own**: a right click in the top band of a docked view opens the view's menu only when nothing of the body takes it (a tab there with its own menu keeps it). New `ui.hit_box_at(p)` and `ui.pointer_on_at(box, p)` say what a press at a given point would act on and what is in front there, by the last layout, so a program can decide per event of a batch, not only at the pointer's last position.
