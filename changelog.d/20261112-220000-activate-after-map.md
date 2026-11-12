type: Fixed

**A window shown and raised at once comes to the front on Wayland**: the activation now waits for its first picture, so a compositor that only activates windows it shows (ShojiWM) no longer leaves it behind the window in front.
