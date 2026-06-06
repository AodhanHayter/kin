# kin

A [clan](https://clan.lol)-managed NixOS cluster — a test migration off the
unmaintained snowfall-lib `modernage` config. Three Beelink EQ13 nodes running
k3s with GlusterFS replica-3 storage.

## Machines

| host   | role        | notes                                             |
| ------ | ----------- | ------------------------------------------------- |
| atlas  | k3s server  | `clusterInit` (embedded etcd HA), gluster primary |
| apollo | k3s agent   | joins `https://atlas.local:6443`                  |
| hermes | k3s agent   | joins `https://atlas.local:6443`                  |

All x86_64-linux, BIOS/grub on `/dev/sda`. GlusterFS brick at
`/data/glusterfs/brick1` (xfs, 100 GiB). mDNS + tailscale enabled.
`stateVersion = "24.05"` (pinned, not managed by clan).

> Deployed and running. Use `clan machines update <host>` for changes.

## Repository layout

```
flake.nix                          clan-core.lib.clan wrapper; machines + inventory
devenv.nix / devenv.yaml           dev shell (clan CLI, git, nixfmt-rfc-style)
devenv.lock                        locked devenv inputs (nixpkgs, clan-core, git-hooks)

machines/
  atlas/configuration.nix          atlas: hostname + k3s-server module
  apollo/configuration.nix         apollo: hostname + k3s-agent module
  hermes/configuration.nix         hermes: hostname + k3s-agent module

modules/
  common.nix                       baseline: nix, users, ssh root@ key-only, avahi, sudo, locale
  hardware-beelink-eq13.nix        kernel modules + grub /dev/sda (shared, identical hardware)
  disko.nix                        /dev/sda partitioning — LOAD-BEARING (no fileSystems elsewhere)
  k3s-token.nix                    clan-vars generator: shared k3s join token (all 3 nodes)
  k3s-server.nix                   atlas control-plane + firewall (6443, 2379, 2380, 8472)
  k3s-agent.nix                    apollo/hermes worker + firewall
  gluster.nix                      GlusterFS daemon + ports (24007, 24008, 38465-38467, 49152-49252)
  tailscale.nix                    tailscale service + openFirewall

vars/
  shared/k3s-token/                generated shared k3s token (sops-encrypted)
  per-machine/{atlas,apollo,hermes}/state-version/

sops/
  machines/{atlas,apollo,hermes}/  per-machine age keys (derived from SSH host keys)
  users/aodhan/                    admin user age key (shared with the Linux deploy host)
```

Each `machines/<host>/configuration.nix` is minimal: hostname, role module
import, stateVersion. All shared modules are imported via the `base` list in
`flake.nix`.

## The k3s token: clan vars vs. snowfall

The snow config had agents read a manual sops secret while the server
(`clusterInit`) never set a matching token — they were out of sync. Here,
`modules/k3s-token.nix` defines a single **shared** clan-vars generator:

```nix
clan.core.vars.generators.k3s-token = {
  share = true;                  # one value across all machines
  files."token".secret = true;   # sops-encrypted, deployed to the host
  runtimeInputs = [ pkgs.openssl ];
  script = ''
    openssl rand -hex 32 > "$out"/token
  '';
};
```

atlas (server) and both agents reference the same path —
`config.clan.core.vars.generators.k3s-token.files."token".path` — which
resolves on-host to `/run/secrets/vars/k3s-token/token`. Generated once,
distributed everywhere.

## Deploying changes

The clan CLI lives in the devenv shell (there is no flake devShell).

```bash
devenv shell                 # provides the `clan` CLI
clan machines list           # → atlas / apollo / hermes
clan machines update atlas   # in-place nixos-rebuild switch over SSH (no wipe)
clan machines update apollo
clan machines update hermes
```

- Deploy target is `root@<host>.local`, **SSH key-only** (set in
  `modules/common.nix`: `PermitRootLogin = "prohibit-password"`, no password
  auth). Authorized keys are baked into `common.nix`.
- `clan machines update` is non-destructive. **`clan machines install` would
  WIPE disks via disko** — only for fresh provisioning, never for these
  running nodes.

### Build host (Mac vs. Linux)

Closures are `x86_64-linux`; a Mac (`aarch64-darwin`) **cannot build them**.
This cluster is driven from a Linux host (`ultimo`, which holds a clone of this
repo). To deploy from a Mac, build on a Linux host:

```bash
clan machines update --build-host ultimo atlas
```

The clan-secrets admin age key (`~/.config/sops/age/keys.txt`) is the same on
the Mac and on `ultimo` (both are user `aodhan`), so either can
decrypt/manage secrets — only the *build* must happen on Linux.

## Gotchas

- **disko is load-bearing.** `hardware-beelink-eq13.nix` declares no
  `fileSystems`; `disko.nix` generates `/`, `/boot`, swap, and the gluster
  brick. Drop it and the machine won't boot.
- **Regenerating the k3s token reforms the cluster.** `clan vars generate
  --regenerate` mints a new token; k3s then fails to start with a token
  mismatch until you wipe `/var/lib/rancher/k3s` on each node and let it
  rejoin. Don't do it casually.
- **New kernel needs a reboot.** `nixos-rebuild switch` won't reboot; run
  `reboot` on the node to pick up a kernel bump.
- **stateVersion stays `24.05`** (per-machine, not managed by clan).

## Secrets bootstrap (already done)

For reference — this was performed once and the encrypted material is committed:

```bash
clan vars keygen --user aodhan                 # admin age key
clan secrets users add aodhan <age-pubkey>     # register admin
clan secrets machines add <host> <host-agekey> # per host (derived from ssh host key)
clan vars generate                             # mint + encrypt the shared token
```

## Trimmed vs. snowfall

Headless k3s nodes don't need the dev suite, so these were dropped:
home-manager, neovim/tmux/zsh/prezto, fonts, and determinate-nix (with its
`eval-cores`/snowfall-FUP nix options). GlusterFS peering + volume creation
remain manual (out-of-band).

## Git hooks

`devenv shell` installs pre-commit hooks (defined in `devenv.nix` via
git-hooks.nix): **shellcheck** for shell scripts, **nixfmt** (rfc-style) for
Nix files. A commit fails if any `.nix` file is unformatted.
