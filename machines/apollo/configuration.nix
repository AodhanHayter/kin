# apollo — k3s agent + gluster peer.
{
  imports = [
    ../../modules/roles/k3s-agent
  ];

  networking.hostName = "apollo";

  system.stateVersion = "24.05";
}
