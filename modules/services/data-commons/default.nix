# kin/data-commons — the data-commons platform (github.com/FissioAI/
# data-commons), deployed from the server through k3s' helm-controller as an
# OCI chart. Replaces the old kin/fissio deployment (the unit cleans up its
# HelmChart, namespace, and chart-auth secret on first run).
#
# The chart is app-only (Deployment + Service + Ingress); everything else is
# this module's job (kin/cnpg provides the CNPG operator and the
# cnpg-longhorn storage class):
#   * three CNPG Clusters: data-commons-pg (app), keycloak-pg, openfga-pg —
#     CNPG auto-mints each cluster's `<name>-app` credentials secret;
#   * Keycloak (production mode, postgres-backed, realm imported from a
#     templated JSON) behind traefik at keycloak.local;
#   * OpenFGA (postgres datastore, preshared-key authn) as a cluster-internal
#     service only;
#   * the data-commons-secrets oneshot that composes every k8s secret from
#     CNPG credentials + clan vars, applies the companion workloads, and
#     applies the app HelmChart LAST (never via manifests auto-deploy, which
#     would let helm-controller race the secrets).
#
# Both GHCR packages (image + chart) are private. Auth is a classic PAT named
# `kin-ghcr-pull` with only the `read:packages` scope (same generator name as
# the old fissio module, so the existing var is reused):
#   clan vars generate atlas --generator ghcr-pull
# New secret material for Keycloak/OpenFGA is minted with:
#   clan vars generate atlas
#
# Object storage (release >= 0.3.0 RAISES at boot without it): the app talks
# to Garage on lenny (kin/garage) at http://10.10.3.42:3900, bucket
# `data-commons`, region `garage`, with the shared data-commons-s3 key from
# kin/secrets. lenny's garage-provision oneshot creates that bucket, imports
# the same key with read/write/owner, and sets the CORS rule the browser
# presigned PUT needs. Optional knobs (OBJECT_GUID_PREFIX, S3_PRESIGN_TTL,
# S3_PRESIGN_MAX_TTL, S3_MAX_HASH_BYTES) are left at their app defaults.
#
# LAN exposure: data-commons.local + keycloak.local via avahi aliases ->
# atlas -> traefik. In-cluster, coredns pins data-commons.local to atlas and
# rewrites keycloak.local straight to the keycloak Service, so app pods reach
# the OIDC issuer under the exact browser-visible URL.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/data-commons";
  manifest.description = "data-commons platform deployed into k3s from the server.";
  manifest.categories = [ "Development" ];

  roles.default = {
    description = "Deploy the data-commons chart + CNPG database from this server.";
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
          let
            # ── app release pin ──────────────────────────────────────────
            # Bumping the app release means changing ONLY these two lines:
            # the chart version from Chart.yaml and the image digest printed
            # in the release workflow's run summary.
            #
            # Set imageDigest = null to stage a chart bump before its image
            # exists: the secrets oneshot SKIPS applying the HelmChart while
            # it is null (see "data-commons HelmChart" below) instead of
            # pinning a bogus digest that comin would auto-apply into an
            # ImagePullBackOff; the env/companion wiring still converges.
            chartVersion = "0.5.0";
            imageDigest = "sha256:312fa3dd09568b736be15d465cd65bd85561e6a1870c1ee7f8bb837909c718c9";

            # Companion image pins (update deliberately, they are decoupled
            # from app releases).
            keycloakImage = "quay.io/keycloak/keycloak:26.7.3@sha256:ff4257d0d64efbe99ed1ddfaf07765cc3c36dc7518bf8324d41961327f441c54";
            openfgaImage = "openfga/openfga:v1.19.0@sha256:78d1fa601d42340ecb131305d80d3767d0f254f9b1bc3646f9a557e11b24c63a";

            atlasIp = "10.10.3.100";

            # Garage (kin/garage) lives on lenny. Addressed by LAN IP, not
            # `lenny.local`: pods can't resolve mDNS (same reason Longhorn's
            # AWS_ENDPOINTS and the etcd-s3 config use the raw IP), and the
            # host in a presigned URL is part of the signature — so the app
            # pods and the LAN browser that follows the presigned PUT/GET must
            # use the exact same authority. A raw LAN IP satisfies both.
            garageEndpoint = "http://10.10.3.42:3900";
            s3Bucket = "data-commons";
            s3Region = "garage";

            s3Gen = config.clan.core.vars.generators.data-commons-s3;

            # Stable admin subject: the realm import pins the dc-admin user's
            # UUID (see realm-data-commons.json), so the app's admin-subs env
            # can reference it verbatim.
            adminSub = "a2f0c3d4-5e6b-4a7c-8d9e-0f1a2b3c4d5e";

            envGen = config.clan.core.vars.generators.data-commons-env;
            kcGen = config.clan.core.vars.generators.data-commons-keycloak;
            fgaGen = config.clan.core.vars.generators.data-commons-fga;

            # Keycloak realm import template. Checked into the store — it
            # holds only @PORTAL_CLIENT_SECRET@ / @USER_PASSWORD@ tokens, the
            # secrets are sed-substituted at activation by the oneshot.
            #
            # Users (data-commons-kfb.1): dc-admin plus the four demo
            # personas steward.grid, analyst.plant, viewer.org and outsider.
            # All five share the one user-password var. Their UUIDs are
            # PINNED here because the app's OpenFGA seed manifest
            # (priv/seed/authz.json in the data-commons repo) grants tuples
            # to those literal subjects — the realm import is the only
            # Keycloak path that honours a supplied user id, so these UUIDs
            # and that manifest must be changed together or the personas log
            # in holding no permissions. AUTHZ_ADMIN_SUBS (below) still owns
            # dc-admin's org-admin grant; the manifest deliberately does not.
            #
            # --import-realm semantics: Keycloak imports at every startup but
            # SKIPS realms that already exist, so restarts are no-ops — and
            # later edits to this template will NOT reach a live realm.
            # Post-first-boot realm changes need kcadm/admin-console, or a
            # realm delete + pod restart (sessions lost; the pinned user UUID
            # survives reimport). The four personas were ADDED after first
            # boot, so a live realm needs exactly that delete + restart
            # before they exist.
            realmTemplate = ./realm-data-commons.json;

            # CNPG database cluster. postInitSQL grants CREATEROLE: the app
            # login role doubles as the migration role and D3 migrations
            # create per-module NOLOGIN roles.
            pgCluster = pkgs.writeText "data-commons-pg.json" (
              builtins.toJSON {
                apiVersion = "postgresql.cnpg.io/v1";
                kind = "Cluster";
                metadata = {
                  name = "data-commons-pg";
                  namespace = "data-commons";
                };
                spec = {
                  instances = 1;
                  storage = {
                    storageClass = "cnpg-longhorn";
                    size = "5Gi";
                  };
                  bootstrap.initdb = {
                    database = "data_commons";
                    owner = "data_commons";
                    postInitSQL = [ "ALTER ROLE data_commons WITH CREATEROLE" ];
                  };
                };
              }
            );

            # Keycloak's own database — a separate tiny CNPG Cluster keeps
            # the app DB's blast radius untouched and auto-mints
            # keycloak-pg-app (jdbc-uri/username/password keys).
            keycloakPgCluster = pkgs.writeText "keycloak-pg.json" (
              builtins.toJSON {
                apiVersion = "postgresql.cnpg.io/v1";
                kind = "Cluster";
                metadata = {
                  name = "keycloak-pg";
                  namespace = "data-commons";
                };
                spec = {
                  instances = 1;
                  storage = {
                    storageClass = "cnpg-longhorn";
                    size = "2Gi";
                  };
                  bootstrap.initdb = {
                    database = "keycloak";
                    owner = "keycloak";
                  };
                };
              }
            );

            # OpenFGA's database — in-memory is forbidden (state would die
            # with the pod), postgres datastore is mandatory.
            openfgaPgCluster = pkgs.writeText "openfga-pg.json" (
              builtins.toJSON {
                apiVersion = "postgresql.cnpg.io/v1";
                kind = "Cluster";
                metadata = {
                  name = "openfga-pg";
                  namespace = "data-commons";
                };
                spec = {
                  instances = 1;
                  storage = {
                    storageClass = "cnpg-longhorn";
                    size = "1Gi";
                  };
                  bootstrap.initdb = {
                    database = "openfga";
                    owner = "openfga";
                  };
                };
              }
            );

            # Keycloak workload: production mode ("start"), http-only behind
            # traefik, postgres-backed, realm imported on first boot from the
            # keycloak-realm-import secret. Secrets ride the keycloak-env
            # secret (composed by the oneshot); only non-secret config is
            # inlined here. KC_HOSTNAME uses the full-URL form so the issuer
            # is exactly http://keycloak.local/realms/data-commons for both
            # LAN browsers and in-cluster pods (coredns rewrite below).
            keycloakManifest = pkgs.writeText "keycloak.json" (
              builtins.toJSON {
                apiVersion = "v1";
                kind = "List";
                items = [
                  {
                    apiVersion = "apps/v1";
                    kind = "Deployment";
                    metadata = {
                      name = "keycloak";
                      namespace = "data-commons";
                      labels.app = "keycloak";
                    };
                    spec = {
                      # Keep replicas=1: Keycloak clustering buys nothing
                      # here, and a single writer keeps --import-realm simple.
                      replicas = 1;
                      selector.matchLabels.app = "keycloak";
                      template = {
                        metadata.labels.app = "keycloak";
                        spec = {
                          containers = [
                            {
                              name = "keycloak";
                              image = keycloakImage;
                              args = [
                                "start"
                                "--import-realm"
                              ];
                              envFrom = [ { secretRef.name = "keycloak-env"; } ];
                              env = [
                                {
                                  name = "KC_HOSTNAME";
                                  value = "http://keycloak.local";
                                }
                                {
                                  name = "KC_HTTP_ENABLED";
                                  value = "true";
                                }
                                {
                                  name = "KC_PROXY_HEADERS";
                                  value = "xforwarded";
                                }
                                {
                                  name = "KC_HEALTH_ENABLED";
                                  value = "true";
                                }
                              ];
                              ports = [
                                {
                                  name = "http";
                                  containerPort = 8080;
                                }
                                {
                                  name = "mgmt";
                                  containerPort = 9000;
                                }
                              ];
                              startupProbe = {
                                httpGet = {
                                  path = "/health/started";
                                  port = 9000;
                                };
                                periodSeconds = 5;
                                failureThreshold = 90;
                              };
                              readinessProbe = {
                                httpGet = {
                                  path = "/health/ready";
                                  port = 9000;
                                };
                                periodSeconds = 10;
                              };
                              livenessProbe = {
                                httpGet = {
                                  path = "/health/live";
                                  port = 9000;
                                };
                                periodSeconds = 30;
                              };
                              volumeMounts = [
                                {
                                  name = "realm-import";
                                  mountPath = "/opt/keycloak/data/import";
                                  readOnly = true;
                                }
                              ];
                            }
                          ];
                          volumes = [
                            {
                              name = "realm-import";
                              secret.secretName = "keycloak-realm-import";
                            }
                          ];
                        };
                      };
                    };
                  }
                  {
                    apiVersion = "v1";
                    kind = "Service";
                    metadata = {
                      name = "keycloak";
                      namespace = "data-commons";
                      labels.app = "keycloak";
                    };
                    spec = {
                      selector.app = "keycloak";
                      # Service port 80: in-cluster callers hit
                      # http://keycloak.local (implicit :80) after the
                      # coredns rewrite to this Service, so it must answer
                      # on 80. Traefik reaches it through the Ingress below.
                      ports = [
                        {
                          name = "http";
                          port = 80;
                          targetPort = 8080;
                        }
                      ];
                    };
                  }
                  {
                    apiVersion = "networking.k8s.io/v1";
                    kind = "Ingress";
                    metadata = {
                      name = "keycloak";
                      namespace = "data-commons";
                    };
                    spec.rules = [
                      {
                        host = "keycloak.local";
                        http.paths = [
                          {
                            path = "/";
                            pathType = "Prefix";
                            backend.service = {
                              name = "keycloak";
                              port.number = 80;
                            };
                          }
                        ];
                      }
                    ];
                  }
                ];
              }
            );

            # OpenFGA workload: postgres datastore, preshared-key authn,
            # cluster-internal only (no ingress). The migrate initContainer
            # runs the datastore migrations before every start (idempotent).
            # Store/model/admin-tuple bootstrap is NOT here — the app's
            # authz-bootstrap initContainer (chart >= 0.2.0) owns that.
            openfgaManifest = pkgs.writeText "openfga.json" (
              builtins.toJSON {
                apiVersion = "v1";
                kind = "List";
                items = [
                  {
                    apiVersion = "apps/v1";
                    kind = "Deployment";
                    metadata = {
                      name = "openfga";
                      namespace = "data-commons";
                      labels.app = "openfga";
                    };
                    spec = {
                      replicas = 1;
                      selector.matchLabels.app = "openfga";
                      template = {
                        metadata.labels.app = "openfga";
                        spec = {
                          initContainers = [
                            {
                              name = "migrate";
                              image = openfgaImage;
                              args = [ "migrate" ];
                              envFrom = [ { secretRef.name = "openfga-env"; } ];
                            }
                          ];
                          containers = [
                            {
                              name = "openfga";
                              image = openfgaImage;
                              args = [ "run" ];
                              envFrom = [ { secretRef.name = "openfga-env"; } ];
                              env = [
                                {
                                  name = "OPENFGA_PLAYGROUND_ENABLED";
                                  value = "false";
                                }
                              ];
                              ports = [
                                {
                                  name = "http";
                                  containerPort = 8080;
                                }
                                {
                                  name = "grpc";
                                  containerPort = 8081;
                                }
                              ];
                              readinessProbe = {
                                httpGet = {
                                  path = "/healthz";
                                  port = 8080;
                                };
                                periodSeconds = 10;
                              };
                              # Readiness alone only drops a wedged process
                              # from Endpoints; liveness restarts it.
                              livenessProbe = {
                                httpGet = {
                                  path = "/healthz";
                                  port = 8080;
                                };
                                initialDelaySeconds = 30;
                                periodSeconds = 30;
                              };
                            }
                          ];
                        };
                      };
                    };
                  }
                  {
                    apiVersion = "v1";
                    kind = "Service";
                    metadata = {
                      name = "openfga";
                      namespace = "data-commons";
                      labels.app = "openfga";
                    };
                    spec = {
                      selector.app = "openfga";
                      ports = [
                        {
                          name = "http";
                          port = 8080;
                          targetPort = 8080;
                        }
                      ];
                    };
                  }
                ];
              }
            );

            # Applied by data-commons-secrets after the namespace + pull
            # secrets exist — never via k3s manifests auto-deploy, which would
            # race helm-controller against the secrets unit.
            helmChart = pkgs.writeText "data-commons-helmchart.json" (
              builtins.toJSON {
                apiVersion = "helm.cattle.io/v1";
                kind = "HelmChart";
                metadata = {
                  name = "data-commons";
                  namespace = "kube-system";
                };
                spec = {
                  chart = "oci://ghcr.io/fissioai/charts/data-commons";
                  version = chartVersion;
                  targetNamespace = "data-commons";
                  dockerRegistrySecret.name = "data-commons-chart-auth";
                  valuesContent = ''
                    image:
                      digest: ${imageDigest}
                    imagePullSecrets:
                      - name: ghcr-pull
                    existingSecret: data-commons-env
                    env:
                      phxHost: data-commons.local
                    ingress:
                      enabled: true
                      host: data-commons.local
                    # Seeds staging personas' data (data-commons-kfb.3). The
                    # post-install/post-upgrade hook Job is idempotent, safe
                    # to leave on across upgrades; reset with:
                    #   kubectl exec deploy/data-commons -c app -- \
                    #     /app/bin/data_commons rpc "DataCommons.Seed.reset()"
                    seed:
                      enabled: true
                  '';
                };
              }
            );
          in
          {
            # GHCR pull token — same generator name as the old fissio module,
            # so the already-prompted var on atlas carries over.
            clan.core.vars.generators.ghcr-pull = {
              prompts.token = {
                description = "GitHub classic PAT `kin-ghcr-pull` (read:packages) for ghcr.io pulls";
                type = "hidden";
                persist = true;
              };
            };

            # App secrets. DATABASE_URL is composed at activation from CNPG's
            # auto-minted credentials; only SECRET_KEY_BASE is minted here.
            clan.core.vars.generators.data-commons-env = {
              files."secret-key-base".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -base64 48 | tr -d '\n' > "$out"/secret-key-base
              '';
            };

            # Keycloak secret material: bootstrap admin password, the
            # data-commons-portal client secret, and the dc-admin user
            # password. hex output is sed/JSON/URL-safe for the realm
            # templating.
            clan.core.vars.generators.data-commons-keycloak = {
              files."admin-password".secret = true;
              files."portal-client-secret".secret = true;
              files."user-password".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -hex 24 | tr -d '\n' > "$out"/admin-password
                openssl rand -hex 24 | tr -d '\n' > "$out"/portal-client-secret
                openssl rand -hex 24 | tr -d '\n' > "$out"/user-password
              '';
            };

            # OpenFGA preshared API token (defense-in-depth on the
            # cluster-internal endpoint; the app sends it as FGA_API_TOKEN).
            clan.core.vars.generators.data-commons-fga = {
              files."api-token".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -hex 32 | tr -d '\n' > "$out"/api-token
              '';
            };

            services.k3s.manifests.data-commons.content = [
              # In-cluster DNS for the LAN names (pods can't resolve mDNS).
              # Single writer: this ConfigMap is owned by the data-commons
              # Addon — every data-commons entry MUST live in this one
              # manifest, never a second module.
              #
              #  * data-commons.local -> hosts pin at atlas (same traefik
              #    front door as browsers).
              #  * keycloak.local -> rewrite straight to the keycloak
              #    Service instead of a node-IP hairpin through traefik's
              #    hostPort. The *.override file is imported inside the
              #    default `.:53` block, so the kubernetes plugin answers
              #    with the ClusterIP; CoreDNS auto-reverts exact name
              #    rewrites in the response. The issuer stays byte-identical
              #    (http://keycloak.local) because KC_HOSTNAME pins it and
              #    the Service listens on port 80.
              {
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "coredns-custom";
                  namespace = "kube-system";
                };
                data."data-commons-hosts.server" = ''
                  data-commons.local {
                    hosts {
                      ${atlasIp} data-commons.local
                    }
                  }
                '';
                data."data-commons-keycloak.override" = ''
                  rewrite name exact keycloak.local keycloak.data-commons.svc.cluster.local
                '';
              }
            ];

            systemd.services = {
              # mDNS aliases so LAN browsers reach traefik on atlas.
              avahi-alias-data-commons = {
                description = "mDNS alias data-commons.local -> atlas";
                after = [ "avahi-daemon.service" ];
                requires = [ "avahi-daemon.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R data-commons.local ${atlasIp}";
                  Restart = "always";
                  RestartSec = 5;
                };
              };

              avahi-alias-keycloak = {
                description = "mDNS alias keycloak.local -> atlas";
                after = [ "avahi-daemon.service" ];
                requires = [ "avahi-daemon.service" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R keycloak.local ${atlasIp}";
                  Restart = "always";
                  RestartSec = 5;
                };
              };

              # Secrets reach k8s via kubectl at activation, never via
              # manifests (same pattern as the old fissio-secrets unit).
              # Ordering: namespace -> CNPG clusters -> app env + pull
              # secrets -> app HelmChart -> companions (keycloak/openfga).
              # The app path (S0) comes FIRST and waits on nothing but its
              # own database, so a stuck companion can never block deploying
              # or repairing the app; the companion steps are bounded and
              # warn-and-retry (nonzero exit at the end -> Restart=on-failure
              # reruns the idempotent script). Every step is `apply` or
              # `create --dry-run | apply`. Note: secret-content changes
              # alone do NOT restart running pods (envFrom is start-time) —
              # pair them with a digest bump or `kubectl rollout restart`.
              data-commons-secrets = {
                description = "Sync data-commons DBs, companions, app env + GHCR credentials into k8s";
                wantedBy = [ "multi-user.target" ];
                after = [ "k3s.service" ];
                wants = [ "k3s.service" ];
                path = [ config.services.k3s.package ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  Restart = "on-failure";
                  RestartSec = 10;
                  TimeoutStartSec = 0;
                };
                script = ''
                  set -euo pipefail
                  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                  step() { echo "data-commons-secrets: $1"; }

                  until k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done

                  step "cleaning up old fissio deployment"
                  k3s kubectl delete helmchart fissio -n kube-system --ignore-not-found
                  k3s kubectl delete namespace fissio --ignore-not-found --wait=false
                  k3s kubectl delete secret fissio-chart-auth -n kube-system --ignore-not-found

                  step "namespace"
                  k3s kubectl create namespace data-commons --dry-run=client -o yaml \
                    | k3s kubectl apply -f -

                  step "waiting for CNPG operator CRD"
                  until k3s kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; do sleep 5; done

                  step "CNPG clusters"
                  k3s kubectl apply -f ${pgCluster}
                  k3s kubectl apply -f ${keycloakPgCluster}
                  k3s kubectl apply -f ${openfgaPgCluster}

                  step "waiting for app CNPG credentials"
                  until k3s kubectl -n data-commons get secret data-commons-pg-app >/dev/null 2>&1; do sleep 5; done

                  step "data-commons-env secret"
                  pgsec() { k3s kubectl -n data-commons get secret data-commons-pg-app -o jsonpath="{.data.$1}" | base64 -d; }
                  db_url="ecto://$(pgsec username):$(pgsec password)@$(pgsec host):$(pgsec port)/$(pgsec dbname)"
                  k3s kubectl -n data-commons create secret generic data-commons-env \
                    --from-literal=DATABASE_URL="$db_url" \
                    --from-file=SECRET_KEY_BASE=${envGen.files."secret-key-base".path} \
                    --from-literal=KEYCLOAK_URL=http://keycloak.local \
                    --from-literal=OIDC_ALLOW_INSECURE=true \
                    --from-literal=PHX_SCHEME=http \
                    --from-file=KEYCLOAK_PORTAL_CLIENT_SECRET=${kcGen.files."portal-client-secret".path} \
                    --from-literal=FGA_API_URL=http://openfga.data-commons.svc.cluster.local:8080 \
                    --from-file=FGA_API_TOKEN=${fgaGen.files."api-token".path} \
                    --from-literal=AUTHZ_ADMIN_SUBS=${adminSub} \
                    --from-literal=S3_ENDPOINT=${garageEndpoint} \
                    --from-file=S3_ACCESS_KEY_ID=${s3Gen.files."access-key-id".path} \
                    --from-file=S3_SECRET_ACCESS_KEY=${s3Gen.files."secret-access-key".path} \
                    --from-literal=S3_BUCKET=${s3Bucket} \
                    --from-literal=S3_REGION=${s3Region} \
                    --dry-run=client -o yaml | k3s kubectl apply -f -

                  # GHCR auth, twice: pods pull the image from the app
                  # namespace; helm-controller pulls the chart from the CR's
                  # namespace (kube-system).
                  token=$(cat ${config.clan.core.vars.generators.ghcr-pull.files."token".path})
                  step "ghcr pull secrets"
                  k3s kubectl -n data-commons create secret docker-registry ghcr-pull \
                    --docker-server=ghcr.io --docker-username=aodhanhayter \
                    --docker-password="$token" \
                    --dry-run=client -o yaml | k3s kubectl apply -f -
                  k3s kubectl -n kube-system create secret docker-registry data-commons-chart-auth \
                    --docker-server=ghcr.io --docker-username=aodhanhayter \
                    --docker-password="$token" \
                    --dry-run=client -o yaml | k3s kubectl apply -f -

                  # HelmChart CR now: namespace + data-commons-env + both
                  # pull secrets exist and helm-controller depends on nothing
                  # else — deliberately BEFORE the companions so a stuck
                  # keycloak/openfga can never block deploying or repairing
                  # the app (S0). Still never via manifests auto-deploy.
                  ${
                    if imageDigest == null then
                      ''
                        step "warn: imageDigest is a placeholder (set it from the v0.3.0 release run summary); skipping the HelmChart apply"
                      ''
                    else
                      ''
                        step "data-commons HelmChart"
                        k3s kubectl apply -f ${helmChart}
                      ''
                  }

                  # ── companions (non-fatal for the app path) ──────────────
                  companions_ok=1

                  step "waiting for companion CNPG credentials (bounded)"
                  for s in keycloak-pg-app openfga-pg-app; do
                    for _ in $(seq 1 120); do
                      k3s kubectl -n data-commons get secret "$s" >/dev/null 2>&1 && break
                      sleep 5
                    done
                  done

                  kc_applied=0
                  if k3s kubectl -n data-commons get secret keycloak-pg-app >/dev/null 2>&1; then
                    step "keycloak-env secret"
                    kcsec() { k3s kubectl -n data-commons get secret keycloak-pg-app -o jsonpath="{.data.$1}" | base64 -d; }
                    # KC_DB_URL carries no credentials — they ride
                    # KC_DB_USERNAME/KC_DB_PASSWORD, keeping the DB password
                    # off kubectl argv and out of logged datasource URLs.
                    k3s kubectl -n data-commons create secret generic keycloak-env \
                      --from-literal=KC_DB=postgres \
                      --from-literal=KC_DB_URL="jdbc:postgresql://$(kcsec host):$(kcsec port)/$(kcsec dbname)" \
                      --from-literal=KC_DB_USERNAME="$(kcsec username)" \
                      --from-literal=KC_DB_PASSWORD="$(kcsec password)" \
                      --from-literal=KC_BOOTSTRAP_ADMIN_USERNAME=admin \
                      --from-file=KC_BOOTSTRAP_ADMIN_PASSWORD=${kcGen.files."admin-password".path} \
                      --dry-run=client -o yaml | k3s kubectl apply -f -

                    # Realm import: secrets flow vars file -> sed program in
                    # a 0600 tmpfile (printf is a shell builtin and `sed -f`
                    # keeps them off argv//proc/cmdline) -> rendered tmpfile
                    # -> k8s Secret. Never the nix store. Substitution
                    # safety: the generators emit pure hex (no sed
                    # metacharacters, no JSON escapes). @USER_PASSWORD@ now
                    # occurs once per seeded user (five, since kfb.1 added
                    # the demo personas), so both rules carry the `g` flag —
                    # without it correctness would silently depend on the
                    # template keeping one placeholder per line, which a
                    # reformat could break.
                    step "keycloak-realm-import secret"
                    umask 077
                    sedprog=$(mktemp)
                    realm=$(mktemp)
                    trap 'rm -f "$sedprog" "$realm"' EXIT
                    printf 's|@PORTAL_CLIENT_SECRET@|%s|g\n' "$(cat ${
                      kcGen.files."portal-client-secret".path
                    })" > "$sedprog"
                    printf 's|@USER_PASSWORD@|%s|g\n' "$(cat ${kcGen.files."user-password".path})" >> "$sedprog"
                    sed -f "$sedprog" ${realmTemplate} > "$realm"
                    k3s kubectl -n data-commons create secret generic keycloak-realm-import \
                      --from-file=data-commons-realm.json="$realm" \
                      --dry-run=client -o yaml | k3s kubectl apply -f -
                    rm -f "$sedprog" "$realm"

                    step "keycloak workload"
                    k3s kubectl apply -f ${keycloakManifest}
                    kc_applied=1
                  else
                    step "warn: keycloak-pg-app not ready; keycloak deferred to the next unit run"
                    companions_ok=0
                  fi

                  fga_applied=0
                  if k3s kubectl -n data-commons get secret openfga-pg-app >/dev/null 2>&1; then
                    step "openfga-env secret"
                    fgasec() { k3s kubectl -n data-commons get secret openfga-pg-app -o jsonpath="{.data.$1}" | base64 -d; }
                    k3s kubectl -n data-commons create secret generic openfga-env \
                      --from-literal=OPENFGA_DATASTORE_ENGINE=postgres \
                      --from-literal=OPENFGA_DATASTORE_URI="$(fgasec uri)" \
                      --from-literal=OPENFGA_AUTHN_METHOD=preshared \
                      --from-file=OPENFGA_AUTHN_PRESHARED_KEYS=${fgaGen.files."api-token".path} \
                      --dry-run=client -o yaml | k3s kubectl apply -f -

                    step "openfga workload"
                    k3s kubectl apply -f ${openfgaManifest}
                    fga_applied=1
                  else
                    step "warn: openfga-pg-app not ready; openfga deferred to the next unit run"
                    companions_ok=0
                  fi

                  if [ "$kc_applied" = 1 ]; then
                    k3s kubectl -n data-commons rollout status deployment/keycloak --timeout=600s \
                      || { step "warn: keycloak rollout not ready; the app's OIDC worker retries on its own"; companions_ok=0; }
                  fi
                  if [ "$fga_applied" = 1 ]; then
                    k3s kubectl -n data-commons rollout status deployment/openfga --timeout=600s \
                      || { step "warn: openfga rollout not ready; the app's authz-bootstrap init retries on its own"; companions_ok=0; }
                  fi

                  if [ "$companions_ok" != 1 ]; then
                    step "companions not converged; exiting nonzero so the unit retries (app deploy unaffected)"
                    exit 1
                  fi
                '';
              };
            };
          };
      };
  };
}
