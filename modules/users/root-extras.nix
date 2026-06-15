# Supplements the clan-core `users` service for root: clan deploys over root@
# key-only, so root's authorized keys are load-bearing. The users service owns
# the account/password; the deploy keys are set here and merged in. Attached via
# the user-root instance's roles.default.extraModules in clan.nix.
{ ... }:
{
  users.users.root.openssh.authorizedKeys.keys = import ../ssh-keys.nix;
}
