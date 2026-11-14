type: Fixed

**A floating window no longer cuts its labels**: a view that opens as a floating window with no remembered size is as wide as what is in it asks (its `width_em` at least), centred, and no rect, remembered or resized by the user, makes it narrower than what is in it on one line. A `form_row`'s label is now at least its words on one line, the control beside it giving way ("Saturation" was cut to "Sa…").
