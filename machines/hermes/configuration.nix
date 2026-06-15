# hermes — EQ13 box. Its k3s-agent role comes from the inventory tag in
# clan.nix; this file is just the machine's hardware + identity.
{ ... }:
{
  imports = [
    ../../modules/hardware/beelink-eq13
    ../../modules/storage/disko-eq13
  ];

  networking.hostName = "hermes";

  system.stateVersion = "24.05";
}
