# k3s control-plane node (atlas). Initializes the embedded-etcd HA cluster.
{ config, pkgs, ... }:
{
  imports = [ ./k3s-common.nix ];

  # Server-only ports (agents dial out; they listen on none of these).
  networking.firewall.allowedTCPPorts = [
    6443 # k3s API server
    2379 # etcd clients
    2380 # etcd peers
  ];

  # Bare `kubectl` for root on the server (agents have no credentials).
  environment.systemPackages = [ pkgs.kubectl ];
  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

  services.k3s = {
    enable = true;
    role = "server";
    clusterInit = true;
    tokenFile = config.clan.core.vars.generators.k3s-token.files."token".path;

    # Extra names on the API serving cert so kubectl works from the Mac
    # (LAN via mDNS name, anywhere via tailnet name).
    extraFlags = [
      "--tls-san=atlas.local"
      "--tls-san=atlas.tail30507a.ts.net"
    ];

    # Longhorn is the storage layer; drop k3s' bundled local-path provisioner so
    # there is a single default StorageClass (longhorn) instead of two.
    disable = [ "local-storage" ];

    # Longhorn, deployed cluster-wide from the server via k3s' bundled
    # helm-controller. defaultDataPath matches the disko xfs mount; replica-3
    # spreads each volume across atlas/apollo/hermes.
    manifests.longhorn.content = [
      {
        apiVersion = "v1";
        kind = "Namespace";
        metadata.name = "longhorn-system";
      }
      {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChart";
        metadata = {
          name = "longhorn";
          namespace = "kube-system";
        };
        spec = {
          repo = "https://charts.longhorn.io";
          chart = "longhorn";
          version = "1.12.0";
          targetNamespace = "longhorn-system";
          valuesContent = ''
            defaultSettings:
              defaultDataPath: /var/lib/longhorn
              defaultReplicaCount: 3
            persistence:
              defaultClass: true
              defaultClassReplicaCount: 3
          '';
        };
      }
    ];
  };
}
