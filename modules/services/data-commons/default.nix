# kin/data-commons — the data-commons platform (github.com/FissioAI/
# data-commons), deployed from the server through k3s' helm-controller as an
# OCI chart. Replaces the old kin/fissio deployment (the unit cleans up its
# HelmChart, namespace, and chart-auth secret on first run).
#
# The chart is app-only (Deployment + Service + Ingress); the database is a
# CloudNativePG Cluster this module creates (kin/cnpg provides the operator
# and the cnpg-longhorn storage class). CNPG auto-mints the app credentials;
# the secrets unit composes DATABASE_URL from them. Keycloak/OpenFGA/Garage
# companions arrive with later slices.
#
# Both GHCR packages (image + chart) are private. Auth is a classic PAT named
# `kin-ghcr-pull` with only the `read:packages` scope (same generator name as
# the old fissio module, so the existing var is reused):
#   clan vars generate atlas --generator ghcr-pull
#
# LAN exposure: data-commons.local via avahi alias -> atlas -> traefik, with
# a coredns-custom pin so pods resolve the name too.
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
            chartVersion = "0.1.0";
            # Immutable image pin from the release workflow; update together
            # with chartVersion.
            imageDigest = "sha256:c2a2df1eecaecfbd8ed3b1a09838acc0432149f5291bc07a3e719fe721552d2c";
            atlasIp = "10.10.3.100";
            envGen = config.clan.core.vars.generators.data-commons-env;

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

            services.k3s.manifests.data-commons.content = [
              # Cluster-DNS pin for the mDNS hostname: pods can't resolve
              # mDNS, and in-cluster callers may use the LAN name.
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
              }
            ];

            systemd.services = {
              # mDNS alias so LAN browsers reach traefik on atlas.
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

              # Secrets reach k8s via kubectl at activation, never via
              # manifests (same pattern as the old fissio-secrets unit).
              data-commons-secrets = {
                description = "Sync data-commons DB, app env + GHCR credentials into k8s";
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

                  step "CNPG cluster"
                  k3s kubectl apply -f ${pgCluster}

                  step "waiting for CNPG app credentials"
                  until k3s kubectl -n data-commons get secret data-commons-pg-app >/dev/null 2>&1; do sleep 5; done

                  step "data-commons-env secret"
                  pgsec() { k3s kubectl -n data-commons get secret data-commons-pg-app -o jsonpath="{.data.$1}" | base64 -d; }
                  db_url="ecto://$(pgsec username):$(pgsec password)@$(pgsec host):$(pgsec port)/$(pgsec dbname)"
                  k3s kubectl -n data-commons create secret generic data-commons-env \
                    --from-literal=DATABASE_URL="$db_url" \
                    --from-file=SECRET_KEY_BASE=${envGen.files."secret-key-base".path} \
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

                  # HelmChart CR last: namespace and both pull secrets exist,
                  # so helm-controller can't race this unit.
                  step "data-commons HelmChart"
                  k3s kubectl apply -f ${helmChart}
                '';
              };
            };
          };
      };
  };
}
