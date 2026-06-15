# kin/nix-cache — share the nix store across the cluster with a harmonia binary
# cache (ref: clan-core/nix-cache, DavHau/hyperconfig). One machine runs the
# harmonia server (atlas); every machine is a client that substitutes from it.
#
# The signing keypair is NOT declared here: it's the shared `nix-cache-key`
# generator in kin/secrets (tags.all), because the server needs the sign-key and
# every client needs the pub-key — a cross-host secret, which kin's hard rule
# keeps in kin/secrets rather than gated behind a role.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/nix-cache";
  manifest.description = "Serve the nix store between machines via a harmonia binary cache.";
  manifest.categories = [ "Utility" ];

  # The machine running harmonia. Reads the shared sign-key to sign served paths.
  roles.server = {
    description = "Run the harmonia binary cache on this machine.";
    interface =
      { lib, ... }:
      {
        options.priority = lib.mkOption {
          type = lib.types.int;
          default = 50;
          description = ''
            Reported cache priority (lower = preferred). The default 50 is
            higher than cache.nixos.org's ~40, so upstream stays preferred.
          '';
        };
      };
    perInstance =
      { settings, ... }:
      {
        nixosModule =
          { config, ... }:
          {
            services.harmonia = {
              enable = true;
              signKeyPaths = [ config.clan.core.vars.generators.nix-cache-key.files."sign-key".path ];
              settings.priority = settings.priority;
            };
            networking.firewall.allowedTCPPorts = [ 5000 ];
          };
      };
  };

  # Every node: trust and substitute from each server, addressed by mDNS name.
  roles.client = {
    description = "Substitute from the cluster's harmonia cache(s).";
    perInstance =
      { roles, ... }:
      {
        nixosModule =
          { config, ... }:
          let
            domain = config.clan.core.settings.domain;
            servers = builtins.attrNames roles.server.machines;
          in
          {
            nix.settings.substituters = builtins.map (m: "http://${m}.${domain}:5000") servers;
            nix.settings.trusted-public-keys = [
              config.clan.core.vars.generators.nix-cache-key.files."pub-key".value
            ];
          };
      };
  };
}
