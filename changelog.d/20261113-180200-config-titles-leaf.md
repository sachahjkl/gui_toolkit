type: Changed

**A preference's title is its last segment**: `config.title_of` no longer repeats the groups, which a settings page shows as headings (`network.http.max_connections` reads "Max connections" under "HTTP"). `config.matches(prefs, def, query)` now takes the registry and finds a preference by the titles of its groups too.
