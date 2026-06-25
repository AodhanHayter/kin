# kin/comin — GitOps pull-deploy on every node.
#
# comin (https://github.com/nlewo/comin) is Flux-for-NixOS: each machine polls
# this repo's git remote on a timer, builds its OWN nixosConfigurations.<host>
# (hostname == machine name in kin), and activates it. After a one-time bootstrap
# (`clan machines update <host>` once, to land this service), every later
# `git push` to the tracked branch auto-deploys cluster-wide — no more manual
# ssh deploys.
#
# Pull, read-only: comin never writes to the repo and needs no write access. The
# repo is PUBLIC, so no token/auth is configured. Transport is HTTPS — comin uses
# go-git and has no ssh-key auth option, so the https clone URL is used even
# though `git remote` is ssh.
#
# Branch semantics (per host):
#   - master            -> operation "switch": permanent, updates the bootloader.
#   - testing-<host>    -> operation "test"  : ephemeral, reverts on reboot.
# comin prefers testing over master. Push a commit (rebased on master) to
# `testing-<host>` to trial a config on one box live; fast-forward master onto it
# to promote.
#
# The comin NixOS module is NOT in nixpkgs; it comes from the `comin` flake input,
# imported below via the `inputs` specialArg (threaded by flake.nix:
# `specialArgs = { inherit inputs; }`). kin/comin is the first kin service to use
# that specialArg.
#
# NOTE: comin and `clan machines update` both run switch-to-configuration — once
# comin is live it is the primary deploy path; don't run both on one host at the
# same instant. `clan vars generate` stays a manual privileged step; comin only
# deploys already-committed vars (decrypted on-host at activation as usual).
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/comin";
  manifest.description = "GitOps pull-deploy: every node polls git and self-activates.";
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Poll the repo and deploy this machine's own config.";
    interface =
      { lib, ... }:
      {
        options.remoteUrl = lib.mkOption {
          type = lib.types.str;
          description = "HTTPS git URL comin polls (read-only).";
        };
        options.branch = lib.mkOption {
          type = lib.types.str;
          default = "master";
          description = "Production branch; commits here are switched (permanent).";
        };
      };
    perInstance =
      { settings, ... }:
      {
        nixosModule =
          { inputs, ... }:
          {
            imports = [ inputs.comin.nixosModules.comin ];

            services.comin = {
              enable = true;
              remotes = [
                {
                  name = "origin";
                  url = settings.remoteUrl;
                  branches.main.name = settings.branch;
                }
              ];
              # Expose the Prometheus exporter (:4243), scraped by
              # kube-prometheus-stack (kin/monitoring) via the k8s node list.
              # Blanket-opened like node-exporter's 9100 — VLAN4 isolation is the
              # boundary, consistent with every other metrics port in kin.
              exporter.openFirewall = true;
            };
          };
      };
  };
}
