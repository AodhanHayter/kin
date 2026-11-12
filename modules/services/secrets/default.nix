# kin/secrets — shared clan vars consumed by more than one service. Applied to
# roles.default.tags.all so the generators exist on EVERY machine
# unconditionally; this is the native-idiom replacement for "generators stay
# outside mkIf". A host that carries a secret it doesn't use is harmless; a
# consuming host missing the secret is not.
#
#   k3s-token         — shared k3s join token (server + all agents).
#   garage-backup-key — shared S3 creds: consumed by atlas (Longhorn backups +
#                       etcd snapshots) AND lenny (Garage import).
#   nix-cache-key     — harmonia binary-cache keypair: sign-key signs on the
#                       cache server (atlas), pub-key trusted by every client.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/secrets";
  manifest.description = "Shared cluster secrets (k3s token, Garage backup key).";
  manifest.categories = [ "System" ];

  roles.default = {
    description = "Provision the shared cluster secrets on a machine.";
    perInstance =
      { ... }:
      {
        nixosModule =
          { pkgs, ... }:
          {
            clan.core.vars.generators.k3s-token = {
              share = true; # one value, shared across all nodes
              files."token".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                openssl rand -hex 32 > "$out"/token
              '';
            };

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

            # harmonia binary-cache signing keypair. sign-key is consumed by the
            # cache server (atlas) to sign served paths; pub-key (non-secret, so
            # its .value is eval-readable) is added to every client's
            # trusted-public-keys. Cross-host → lives here, not in kin/nix-cache.
            clan.core.vars.generators.nix-cache-key = {
              share = true;
              files."sign-key".secret = true;
              files."pub-key".secret = false;
              runtimeInputs = [ pkgs.nix ];
              script = ''
                nix-store --generate-binary-cache-key kin-cache-1 \
                  "$out"/sign-key "$out"/pub-key
              '';
            };
          };
      };
  };
}
