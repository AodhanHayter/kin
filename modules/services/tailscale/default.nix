# kin/tailscale — Tailscale on every node, authenticated declaratively via a
# shared clan var. Applied to roles.default.tags.all, so the authkey generator
# exists on every machine.
#
# The auth key is a single shared secret prompted for once:
#   1. Mint a REUSABLE auth key: https://login.tailscale.com/admin/settings/keys
#   2. `clan vars generate` and paste it.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/tailscale";
  manifest.description = "Tailscale mesh VPN on every node, keyed by a shared auth key.";
  manifest.categories = [ "Network" ];

  roles.default = {
    description = "Run Tailscale on a machine.";
    interface =
      { lib, ... }:
      {
        options.openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open the Tailscale UDP port in the firewall.";
        };
      };
    perInstance =
      { settings, ... }:
      {
        nixosModule =
          { config, ... }:
          {
            # Shared auth key, reused by every node.
            clan.core.vars.generators.tailscale = {
              share = true;
              prompts.authkey = {
                description = "Tailscale reusable auth key (admin console -> Settings -> Keys)";
                type = "hidden";
                persist = true;
              };
            };

            services.tailscale = {
              enable = true;
              openFirewall = settings.openFirewall;
              authKeyFile = config.clan.core.vars.generators.tailscale.files."authkey".path;
            };
          };
      };
  };
}
