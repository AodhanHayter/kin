# Shared disko layout — identical /dev/sda partitioning across the EQ13 nodes.
# Load-bearing: these machines have no fileSystems in hardware config; disko
# generates every mount (/, /boot, swap, longhorn data).
#
# v2 (storage rebuild): root capped at 100G, Longhorn takes the remaining
# ~370G of the 477G disk (was a fixed 100G with the rest idle on /).
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
            root = {
              size = "100G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
            # Longhorn data — xfs is Longhorn's recommended filesystem.
            longhorn = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "xfs";
                mountpoint = "/var/lib/longhorn";
              };
            };
          };
        };
      };
    };
  };
}
