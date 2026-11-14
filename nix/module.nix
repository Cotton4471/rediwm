{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.programs.rediwm;
in
{
  options.programs.rediwm = {
    enable = lib.mkEnableOption "the RediWM Wayland session";
    package = lib.mkOption {
      type = lib.types.package;
      description = "RediWM package supplied by the flake.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    services.displayManager.sessionPackages = [ cfg.package ];
    services.graphical-desktop.enable = true;
    programs.xwayland.enable = lib.mkDefault true;
    programs.dconf.enable = lib.mkDefault true;
    security.polkit = {
      enable = true;
    }
    // lib.optionalAttrs (options.security.polkit ? enablePkexecWrapper) {
      # Older NixOS releases enable this wrapper along with polkit.
      enablePkexecWrapper = true;
    };
    security.pam.services.rediwm = { };

    xdg.portal = {
      enable = true;
      wlr.enable = true;
      # NixOS starts xdpw with --config, so its per-user config is bypassed.
      wlr.settings.screencast = {
        max_fps = lib.mkDefault 30;
        chooser_type = lib.mkDefault "dmenu";
        chooser_cmd = lib.mkDefault "${cfg.package}/bin/rediwm-share-picker --xdpw-dmenu";
      };
      extraPortals = [
        cfg.package
        pkgs.xdg-desktop-portal-gtk
      ];
      config.rediwm = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.ScreenCast" = [ "wlr" ];
        "org.freedesktop.impl.portal.Settings" = [
          "rediwm"
          "gtk"
        ];
        "org.freedesktop.impl.portal.FileChooser" = [
          "rediwm"
          "gtk"
        ];
      };
    };
  };
}
