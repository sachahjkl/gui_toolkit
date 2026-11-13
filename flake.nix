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
    # The macOS build of the same release: vendor:wgpu stops the compiler when it is absent, and macOS renders through
    # wgpu (Metal), so `odin check -target:darwin_arm64` of the renderer needs it here.
    wgpu-macos = pkgs.fetchurl {
      url = "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-macos-aarch64-release.zip";
      sha256 = "a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e";
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
        dest_macos=$out/lib/odin/vendor/wgpu/lib/wgpu-macos-aarch64-release
        mkdir -p $dest_macos
        unzip -qo ${wgpu-macos} -d $dest_macos
        echo 29.0.1.1 > $dest_macos/VERSION
        makeWrapper $out/lib/odin/odin $out/bin/odin --set-default ODIN_ROOT $out/lib/odin/ --prefix PATH : ${lib.makeBinPath [pkgs.clang pkgs.lld]}
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
      librsvg # the SVG icons of the icon themes (desktop.file_icon)
      cairo
      glib
      curl # tk_http on Linux (dlopen)
      libwebp # image.webp_encode and webp_decode (dlopen)
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
    packages.${system} = {
      inherit odin;
      # the fonts the tests find, whatever the machine has (CI: FONTCONFIG_FILE=$(nix build .#test-fonts ...)): the text and
      # the color glyphs' tests look for these
      test-fonts = pkgs.makeFontsConf {fontDirectories = with pkgs; [dejavu_fonts noto-fonts-color-emoji];};
    };
    checks.${system}.pre-commit = preCommitCheck;
    formatter.${system} = pkgs.alejandra;

    devShells.${system}.default = pkgs.mkShell {
      # (dbus: dbus-daemon, the notifications' tests start a session bus of their own; curl: the shell's own, a system's curl
      # loads the shell's glibc through LD_LIBRARY_PATH and stops)
      # (libwebp: cwebp, which tk screenshots and tk site_build make the site's pictures light with)
      packages = [odin] ++ (with pkgs; [cargo rustc dbus curl libwebp]) ++ desktops ++ preCommitCheck.enabledPackages;
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
