{
  description = "kin: clan-managed k3s cluster (atlas/apollo/hermes)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/25.11.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      clan-core,
      ...
    }:
    let
      system = "x86_64-linux";

      # Systems an admin might drive `clan` from (Mac + Linux).
      adminSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs adminSystems;

      # Shared NixOS modules every machine imports.
      # (disko's module is provided by clan-core, so we don't import it here.)
      base = [
        ./modules/common.nix
        ./modules/hardware-beelink-eq13.nix
        ./modules/disko.nix
        ./modules/tailscale.nix
        ./modules/gluster.nix
        ./modules/k3s-token.nix
      ];

      clan = clan-core.lib.clan {
        self = self;
        specialArgs = { };

        meta.name = "kin";

        # Per-machine NixOS wiring: platform + module imports.
        machines = {
          atlas = {
            nixpkgs.hostPlatform = system;
            imports = base ++ [ ./machines/atlas/configuration.nix ];
          };
          apollo = {
            nixpkgs.hostPlatform = system;
            imports = base ++ [ ./machines/apollo/configuration.nix ];
          };
          hermes = {
            nixpkgs.hostPlatform = system;
            imports = base ++ [ ./machines/hermes/configuration.nix ];
          };
        };

        # Inventory: deploy targets + tags.
        inventory = {
          machines = {
            atlas = {
              deploy.targetHost = "root@atlas.local";
              tags = [ "k3s-server" ];
            };
            apollo = {
              deploy.targetHost = "root@apollo.local";
              tags = [ "k3s-agent" ];
            };
            hermes = {
              deploy.targetHost = "root@hermes.local";
              tags = [ "k3s-agent" ];
            };
          };
        };
      };
    in
    {
      inherit (clan.config) nixosConfigurations nixosModules clanInternals;
      clan = clan.config;

      # The dev shell lives in devenv.nix (devenv.sh), not here.
      formatter = forAllSystems (s: nixpkgs.legacyPackages.${s}.nixfmt-rfc-style);
    };
}
