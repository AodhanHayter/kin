# GlusterFS daemon + firewall. Peering and volume creation are done manually
# (same as snow — the brick lives on the disko xfs partition at
# /data/glusterfs/brick1; the replica-3 `k3s-vol` is created out-of-band).
{
  services.glusterfs = {
    enable = true;
    useRpcbind = true;
  };

  networking.firewall = {
    allowedTCPPorts = [
      24007 # gluster daemon
      24008 # gluster management
      38465 # gluster NFS
      38466
      38467
    ];
    # Brick ports (up to 100 bricks/node).
    allowedTCPPortRanges = [
      {
        from = 49152;
        to = 49252;
      }
    ];
  };
}
