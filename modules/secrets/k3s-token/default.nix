# Shared k3s join token, generated once via clan vars and distributed to all
# nodes. This replaces the snow approach where agents read a manual sops
# secret but the server (clusterInit) never set a matching token — here the
# server and both agents reference the SAME generated token.
#
# Generate with: `clan vars generate`
{ pkgs, ... }:
{
  clan.core.vars.generators.k3s-token = {
    share = true; # one value, shared across atlas/apollo/hermes
    files."token".secret = true; # sops-encrypted, deployed to the machine
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl rand -hex 32 > "$out"/token
    '';
  };
}
