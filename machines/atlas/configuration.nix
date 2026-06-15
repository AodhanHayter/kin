# atlas — EQ13 box. Roles (k3s server + monitoring + github-runners) are
# assigned by its inventory tags in clan.nix, not here. This file is just the
# machine's hardware + identity (auto-included by clan).
{ ... }:
{
  imports = [
    ../../modules/hardware/beelink-eq13
    ../../modules/storage/disko-eq13
  ];

  networking.hostName = "atlas";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.05";
}
