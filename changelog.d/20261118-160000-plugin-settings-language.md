type: Fixed

**A plugin's settings in the person's language at once**: when the person changes the language, the titles and
descriptions of a plugin's settings take the translations of its manifest's `l10n` at the next build, with no reload
of the plugins and no restart of the plugin. Before, they changed only at the next read of the plugins' folder.
