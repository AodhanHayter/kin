# atlas — k3s control-plane + gluster primary.
{
  imports = [
    ../../modules/k3s-server.nix
    ../../modules/github-runners.nix
  ];

  networking.hostName = "atlas";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.05";
}
