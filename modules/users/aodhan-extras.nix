# Supplements the clan-core `users` service for aodhan. In clan-core 25.11 that
# service manages only the account, password and groups — uid, shell and SSH
# keys are set here and merged in. Attached via the instance's
# roles.default.extraModules in clan.nix.
{ pkgs, ... }:
{
  users.users.aodhan = {
    uid = 1000;
    shell = pkgs.fish;
    openssh.authorizedKeys.keys = import ../ssh-keys.nix;
  };
}
