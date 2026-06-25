# kin/attic — Attic binary cache: a push-based, multi-tenant Nix cache that
# works across architectures and OSes (unlike harmonia, which only re-serves its
# own linux store). One node runs atticd (atlas); every NixOS node substitutes
# from it, and non-clan hosts (e.g. a darwin Mac) push/pull with the `attic`
# client. This is why attic was chosen over harmonia: `attic push` runs from any
# host and the cache holds aarch64-darwin + x86_64-linux closures side by side.
#
# Storage is the atticd default (local: sqlite + /var/lib/atticd/storage on the
# server's disk). It is deliberately NOT backed by Garage S3: attic's S3 client
# addresses buckets vhost-style (attic.s3.lenny.local), which garage can't serve
# without wildcard DNS, and attic exposes no path-style toggle here. To move to
# S3 later: set settings.storage = { type = "s3"; region = "garage"; bucket =
# "attic"; endpoint = "http://lenny.local:3900"; }, add the AWS_* creds (the
# shared garage-backup-key) to the EnvironmentFile, and add an `attic` bucket to
# kin/garage — only after confirming garage path-style addressing works.
#
# The RS256 JWT secret is per-instance (server-only): it signs the admin/push
# tokens and never leaves atlas, so it is NOT a cross-host secret and stays out
# of kin/secrets.
#
# Post-deploy bootstrap (one-time, on atlas as root):
#   1. clan vars generate            # mint the attic-server RS256 secret
#   2. clan machines update atlas    # bring atticd up
#   3. token=$(atticd-atticadm make-token --sub bootstrap --validity '1y' \
#        --pull '*' --push '*' --create-cache '*' --configure-cache '*' \
#        --configure-cache-retention '*' | sed -n 's/^Token: //p')
#   4. nix run nixpkgs#attic-client -- login kin http://atlas.local:8080 "$token"
#      nix run nixpkgs#attic-client -- cache create kin
#      nix run nixpkgs#attic-client -- cache configure kin --public   # pull w/o auth
#      nix run nixpkgs#attic-client -- cache info kin                  # -> Public Key
#   5. put that key in clan.nix: roles.client.tags.all.settings.publicKey = "kin:...";
#      then `clan machines update` every node — substituter wires up only once set.
#
# Mac (or any non-clan host): `nix profile install nixpkgs#attic-client`,
#   `attic login kin http://atlas.local:8080 <push-token>`, `attic use kin`,
#   then `attic push kin <store-path>` / `attic watch-store kin`.
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/attic";
  manifest.description = "Push-based, cross-arch Nix binary cache (atticd) shared across hosts.";
  manifest.categories = [ "Utility" ];

  # The machine running atticd. Holds the RS256 secret and the local cache store.
  roles.server = {
    description = "Run the atticd binary cache server on this machine.";
    interface =
      { lib, ... }:
      {
        options.listenPort = lib.mkOption {
          type = lib.types.port;
          default = 8080;
          description = "TCP port atticd listens on (also opened in the firewall).";
        };
      };
    perInstance =
      { settings, ... }:
      {
        nixosModule =
          { config, pkgs, ... }:
          {
            # RS256 JWT signing secret. Consumed only by atticd on this host, so
            # per-instance (not a cross-host secret -> not in kin/secrets). Stored
            # already in KEY=value form so it IS the EnvironmentFile directly.
            clan.core.vars.generators.attic-server = {
              files."env".secret = true;
              runtimeInputs = [ pkgs.openssl ];
              script = ''
                printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=%s' \
                  "$(openssl genrsa -traditional 4096 | openssl base64 -A)" > "$out"/env
              '';
            };

            services.atticd = {
              enable = true;
              environmentFile = config.clan.core.vars.generators.attic-server.files."env".path;
              settings = {
                listen = "[::]:${toString settings.listenPort}";
                # Storage + database left at the module defaults: sqlite at
                # /var/lib/atticd/server.db, local store at /var/lib/atticd/storage
                # (StateDirectory, on the server disk). See header for the S3 swap.
              };
            };

            networking.firewall.allowedTCPPorts = [ settings.listenPort ];
          };
      };
  };

  # Every NixOS node: substitute from the attic cache. Gated on `publicKey`: the
  # cache's signing key only exists after the cache is created (step 4 above), so
  # until it is set this role is a no-op and deploys stay safe.
  roles.client = {
    description = "Substitute from the cluster's attic cache.";
    interface =
      { lib, ... }:
      {
        options.publicKey = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = ''
            The attic cache's signing public key (`<cache>:<base64>`), shown by
            `attic cache info <cache>`. Empty until the cache is bootstrapped;
            while empty the substituter is not added (its signatures would be
            untrusted anyway).
          '';
        };
        options.cacheName = lib.mkOption {
          type = lib.types.str;
          default = "kin";
          description = "Attic cache name to substitute from.";
        };
        options.listenPort = lib.mkOption {
          type = lib.types.port;
          default = 8080;
          description = "Port the atticd server(s) listen on.";
        };
      };
    perInstance =
      { settings, roles, ... }:
      {
        nixosModule =
          { config, lib, ... }:
          let
            domain = config.clan.core.settings.domain;
            servers = builtins.attrNames roles.server.machines;
          in
          lib.mkIf (settings.publicKey != "") {
            nix.settings.substituters = builtins.map (
              m: "http://${m}.${domain}:${toString settings.listenPort}/${settings.cacheName}"
            ) servers;
            nix.settings.trusted-public-keys = [ settings.publicKey ];
          };
      };
  };
}
