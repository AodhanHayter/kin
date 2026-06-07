# Shared disko layout — identical /dev/sda partitioning across all three nodes.
# Load-bearing: these machines have no fileSystems in hardware config; disko
# generates every mount (/, /boot, swap, longhorn data).
{
  disko.devices = {
    disk = {
      sda = {
        device = "/dev/sda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02"; # BIOS boot partition
            };
            ESP = {
              size = "512M";
              type = "EF00"; # EFI System Partition
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            swap = {
              size = "4G";
              content = {
                type = "swap";
                discardPolicy = "both";
              };
            };
            # Longhorn data dir. Partition key kept as `gluster` so the on-disk
            # partlabel (disk-sda-gluster) is unchanged on the live nodes — only
            # the mountpoint moves. xfs is Longhorn's recommended filesystem.
            gluster = {
              size = "100G";
              content = {
                type = "filesystem";
                format = "xfs";
                mountpoint = "/var/lib/longhorn";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
