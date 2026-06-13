# CLAUDE.md — kin

Guidance for working in this repo. **kin** is a [clan](https://clan.lol)-managed
NixOS cluster: three x86_64-linux Beelink EQ13 boxes (atlas, apollo, hermes)
plus `lenny` (a non-EQ13 Lenovo box), running k3s + Longhorn + tailscale. A test
migration off the unmaintained snowfall-lib config (`modernage` namespace,
`~/development/snow`).

- **Stack:** clan-core 25.11 (`clan-core.lib.clan` wrapper), nixpkgs nixos-25.11, both pinned in `flake.nix`.
- **Topology:** atlas = k3s **server** (`clusterInit`, embedded etcd); apollo/hermes/lenny = k3s **agents** joining `https://atlas.local:6443`.
- **Deployed and live.** Changes go out via `clan machines update <host>`.

## Layout & how it composes

Modules use the snow repo's **snowfall-lib authoring style** (option toggles,
`mkBoolOpt`, `enabled`, suites/roles) **reproduced WITHOUT snowfall-lib** — it
conflicts with clan-core. A hand-rolled `lib/` is injected as the `kin` module
arg via clan `specialArgs`. See **Authoring a module** below.

```
flake.nix                     specialArgs.kin (snow-style lib) + machines (platform + imports) + inventory (deploy.targetHost, tags) + nixosConfigurations.installer (keyed bootstrap ISO)
devenv.nix / devenv.yaml      dev shell: clan-cli + git + nixfmt-rfc-style; git-hooks (shellcheck, nixfmt)
lib/default.nix               snow-style helpers (mkOpt/mkBoolOpt/enabled/disabled), injected as the `kin` arg — NOT snowfall-lib
machines/<host>/configuration.nix   THIN: `{ kin, ... }: with kin;` + one role toggle (kin.roles.* = enabled) + hostname + stateVersion 24.05
modules/                      categorized tree; every module is <category>/<name>/default.nix
  system/common/              nix, users (aodhan + ssh keys via system/ssh-keys.nix), ssh root@ key-only, sudo nopass, avahi, networkmanager, locale — PLAIN (always-on)
  system/k3s-base/            shared k3s node baseline: firewall, atlas /etc/hosts pin, openiscsi, gracefulNodeShutdown — PLAIN
  system/ssh-keys.nix         admin authorized keys (bare list literal) — imported by system/common + the installer ISO
  hardware/beelink-eq13/      EQ13 kernel modules + grub /dev/sda (BIOS) — TOGGLED (kin.hardware.beelink-eq13.enable), EQ13 nodes only
  storage/longhorn-host/      Longhorn host prereqs (iscsi/nfs/FHS shims) — PLAIN
  storage/disko-eq13/         EQ13 /dev/sda layout — LOAD-BEARING (no fileSystems anywhere else), PLAIN
  storage/disko-lenny/        lenny by-id/UEFI layout — LOAD-BEARING, PLAIN
  services/tailscale/         tailscale — TOGGLED (kin.services.tailscale); generator UNCONDITIONAL
  services/monitoring/        kube-prometheus-stack (traefik ingress grafana.local/prometheus.local, mDNS aliases, grafana-admin var) — TOGGLED (server)
  services/garage/            Garage S3 (lenny) — TOGGLED; garage-rpc-secret generator UNCONDITIONAL
  services/github-runners/    ARC GitHub runners (atlas) — TOGGLED; github-runner-token generator UNCONDITIONAL
  secrets/k3s-token/          clan-vars generator: shared token (share=true, openssl rand -hex 32) — PLAIN, NO toggle
  secrets/garage-backup-key/  shared S3 creds (atlas + lenny) — PLAIN, NO toggle
  roles/k3s-server/           kin.roles.k3s-server: server k3s (clusterInit), Longhorn chart, etcd-s3; imports k3s-base + garage-backup-key + monitoring; enables monitoring
  roles/k3s-agent/            kin.roles.k3s-agent: agent k3s join; imports k3s-base
  suites/cluster-node/        baseline every node gets (via baseCommon): imports common + longhorn-host + k3s-token + tailscale; enables tailscale
  suites/eq13-node/           EQ13 tier (via baseEq13): imports beelink-eq13 + disko-eq13; enables beelink-eq13
machines/<host>/hardware-configuration.nix    non-EQ13 nodes only (nixos-generate-config --no-filesystems)
vars/shared/k3s-token/        sops-encrypted shared token (the `secret` file)
vars/per-machine/<h>/state-version/
sops/machines/<h>/key.json    per-host age recipient — EQ13: from ssh host key; fresh installs: clan-generated
sops/users/aodhan/key.json    admin recipient
```

Composition: `flake.nix` injects the `kin` lib (`specialArgs.kin = import ./lib
{ lib = nixpkgs.lib; }`), then builds `baseCommon` (= the `suites/cluster-node`
module: imports common + longhorn-host + k3s-token + tailscale, flips
`kin.services.tailscale = enabled`) imported by every machine, and `baseEq13`
(= `baseCommon` + `suites/eq13-node`, adding the EQ13 hardware profile +
`disko-eq13`) for the three Beelink nodes. EQ13 machines import `baseEq13 ++
[configuration.nix]`; lenny imports `baseCommon ++ [configuration.nix]` and
carries its own hardware + `disko-lenny`. Each thin `configuration.nix` selects
a role by flipping one toggle — `kin.roles.k3s-server = enabled` (atlas) or
`kin.roles.k3s-agent = enabled` (agents). `disko`'s module comes from clan-core
— do **not** add a `disko` flake input/import (it double-defines `diskoLib`),
and do **not** add `snowfall-lib` (it competes with clan-core for flake outputs).

## Authoring a module

Snow-style skeleton; clan-compatible. Modules receive the injected `kin` lib:

```nix
{ config, lib, kin, ... }:
with lib;
with kin;
let cfg = config.kin.services.foo;
in {
  options.kin.services.foo.enable = mkBoolOpt false "Whether to run foo.";
  config = mkMerge [
    { clan.core.vars.generators.foo = { ... }; }   # generator UNCONDITIONAL
    (mkIf cfg.enable { services.foo = { ... }; })   # only the service is gated
  ];
}
```

- **Generators stay OUTSIDE `mkIf`** (via `mkMerge`). Gating a `clan.core.vars.generators.*`
  couples "feature enabled" to "secret exists" → a disabled host silently drops
  its secret at runtime. This is the single most important rule.
- **Toggle selectively.** Only genuinely-optional services/hardware get an
  `enable`; always-on baseline (common, k3s-base, longhorn-host, disko-*,
  secrets/*) stays PLAIN (a bare attrset, no `options`/`mkIf`).
- A toggled leaf is turned on by a suite (`kin.services.tailscale = enabled` in
  cluster-node), a role (`kin.services.monitoring = enabled` in k3s-server), or a
  machine config (`kin.services.garage = enabled` in lenny). Composition is 100%
  explicit imports — no auto-discovery walker, no inventory-tag dispatch (clan
  tags are dead metadata; nothing in per-machine NixOS config reads them).

## clan workflow (inside `devenv shell`)

```bash
devenv shell                          # provides `clan`
clan machines list                    # → atlas / apollo / hermes / lenny
clan machines update atlas            # in-place nixos-rebuild switch over root@; NON-destructive
clan vars list atlas                  # show vars for a machine
clan vars get atlas k3s-token/token   # decrypt a var: <machine> <generator>/<file>
clan vars generate                    # (re)mint vars; needs admin age key present
```

- **Never** `clan machines install` against the three live EQ13 nodes — it runs disko and **wipes the disk**. It IS the bootstrap path for a *fresh* box (see Adding a machine).
- Builds are `x86_64-linux`; a Mac can't build them. `clan machines update` takes `--build-host ultimo`. **`clan machines install` has NO `--build-host`** (only `--build-on`) — run `clan` *from ultimo* for installs (repo cloned there, `devenv shell -- clan ...`).

## Secrets / vars model

- One **shared** generator in `modules/secrets/k3s-token/` (`share = true`) → the
  encrypted token lives at `vars/shared/k3s-token/token/secret`. Every machine
  reads `config.clan.core.vars.generators.k3s-token.files."token".path`
  (resolves on-host to `/run/secrets/vars/k3s-token/token`).
- Each host decrypts its secrets at activation via an age key in
  `sops/machines/<host>/`; `sops-install-secrets` runs during the switch. EQ13
  nodes' keys are derived from the ssh host key; a fresh `clan machines install`
  instead **auto-generates the machine key + re-encrypts shared vars to it** (no
  manual `clan secrets machines add`).
- Admin recipient = user `aodhan` (`sops/users/aodhan/`). That age key
  (`~/.config/sops/age/keys.txt`) is shared between the Mac and `ultimo`, so
  both can decrypt/regenerate.
- Before a deploy, vars must be generated (already done) or the token path
  evaluates to clan's `/no-such-path` sentinel and k3s won't start.

## Adding a machine

1. **Boot it off the installer ISO** — `nix build .#nixosConfigurations.installer.config.system.build.isoImage`
   (on ultimo) → dd to USB. The box comes up as `kin-installer.local`, sshd +
   admin keys baked in. Wire ethernet; grab its IP + facts (`uname -m`, `lsblk`,
   UEFI vs BIOS).
2. `machines/<name>/configuration.nix`: thin `{ kin, ... }: with kin;` module —
   imports the role module (`../../modules/roles/k3s-agent` or `.../k3s-server`),
   flips it on (`kin.roles.k3s-agent = enabled;`), sets `networking.hostName`,
   `system.stateVersion = "24.05"`.
   - **Non-EQ13 box:** also add `machines/<name>/hardware-configuration.nix`
     (run `nixos-generate-config --no-filesystems` on the box) and
     `modules/storage/disko-<name>/default.nix` (by-id devices; UEFI →
     `systemd-boot` + `EF00` ESP, not the EQ13 grub/BIOS/`EF02`); import both
     from configuration.nix.
3. `flake.nix`: add to `machines` — EQ13 → `baseEq13 ++ [./machines/<name>/configuration.nix]`,
   non-EQ13 → `baseCommon ++ [...]` (each with `nixpkgs.hostPlatform = system`).
   Add the `inventory.machines` entry (`deploy.targetHost = "root@<name>.local"; tags = [...]`).
   `git add` the new files (flakes only see tracked files).
4. **Install from ultimo:** `clan machines install <name> --target-host root@<ip>
   --update-hardware-config none --host-key-check accept-new --yes`. clan wipes
   the disko disks, installs, reboots; it auto-generates the machine age key +
   re-encrypts the shared k3s-token, so k3s joins on first boot.
5. `git push` clan's commits from ultimo; fast-forward the Mac.

## Adding a shared module

Create `modules/<category>/<name>/default.nix` in the snow skeleton (see
**Authoring a module** — generator outside `mkIf`). Then wire it in by import +
enable: a node-wide leaf goes in the `suites/cluster-node` import list (+ `kin.<cat>.<name> = enabled`),
an EQ13-only one in `suites/eq13-node`, a server/agent one in the matching
`roles/*`, and a single-host one in that machine's `configuration.nix`. Always-on
baseline can stay PLAIN (no toggle). `git add` the new file, then deploy.

## Hard rules

- **disko is load-bearing — never remove `storage/disko-eq13` (or `disko-lenny`)
  or its effect, and never gate it behind a toggle (`mkIf` on disko = unbootable).**
  No `fileSystems` exist outside it.
- **Never put a `clan.core.vars.generators.*` inside `config = mkIf cfg.enable`.**
  Generators stay unconditional (outside `mkIf`, via `mkMerge`) — gating one
  silently drops its secret on a disabled host. Most dangerous for the k3s-token.
- **Don't add snowfall-lib.** kin replicates its *conventions* only (the `kin`
  lib + option toggles); the actual lib competes with clan-core for flake outputs.
- **Don't regenerate the k3s token casually.** `clan vars generate --regenerate`
  changes the token → k3s fails with a token mismatch until you wipe
  `/var/lib/rancher/k3s` on every node and let it rejoin (a full cluster reform).
- **Deploy target is `root@<host>.local`, key-only.** No password, no doas.
  New deploy keys go in `modules/system/common/` and must be landed in a prior
  generation before they work.
- **Build host must be x86_64-linux** (Mac can edit/decrypt secrets but not build).
- **ultimo's login shell is fish** — wrap remote bash in `ssh ultimo bash -s <<'EOF'`; plain `ssh ultimo '... if/fi ...'` breaks on fish syntax.
- **Nix flakes see only git-tracked files** — `git add` new `.nix` before `nix eval`/`build`/`clan`, else it errors "not tracked by Git".
- **stateVersion is `24.05`, per-machine, not clan-managed** — leave it.
- **Formatting:** the nixfmt (rfc-style) pre-commit hook will reject unformatted
  `.nix`; run `nixfmt <files>` or let the hook fix on commit.

## Verifying a change

```bash
# Evaluate a host's full system (catches module errors) — no build:
nix eval ".#nixosConfigurations.atlas.config.system.build.toplevel.drvPath"

# Build a closure (slow first time; needs x86_64-linux or a remote builder):
nix build ".#nixosConfigurations.atlas.config.system.build.toplevel" --no-link

# clan sees the machines:
clan machines list
```

For a pure refactor (moving/restyling modules without behavior change), gate on
**drvPath equality** — the closure must not change:

```bash
# snapshot before, compare after; works cross-platform (eval, not build):
for h in atlas apollo hermes lenny; do
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath"
done
```

A changed hash means the refactor wasn't semantically null — investigate with
`nix run nixpkgs#nix-diff -- <old>.drv <new>.drv` before deploying.

On a node (as root): `k3s kubectl get nodes` (use `k3s kubectl`, not bare
`kubectl` — the kubeconfig is at `/etc/rancher/k3s/k3s.yaml`); Longhorn:
`k3s kubectl -n longhorn-system get pods`.
