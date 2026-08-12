# kin/gen3 — Gen3 data-commons lab (portal, Fence, Arborist, Indexd, Sheepdog,
# Peregrine) deployed cluster-wide from the server via k3s' bundled
# helm-controller — same pattern as Longhorn/kube-prometheus-stack.
#
# DISPOSABLE LEARNING ENVIRONMENT. `global.dev = true` runs in-namespace
# PostgreSQL + Elasticsearch with persistence off (every restart loses the data)
# and `MOCK_AUTH` logs anyone in as user `test`. LAN/tailnet only — never put
# this behind kin/cloudflared.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/gen3";
  manifest.description = "Gen3 data commons (dev mode, mock auth) deployed into k3s from the server.";
  manifest.categories = [ "Science" ];

  roles.default = {
    description = "Ship the Gen3 lab from this server.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { pkgs, ... }:
          {
            # Traefik ingress (also opened by kin/monitoring; the lists merge).
            networking.firewall.allowedTCPPorts = [
              80
              443
            ];

            # mDNS alias so gen3.local resolves to atlas without a LAN DNS
            # server — same avahi-publish unit shape as grafana/prometheus.
            services.avahi.publish.userServices = true;
            systemd.services.avahi-alias-gen3 = {
              description = "mDNS alias gen3.local -> atlas";
              after = [ "avahi-daemon.service" ];
              requires = [ "avahi-daemon.service" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R gen3.local 10.10.3.100";
                Restart = "always";
                RestartSec = 5;
              };
            };

            services.k3s.manifests.gen3.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = "gen3";
              }
              {
                apiVersion = "helm.cattle.io/v1";
                kind = "HelmChart";
                metadata = {
                  name = "gen3";
                  namespace = "kube-system";
                };
                spec = {
                  repo = "https://helm.gen3.org";
                  chart = "gen3";
                  version = "0.3.84";
                  targetNamespace = "gen3";
                  # No ingress block: with global.dev the revproxy subchart emits
                  # a classless `revproxy-dev` Ingress on global.hostname, and
                  # traefik is the default IngressClass here. TLS is the chart's
                  # self-signed gen3-certs — expect the browser warning.
                  valuesContent = ''
                    global:
                      dev: true
                      hostname: gen3.local

                    # Chart default image (quay.io/cdis/data-portal:master) is
                    # the only current multi-arch build — data-portal-prebuilt:dev
                    # is arm64-only and crashloops here with "exec format error".
                    # Its default 4Gi memory request is for a busy commons;
                    # steady-state on this lab is ~45Mi.
                    portal:
                      resources:
                        requests:
                          cpu: "200m"
                          memory: "512Mi"

                    # Otherwise the ES StatefulSet claims a 30Gi longhorn volume.
                    elasticsearch:
                      persistence:
                        enabled: false

                    # Auto-login as user `test`. Keep this instance private.
                    fence:
                      FENCE_CONFIG:
                        MOCK_AUTH: true

                    # Workspace/analytic components — bring these back only once
                    # the core platform is stable.
                    ambassador:
                      enabled: false
                    hatchery:
                      enabled: false
                    manifestservice:
                      enabled: false
                    wts:
                      enabled: false
                    etl:
                      enabled: false
                    audit:
                      enabled: false
                  '';
                };
              }
            ];
          };
      };
  };
}
