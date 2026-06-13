# Shared S3 credential for the Garage backup store on lenny. One key pair,
# generated once, imported into Garage (lenny) and synced into k8s secrets
# (atlas) for Longhorn backups + k3s etcd snapshots.
{ pkgs, ... }:
{
  clan.core.vars.generators.garage-backup-key = {
    share = true;
    files."access-key-id".secret = true;
    files."secret-access-key".secret = true;
    runtimeInputs = [ pkgs.openssl ];
    # Garage key-import expects its native format: GK + 24 hex, 64-hex secret.
    script = ''
      printf 'GK%s' "$(openssl rand -hex 12)" > "$out"/access-key-id
      printf '%s' "$(openssl rand -hex 32)" > "$out"/secret-access-key
    '';
  };
}
