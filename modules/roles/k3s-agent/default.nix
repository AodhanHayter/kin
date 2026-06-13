# k3s worker node (apollo, hermes, lenny). Joins the cluster led by atlas.
{ config, ... }:

{
  imports = [ ../../system/k3s-base ];

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://atlas.local:6443";
    tokenFile = config.clan.core.vars.generators.k3s-token.files."token".path;
  };
}
