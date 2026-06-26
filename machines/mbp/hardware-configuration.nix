# mbp hardware scan — derived from the live MacBookPro11,5 install
# (nixos-generate-config), with fileSystems/swap stripped because disko owns
# every mount (see modules/storage/disko-mbp). The broadcom-43xx import +
# brcmfmac (in-kernel) + redistributable firmware are what drive the wlp4s0 wifi.
{
  config,
  lib,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/hardware/network/broadcom-43xx.nix")
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
