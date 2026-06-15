# Shared k3s node baseline — imported by BOTH the server and agent roles of the
# kin/k3s service. Covers the k3s node firewall, the atlas join-address pin, the
# Longhorn host prerequisites (iSCSI + NFS + the FHS shims NixOS needs), and
# graceful shutdown draining.
{ pkgs, ... }:
{
  networking.firewall = {
    allowedTCPPorts = [
      10250 # kubelet — metrics-server scrapes <node-ip>:10250
      9100 # node-exporter (hostNetwork) — Prometheus scrapes <node-ip>:9100
    ];
    allowedUDPPorts = [
      8472 # flannel vxlan
    ];
  };

  # Pin the k3s join address in /etc/hosts so it does not depend on avahi/mDNS
  # being up when k3s starts. Requires a DHCP reservation for atlas — keep in sync.
  networking.hosts."10.10.0.100" = [
    "atlas.local"
    "atlas"
  ];

  # Drain pods cleanly on reboot/shutdown (frequent kernel bumps on a test
  # cluster; without this, pods are killed mid-write).
  services.k3s.gracefulNodeShutdown.enable = true;

  # --- Longhorn host prerequisites ---
  # iSCSI initiator (RWO volumes).
  services.openiscsi = {
    enable = true;
    name = "iqn.2020-08.org.linux-iscsi.initiatorhost:nixos";
  };
  boot.kernelModules = [ "iscsi_tcp" ];

  # NFS client: Longhorn's share-manager re-exports RWX volumes over NFS.
  boot.supportedFilesystems.nfs = true;
  services.rpcbind.enable = true;
  environment.systemPackages = with pkgs; [
    nfs-utils
    openiscsi
  ];

  # Expose iscsiadm / mount.nfs to Longhorn's `nsenter` host calls. longhorn-
  # manager/instance-manager shell out via `nsenter <host-mount-ns> iscsiadm`
  # against a stock FHS PATH that does not exist on NixOS; symlink the FHS dirs
  # it searches at the system profile bin dir so the lookups resolve.
  systemd.tmpfiles.rules = [
    "d /usr/local 0755 root root -"
    "L+ /usr/local/bin  - - - - /run/current-system/sw/bin"
    "L+ /usr/local/sbin - - - - /run/current-system/sw/bin"
  ];
}
