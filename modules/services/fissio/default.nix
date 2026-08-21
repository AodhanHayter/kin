# kin/fissio — the Fissio data-commons platform (github.com/FissioAI/
# data-commons), deployed from the server through k3s' helm-controller as an
# OCI chart. The chart bundles the app plus its homelab stand-ins (Postgres,
# Dex IdP, Garage object store, Cerbos sidecar); see deploy/README.md in that
# repo for the full contract. Single role, applied to the k3s-server (atlas)
# where the secrets are consumed.
#
# Both GHCR packages (image + chart) are private. Auth is a classic PAT named
# `kin-ghcr-pull` with only the `read:packages` scope, prompted once:
#   clan vars generate atlas --generator ghcr-pull
#
# LAN exposure: fissio.local / dex.local via avahi aliases -> atlas -> traefik.
# Pods can't resolve mDNS names, and Fissio must fetch JWKS from the Dex
# issuer, so a coredns-custom server block pins both names to atlas in
# cluster DNS too.
#
# After first deploy (one time): run the Garage layout/bucket/key seed steps
# from deploy/README.md, using the object-store key minted by the fissio-env
# generator (`clan vars get atlas fissio-env/object-store-access-key-id`).
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/fissio";
  manifest.description = "Fissio platform deployed into k3s from the server.";
  manifest.categories = [ "Development" ];

  roles.default = {
    description = "Deploy the Fissio platform chart from this server.";
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
            chartVersion = "0.1.3";
            # Immutable image pin from the v0.1.3 release workflow; update
            # together with chartVersion.
            imageDigest = "sha256:294def3cd935d549f9d4a77ec3562ec5831ea5512489d33f76a04f2a6ddabb82";
            atlasIp = "10.10.3.100";
            # Release name is the HelmChart CR name ("fissio"); the chart's
            # fullname helper prefixes it, so in-cluster services are
            # fissio-fissio{,-postgres,-dex,-garage}.
            envGen = config.clan.core.vars.generators.fissio-env;
          in
          {
            # GHCR pull token — consumed only here (server), so scoped to the
            # instance. Classic PAT `kin-ghcr-pull`, read:packages only.
            clan.core.vars.generators.ghcr-pull = {
              prompts.token = {
                description = "GitHub classic PAT `kin-ghcr-pull` (read:packages) for ghcr.io pulls";
                type = "hidden";
                persist = true;
              };
            };

            # App secrets, minted once. The database URLs embed the generated
            # Postgres password and the chart's fixed service names; the object
            # store key pair is imported into Garage during the one-time seed
            # (see header). secret-key-base signs Phoenix cookies.
            clan.core.vars.generators.fissio-env = {
              files."postgres-password".secret = true;
              files."secret-key-base".secret = true;
              files."object-store-access-key-id".secret = true;
              files."object-store-secret-access-key".secret = true;
              files."database-url".secret = true;
              files."warehouse-database-url".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                pgpw=$(openssl rand -hex 24)
                printf '%s' "$pgpw" > "$out"/postgres-password
                openssl rand -base64 48 | tr -d '\n' > "$out"/secret-key-base
                # Garage key-id format: GK + 24 hex chars.
                printf 'GK%s' "$(openssl rand -hex 12)" > "$out"/object-store-access-key-id
                openssl rand -hex 32 | tr -d '\n' > "$out"/object-store-secret-access-key
                printf 'ecto://postgres:%s@fissio-fissio-postgres/fissio' "$pgpw" > "$out"/database-url
                printf 'ecto://postgres:%s@fissio-fissio-postgres/fissio_warehouse' "$pgpw" > "$out"/warehouse-database-url
              '';
            };

            services.k3s.manifests.fissio.content = [
              # Cluster-DNS pin for the mDNS hostnames (see header). A .server
              # import adds separate zone blocks, so it cannot collide with the
              # hosts plugin k3s already runs for NodeHosts.
              {
                apiVersion = "v1";
                kind = "ConfigMap";
                metadata = {
                  name = "coredns-custom";
                  namespace = "kube-system";
                };
                data."fissio-hosts.server" = ''
                  fissio.local dex.local {
                    hosts {
                      ${atlasIp} fissio.local dex.local
                    }
                  }
                '';
              }
              {
                apiVersion = "helm.cattle.io/v1";
                kind = "HelmChart";
                metadata = {
                  name = "fissio";
                  namespace = "kube-system";
                };
                spec = {
                  chart = "oci://ghcr.io/fissioai/charts/fissio";
                  version = chartVersion;
                  targetNamespace = "fissio";
                  # Private OCI registry; the secret must live in this CR's
                  # namespace (kube-system) and is synced by fissio-secrets.
                  dockerRegistrySecret.name = "fissio-chart-auth";
                  valuesContent = ''
                    image:
                      digest: ${imageDigest}
                    fissio:
                      host: fissio.local
                      # http: LAN-only demo — traefik's default cert is
                      # self-signed, and Fissio's JWKS fetch would reject it.
                      oidcIssuer: http://dex.local/dex
                      objectStoreEndpoint: http://fissio-fissio-garage:3900
                    dex:
                      host: dex.local
                  '';
                };
              }
            ];

            # mDNS aliases so LAN browsers reach traefik on atlas — same
            # pattern as monitoring's grafana/prometheus aliases.
            systemd.services =
              lib.genAttrs
                [
                  "avahi-alias-fissio"
                  "avahi-alias-dex"
                ]
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
                      ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R ${name}.local ${atlasIp}";
                      Restart = "always";
                      RestartSec = 5;
                    };
                  }
                )
              // {
                # Same pattern as longhorn-backup-credentials: secrets reach
                # k8s via kubectl at activation, never via manifests.
                fissio-secrets = {
                  description = "Sync Fissio app + GHCR credentials into k8s Secrets";
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
                    k3s kubectl create namespace fissio --dry-run=client -o yaml \
                      | k3s kubectl apply -f -

                    # App env, consumed via the chart's existingSecret.
                    k3s kubectl -n fissio create secret generic fissio-env \
                      --from-file=DATABASE_URL=${envGen.files."database-url".path} \
                      --from-file=WAREHOUSE_DATABASE_URL=${envGen.files."warehouse-database-url".path} \
                      --from-file=SECRET_KEY_BASE=${envGen.files."secret-key-base".path} \
                      --from-file=POSTGRES_PASSWORD=${envGen.files."postgres-password".path} \
                      --from-file=OBJECT_STORE_ACCESS_KEY_ID=${envGen.files."object-store-access-key-id".path} \
                      --from-file=OBJECT_STORE_SECRET_ACCESS_KEY=${envGen.files."object-store-secret-access-key".path} \
                      --dry-run=client -o yaml | k3s kubectl apply -f -

                    # GHCR auth, twice: pods pull the image from the app
                    # namespace; helm-controller pulls the chart from the CR's
                    # namespace (kube-system).
                    token=$(cat ${config.clan.core.vars.generators.ghcr-pull.files."token".path})
                    k3s kubectl -n fissio create secret docker-registry ghcr-pull \
                      --docker-server=ghcr.io --docker-username=aodhanhayter \
                      --docker-password="$token" \
                      --dry-run=client -o yaml | k3s kubectl apply -f -
                    k3s kubectl -n kube-system create secret docker-registry fissio-chart-auth \
                      --docker-server=ghcr.io --docker-username=aodhanhayter \
                      --docker-password="$token" \
                      --dry-run=client -o yaml | k3s kubectl apply -f -
                  '';
                };
              };
          };
      };
  };
}
