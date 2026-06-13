# atlas — k3s control-plane + GitHub Actions runners.
{ kin, ... }:
with kin;
{
  imports = [
    ../../modules/roles/k3s-server
    ../../modules/services/github-runners
  ];

  networking.hostName = "atlas";

  kin.roles.k3s-server = enabled;
  kin.services.github-runners = enabled;

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.05";
}
