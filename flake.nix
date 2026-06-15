{
  description = "kin: clan-managed k3s cluster (atlas/apollo/hermes/lenny)";

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
    }@inputs:
    let
      system = "x86_64-linux";

      # Systems an admin might drive `clan` from (Mac + Linux).
      adminSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs adminSystems;

      # The whole clan — meta, machines, tags and service instances — lives in
      # ./clan.nix (the clan.lol native layout). flake.nix only wires it up and
      # adds the bootstrap installer ISO. No snowfall-style lib, no per-machine
      # import lists: machines/<name>/{configuration,hardware-configuration,
      # disko}.nix are auto-included, and everything else is a clan.service
      # deployed via inventory.instances.
      clan = clan-core.lib.clan {
        inherit self;
        specialArgs = { inherit inputs; };
        imports = [ ./clan.nix ];
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
                users.users.root.openssh.authorizedKeys.keys = import ./modules/ssh-keys.nix;

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
