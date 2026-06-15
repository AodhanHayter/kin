# lenny — Lenovo box (non-EQ13), so it carries its own hardware scan + disko
# layout instead of the shared Beelink modules. Its k3s-agent role and the
# Garage backup target are assigned by inventory in clan.nix.
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/storage/disko-lenny
  ];

  networking.hostName = "lenny";

  # UEFI box — boots systemd-boot (the EQ13 nodes use grub on BIOS).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  system.stateVersion = "24.05";
}
