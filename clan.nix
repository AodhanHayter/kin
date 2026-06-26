# clan.nix — the inventory "brain" for kin.
#
# This is the clan.lol native layout: meta + machines(+tags) + service
# instances all live here, and machines/<name>/{configuration,hardware-
# configuration,disko}.nix are auto-included per host. Composition is 100%
# inventory.instances — every capability is a clan.service assigned to a role,
# and roles are filled by the machine tags below. There is no snowfall-style
# toggle layer; `modules` registers kin's own services, `module.input = "self"`
# pulls them, and `module.input = "clan-core"` pulls upstream prebuilt ones.
{ ... }:
{
  meta.name = "kin";
  # mDNS domain; surfaces as config.clan.core.settings.domain (used to derive
  # the k3s server address, etc.).
  meta.domain = "local";

  # Machines + tags. Tags are the wiring: instances below fill roles by tag.
  inventory.machines = {
    atlas = {
      tags = [
        "k3s-server"
        "eq13"
      ];
      deploy.targetHost = "root@atlas.local";
    };
    apollo = {
      tags = [
        "k3s-agent"
        "eq13"
      ];
      deploy.targetHost = "root@apollo.local";
    };
    hermes = {
      tags = [
        "k3s-agent"
        "eq13"
      ];
      deploy.targetHost = "root@hermes.local";
    };
    lenny = {
      tags = [ "k3s-agent" ];
      deploy.targetHost = "root@lenny.local";
    };
    # Intel MacBookPro11,5 — non-EQ13, joins the LAN over broadcom wifi (kin/wifi).
    mbp = {
      tags = [ "k3s-agent" ];
      deploy.targetHost = "root@mbp.local";
    };
  };

  # Register kin's own clan.service modules so instances can select them with
  # module.input = "self".
  modules = {
    "kin/base" = ./modules/services/base;
    "kin/secrets" = ./modules/services/secrets;
    "kin/k3s" = ./modules/services/k3s;
    "kin/tailscale" = ./modules/services/tailscale;
    "kin/monitoring" = ./modules/services/monitoring;
    "kin/garage" = ./modules/services/garage;
    "kin/github-runners" = ./modules/services/github-runners;
    "kin/nix-cache" = ./modules/services/nix-cache;
    "kin/attic" = ./modules/services/attic;
    "kin/cloudflared" = ./modules/services/cloudflared;
    "kin/hello" = ./modules/services/hello;
    "kin/comin" = ./modules/services/comin;
    "kin/wifi" = ./modules/services/wifi;
  };

  inventory.instances = {
    # ---- always-on baseline (every machine) ----
    base = {
      module = {
        name = "kin/base";
        input = "self";
      };
      roles.default.tags.all = { };
    };

    # Shared secrets that several services read. Declared on tags.all so the
    # generators exist unconditionally on every host — the native-idiom
    # equivalent of "generators stay outside mkIf". A disabled/non-consuming
    # host carrying the secret is harmless; a consuming host missing it is not.
    cluster-secrets = {
      module = {
        name = "kin/secrets";
        input = "self";
      };
      roles.default.tags.all = { };
    };

    # ---- accounts + ssh (upstream prebuilt services) ----
    # The clan-core 25.11 `users` service manages only the account, password and
    # groups; SSH keys (and uid/shell for aodhan) are supplied via extraModules.
    user-root = {
      module = {
        name = "users";
        input = "clan-core";
      };
      roles.default.tags.all = { };
      roles.default.settings = {
        user = "root";
        prompt = false; # deploy is key-only; password auto-generated
      };
      roles.default.extraModules = [ ./modules/users/root-extras.nix ];
    };
    user-aodhan = {
      module = {
        name = "users";
        input = "clan-core";
      };
      roles.default.tags.all = { };
      roles.default.settings = {
        user = "aodhan";
        prompt = false; # auto-generate; retrieve via `clan vars get`
        share = true; # same password on every machine
        groups = [
          "wheel"
          "networkmanager"
        ];
      };
      # uid, shell and SSH keys (the service covers none of these in 25.11).
      roles.default.extraModules = [ ./modules/users/aodhan-extras.nix ];
    };
    sshd = {
      module = {
        name = "sshd";
        input = "clan-core";
      };
      # Flat .local LAN reached by mDNS name — leave certificate.searchDomains
      # empty (the default) so no CA host certs are generated.
      roles.server.tags.all = { };
    };

    # ---- upstream prebuilt: trust the clan.lol + nix-community caches ----
    nix-caches = {
      module = {
        name = "trusted-nix-caches";
        input = "clan-core";
      };
      roles.default.tags.all = { };
    };

    # ---- tailscale (every machine) ----
    tailscale = {
      module = {
        name = "kin/tailscale";
        input = "self";
      };
      roles.default.tags.all = { };
    };

    # ---- comin GitOps: every node polls master and self-deploys ----
    comin = {
      module = {
        name = "kin/comin";
        input = "self";
      };
      roles.default.tags.all = { };
      roles.default.settings = {
        remoteUrl = "https://github.com/AodhanHayter/kin.git";
        branch = "master";
      };
    };

    # ---- k3s: atlas = server (clusterInit), the rest = agents ----
    k3s = {
      module = {
        name = "kin/k3s";
        input = "self";
      };
      roles.server.tags.k3s-server = { };
      roles.agent.tags.k3s-agent = { };
    };

    # ---- cluster-wide observability, shipped from the server ----
    monitoring = {
      module = {
        name = "kin/monitoring";
        input = "self";
      };
      roles.default.tags.k3s-server = { };
    };

    # ---- Garage S3 backup target (lenny only) ----
    garage = {
      module = {
        name = "kin/garage";
        input = "self";
      };
      roles.default.machines.lenny = { };
    };

    # ---- declarative wifi for the ethernet-less mbp MacBookPro (mbp only) ----
    wifi = {
      module = {
        name = "kin/wifi";
        input = "self";
      };
      roles.default.machines.mbp = { };
    };

    # ---- ARC GitHub Actions runners (server only) ----
    github-runners = {
      module = {
        name = "kin/github-runners";
        input = "self";
      };
      roles.default.tags.k3s-server = { };
    };

    # ---- Cloudflare Tunnel connector (server only) ----
    cloudflared = {
      module = {
        name = "kin/cloudflared";
        input = "self";
      };
      roles.default.tags.k3s-server = { };
    };

    # ---- hello demo origin behind the tunnel (server applies manifests) ----
    hello = {
      module = {
        name = "kin/hello";
        input = "self";
      };
      roles.default.tags.k3s-server = { };
    };

    # ---- harmonia binary cache: atlas serves, every node substitutes ----
    nix-cache = {
      module = {
        name = "kin/nix-cache";
        input = "self";
      };
      roles.server.machines.atlas = { };
      roles.client.tags.all = { };
    };

    # ---- attic binary cache: atlas serves, every node substitutes; cross-arch
    # + darwin push from non-clan hosts. publicKey set after cache bootstrap
    # (see modules/services/attic header); empty -> client substituter is off.
    attic = {
      module = {
        name = "kin/attic";
        input = "self";
      };
      roles.server.machines.atlas = { };
      roles.client = {
        tags.all = { };
        settings.publicKey = "kin:PBN2+XUcxLbw63KMem0RDJ2V+te0crwD5ucQeek3luw=";
      };
    };
  };
}
