# k3s control-plane node (atlas). Initializes the embedded-etcd HA cluster.
{ config, ... }:
{
  networking.firewall = {
    allowedTCPPorts = [
      6443 # k3s API server
      2379 # etcd clients
      2380 # etcd peers
    ];
    allowedUDPPorts = [
      8472 # flannel vxlan
    ];
  };

  # Longhorn / iSCSI support.
  services.openiscsi = {
    enable = true;
    name = "iqn.2020-08.org.linux-iscsi.initiatorhost:nixos";
  };

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    tokenFile = config.clan.core.vars.generators.k3s-token.files."token".path;
  };
}
