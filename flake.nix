{
  # The toolkit's development on Linux: the pinned Odin with wgpu-native in its vendor folder, Rust for the native text backend,
  # the libraries the examples open, and what tk desktop_tests starts (Xvfb, openbox, Xorg's dummy driver, sway).
  #   nix develop                          then: odin run tools/tk -- ci (or build, desktop_tests, release)
  # git and gh are the system's (gh with its own login).
  description = "gui_toolkit: a fast, native, immediate-mode GUI toolkit in Odin";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2605";
    git-hooks = {
      url = "https://flakehub.com/f/cachix/git-hooks.nix/0.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    git-hooks,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    inherit (pkgs) lib;

    # wgpu-native where vendor:wgpu looks for it (tools/tk fetch_wgpu pins the same release)
    wgpu = pkgs.fetchurl {
      url = "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-linux-x86_64-release.zip";
      sha256 = "95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a";
    };

    # The compiler the toolkit is written for (README: dev-2026-11a). It is statically linked: nothing to patch.
    odin = pkgs.stdenv.mkDerivation {
      pname = "odin";
      version = "dev-2026-11a";
      src = pkgs.fetchurl {
        url = "https://github.com/odin-lang/Odin/releases/download/dev-2026-11a/odin-linux-amd64-dev-2026-11a.tar.gz";
        sha256 = "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618";
      };
      nativeBuildInputs = [pkgs.makeWrapper pkgs.unzip];
      dontBuild = true;
      dontStrip = true;
      dontPatchELF = true;
      installPhase = ''
        mkdir -p $out/lib/odin $out/bin
        cp -r . $out/lib/odin
        dest=$out/lib/odin/vendor/wgpu/lib/wgpu-linux-x86_64-release
        mkdir -p $dest
        unzip -qo ${wgpu} -d $dest
        echo 29.0.1.1 > $dest/VERSION
        makeWrapper $out/lib/odin/odin $out/bin/odin --set ODIN_ROOT $out/lib/odin/ --prefix PATH : ${lib.makeBinPath [pkgs.clang pkgs.lld]}
      '';
    };

    # What the examples and the tests open with dlopen.
    runtime = with pkgs; [
      vulkan-loader
      mesa
      libxkbcommon
      wayland
      libx11
      libxcb
      libxcb-cursor
      fontconfig
      freetype
      dbus
    ];

    # What tk desktop_tests starts and asks.
    desktops = with pkgs; [
      xvfb
      xorg-server
      xf86-video-dummy
      openbox
      xdotool
      xclip
      xprop
      xwininfo
      xrandr
      sway
      wl-clipboard
      wtype
    ];

    preCommitCheck = git-hooks.lib.${system}.run {
      package = pkgs.prek;
      src = ./.;
      hooks = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
      };
    };
  in {
    packages.${system}.odin = odin;
    checks.${system}.pre-commit = preCommitCheck;
    formatter.${system} = pkgs.alejandra;

    devShells.${system}.default = pkgs.mkShell {
      packages = [odin] ++ (with pkgs; [cargo rustc]) ++ desktops ++ preCommitCheck.enabledPackages;
      buildInputs = [pkgs.fontconfig];
      # (nix develop clears LD_LIBRARY_PATH when it is an attribute)
      shellHook =
        preCommitCheck.shellHook
        + ''
          export LD_LIBRARY_PATH=${lib.makeLibraryPath runtime}
          export XORG_MODULES=${pkgs.xf86-video-dummy}/lib/xorg/modules,${pkgs.xorg-server}/lib/xorg/modules
        '';
    };
  };
}
