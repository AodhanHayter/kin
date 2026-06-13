# Baseline suite every kin cluster node imports (flake `baseCommon`): the
# always-on system/storage/secret modules plus Tailscale. Selection is by
# import (this has no off-state), so it carries no enable toggle of its own —
# it just pulls in the baseline modules and flips the toggled ones it wants on.
{ kin, ... }:
with kin;
{
  imports = [
    ../../system/common
    ../../storage/longhorn-host
    ../../secrets/k3s-token
    ../../services/tailscale
  ];

  kin.services.tailscale = enabled;
}
