# apollo — k3s agent + gluster peer.
{
  imports = [
    ../../modules/k3s-agent.nix
  ];

  networking.hostName = "apollo";

  system.stateVersion = "24.05";
}
