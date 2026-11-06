# kin/gl-trueup — HTS GL true-up web app (QBO vs Business Central; marimo)
# behind the Cloudflare Tunnel + Access. Source and image: the private
# FissioAI/hitech-data repo (Dockerfile, .github/workflows/image.yml,
# docs/gl-trueup.md).
#
# State lives on one Longhorn PVC mounted at /srv/data: the QBO/BC lake, mapping
# workbooks, report outputs, and tokens/ — the QBO realm IDs + refresh
# tokens. Intuit rotates refresh tokens on use, so they can't live in a
# sops/clan var (this unit would re-apply a stale one on every boot); the app
# writes the rotated token back to /srv/data/tokens itself.
#
# Static credentials are clan vars, prompted once:
#   clan vars generate atlas --generator gl-trueup
# and synced to the `gl-trueup-env` Secret by the gl-trueup-secrets oneshot.
# Secret changes don't restart the pod (envFrom is start-time):
#   kubectl -n gl-trueup rollout restart deploy/gl-trueup
#
# Image: set `imageDigest` on the instance in clan.nix from the hitech-data
# Image workflow run summary. While null, the Deployment is not applied.
#
# Exposure (Cloudflare, personal account; created with the `cf` CLI, not
# managed here):
#   * tunnel kin-homelab ingress rule gl-trueup.fissio.com ->
#       http://gl-trueup.gl-trueup.svc.cluster.local:80 (before the catch-all;
#       `cf tunnels config update` replaces ALL rules, so get + edit + put)
#   * proxied CNAME gl-trueup.fissio.com -> <tunnel id>.cfargotunnel.com
#   * Access app "gl-trueup": One-time PIN only, inline Allow policy
#     "HTS accountants" (email list). Its definition + runbook live in
#     hitech-data (deploy/cloudflare-access.json, docs/gl-trueup.md › Deploy;
#     private repo, so emails stay out of here). marimo run has no auth of
#     its own: never route the hostname without this app.
#
# Seeding tokens / reconnecting QBO: see "Deploy" in hitech-data's
# docs/gl-trueup.md.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/gl-trueup";
  manifest.description = "GL true-up web app (marimo) behind the Cloudflare Tunnel.";
  manifest.categories = [ "Utility" ];

  roles.default = {
    description = "Deploy the gl-trueup origin from this server.";
    interface =
      { lib, ... }:
      {
        options.imageDigest = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "sha256:0123…";
          description = "Digest of ghcr.io/fissioai/hitech-data to run; null skips the Deployment.";
        };
      };
    perInstance =
      { settings, ... }:
      {
        nixosModule =
          { config, lib, ... }:
          let
            namespace = "gl-trueup";
            gen = config.clan.core.vars.generators.gl-trueup;
            # ghcr-pull is declared by kin/data-commons (same server).
            ghcrToken = config.clan.core.vars.generators.ghcr-pull.files."token".path;
            deployment = {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = {
                name = "gl-trueup";
                inherit namespace;
              };
              spec = {
                replicas = 1;
                # RWO volume: the old pod must let go before the new one mounts it.
                strategy.type = "Recreate";
                selector.matchLabels.app = "gl-trueup";
                template = {
                  metadata.labels.app = "gl-trueup";
                  spec = {
                    automountServiceAccountToken = false;
                    imagePullSecrets = [ { name = "ghcr-pull"; } ];
                    securityContext = {
                      runAsNonRoot = true;
                      runAsUser = 1000;
                      runAsGroup = 1000;
                      fsGroup = 1000; # PVC writable by the app user
                      seccompProfile.type = "RuntimeDefault";
                    };
                    containers = [
                      {
                        name = "app";
                        image = "ghcr.io/fissioai/hitech-data@${settings.imageDigest}";
                        # HITECH_DATA_DIR=/srv and QBO_TOKEN_DIR=/srv/data/tokens come from the image.
                        env = [
                          {
                            name = "QBO_ENVIRONMENT";
                            value = "production";
                          }
                          {
                            name = "BC_ENVIRONMENT";
                            value = "production";
                          }
                        ];
                        envFrom = [ { secretRef.name = "gl-trueup-env"; } ];
                        ports = [ { containerPort = 2718; } ];
                        securityContext = {
                          allowPrivilegeEscalation = false;
                          capabilities.drop = [ "ALL" ];
                        };
                        volumeMounts = [
                          {
                            name = "data";
                            mountPath = "/srv/data";
                          }
                        ];
                        readinessProbe = {
                          httpGet = {
                            path = "/";
                            port = 2718;
                          };
                          periodSeconds = 10;
                        };
                      }
                    ];
                    volumes = [
                      {
                        name = "data";
                        persistentVolumeClaim.claimName = "gl-trueup-data";
                      }
                    ];
                  };
                };
              };
            };
          in
          {
            services.k3s.manifests.gl-trueup.content = [
              {
                apiVersion = "v1";
                kind = "Namespace";
                metadata.name = namespace;
              }
              {
                apiVersion = "v1";
                kind = "PersistentVolumeClaim";
                metadata = {
                  name = "gl-trueup-data";
                  inherit namespace;
                };
                spec = {
                  accessModes = [ "ReadWriteOnce" ];
                  resources.requests.storage = "5Gi";
                };
              }
              {
                apiVersion = "v1";
                kind = "Service";
                metadata = {
                  name = "gl-trueup";
                  inherit namespace;
                };
                spec = {
                  selector.app = "gl-trueup";
                  ports = [
                    {
                      port = 80;
                      targetPort = 2718;
                    }
                  ];
                };
              }
            ]
            ++ lib.optional (settings.imageDigest != null) deployment;

            clan.core.vars.generators.gl-trueup = {
              prompts =
                lib.genAttrs
                  [
                    "QBO_CLIENT_ID"
                    "QBO_CLIENT_SECRET"
                    "BC_TENANT_ID"
                    "BC_CLIENT_ID"
                    "BC_CLIENT_SECRET"
                  ]
                  (name: {
                    description = "gl-trueup ${name} (secretspec: hitech-data production)";
                    type = "hidden";
                    persist = true;
                  });
            };

            # Secrets reach k8s via kubectl at activation, never via manifests
            # (same pattern as data-commons-secrets).
            systemd.services.gl-trueup-secrets = {
              description =
                lib.warnIf (settings.imageDigest == null)
                  "gl-trueup: imageDigest is null; the Deployment is not applied. Set it from the hitech-data Image workflow summary."
                  "Sync gl-trueup credentials + GHCR pull secret into k8s";
              wantedBy = [ "multi-user.target" ];
              after = [ "k3s.service" ];
              wants = [ "k3s.service" ];
              path = [ config.services.k3s.package ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                Restart = "on-failure";
                RestartSec = 10;
              };
              script = ''
                set -euo pipefail
                export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                until k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
                k3s kubectl create namespace ${namespace} --dry-run=client -o yaml | k3s kubectl apply -f -
                k3s kubectl -n ${namespace} create secret generic gl-trueup-env \
                  ${
                    lib.concatMapStringsSep " " (n: "--from-literal=${n}=\"$(cat ${gen.files.${n}.path})\"") (
                      builtins.attrNames gen.prompts
                    )
                  } \
                  --dry-run=client -o yaml | k3s kubectl apply -f -
                k3s kubectl -n ${namespace} create secret docker-registry ghcr-pull \
                  --docker-server=ghcr.io --docker-username=aodhanhayter \
                  --docker-password="$(cat ${ghcrToken})" \
                  --dry-run=client -o yaml | k3s kubectl apply -f -
              '';
            };
          };
      };
  };
}
