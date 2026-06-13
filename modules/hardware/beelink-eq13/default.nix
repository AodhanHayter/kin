# Beelink EQ13 hardware profile. All three nodes are identical EQ13 boxes,
# so this is shared. Merges the nixos-generate-config output from snow with
# the BIOS/grub bootloader settings.
{
  config,
  lib,
  kin,
  modulesPath,
  ...
}:
with lib;
with kin;
let
  cfg = config.kin.hardware.beelink-eq13;
in
{
  # Hardware-scan profiles are imported unconditionally (this module is only
  # pulled in by the eq13-node suite, so non-EQ13 hosts never see it).
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  options.kin.hardware.beelink-eq13 = {
    enable = mkBoolOpt false "Whether this node is a Beelink EQ13 box.";
  };

  config = mkIf cfg.enable {
    boot.initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "usb_storage"
      "usbhid"
      "sd_mod"
    ];
    boot.initrd.kernelModules = [ ];
    boot.kernelModules = [ "kvm-intel" ];
    boot.extraModulePackages = [ ];

    # BIOS boot on /dev/sda (matches the disko EF02 BIOS-boot partition).
    boot.loader.grub = {
      enable = true;
      device = "/dev/sda";
      efiSupport = true;
      efiInstallAsRemovable = true;
    };

    hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
    hardware.enableRedistributableFirmware = lib.mkDefault true;
  };
}
