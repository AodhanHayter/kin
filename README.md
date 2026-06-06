# kin

[clan](https://clan.lol)-managed NixOS cluster — a test migration off the
snowfall-lib `modernage` config for three k3s nodes.

## Machines

| host   | role              | notes                                   |
| ------ | ----------------- | --------------------------------------- |
| atlas  | k3s **server**    | `clusterInit` (embedded etcd), gluster primary |
| apollo | k3s **agent**     | joins `https://atlas.local:6443`        |
| hermes | k3s **agent**     | joins `https://atlas.local:6443`        |

All three are Beelink EQ13 boxes (x86_64-linux), BIOS/grub on `/dev/sda`,
GlusterFS replica-3 brick at `/data/glusterfs/brick1`, tailscale, mDNS.

## Layout

```
flake.nix                     clan-core.lib.clan wrapper; machines + inventory
machines/<host>/configuration.nix   thin per-host: hostname, role module, stateVersion
modules/
  common.nix                  nix, users, ssh (root@ key-only), avahi, sudo, locale
  hardware-beelink-eq13.nix    kernel modules + grub (shared; identical hardware)
  disko.nix                    /dev/sda layout — LOAD-BEARING (no fileSystems elsewhere)
  k3s-token.nix                shared clan-vars generator (one token, all nodes)
  k3s-server.nix / k3s-agent.nix
  gluster.nix / tailscale.nix
```

`flake.nix` imports the shared modules into every machine via `base`; each
`machines/<host>/configuration.nix` only adds the host's role module +
hostname + `stateVersion`.

## Why clan vars for the k3s token

The snow config had agents read a manual sops secret `k3s/token` while the
server (`clusterInit`) never set a matching token — so the token wasn't truly
shared. Here `modules/k3s-token.nix` defines one `share = true` generator;
atlas (server) and both agents reference the **same**
`config.clan.core.vars.generators.k3s-token.files.token.path`. Generate once,
distributed everywhere.

## First-time setup (run from the Mac)

```bash
devenv shell           # gets the `clan` CLI (dev env lives in devenv.nix)

clan machines list     # should show atlas / apollo / hermes

# 1. register yourself as a secrets admin (creates an age key)
clan vars keygen --user aodhan
clan secrets users add aodhan "$(cat ~/.config/sops/age/keys.txt | grep -oP 'public key: \K.*')"

# 2. mint + encrypt the shared k3s token (and any other vars)
clan vars generate

# commit the generated sops/ + vars/ material
git add -A
```

> Until `clan vars generate` runs, the token path evaluates to
> `/no-such-path` (a clan sentinel). **Generate vars before deploying** or k3s
> will fail to start.

## Deploy (adopt the running machines — NO wipe)

```bash
# in-place nixos-rebuild switch over SSH, one at a time:
clan machines update atlas
clan machines update apollo
clan machines update hermes
```

`update` is non-destructive (it does **not** run disko). `clan machines
install` WOULD wipe disks via disko — only use that for fresh provisioning.

### Deploy prerequisites / caveats

- **SSH as root, key-only.** `inventory.machines.<h>.deploy.targetHost =
  "root@<h>.local"`. `modules/common.nix` sets
  `PermitRootLogin = "prohibit-password"` and authorizes the keys. This
  differs from snow (which deployed as `aodhan` + `doas`); clan's documented
  path is `root@`.
- **Bootstrap auth.** The currently-running generation on the boxes authorizes
  a different key than is in this repo. To land the first `update`, the
  deploying key must already be authorized on the live machine — add your
  current key to the running `authorized_keys` (or deploy the first switch
  through whatever host currently has access). After the first successful
  `update`, the keys in `modules/common.nix` take over.
- nixpkgs is pinned to `nixos-25.11` to match `clan-core` 25.11.

## What was intentionally trimmed vs snow

Headless k3s nodes don't need the dev-environment suite, so these were dropped:
home-manager, neovim/tmux modules, prezto/zsh setup, fonts, determinate-nix
(and its `eval-cores`/snowfall-FUP nix options). GlusterFS peering + volume
creation remain manual (the snow module's automation was commented out too).
