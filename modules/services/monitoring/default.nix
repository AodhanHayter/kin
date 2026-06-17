# kin/monitoring — cluster observability: kube-prometheus-stack (Prometheus +
# Grafana + Alertmanager + node-exporter + kube-state-metrics + default
# dashboards), deployed cluster-wide from the server via k3s' bundled
# helm-controller — same pattern as Longhorn. Single role, applied only to the
# k3s-server (atlas), so the grafana-admin generator lives where it's consumed.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/monitoring";
  manifest.description = "kube-prometheus-stack deployed into k3s from the server.";
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Ship cluster-wide observability from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          {
            # Grafana admin password — consumed only here (server), so the
            # generator is scoped to this instance.
            clan.core.vars.generators.grafana-admin = {
              files."password".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -base64 24 | tr -d '\n' > "$out"/password
              '';
            };

            # k3s runs the whole control plane in one process with metrics
            # listeners bound to localhost; rebind them so Prometheus can scrape
            # from the pod network. etcd gets its own flag (http on 0.0.0.0:2381).
            services.k3s.extraFlags = [
              "--kube-controller-manager-arg=bind-address=0.0.0.0"
              "--kube-scheduler-arg=bind-address=0.0.0.0"
              "--etcd-expose-metrics=true"
            ];

            networking.firewall.allowedTCPPorts = [
              10257 # kube-controller-manager metrics (https)
              10259 # kube-scheduler metrics (https)
              2381 # etcd metrics (http)
              80 # traefik ingress (svclb) — grafana.local / prometheus.local
              443 # traefik ingress (svclb)
            ];

            # mDNS aliases for the ingress hostnames. Traefik routes on Host
            # header; these make grafana.local / prometheus.local resolve to
            # atlas without a LAN DNS server. avahi-publish blocks, so
            # Restart=always. avahi denies client entry groups unless
            # user-service publishing is on.
            services.avahi.publish.userServices = true;
            systemd.services =
              lib.genAttrs
                (map (n: "avahi-alias-${n}") [
                  "grafana"
                  "prometheus"
                ])
                (
                  unit:
                  let
                    name = lib.removePrefix "avahi-alias-" unit;
                  in
                  {
                    description = "mDNS alias ${name}.local -> atlas";
                    after = [ "avahi-daemon.service" ];
                    requires = [ "avahi-daemon.service" ];
                    wantedBy = [ "multi-user.target" ];
                    serviceConfig = {
                      ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R ${name}.local 10.10.3.100";
                      Restart = "always";
                      RestartSec = 5;
                    };
                  }
                )
              // {
                # Same pattern as longhorn-backup-credentials: secrets reach k8s
                # via kubectl at activation, never via manifests.
                grafana-admin-secret = {
                  description = "Sync Grafana admin credentials into a k8s Secret";
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
                    k3s kubectl create namespace monitoring --dry-run=client -o yaml \
                      | k3s kubectl apply -f -
                    k3s kubectl -n monitoring create secret generic grafana-admin \
                      --from-literal=admin-user=admin \
                      --from-file=admin-password=${
                        config.clan.core.vars.generators.grafana-admin.files."password".path
                      } \
                      --dry-run=client -o yaml | k3s kubectl apply -f -
                  '';
                };
              };

            services.k3s.manifests.monitoring.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = "monitoring";
              }
              {
                apiVersion = "helm.cattle.io/v1";
                kind = "HelmChart";
                metadata = {
                  name = "kube-prometheus-stack";
                  namespace = "kube-system";
                };
                spec = {
                  repo = "https://prometheus-community.github.io/helm-charts";
                  chart = "kube-prometheus-stack";
                  version = "86.2.2";
                  targetNamespace = "monitoring";
                  valuesContent = ''
                    grafana:
                      admin:
                        existingSecret: grafana-admin
                        userKey: admin-user
                        passwordKey: admin-password
                      ingress:
                        enabled: true
                        hosts: [grafana.local]
                      persistence:
                        enabled: true
                        size: 5Gi
                      # RWO Longhorn PVC — RollingUpdate would deadlock on multi-attach.
                      deploymentStrategy:
                        type: Recreate

                    prometheus:
                      ingress:
                        enabled: true
                        hosts: [prometheus.local]
                        paths: ["/"]
                      prometheusSpec:
                        retention: 15d
                        retentionSize: 25GB
                        storageSpec:
                          volumeClaimTemplate:
                            spec:
                              accessModes: [ReadWriteOnce]
                              resources:
                                requests:
                                  storage: 30Gi

                    # Control plane lives only on atlas (single k3s server); scrape it
                    # by node IP. Serving certs don't carry that IP as a SAN, hence
                    # insecureSkipVerify.
                    kubeControllerManager:
                      endpoints: [10.10.3.100]
                      serviceMonitor:
                        https: true
                        insecureSkipVerify: true
                    kubeScheduler:
                      endpoints: [10.10.3.100]
                      serviceMonitor:
                        https: true
                        insecureSkipVerify: true
                    kubeEtcd:
                      endpoints: [10.10.3.100]
                      service:
                        port: 2381
                        targetPort: 2381

                    # k3s' kube-proxy metrics stay localhost-only; not worth a flag on
                    # every node.
                    kubeProxy:
                      enabled: false
                  '';
                };
              }
            ];
          };
      };
  };
}
