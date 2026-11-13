type: Removed

**`ui.stepper`, `ui.slider_field`, `ui.Slider_Field`, `ui.slider_field_destroy`**: `ui.number` does what both did, and more (`ui.number(id, &v, lo = 0, hi = 99)`; with `slider = true` for a slider beside the field). The number being typed is kept by the interface: a program keeps no field for it.
