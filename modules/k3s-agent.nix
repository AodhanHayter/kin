# k3s worker node (apollo, hermes). Joins the cluster led by atlas.
{ config, ... }:
{
  networking.firewall = {
    allowedTCPPorts = [
      6443
      2379
      2380
    ];
    allowedUDPPorts = [
      8472 # flannel vxlan
    ];
  };

  services.openiscsi = {
    enable = true;
    name = "iqn.2020-08.org.linux-iscsi.initiatorhost:nixos";
  };

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://atlas.local:6443";
    tokenFile = config.clan.core.vars.generators.k3s-token.files."token".path;
  };
}
