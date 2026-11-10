type: Fixed

**Setup, a copy of the Nix store beside what an earlier install left**: it read as "To repair", with "The installed program is missing" in red, when an icon or a menu entry of an earlier install was left. A copy of the Nix store with no installed copy is now the Nix package's (`State.Nix_Package`, `setup.state_of`): the screen says an earlier install left files, and offers only to remove them ("Remove what is left"), never a repair that would install this copy beside the package. `setup.leftover` says when something is left.
