{
  description = "kin: clan-managed k3s cluster (atlas/apollo/hermes/lenny)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    clan-core = {
      url = "https://git.clan.lol/clan/clan-core/archive/25.11.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Apple hardware support for the mbp node (MacBookPro11,5): mbpfan, Intel
    # microcode, SSD trim, broadcom firmware. See modules/hardware/macbook-pro-11-5.
    nixos-hardware = {
      url = "github:nixos/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # GitOps pull-deploy (kin/comin). Module isn't in nixpkgs; comes from here.
    comin = {
      url = "github:nlewo/comin";
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

      # Shared bootstrap-installer config (key-only root sshd + mDNS + git +
      # flakes). Used by both the generic `installer` and the `installer-mac`
      # variant that adds broadcom wifi for the MacBookPro node.
      installerCommon =
        {
          modulesPath,
          pkgs,
          ...
        }:
        {
          imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

          services.openssh = {
            enable = true;
            settings.PermitRootLogin = "prohibit-password";
          };
          users.users.root.openssh.authorizedKeys.keys = import ./modules/ssh-keys.nix;

          # mDNS so the installer resolves by name without hunting the IP.
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
        };

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
            installerCommon
            { networking.hostName = "kin-installer"; }
          ];
        };

        # MacBookPro bootstrap ISO: the generic installer plus the
        # macbook-pro-11-5 hardware module (broadcom `wl` driver + firmware) and
        # iwd, so a Mac with no ethernet can join wifi from its own console
        # before install:  iwctl station wlan0 connect <SSID>
        installer-mac = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            installerCommon
            ./modules/hardware/macbook-pro-11-5
            {
              networking.hostName = "kin-installer-mac";
              networking.wireless.iwd.enable = true;
              nixpkgs.config.allowUnfree = true;
            }
          ];
        };
      };
      inherit (clan.config) nixosModules clanInternals;
      clan = clan.config;

      # The dev shell lives in devenv.nix (devenv.sh), not here.
      formatter = forAllSystems (s: nixpkgs.legacyPackages.${s}.nixfmt-rfc-style);
    };
}
