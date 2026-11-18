type: Fixed

**Removing a palette source no longer crashes.** A source's last query and error were kept in the allocator of the
build that asked, and freed with the allocator of the code that removed the source; a program that removed one outside
its builds (a plugin turned off, a reload) freed them with the wrong one.
