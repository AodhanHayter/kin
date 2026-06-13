# Tailscale, authenticated declaratively via a clan var.
#
# The auth key is a single shared secret prompted for once:
#   1. Mint a REUSABLE auth key: https://login.tailscale.com/admin/settings/keys
#   2. `clan vars generate --generator tailscale` and paste it.
# Until the var is generated, `clan machines update` will prompt for it.
{
  config,
  lib,
  kin,
  ...
}:
with lib;
with kin;
let
  cfg = config.kin.services.tailscale;
in
{
  options.kin.services.tailscale = {
    enable = mkBoolOpt false "Whether to enable Tailscale on this node.";
    openFirewall = mkBoolOpt true "Open the Tailscale UDP port in the firewall.";
  };

  config = mkMerge [
    # Generator is defined UNCONDITIONALLY (outside mkIf): the generator name
    # "tailscale" + file "authkey" are load-bearing string keys, and the
    # encrypted var must exist regardless of the enable toggle so a disabled
    # host can never silently drop the secret.
    {
      clan.core.vars.generators.tailscale = {
        share = true; # one key, reused by every node
        prompts.authkey = {
          description = "Tailscale reusable auth key (admin console -> Settings -> Keys)";
          type = "hidden";
          persist = true;
        };
      };
    }

    (mkIf cfg.enable {
      services.tailscale = {
        enable = true;
        openFirewall = cfg.openFirewall;
        authKeyFile = config.clan.core.vars.generators.tailscale.files."authkey".path;
      };
    })
  ];
}
