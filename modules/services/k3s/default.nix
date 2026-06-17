# kin/k3s — the cluster as a single clan.service with two roles:
#   server (atlas) — inits the embedded-etcd control plane, ships the Longhorn
#                    chart, takes off-node etcd snapshots to Garage.
#   agent  (apollo/hermes/lenny) — joins the server, derived from the inventory
#                    rather than a hardcoded address.
#
# The shared k3s join token comes from the kin/secrets service (present on every
# node via tags.all). Both roles import ./base.nix for the node baseline.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/k3s";
  manifest.description = "k3s cluster: one clusterInit server + agents, with Longhorn.";
  manifest.categories = [ "System" ];

  # Single clusterInit control plane: only atlas carries the k3s-server tag, so
  # the server role has exactly one machine. Tag a second machine to grow an HA
  # 3-server etcd later.

  roles.server = {
    description = "k3s control-plane node that inits the cluster.";
    interface =
      { lib, ... }:
      {
        # Extra SANs on the API serving cert so kubectl works off-node (LAN via
        # mDNS, anywhere via tailnet).
        options.tlsSans = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "atlas.local"
            "atlas.tail30507a.ts.net"
          ];
          description = "Additional TLS SANs for the k3s API server certificate.";
        };
      };
    perInstance =
      { settings, ... }:
      {
        nixosModule =
          {
            config,
            pkgs,
            ...
          }:
          {
            imports = [ ./base.nix ];

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

              extraFlags = (map (san: "--tls-san=${san}") settings.tlsSans) ++ [
                # Off-node etcd snapshots to Garage (default cadence: every 12h,
                # keep 5). Credentials come from the etcd-s3-config secret, read at
                # snapshot time — not from flags, which would land in the nix store.
                "--etcd-s3"
                "--etcd-s3-config-secret=etcd-s3-config"
              ];

              # Longhorn is the storage layer; drop k3s' bundled local-path
              # provisioner so there is a single default StorageClass (longhorn).
              disable = [ "local-storage" ];

              # Longhorn, deployed cluster-wide from the server via k3s' bundled
              # helm-controller. defaultDataPath matches the disko xfs mount;
              # replica-3 spreads each volume across atlas/apollo/hermes.
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
                        # The Longhorn partition is dedicated; the default 30% reserve
                        # is meant for shared disks.
                        storageReservedPercentageForDefaultDisk: 10
                        # Garage on lenny; credentials synced by longhorn-backup-credentials.
                        backupTarget: s3://longhorn-backups@garage/
                        backupTargetCredentialSecret: longhorn-backup-credentials
                      persistence:
                        defaultClass: true
                        defaultClassReplicaCount: 3
                    '';
                  };
                }
              ];
            };

            # Garage S3 credentials for Longhorn backups and etcd snapshots:
            # secrets can't ride HelmChart manifests through the world-readable
            # store, so sync them from the sops-decrypted vars into k8s Secrets.
            systemd.services.longhorn-backup-credentials = {
              description = "Sync Garage S3 credentials into k8s Secrets";
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
                k3s kubectl create namespace longhorn-system --dry-run=client -o yaml \
                  | k3s kubectl apply -f -
                k3s kubectl -n longhorn-system create secret generic longhorn-backup-credentials \
                  --from-file=AWS_ACCESS_KEY_ID=${
                    config.clan.core.vars.generators.garage-backup-key.files."access-key-id".path
                  } \
                  --from-file=AWS_SECRET_ACCESS_KEY=${
                    config.clan.core.vars.generators.garage-backup-key.files."secret-access-key".path
                  } \
                  --from-literal=AWS_ENDPOINTS=http://10.10.3.42:3900 \
                  --dry-run=client -o yaml | k3s kubectl apply -f -

                # defaultSettings.backupTarget only seeds on the manager's first
                # start and is skipped if the secret isn't there yet; the
                # BackupTarget CR is the authoritative knob in Longhorn >= 1.6.
                until k3s kubectl -n longhorn-system get backuptarget default >/dev/null 2>&1; do
                  sleep 5
                done
                k3s kubectl -n longhorn-system patch backuptarget default --type merge -p '{
                  "spec": {
                    "backupTargetURL": "s3://longhorn-backups@garage/",
                    "credentialSecret": "longhorn-backup-credentials"
                  }
                }'

                # S3 config for k3s etcd snapshots (--etcd-s3-config-secret).
                k3s kubectl -n kube-system create secret generic etcd-s3-config \
                  --from-literal=etcd-s3-endpoint=10.10.3.42:3900 \
                  --from-file=etcd-s3-access-key=${
                    config.clan.core.vars.generators.garage-backup-key.files."access-key-id".path
                  } \
                  --from-file=etcd-s3-secret-key=${
                    config.clan.core.vars.generators.garage-backup-key.files."secret-access-key".path
                  } \
                  --from-literal=etcd-s3-bucket=etcd-snapshots \
                  --from-literal=etcd-s3-region=garage \
                  --from-literal=etcd-s3-insecure=true \
                  --dry-run=client -o yaml | k3s kubectl apply -f -
              '';
            };
          };
      };
  };

  roles.agent = {
    description = "k3s worker node that joins the server.";
    interface =
      { lib, ... }:
      {
        # Override only if the server can't be derived (e.g. >1 server machine).
        options.serverName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Machine name of the k3s server to join; null = derive from the server role.";
        };
      };
    perInstance =
      { settings, roles, ... }:
      {
        nixosModule =
          {
            config,
            ...
          }:
          let
            # Derive the server's address from the inventory instead of hardcoding
            # it: the single server-role machine's name + the clan domain.
            server =
              if settings.serverName != null then
                settings.serverName
              else
                builtins.head (builtins.attrNames roles.server.machines);
            domain = config.clan.core.settings.domain;
          in
          {
            imports = [ ./base.nix ];

            services.k3s = {
              enable = true;
              role = "agent";
              serverAddr = "https://${server}.${domain}:6443";
              tokenFile = config.clan.core.vars.generators.k3s-token.files."token".path;
            };
          };
      };
  };
}
