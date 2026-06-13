# Tailscale, authenticated declaratively via a clan var.
#
# The auth key is a single shared secret prompted for once:
#   1. Mint a REUSABLE auth key: https://login.tailscale.com/admin/settings/keys
#   2. `clan vars generate --generator tailscale` and paste it.
# Until the var is generated, `clan machines update` will prompt for it.
{ config, ... }:
{
  clan.core.vars.generators.tailscale = {
    share = true; # one key, reused by every node
    prompts.authkey = {
      description = "Tailscale reusable auth key (admin console -> Settings -> Keys)";
      type = "hidden";
      persist = true;
    };
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.clan.core.vars.generators.tailscale.files."authkey".path;
  };
}
