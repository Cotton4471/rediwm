{ wlroots_0_20, fetchurl }:

# Match scripts/build-wlroots.sh, including RediWM's local patches. Nix
# supplies the dependencies; Meson must never download fallback subprojects.
wlroots_0_20.overrideAttrs (old: {
  version = "0.20.2";
  src = fetchurl {
    url = "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.20.2/wlroots-0.20.2.tar.gz";
    sha256 = "972c7ac44b17828f4702bfae7cd8347346a3fb5b2c1076cfa2c3fcedac5ec343";
  };
  patches = (old.patches or [ ]) ++ [ ../patches/wlroots/0001-repair-window-titles.patch ];
  outputs = [ "out" ];
  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Dexamples=false"
    "-Dbackends=drm,libinput,x11"
    "-Drenderers=gles2"
    "-Dsession=enabled"
    "-Dcolor-management=enabled"
    "-Dlibliftoff=disabled"
  ];
  # Nixpkgs normally copies example executables to a separate output.
  postFixup = "";
})
