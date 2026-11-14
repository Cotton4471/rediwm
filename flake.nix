{
  description = "RediWM Wayland desktop";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          rediwm = pkgs.callPackage ./nix/package.nix { };
        in
        {
          inherit rediwm;
          default = rediwm;
        }
      );

      nixosModules.default = self.nixosModules.rediwm;
      nixosModules.rediwm = { pkgs, lib, ... }: {
        imports = [ ./nix/module.nix ];
        programs.rediwm.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.rediwm;
      };

      checks = forAllSystems (system: {
        package = self.packages.${system}.rediwm;
        module = import ./nix/module-check.nix {
          inherit nixpkgs system;
          rediwmModule = self.nixosModules.rediwm;
        };
      });
    };
}
