# GitHub Actions runners on the cluster via ARC (actions-runner-controller),
# deployed from the server through k3s' helm-controller — same pattern as
# Longhorn. One runner scale set per entry in `repos`; workflows target them
# with `runs-on: homelab-k3s`. Runners are ephemeral, scale 0->4, dind for docker.
#
# Auth is a classic PAT with `repo` scope, prompted once:
#   clan vars generate --generator github-runner-token
# A oneshot unit syncs it into the arc-runners namespace as a k8s Secret.
{ config, ... }:
let
  arcVersion = "0.14.2";
  chartRepo = "oci://ghcr.io/actions/actions-runner-controller-charts";
  secretName = "github-config-secret";

  # repo-level runner scale sets: <release-suffix> = <github repo url>
  repos = {
    kin = "https://github.com/AodhanHayter/kin";
  };

  tokenPath = config.clan.core.vars.generators.github-runner-token.files."token".path;

  namespaces =
    builtins.map
      (name: {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = name;
      })
      [
        "arc-systems"
        "arc-runners"
      ];

  controller = {
    apiVersion = "helm.cattle.io/v1";
    kind = "HelmChart";
    metadata = {
      name = "arc-controller";
      namespace = "kube-system";
    };
    spec = {
      chart = "${chartRepo}/gha-runner-scale-set-controller";
      version = arcVersion;
      targetNamespace = "arc-systems";
    };
  };

  scaleSets = builtins.attrValues (
    builtins.mapAttrs (name: url: {
      apiVersion = "helm.cattle.io/v1";
      kind = "HelmChart";
      metadata = {
        name = "arc-runners-${name}";
        namespace = "kube-system";
      };
      spec = {
        chart = "${chartRepo}/gha-runner-scale-set";
        version = arcVersion;
        targetNamespace = "arc-runners";
        valuesContent = ''
          githubConfigUrl: ${url}
          githubConfigSecret: ${secretName}
          runnerScaleSetName: homelab-k3s
          minRunners: 0
          maxRunners: 4
          containerMode:
            type: dind
        '';
      };
    }) repos
  );
in
{
  clan.core.vars.generators.github-runner-token = {
    prompts.token = {
      description = "GitHub classic PAT with `repo` scope (ARC runner registration)";
      type = "hidden";
      persist = true;
    };
  };

  services.k3s.manifests.github-runners.content = namespaces ++ [ controller ] ++ scaleSets;

  # The PAT can't live in a HelmChart manifest (nix store is world-readable),
  # so it is synced from the sops-decrypted var into a k8s Secret at boot.
  systemd.services.arc-github-token = {
    description = "Sync GitHub PAT into the arc-runners namespace";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" ];
    wants = [ "k3s.service" ];
    path = [ config.services.k3s.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      until k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
      k3s kubectl create namespace arc-runners --dry-run=client -o yaml \
        | k3s kubectl apply -f -
      k3s kubectl -n arc-runners create secret generic ${secretName} \
        --from-file=github_token=${tokenPath} \
        --dry-run=client -o yaml | k3s kubectl apply -f -
    '';
  };
}
