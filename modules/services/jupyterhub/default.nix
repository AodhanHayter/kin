# Jupyter notebooks for the admin-only internet demo. Public routing and the
# separate Keycloak client are provisioned explicitly, not by this service.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/jupyterhub";
  manifest.description = "Persistent Data Commons notebooks on k3s.";
  manifest.categories = [ "Development" ];

  roles.default = {
    description = "Deploy JupyterHub and its credentials from the k3s server.";
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
            namespace = "data-commons-workspaces";
            hostname = "demo-workspaces.fissio.com";
            issuer = "https://demo-auth.fissio.com/realms/data-commons/protocol/openid-connect";
            gen = config.clan.core.vars.generators.data-commons-jupyterhub;

            # Set from the workspace image's publication receipt. A null pin
            # prepares secrets only: never install an unpublished notebook image.
            workspaceImageDigest = "sha256:7dd427d4eb3680e3a3be045000d6e8335ea7acde88bb301d36a6eea5c512723b";

            values = {
              hub = {
                existingSecret = "jupyterhub-existing-secret";
                image.tag = "4.4.2@sha256:108fbb01c3fe23e4a81efc8899aa73b4c15413615c73dfcdc44248eb63096e41";
                allowNamedServers = true;
                namedServerLimitPerUser = 2;
                redirectToServer = false;
                db = {
                  type = "sqlite-pvc";
                  pvc = {
                    storage = "1Gi";
                    storageClassName = "longhorn";
                  };
                };
                config = {
                  JupyterHub = {
                    authenticator_class = "generic-oauth";
                    public_url = "https://${hostname}";
                    admin_access = false;
                  };
                  GenericOAuthenticator = {
                    client_id = "jupyterhub";
                    oauth_callback_url = "https://${hostname}/hub/oauth_callback";
                    authorize_url = "${issuer}/auth";
                    token_url = "${issuer}/token";
                    userdata_url = "${issuer}/userinfo";
                    username_claim = "preferred_username";
                    scope = [
                      "openid"
                      "profile"
                    ];
                    allow_all = false;
                    allow_existing_users = false;
                    allowed_users = [ "dc-admin" ];
                    # A Hub admin cannot be restricted by the user-role override.
                    admin_users = [ ];
                  };
                  KubeSpawner = {
                    delete_pvc = false;
                    automount_service_account_token = false;
                    pod_security_context.seccompProfile.type = "RuntimeDefault";
                    container_security_context = {
                      runAsNonRoot = true;
                      capabilities.drop = [ "ALL" ];
                    };
                  };
                };
                services.data-commons = { };
                loadRoles = {
                  # Humans may open notebooks, but only the portal may launch
                  # or stop them. The hook below validates, not authenticates.
                  user.scopes = [
                    # Required by the notebook OAuth code exchange.
                    "read:users:name!user"
                    "read:users:groups!user"
                    "access:servers!user"
                    "users:activity!user"
                  ];
                  data-commons-launcher = {
                    services = [ "data-commons" ];
                    scopes = [
                      "admin:users!user=dc-admin"
                      "admin:servers!user=dc-admin"
                      "read:users:activity!user=dc-admin"
                    ];
                  };
                };
                extraConfig.workspace = builtins.readFile ./workspace-spawner.py;
              };
              proxy = {
                service.type = "ClusterIP";
                https.enabled = false;
                # Leave the proxy token to the chart's persistent Secret.
                # Providing it in valuesContent would leak it into the store.
              };
              singleuser = {
                # k3s enforces this NetworkPolicy. Avoid the privileged init
                # container: its legacy iptables filter table is absent on NixOS.
                cloudMetadata.blockWithIptables = false;
                networkPolicy.egressAllowRules.cloudMetadataServer = false;
                image = {
                  name =
                    "ghcr.io/fissioai/data-commons-workspace"
                    + lib.optionalString (workspaceImageDigest != null) "@${workspaceImageDigest}";
                  tag = if workspaceImageDigest == null then "unpublished" else "";
                  pullSecrets = [ "ghcr-pull" ];
                };
                defaultUrl = "/lab";
                uid = 1000;
                fsGid = 1000;
                cpu = {
                  guarantee = 1;
                  limit = 1;
                };
                # JupyterHub uses G (binary GiB), not Kubernetes' Gi suffix.
                memory = {
                  guarantee = "2G";
                  limit = "2G";
                };
                storage = {
                  capacity = "10Gi";
                  dynamic = {
                    storageClass = "longhorn";
                    pvcNameTemplate = "claim-{username}";
                    storageAccessModes = [ "ReadWriteMany" ];
                  };
                };
                # Files share a home; runtime credentials and SQLite history
                # stay pod-local, avoiding concurrent SQLite writers over NFS.
                extraEnv = {
                  JUPYTER_RUNTIME_DIR = "/tmp/jupyter-runtime";
                  JUPYTER_DATA_DIR = "/tmp/jupyter-data";
                  IPYTHONDIR = "/tmp/ipython";
                };
              };
              # Data Commons owns stop + delegation revocation, including idle
              # and absolute expiry. A second culler would leave stale app rows.
              cull.enabled = false;
              scheduling.userScheduler.enabled = false;
              prePuller.hook.enabled = false;
              prePuller.continuous.enabled = false;
            };

            helmChart = pkgs.writeText "data-commons-jupyterhub.json" (
              builtins.toJSON {
                apiVersion = "helm.cattle.io/v1";
                kind = "HelmChart";
                metadata = {
                  name = "data-commons-jupyterhub";
                  namespace = "kube-system";
                };
                spec = {
                  repo = "https://hub.jupyter.org/helm-chart/";
                  chart = "jupyterhub";
                  version = "4.4.2"; # JupyterHub 5.5.2
                  targetNamespace = namespace;
                  valuesContent = builtins.toJSON values;
                };
              }
            );
          in
          {
            # Offline render/contract checks without installing the chart.
            system.build.jupyterhubManifest = helmChart;

            clan.core.vars.generators.data-commons-jupyterhub = {
              files."hub-api-token".secret = true;
              files."oidc-client-secret".secret = true;
              files."cookie-secret".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -hex 32 | tr -d '\n' > "$out"/hub-api-token
                openssl rand -hex 24 | tr -d '\n' > "$out"/oidc-client-secret
                openssl rand -hex 32 | tr -d '\n' > "$out"/cookie-secret
              '';
            };

            systemd.services.jupyterhub-secrets = {
              description =
                lib.warnIf (workspaceImageDigest == null)
                  "jupyterhub: no published workspace image digest; HelmChart apply is disabled"
                  "Sync notebook credentials and JupyterHub into k3s";
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
                until k3s kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
                k3s kubectl create namespace ${namespace} --dry-run=client -o yaml \
                  | k3s kubectl apply -f -

                umask 077
                tmp=$(mktemp -d)
                trap 'rm -f "$tmp/values.yaml" "$tmp/registry.json"; rmdir "$tmp"' EXIT
                # Hex-only generated secrets; printf is a shell builtin.
                # No secret values are passed in argv or written into Nix.
                printf '{"hub":{"config":{"GenericOAuthenticator":{"client_secret":"%s"}}}}' \
                  "$(cat ${gen.files."oidc-client-secret".path})" > "$tmp/values.yaml"
                k3s kubectl -n ${namespace} create secret generic jupyterhub-existing-secret \
                  --from-file=values.yaml="$tmp/values.yaml" \
                  --from-file=hub.services.data-commons.apiToken=${gen.files."hub-api-token".path} \
                  --from-file=hub.config.JupyterHub.cookie_secret=${gen.files."cookie-secret".path} \
                  --dry-run=client -o yaml | k3s kubectl apply -f -

                auth=$(printf 'aodhanhayter:%s' "$(cat ${
                  config.clan.core.vars.generators.ghcr-pull.files."token".path
                })" | base64 -w0)
                printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$auth" > "$tmp/registry.json"
                k3s kubectl -n ${namespace} create secret generic ghcr-pull \
                  --type=kubernetes.io/dockerconfigjson \
                  --from-file=.dockerconfigjson="$tmp/registry.json" \
                  --dry-run=client -o yaml | k3s kubectl apply -f -

                ${
                  if workspaceImageDigest == null then
                    ''
                      echo "jupyterhub: image unpublished; HelmChart not applied"
                    ''
                  else
                    ''
                      k3s kubectl apply -f ${helmChart}
                    ''
                }
              '';
            };
          };
      };
  };
}
