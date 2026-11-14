{
  nixpkgs,
  system,
  rediwmModule,
}:
let
  evaluated = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      rediwmModule
      {
        programs.rediwm.enable = true;
        system.stateVersion = "26.05";
        boot.isContainer = true;
      }
    ];
  };
  inherit (evaluated) config pkgs;
in
assert builtins.elem config.programs.rediwm.package config.services.displayManager.sessionPackages;
assert config.security.polkit.enable;
assert config.security.wrappers.pkexec.setuid;
assert config.services.displayManager.defaultSession == null;
assert config.xdg.portal.config.rediwm."org.freedesktop.impl.portal.ScreenCast" == "wlr";
assert nixpkgs.lib.all (entry: entry.assertion) config.assertions;
pkgs.runCommand "rediwm-module-check" { } ''
  test -s ${config.environment.etc."pam.d/rediwm".source}
  touch "$out"
''
