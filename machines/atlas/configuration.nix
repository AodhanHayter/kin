# atlas — k3s control-plane + gluster primary.
{
  imports = [
    ../../modules/roles/k3s-server
    ../../modules/services/github-runners
  ];

  networking.hostName = "atlas";

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "24.05";
}
