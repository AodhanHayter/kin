# Longhorn (k3s CSI storage) host prerequisites.
#
# The iSCSI initiator Longhorn uses for RWO volumes is enabled in the k3s role
# modules (services.openiscsi). NixOS's non-FHS layout still breaks Longhorn:
# longhorn-manager/instance-manager shell out as `nsenter <host-mount-ns>
# iscsiadm` (and `mount.nfs` for RWX), resolving those binaries against a stock
# FHS PATH (/usr/local/(s)bin, /usr/(s)bin, /sbin) that does not exist on NixOS.
# We satisfy it by exposing the system profile's bin dir at the FHS locations
# nsenter searches, and by providing the NFS client used for RWX volumes.
{ pkgs, ... }:
{
  boot.kernelModules = [ "iscsi_tcp" ];

  # NFS client: Longhorn's share-manager re-exports RWX volumes over NFS, and
  # the consuming nodes mount them as NFS clients.
  boot.supportedFilesystems.nfs = true;
  services.rpcbind.enable = true;
  environment.systemPackages = with pkgs; [
    nfs-utils
    openiscsi
  ];

  # Expose iscsiadm / mount.nfs to Longhorn's `nsenter` host calls. The system
  # profile bin dir holds both (openiscsi + nfs-utils above); symlinking the FHS
  # dirs that the container PATH searches at it makes the lookups resolve.
  systemd.tmpfiles.rules = [
    "d /usr/local 0755 root root -"
    "L+ /usr/local/bin  - - - - /run/current-system/sw/bin"
    "L+ /usr/local/sbin - - - - /run/current-system/sw/bin"
  ];
}
