type: Fixed

**No crash on closing after What's new was shown**: a release whose text had no capital letter was freed twice when the program ended, which Windows stopped as heap corruption; `ascii.lower` now always returns a copy.
