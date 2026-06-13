# Garage (S3-compatible object store) on lenny — backup target for Longhorn
# volume backups and k3s etcd snapshots. Single node, replication factor 1:
# this is the off-cluster copy, not HA storage. Data lives on the 1 TB HDD
# (disko mounts it at /var/lib/garage).
#
# The RPC secret and the S3 key are clan vars; a oneshot provisions the
# cluster layout, buckets and key on boot, so a rebuilt lenny converges
# without manual `garage` commands.
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
in
{
  imports = [ ../../secrets/garage-backup-key ];

  clan.core.vars.generators.garage-rpc-secret = {
    files."env".secret = true;
    runtimeInputs = [ pkgs.openssl ];
    # EnvironmentFile form keeps the secret out of the world-readable
    # nix-store TOML config; systemd injects it at start.
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

  # /var/lib/garage is a disko mountpoint (the 1 TB HDD). The module default
  # DynamicUser=true makes systemd try to replace it with a symlink into
  # /var/lib/private, which fails with "Device or resource busy" — run as
  # root instead so the mountpoint can stay.
  systemd.services.garage.serviceConfig.DynamicUser = lib.mkForce false;

  # S3 API for Longhorn / k3s on the other nodes.
  networking.firewall.allowedTCPPorts = [ 3900 ];

  systemd.services.garage-provision = {
    description = "Provision Garage layout, buckets and backup key";
    wantedBy = [ "multi-user.target" ];
    after = [ "garage.service" ];
    wants = [ "garage.service" ];
    path = [ config.services.garage.package ];
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

      for bucket in longhorn-backups etcd-snapshots; do
        garage bucket info "$bucket" >/dev/null 2>&1 \
          || garage bucket create "$bucket"
        garage bucket allow "$bucket" --read --write --key "$access"
      done
    '';
  };
}
