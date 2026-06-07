# lenny disk layout — UEFI, two disks, by-id (stable across sd* reordering).
# Load-bearing: no fileSystems exist elsewhere; disko generates every mount.
#   SSD  -> ESP + swap + ext4 root (NixOS + Longhorn live data in /var/lib/longhorn)
#   HDD  -> ext4 /mnt/bulk (Longhorn backup target / cold + bulk data)
{
  disko.devices = {
    disk = {
      ssd = {
        device = "/dev/disk/by-id/ata-MKNSSDAT240GB-DX_MKN1244A0000143816";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00"; # EFI System Partition (UEFI boot, systemd-boot)
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = "8G";
              content = {
                type = "swap";
                discardPolicy = "both";
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
      bulk = {
        device = "/dev/disk/by-id/ata-ST1000LM024_HN-M101MBB_S2U5J9CCB89055";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/mnt/bulk";
              };
            };
          };
        };
      };
    };
  };
}
