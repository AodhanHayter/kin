# kin/cnpg — CloudNativePG operator: spin up production-shaped Postgres clusters
# on demand (one `Cluster` CR = primary + replicas + failover + PITR) to model
# real-world deployments. Deployed cluster-wide from the server via k3s'
# helm-controller, same pattern as Longhorn/monitoring. Single role on the
# k3s-server (atlas).
#
# The operator itself consumes no secrets at install. Per-Cluster app passwords
# are auto-minted by CNPG; barman-cloud PITR to Garage (the cnpg-backups bucket)
# is wired per-Cluster when you create one, reusing the shared garage-backup-key.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/cnpg";
  manifest.description = "CloudNativePG operator for on-demand Postgres clusters.";
  # "Database" is not in the clan-core 25.11 category enum; "System" is.
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Run the CloudNativePG operator from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { ... }:
          {
            services.k3s.manifests.cnpg.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = "cnpg-system";
              }
              # Single-replica Longhorn class for Postgres data: CNPG does HA at
              # the app layer (instances + synchronous replication) and PITR is
              # the durability backstop, so Longhorn's default 3x replication
              # would only add write latency. strict-local keeps the single
              # replica on the pod's node; WaitForFirstConsumer binds after the
              # pod is scheduled so locality holds.
              {
                apiVersion = "storage.k8s.io/v1";
                kind = "StorageClass";
                metadata.name = "cnpg-longhorn";
                provisioner = "driver.longhorn.io";
                allowVolumeExpansion = true;
                reclaimPolicy = "Delete";
                volumeBindingMode = "WaitForFirstConsumer";
                parameters = {
                  numberOfReplicas = "1";
                  dataLocality = "strict-local";
                  staleReplicaTimeout = "30";
                  fsType = "ext4";
                };
              }
              {
                apiVersion = "helm.cattle.io/v1";
                kind = "HelmChart";
                metadata = {
                  name = "cloudnative-pg";
                  namespace = "kube-system";
                };
                spec = {
                  repo = "https://cloudnative-pg.github.io/charts";
                  chart = "cloudnative-pg";
                  version = "0.29.0"; # operator appVersion 1.30.0
                  targetNamespace = "cnpg-system";
                  valuesContent = ''
                    crds:
                      create: true
                    # Scrape the operator into the existing kube-prometheus-stack.
                    # The stack's PodMonitor selector matches release=<chart name>,
                    # so the label is required or the PodMonitor is ignored.
                    monitoring:
                      podMonitorEnabled: true
                      podMonitorAdditionalLabels:
                        release: kube-prometheus-stack
                  '';
                };
              }
            ];
          };
      };
  };
}
