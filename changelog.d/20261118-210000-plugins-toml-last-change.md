type: Fixed

**The Plugins page keeps the last change.** Changes made one after another (a plugin turned on, then off, a grant)
were each written on their own, and an older write could land last: the plugin was on again at the next start. They
are written one at a time now, the last state last.
