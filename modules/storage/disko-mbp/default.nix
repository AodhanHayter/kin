# mbp disk layout — Intel MacBookPro11,5, single internal SSD, UEFI/systemd-boot.
# Load-bearing like disko-lenny: no fileSystems exist anywhere else, disko
# generates every mount. Single disk → ESP + swap + root (ext4, rest). No
# dedicated Longhorn partition: mbp joins over wifi and is a compute agent, not a
# Longhorn storage replica (replicating volumes over wifi is a bad idea).
#
# Device id read off the live install (the internal 512G Apple SSD).
{
  disko.devices.disk.main = {
    device = "/dev/disk/by-id/ata-APPLE_SSD_SM0512G_S29ANYBG444677";
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
}
