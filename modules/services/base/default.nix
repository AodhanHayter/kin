# kin/base — always-on OS baseline for every kin node (nix, networking, mDNS,
# sudo, locale, shell, base packages). Applied via inventory.instances to
# roles.default.tags.all. User accounts and the sshd daemon are NOT here: the
# clan-core `users` and `sshd` services own those (see clan.nix).
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/base";
  manifest.description = "Baseline NixOS config every kin cluster node shares.";
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Apply the kin baseline to a machine.";
    perInstance =
      { ... }:
      {
        nixosModule =
          {
            lib,
            pkgs,
            ...
          }:
          {
            # Every kin node is an x86_64-linux box.
            nixpkgs.hostPlatform = "x86_64-linux";

            # --- nix ---
            nix.settings = {
              experimental-features = [
                "nix-command"
                "flakes"
              ];
              trusted-users = [
                "root"
                "aodhan"
              ];
              auto-optimise-store = true;
              warn-dirty = false;
            };
            nixpkgs.config.allowUnfree = true;

            # --- networking ---
            networking.networkmanager = {
              enable = true;
              dhcp = "internal";
            };
            # Avoids the well-known nixos-rebuild hang on NetworkManager-wait-online.
            systemd.services.NetworkManager-wait-online.enable = false;

            # mDNS so `<host>.local` resolves across the cluster (k3s serverAddr).
            services.avahi = {
              enable = true;
              nssmdns4 = true;
              nssmdns6 = true;
              ipv6 = true;
              publish = {
                enable = true;
                addresses = true;
                workstation = true;
              };
            };

            # --- ssh daemon knobs (the sshd service enables openssh + host keys) ---
            services.openssh = {
              ports = [
                22
                2222
              ];
              settings.PermitRootLogin = "prohibit-password";
            };

            # --- privileges ---
            # nixos-rebuild remote activation needs sudo; keep wheel passwordless.
            security.sudo.wheelNeedsPassword = false;

            programs.fish.enable = true;

            # --- locale / time ---
            time.timeZone = lib.mkDefault "America/New_York";
            i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

            environment.systemPackages = with pkgs; [
              git
              vim
              htop
            ];
          };
      };
  };
}
