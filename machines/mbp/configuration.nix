# mbp — Intel MacBookPro11,5 (Mid-2015 15"), non-EQ13. Carries its own hardware
# scan + disko + the shared macbook-pro-11-5 hardware module. Its k3s-agent role
# is assigned by inventory in clan.nix; it joins on the cluster VLAN over a USB
# ethernet dongle (its switch port is tagged onto VLAN4 in UniFi).
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/storage/disko-mbp
    ../../modules/hardware/macbook-pro-11-5
  ];

  networking.hostName = "mbp";

  # Mac EFI. systemd-boot + NVRAM writes are confirmed working on this exact box
  # (the prior NixOS install booted this way), so match it.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Headless homelab node — closing the lid must not suspend it.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  system.stateVersion = "24.05";
}
