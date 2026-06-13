# apollo — k3s agent + Longhorn storage node.
{ kin, ... }:
with kin;
{
  imports = [
    ../../modules/roles/k3s-agent
  ];

  networking.hostName = "apollo";

  kin.roles.k3s-agent = enabled;

  system.stateVersion = "24.05";
}
