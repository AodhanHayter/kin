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

      # Modules every machine imports, regardless of hardware. The cluster-node
      # suite pulls in the baseline system/storage/secret modules + Tailscale.
      # (disko's module is provided by clan-core, so we don't import it here.)
      baseCommon = [
        ./modules/suites/cluster-node
      ];
      # The three Beelink EQ13 nodes additionally share one hardware profile +
      # /dev/sda disko layout. Non-EQ13 machines (e.g. lenny) bring their own.
      baseEq13 = baseCommon ++ [
        ./modules/suites/eq13-node
      ];

      clan = clan-core.lib.clan {
        self = self;
        # Snow-style module helpers (kin.mkBoolOpt / kin.enabled / ...) made
        # available as the `kin` arg inside every machine module. Built from
        # the flake-input lib (resolved before module eval — recursion-free).
        specialArgs = {
          kin = import ./lib { lib = nixpkgs.lib; };
        };

        meta.name = "kin";

        # Per-machine NixOS wiring: platform + module imports.
        machines = {
          atlas = {
            nixpkgs.hostPlatform = system;
            imports = baseEq13 ++ [ ./machines/atlas/configuration.nix ];
          };
          apollo = {
            nixpkgs.hostPlatform = system;
            imports = baseEq13 ++ [ ./machines/apollo/configuration.nix ];
          };
          hermes = {
            nixpkgs.hostPlatform = system;
            imports = baseEq13 ++ [ ./machines/hermes/configuration.nix ];
          };
          lenny = {
            nixpkgs.hostPlatform = system;
            imports = baseCommon ++ [ ./machines/lenny/configuration.nix ];
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
            lenny = {
              deploy.targetHost = "root@lenny.local";
              tags = [ "k3s-agent" ];
            };
          };
        };
      };
    in
    {
      # clan-managed machines + a generic keyed installer ISO used to bootstrap
      # fresh boxes (boot it, then `clan machines install` over ssh).
      nixosConfigurations = clan.config.nixosConfigurations // {
        installer = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            (
              {
                modulesPath,
                pkgs,
                ...
              }:
              {
                imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

                networking.hostName = "kin-installer";

                services.openssh = {
                  enable = true;
                  settings.PermitRootLogin = "prohibit-password";
                };
                users.users.root.openssh.authorizedKeys.keys = import ./modules/system/ssh-keys.nix;

                # mDNS so `kin-installer.local` resolves without hunting the IP.
                services.avahi = {
                  enable = true;
                  nssmdns4 = true;
                  publish = {
                    enable = true;
                    addresses = true;
                    workstation = true;
                  };
                };

                nix.settings.experimental-features = [
                  "nix-command"
                  "flakes"
                ];
                environment.systemPackages = with pkgs; [ git ];
              }
            )
          ];
        };
      };
      inherit (clan.config) nixosModules clanInternals;
      clan = clan.config;

      # The dev shell lives in devenv.nix (devenv.sh), not here.
      formatter = forAllSystems (s: nixpkgs.legacyPackages.${s}.nixfmt-rfc-style);
    };
}
