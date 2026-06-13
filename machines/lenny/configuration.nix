# lenny — Lenovo box, k3s agent + Longhorn. Non-EQ13 hardware, so it carries
# its own hardware scan + disko layout instead of the shared Beelink modules.
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/storage/disko-lenny
    ../../modules/roles/k3s-agent
    ../../modules/services/garage
  ];

  networking.hostName = "lenny";

  # UEFI box — boots systemd-boot (the EQ13 nodes use grub on BIOS).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "24.05";
}
