# kin/garage — Garage (S3-compatible object store) on lenny: the off-cluster
# backup target for Longhorn volume backups and k3s etcd snapshots. Single node,
# replication factor 1. Data lives on the 1 TB HDD (disko mounts /var/lib/garage).
#
# The RPC secret is a per-instance var; the S3 key is the shared
# garage-backup-key from kin/secrets (also imported into Garage on atlas's
# behalf). A oneshot provisions the layout, buckets and key on boot, so a
# rebuilt lenny converges without manual `garage` commands. Assigned to a single
# machine (lenny) via the instance in clan.nix.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/garage";
  manifest.description = "Single-node Garage S3 store used as the cluster backup target.";
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Run a Garage S3 node (backup target) on this machine.";
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
            garageSettings = {
              replication_factor = 1;
              metadata_dir = "/var/lib/garage/meta";
              data_dir = "/var/lib/garage/data";
              db_engine = "lmdb";

              rpc_bind_addr = "[::]:3901";
              rpc_public_addr = "127.0.0.1:3901";

              s3_api = {
                s3_region = "garage";
                api_bind_addr = "[::]:3900";
                root_domain = ".s3.lenny.local";
              };
            };

            # The CLI needs the same config + RPC secret as the daemon to talk to it.
            configFile = (pkgs.formats.toml { }).generate "garage-cli.toml" garageSettings;

            rpcEnvPath = config.clan.core.vars.generators.garage-rpc-secret.files."env".path;
            accessKeyPath = config.clan.core.vars.generators.garage-backup-key.files."access-key-id".path;
            secretKeyPath = config.clan.core.vars.generators.garage-backup-key.files."secret-access-key".path;

            # App-scoped key for the data-commons object store (shared var, so
            # atlas hands the same id/secret to the app pods).
            dcAccessKeyPath = config.clan.core.vars.generators.data-commons-s3.files."access-key-id".path;
            dcSecretKeyPath = config.clan.core.vars.generators.data-commons-s3.files."secret-access-key".path;

            # Browser presigned PUT/GET from the portal (origin
            # http://data-commons.local, presigned host http://10.10.3.42:3900)
            # is cross-origin, so the bucket needs a CORS rule. Garage exposes
            # CORS only through the S3 PutBucketCors API — no CLI verb — so the
            # oneshot signs the call with curl's native SigV4 (same mechanism as
            # data-commons' devenv.nix). Full overwrite → idempotent.
            dcCorsXml = pkgs.writeText "data-commons-cors.xml" ''
              <CORSConfiguration>
                <CORSRule>
                  <AllowedOrigin>http://data-commons.local</AllowedOrigin>
                  <AllowedMethod>PUT</AllowedMethod>
                  <AllowedMethod>GET</AllowedMethod>
                  <AllowedHeader>*</AllowedHeader>
                  <ExposeHeader>ETag</ExposeHeader>
                </CORSRule>
              </CORSConfiguration>
            '';
          in
          {
            # RPC secret — consumed only by this node, so scoped to the instance.
            # EnvironmentFile form keeps the secret out of the world-readable
            # nix-store TOML config; systemd injects it at start.
            clan.core.vars.generators.garage-rpc-secret = {
              files."env".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                printf 'GARAGE_RPC_SECRET=%s' "$(openssl rand -hex 32)" > "$out"/env
              '';
            };

            services.garage = {
              enable = true;
              package = pkgs.garage_2;
              environmentFile = rpcEnvPath;
              settings = garageSettings;
            };

            # /var/lib/garage is a disko mountpoint (the 1 TB HDD). The module
            # default DynamicUser=true makes systemd try to replace it with a
            # symlink into /var/lib/private, which fails with "Device or resource
            # busy" — run as root instead so the mountpoint can stay.
            systemd.services.garage.serviceConfig.DynamicUser = lib.mkForce false;

            # S3 API for Longhorn / k3s on the other nodes.
            networking.firewall.allowedTCPPorts = [ 3900 ];

            # mDNS alias so LAN browsers following a presigned URL resolve
            # `s3.local` to lenny's own address — the SAME name the
            # data-commons module pins in-cluster (coredns `hosts` block) for
            # app pods, since the host in a presigned URL is part of the
            # SigV4 signature and must be byte-identical for both callers
            # (data-commons-8qq). Published from lenny itself, unlike the
            # data-commons.local/keycloak.local aliases atlas publishes for
            # itself — avahi-publish just injects an mDNS record, it doesn't
            # require the publishing host to own the address, but publishing
            # from the address's actual owner is the simpler, more obviously
            # correct choice here.
            # avahi denies client entry groups unless user-service
            # publishing is on, and avahi-publish is a client. Without this
            # the unit below crash-loops under Restart=always and s3.local
            # never resolves on the LAN — which breaks EVERY presigned
            # upload/download, since the host is part of the SigV4 signature
            # and has no fallback. Same flag, same reason, as
            # modules/services/monitoring and modules/services/gen3 (which
            # only ever needed it because they land on atlas).
            services.avahi.publish.userServices = true;
            systemd.services.avahi-alias-s3 = {
              description = "mDNS alias s3.local -> lenny (this host)";
              after = [ "avahi-daemon.service" ];
              requires = [ "avahi-daemon.service" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${pkgs.avahi}/bin/avahi-publish -a -R s3.local 10.10.3.42";
                Restart = "always";
                RestartSec = 5;
              };
            };

            systemd.services.garage-provision = {
              description = "Provision Garage layout, buckets and backup key";
              wantedBy = [ "multi-user.target" ];
              after = [ "garage.service" ];
              wants = [ "garage.service" ];
              path = [
                config.services.garage.package
                pkgs.curl
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                export GARAGE_CONFIG_FILE=${configFile}
                set -a
                . ${rpcEnvPath}
                set +a

                until garage status >/dev/null 2>&1; do sleep 2; done

                node=$(garage node id -q | cut -d@ -f1)
                if ! garage layout show | grep -q "''${node:0:16}"; then
                  garage layout assign -z home -c 900G "$node"
                fi
                # `layout show` prints the exact version to apply when changes are
                # staged; no hint means nothing staged.
                version=$(garage layout show | sed -n 's/.*apply --version \([0-9]*\).*/\1/p' | tail -1)
                if [ -n "$version" ]; then
                  garage layout apply --version "$version"
                fi

                access=$(cat ${accessKeyPath})
                secret=$(cat ${secretKeyPath})
                garage key info "$access" >/dev/null 2>&1 \
                  || garage key import --yes -n kin-backup "$access" "$secret"

                for bucket in longhorn-backups etcd-snapshots loki-chunks cnpg-backups; do
                  garage bucket info "$bucket" >/dev/null 2>&1 \
                    || garage bucket create "$bucket"
                  garage bucket allow "$bucket" --read --write --key "$access"
                done

                # ── data-commons object store ────────────────────────────
                # Its own key, granted only on the data-commons bucket.
                # --owner is required on top of read/write: CORS (and any other
                # bucket-configuration op) goes through the S3 API and is
                # owner-only.
                dc_access=$(cat ${dcAccessKeyPath})
                dc_secret=$(cat ${dcSecretKeyPath})
                garage key info "$dc_access" >/dev/null 2>&1 \
                  || garage key import --yes -n data-commons "$dc_access" "$dc_secret"

                garage bucket info data-commons >/dev/null 2>&1 \
                  || garage bucket create data-commons
                garage bucket allow data-commons --read --write --owner --key "$dc_access"

                # PutBucketCors against the local S3 API. Non-fatal: a failed
                # CORS write must not wedge layout/bucket provisioning, and
                # Restart=on-failure isn't set on this unit.
                curl -sS -f -X PUT "http://127.0.0.1:3900/data-commons?cors" \
                  --user "$dc_access:$dc_secret" \
                  --aws-sigv4 "aws:amz:${garageSettings.s3_api.s3_region}:s3" \
                  --upload-file ${dcCorsXml} \
                  || echo "garage-provision: warn: PutBucketCors on data-commons failed"
              '';
            };
          };
      };
  };
}
