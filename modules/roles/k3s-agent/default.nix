# k3s worker node (apollo, hermes, lenny). Joins the cluster led by atlas.
{
  config,
  lib,
  kin,
  ...
}:
with lib;
with kin;
let
  cfg = config.kin.roles.k3s-agent;
in
{
  imports = [ ../../system/k3s-base ];

  options.kin.roles.k3s-agent = {
    enable = mkBoolOpt false "Run this node as a k3s agent (worker) joining atlas.";
  };

  config = mkIf cfg.enable {
    services.k3s = {
      enable = true;
      role = "agent";
      serverAddr = "https://atlas.local:6443";
      tokenFile = config.clan.core.vars.generators.k3s-token.files."token".path;
    };
  };
}
