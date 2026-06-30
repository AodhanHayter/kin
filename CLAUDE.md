# CLAUDE.md — kin

Guidance for working in this repo. **kin** is a [clan](https://clan.lol)-managed
NixOS cluster: three x86_64-linux Beelink EQ13 boxes (atlas, apollo, hermes)
plus two non-EQ13 boxes — `lenny` (Lenovo) and `mbp` (Intel MacBookPro11,5,
joins via USB-ethernet tagged onto the cluster VLAN) — running k3s + Longhorn + tailscale.
Homelab / learning cluster — treat it as a blank slate (nothing in it is
precious), optimised for staying consistent with upstream clan.lol conventions.

- **Stack:** clan-core 25.11 (`clan-core.lib.clan` wrapper), nixpkgs nixos-25.11, both pinned in `flake.nix`.
- **Topology:** atlas = k3s **server** (`clusterInit`, embedded etcd); apollo/hermes/lenny/mbp = k3s **agents**. The agent join address is **derived** from the inventory (the single `k3s-server`-tagged machine), not hardcoded.
- **Architecture:** 100% clan-native. Every capability is a `clan.service` deployed by `inventory.instances`; roles are filled by machine **tags**. There is **no** snowfall-style toggle layer, no `kin` lib, no suites/roles-via-imports.

## Layout & how it composes

```
flake.nix                     THIN: clan-core.lib.clan { imports = [ ./clan.nix ]; } + the keyed installer ISO + formatter. No machine lists, no lib.
clan.nix                      THE BRAIN: meta(name+domain) + inventory.machines(tags + deploy.targetHost) + `modules` (registers kin's own services) + inventory.instances (every service, wired to roles by tag/machine).
devenv.nix / devenv.yaml      dev shell: clan-cli + git + nixfmt-rfc-style; git-hooks (shellcheck, nixfmt)
machines/<host>/
  configuration.nix           THIN, AUTO-INCLUDED: hostname + stateVersion 24.05 + hardware/disko imports. NO roles (tags assign those). `{ ... }:` plain module.
  hardware-configuration.nix   non-EQ13 only (nixos-generate-config --no-filesystems) — AUTO-INCLUDED
  disko.nix                    optional per-machine layout — AUTO-INCLUDED if present
modules/
  ssh-keys.nix                admin authorized keys (bare list literal) — imported by the user-*-extras modules + the installer ISO
  users/{root,aodhan}-extras.nix   supplement the clan-core `users` service (SSH keys; aodhan uid/shell) — attached via instance extraModules
  hardware/beelink-eq13/      EQ13 kernel modules + grub /dev/sda (BIOS) — PLAIN, imported by EQ13 machine configs
  storage/disko-eq13/         EQ13 /dev/sda layout — LOAD-BEARING (no fileSystems elsewhere), PLAIN, imported by EQ13 machine configs
  storage/disko-lenny/        lenny by-id/UEFI layout — LOAD-BEARING, PLAIN, imported by lenny
  services/                   kin's own clan.service modules (_class = "clan.service"):
    base/                     kin/base — OS baseline (nix, avahi, networkmanager, sudo, locale, fish, hostPlatform, sshd port knobs) — role default @ tags.all
    secrets/                  kin/secrets — SHARED vars generators (k3s-token, garage-backup-key) — role default @ tags.all (present on EVERY host)
    k3s/                      kin/k3s — roles.server (clusterInit, Longhorn chart, etcd-s3) + roles.agent (join, derives serverAddr). base.nix = shared node baseline (firewall, atlas hosts-pin, openiscsi, Longhorn host prereqs) imported by both roles
    tailscale/                kin/tailscale — role default @ tags.all; authkey generator (shared, prompted)
    monitoring/               kin/monitoring — kube-prometheus-stack via helm; role default @ tags.k3s-server; grafana-admin generator
    garage/                   kin/garage — single-node Garage S3 backup target; role default @ machines.lenny; garage-rpc-secret generator
    github-runners/           kin/github-runners — ARC runners via helm; role default @ tags.k3s-server; github-runner-token generator
vars/shared/<gen>/            sops-encrypted shared vars (k3s-token, garage-backup-key, tailscale)
vars/per-machine/<h>/<gen>/   per-machine vars (openssh host keys, user-password-*, state-version, garage-rpc-secret on lenny, ...)
sops/machines/<h>/key.json    per-host age recipient — EQ13: from ssh host key; fresh installs: clan-generated
sops/users/aodhan/key.json    admin recipient
```

**Composition (read this).** `flake.nix` just calls `clan-core.lib.clan {
imports = [ ./clan.nix ]; }`. `clan.nix` registers kin's services under top-level
`modules` (e.g. `"kin/k3s" = ./modules/services/k3s`) and deploys them via
`inventory.instances`. Each instance selects a module (`module.input = "self"`
for kin's own, `"clan-core"` for upstream prebuilt) and fills its roles by
**tag** (`roles.server.tags.k3s-server`, `roles.default.tags.all`) or by machine
(`roles.default.machines.lenny`). The machine **tags** in `inventory.machines`
(`k3s-server`, `k3s-agent`, `eq13`, plus the built-in `all`) are the live
wiring. Per-machine hardware/disko/hostname live in the auto-included
`machines/<host>/*.nix`; everything else is an instance. Upstream prebuilt
services in use: `users` (root + aodhan), `sshd`, `trusted-nix-caches`.

Do **not** add a `disko` flake input/import (clan-core provides `diskoLib`;
double-defining breaks eval) and do **not** add `snowfall-lib` (competes with
clan-core for flake outputs).

## Authoring a clan.service module

Custom services are `_class = "clan.service"` modules (see
<https://clan.lol/docs/25.11/services/definition>). Skeleton:

```nix
{ ... }:
{
  _class = "clan.service";
  manifest.name = "kin/foo";
  manifest.description = "...";
  manifest.categories = [ "System" ];   # fixed enum — see gotchas below

  roles.default = {                      # or roles.server / roles.agent / ...
    interface = { lib, ... }: {
      options.bar = lib.mkOption { type = lib.types.str; default = "x"; };
    };
    perInstance = { settings, roles, ... }: {
      nixosModule = { config, pkgs, ... }: {
        services.foo = { enable = true; baz = settings.bar; };
        # Cross-machine: read another role's members, e.g.
        #   server = builtins.head (builtins.attrNames roles.server.machines);
      };
    };
  };
}
```

Then in `clan.nix`: register it (`modules."kin/foo" = ./modules/services/foo;`)
and deploy it (`inventory.instances.foo = { module = { name = "kin/foo"; input =
"self"; }; roles.default.tags.<tag> = {}; };`). `git add` the new files (flakes
only see tracked files).

- **Shared secrets go in a service whose role covers EVERY consuming machine.**
  A `clan.core.vars.generators.*` declared in a `perInstance` only exists on that
  role's member machines. For a secret consumed across hosts (k3s-token,
  garage-backup-key), declare it in `kin/secrets` (role default @ `tags.all`), so
  it exists on every node unconditionally. A generator scoped to a single-host
  service (grafana-admin on the server, garage-rpc-secret on lenny) is fine
  inside that service's `perInstance` — the consuming host == the running host.
  Never gate a shared secret behind partial role membership.
- **Settings must be serializable** (they round-trip through inventory). Expose
  plain data via `interface.options`; keep functions/derivations inside
  `perInstance`/`perMachine`.
- **clan-core 25.11 gotchas** (the pinned version is older than `../clan-core`'s
  `main`; verify against the pinned store path, not the checkout):
  - `manifest.categories` is a fixed enum (Audio/AudioVideo/Desktop/Development/
    Education/Game/Graphics/Network/Office/Science/Settings/Social/System/
    Uncategorized/Utility/Video). No "Monitoring".
  - `manifest.constraints` does **not** exist. Enforce "one server" by tagging
    one machine, not by a constraint.
  - the prebuilt `users` service manages only account/password/groups — **no**
    `openssh`/uid/shell options; supply those via `roles.*.extraModules`.
  - the prebuilt `sshd` service has **no** `certificate.enable`; the CA cert is
    gated by `certificate.searchDomains` (default `[]` → no cert).

## clan workflow (inside `devenv shell`)

```bash
devenv shell                          # provides `clan`
clan machines list                    # → atlas / apollo / hermes / lenny / mbp
clan machines update atlas            # in-place nixos-rebuild switch over root@; NON-destructive
clan vars list atlas                  # show vars for a machine
clan vars get atlas k3s-token/token   # decrypt a var: <machine> <generator>/<file>
clan vars generate                    # (re)mint vars; needs admin age key present; PROMPTS for tailscale authkey + github PAT
```

- **Never** `clan machines install` against a live node — it runs disko and **wipes the disk**. It IS the bootstrap path for a *fresh* box (see Adding a machine).
- Builds are `x86_64-linux`; a Mac can't build them. `clan machines update` takes `--build-host ultimo`. **`clan machines install` has NO `--build-host`** (only `--build-on`) — run `clan` *from ultimo* for installs (repo cloned there, `devenv shell -- clan ...`).

## Secrets / vars model

- **Shared** generators live in `kin/secrets` (role default @ `tags.all`,
  `share = true`): `k3s-token` → `vars/shared/k3s-token/token/secret`,
  `garage-backup-key` → shared S3 creds consumed by atlas (Longhorn/etcd backups)
  AND lenny (Garage). Every machine reads e.g.
  `config.clan.core.vars.generators.k3s-token.files."token".path` (resolves
  on-host to `/run/secrets/vars/k3s-token/token`).
- **Per-service** generators sit in their own service's `perInstance`:
  `tailscale` authkey (tags.all), `grafana-admin` (server), `garage-rpc-secret`
  (lenny), `github-runner-token` (server). The prebuilt `users`/`sshd` services
  add `user-password-*` and `openssh` host-key generators.
- Each host decrypts its secrets at activation via a **standalone machine age
  key** (`sops/machines/<host>/key.json`, deployed to `/var/lib/sops-nix/key.txt`)
  — independent of the SSH host key, so deploys never break decryption. A fresh
  `clan machines install` auto-generates that key + re-encrypts shared vars to it.
  (Historically EQ13 keys were *bootstrapped* from the ssh host key; that is
  no longer load-bearing.)
- The `sshd` service now owns the **SSH host keys** (clan `openssh` generator,
  vars-managed). Deploying onto an already-live box swaps its host key → clear
  stale entries (`ssh-keygen -R <host>`); sops is unaffected.
- Admin recipient = user `aodhan` (`sops/users/aodhan/`). That age key
  (`~/.config/sops/age/keys.txt`) is shared between the Mac and `ultimo`.
- **Pre-deploy gate (run `clan vars generate` first).** The prebuilt `users` +
  `sshd` services add NEW generators (`openssh` host keys, `user-password-root`,
  `user-password-aodhan`). Until they're minted, full `toplevel` eval fails (the
  sshd module reads the host pubkey `.value` at eval time) AND — because the
  `users` service forces `mutableUsers = false` — **neither root nor aodhan has a
  console password** (SSH-key login still works, so deploys don't brick).
  Retrieve aodhan's console password after generating:
  `clan vars get <machine> user-password-aodhan/user-password`.

## Adding a machine

1. **Boot it off the installer ISO** — `nix build .#nixosConfigurations.installer.config.system.build.isoImage`
   (on ultimo) → dd to USB. The box comes up as `kin-installer.local`, sshd +
   admin keys baked in. Wire ethernet; grab its IP + facts (`uname -m`, `lsblk`,
   UEFI vs BIOS).
2. `machines/<name>/configuration.nix` (auto-included): plain `{ ... }:` module —
   `networking.hostName`, `system.stateVersion = "24.05"`, and the hardware/disko
   imports. EQ13 → import `../../modules/hardware/beelink-eq13` +
   `../../modules/storage/disko-eq13`. Non-EQ13 → add
   `machines/<name>/hardware-configuration.nix` (`nixos-generate-config
   --no-filesystems`) and a disko layout (by-id devices; UEFI → `systemd-boot` +
   `EF00` ESP, not the EQ13 grub/BIOS/`EF02`); import the disko + set
   `boot.loader.systemd-boot`.
3. `clan.nix`: add the `inventory.machines.<name>` entry (`deploy.targetHost =
   "root@<name>.local"; tags = [ "k3s-agent" ... ];`). The tags wire it into the
   existing service instances — no per-machine role config. `git add` new files.
4. **Install from ultimo:** `clan machines install <name> --target-host root@<ip>
   --update-hardware-config none --host-key-check accept-new --yes`. clan wipes
   the disko disks, installs, reboots; it auto-generates the machine age key +
   re-encrypts shared vars, so k3s joins on first boot.
5. `git push` clan's commits from ultimo; fast-forward the Mac.

## Adding / changing a service

- **New kin service:** author `modules/services/<name>/default.nix` (see
  **Authoring a clan.service module**), register it under `clan.nix` `modules`,
  add an `inventory.instances.<name>` entry assigning roles by tag/machine.
- **Adopt an upstream prebuilt service:** no module file — just an
  `inventory.instances.<name>` entry with `module = { name = "<svc>"; input =
  "clan-core"; }`. Check the pinned interface (see gotchas) before assuming
  options exist.
- **Change where a service runs:** edit the instance's role `tags`/`machines` in
  `clan.nix` — the machine tags are the single source of truth.
- **Pin Helm chart versions + values from source, not memory/search:**
  `curl -fsSL <repo>/index.yaml | grep -A2 '^  <chart>:'` for the real version,
  and `curl` the chart's `values.yaml` to confirm value keys before writing
  `valuesContent` — artifacthub/web search lag releases, and a wrong version/key
  fails silently in the `helm-install-<name>` job, never at `nix eval`.

## Hard rules

- **disko is load-bearing — never remove `storage/disko-eq13` / `disko-lenny` or
  its effect, and never gate it (`mkIf`/role membership on disko = unbootable).**
  It is a plain import in `machines/<host>/configuration.nix`, never a service.
- **Shared-secret generators must reach every consuming host.** Put cluster-wide
  secrets in `kin/secrets` (`tags.all`); never declare a cross-host secret inside
  a `perInstance` gated by partial role membership, or a consuming host silently
  loses it (most dangerous for `k3s-token`).
- **Don't add snowfall-lib** (competes with clan-core for flake outputs). The old
  `kin` lib / `mkBoolOpt` toggle layer is gone — don't reintroduce it; use
  `clan.service` roles + `interface.options` instead.
- **Don't regenerate the k3s token casually.** `clan vars generate --regenerate`
  on `k3s-token` → token mismatch until you wipe `/var/lib/rancher/k3s` on every
  node and let it rejoin (a full cluster reform). The on-disk path depends only
  on `(generator name, share, file)` — keep the name `k3s-token` + `share=true`.
- **Deploy target is `root@<host>.local`, key-only.** No password, no doas. Root
  authorized keys come from the `user-root` instance's `root-extras.nix` (which
  imports `modules/ssh-keys.nix`); a new deploy key must land in a prior
  generation before it works.
- **Build host must be x86_64-linux** (Mac can edit/decrypt secrets but not build).
- **ultimo's login shell is fish** — wrap remote bash in `ssh ultimo bash -s <<'EOF'`; plain `ssh ultimo '... if/fi ...'` breaks on fish syntax.
- **Nix flakes see only git-tracked files** — `git add` new `.nix` before `nix eval`/`build`/`clan`, else it errors "not tracked by Git".
- **stateVersion is `24.05`, per-machine, not clan-managed** — leave it.
- **Formatting:** the nixfmt (rfc-style) pre-commit hook will reject unformatted
  `.nix`; run `nixfmt <files>` or let the hook fix on commit.

## Verifying a change

```bash
# Evaluate a host's full system (catches module errors) — no build.
# NOTE: after adding generators, this fails on ungenerated `.value` reads (e.g.
# the sshd host pubkey) until `clan vars generate` runs — that's expected, not a
# module error. To check WIRING without generating vars, eval a specific option:
nix eval --raw '.#nixosConfigurations.apollo.config.services.k3s.serverAddr'   # → https://atlas.local:6443
nix eval --json '.#nixosConfigurations.atlas.config.clan.core.vars.generators' --apply 'builtins.attrNames'

# Full closure (after vars exist; needs x86_64-linux or a remote builder):
nix build ".#nixosConfigurations.atlas.config.system.build.toplevel" --no-link

clan machines list                    # clan sees the machines
```

On a node (as root): `k3s kubectl get nodes` (use `k3s kubectl`, not bare
`kubectl` — kubeconfig is at `/etc/rancher/k3s/k3s.yaml`); Longhorn:
`k3s kubectl -n longhorn-system get pods`.

**From the Mac (no ssh):** `kubectl` is on PATH with context `kin` →
`kubectl -n <ns> get pods` reaches the cluster directly.

**Verify an in-cluster Helm deploy** (after `git push`, comin auto-applies in
~60s): `kubectl -n kube-system get helmchart` shows the chart; a stuck/failed
install surfaces in `kubectl -n kube-system get pods | grep helm-install-<name>`
(read its logs — helm-controller failures are otherwise quiet). Probe a ClusterIP
service from a throwaway pod: `kubectl -n <ns> run t --rm -i --restart=Never
--image=curlimages/curl:8.11.1 --command -- sh -c 'curl -s <url>'`.

**kube-prometheus-stack Grafana:** datasource/value-only changes do NOT roll the
grafana pod (provisioning loads at startup) → after such a change run
`kubectl -n monitoring rollout restart deploy kube-prometheus-stack-grafana`.
Admin creds: `clan vars get atlas grafana-admin/password` (user `admin`).
