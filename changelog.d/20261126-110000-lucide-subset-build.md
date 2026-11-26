type: Fixed

**Programs are 860 KB smaller again**: since 0.360.0 a build in a fresh tree (a Nix package, the CI's release) put the whole Lucide icon font in the program instead of the icons it uses; a project with the Lucide subset now never builds without it.
