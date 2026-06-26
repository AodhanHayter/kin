# MacBookPro11,5 (Intel, Mid-2015 15") hardware — the non-EQ13 analogue of
# modules/hardware/beelink-eq13. Pulls the nixos-hardware apple module (mbpfan
# fan/thermal control, Intel microcode, SSD trim, redistributable firmware, the
# XHC1 suspend-wake fix). Imported by machines/mbp AND the installer-mac ISO.
#
# Wifi: this unit's Broadcom chip (BCM43602, iface wlp4s0) runs on the in-kernel
# `brcmfmac` driver + redistributable firmware — confirmed against the live
# install before adopting the box. So NO proprietary broadcom_sta/`wl` and NO
# driver blacklist (forcing wl here would kill wifi on this headless node).
# `inputs` reaches here via the clan/nixosSystem specialArgs.
{ inputs, lib, ... }:
{
  imports = [ inputs.nixos-hardware.nixosModules.apple-macbook-pro-11-5 ];

  # Headless node / installer — no webcam, so skip the unfree facetimehd firmware
  # the apple module enables by default once allowUnfree is on.
  hardware.facetimehd.enable = lib.mkForce false;
}
