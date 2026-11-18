type: Fixed

**A plugin that dies at its start on Windows is seen as crashed**: another plugin's process no longer holds its pipe,
so the plugin no longer stays "starting" for ever.
