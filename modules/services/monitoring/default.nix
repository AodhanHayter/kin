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
                        # Scrape comin's exporter (:4243) on every node via the
                        # k8s node list — comin runs on all nodes (tags.all), so
                        # the node set IS the target set; no hardcoded IPs.
                        additionalScrapeConfigs:
                          - job_name: comin
                            kubernetes_sd_configs:
                              - role: node
                            scheme: http
                            metrics_path: /metrics
                            scrape_interval: 30s
                            relabel_configs:
                              - source_labels: [__meta_kubernetes_node_address_InternalIP]
                                target_label: __address__
                                replacement: "$1:4243"
                              - source_labels: [__meta_kubernetes_node_name]
                                target_label: instance

                    # comin GitOps health alerts. additionalPrometheusRulesMap is
                    # rendered to a PrometheusRule by the chart, so its ruleSelector
                    # picks them up. instance = node hostname (from the relabel above).
                    additionalPrometheusRulesMap:
                      comin:
                        groups:
                          - name: comin.rules
                            rules:
                              - alert: CominTargetDown
                                expr: up{job="comin"} == 0
                                for: 10m
                                labels:
                                  severity: warning
                                annotations:
                                  summary: "comin exporter down on {{ $labels.instance }}"
                                  description: "Prometheus can't scrape comin :4243 on {{ $labels.instance }} for 10m; deploy state unknown."
                              - alert: CominDeploymentFailed
                                expr: comin_last_deployment_failed == 1
                                for: 5m
                                labels:
                                  severity: critical
                                annotations:
                                  summary: "comin deployment FAILED on {{ $labels.instance }}"
                                  description: "switch-to-configuration failed on {{ $labels.instance }} (comin_last_deployment_failed=1)."
                              - alert: CominEvalOrBuildFailed
                                expr: (comin_last_eval_failed == 1) or (comin_last_build_failed == 1)
                                for: 15m
                                labels:
                                  severity: warning
                                annotations:
                                  summary: "comin eval/build failed on {{ $labels.instance }}"
                                  description: "Node not converging: comin_last_eval_failed or comin_last_build_failed =1 on {{ $labels.instance }} for 15m."
                              - alert: CominFetchFailed
                                expr: max by (instance) (comin_last_fetch_failed) == 1
                                for: 30m
                                labels:
                                  severity: warning
                                annotations:
                                  summary: "comin git fetch failing on {{ $labels.instance }}"
                                  description: "comin_last_fetch_failed=1 (remote unreachable) on {{ $labels.instance }} for 30m."
                              - alert: CominSuspended
                                expr: comin_is_suspended == 1
                                for: 1h
                                labels:
                                  severity: info
                                annotations:
                                  summary: "comin suspended on {{ $labels.instance }}"
                                  description: "Automatic deploys paused (comin_is_suspended=1) on {{ $labels.instance }} for 1h."
                              - alert: CominNeedReboot
                                expr: comin_need_to_reboot == 1
                                for: 6h
                                labels:
                                  severity: info
                                annotations:
                                  summary: "{{ $labels.instance }} needs reboot (comin)"
                                  description: "comin_need_to_reboot=1 for 6h on {{ $labels.instance }}; kernel/initrd change not active until reboot."

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
