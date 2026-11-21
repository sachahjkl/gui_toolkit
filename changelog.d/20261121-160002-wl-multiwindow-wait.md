type: Fixed

**Input on secondary windows on Wayland**: pointer, keyboard and other events arriving on any shown window other than
the first now wake `host.hosts_wait` (`wl_wait`) at once instead of piling up until the first window receives an event.
