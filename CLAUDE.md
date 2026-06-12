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

```
flake.nix                     machines (platform + imports) + inventory (deploy.targetHost, tags) + nixosConfigurations.installer (keyed bootstrap ISO)
devenv.nix / devenv.yaml      dev shell: clan-cli + git + nixfmt-rfc-style; git-hooks (shellcheck, nixfmt)
machines/<host>/configuration.nix   THIN: hostname + role module + stateVersion 24.05
modules/
  common.nix                  nix, users (aodhan + ssh keys via ssh-keys.nix), ssh root@ key-only, sudo nopass, avahi, networkmanager, locale
  ssh-keys.nix                admin authorized keys — shared by common.nix + the installer ISO
  hardware-beelink-eq13.nix   EQ13 kernel modules + grub /dev/sda (BIOS) — EQ13 nodes only
  disko.nix                   EQ13 /dev/sda layout — LOAD-BEARING (no fileSystems anywhere else)
  disko-<name>.nix            per-machine disko for non-EQ13 nodes (e.g. disko-lenny.nix: by-id, UEFI)
  k3s-token.nix               clan-vars generator: shared token (share=true, openssl rand -hex 32)
  k3s-server.nix              role=server, clusterInit, firewall, openiscsi
  k3s-agent.nix               role=agent, serverAddr=https://atlas.local:6443, firewall, openiscsi
  longhorn.nix / tailscale.nix Longhorn host prereqs (iscsi/nfs/FHS shims) / tailscale
  monitoring.nix              kube-prometheus-stack HelmChart (server-side; traefik ingress grafana.local/prometheus.local + avahi mDNS aliases, control-plane metrics flags, grafana-admin var+secret sync)
machines/<host>/hardware-configuration.nix    non-EQ13 nodes only (nixos-generate-config --no-filesystems)
vars/shared/k3s-token/        sops-encrypted shared token (the `secret` file)
vars/per-machine/<h>/state-version/
sops/machines/<h>/key.json    per-host age recipient — EQ13: from ssh host key; fresh installs: clan-generated
sops/users/aodhan/key.json    admin recipient
```

Composition: `flake.nix` builds `baseCommon` (`common`, `tailscale`, `longhorn`,
`k3s-token`) imported by every machine, and `baseEq13` (= `baseCommon` +
`hardware-beelink-eq13` + `disko`) for the three Beelink nodes. EQ13 machines
import `baseEq13 ++ [configuration.nix]`; non-EQ13 nodes (lenny) import
`baseCommon ++ [configuration.nix]` and carry their own hardware + disko. The
per-host `configuration.nix` adds the role module (`k3s-server.nix` for atlas,
`k3s-agent.nix` for the agents). `disko`'s module comes from clan-core — do
**not** add a `disko` flake input/import (it double-defines `diskoLib`).

## clan workflow (inside `devenv shell`)

```bash
devenv shell                          # provides `clan`
clan machines list                    # → atlas / apollo / hermes
clan machines update atlas            # in-place nixos-rebuild switch over root@; NON-destructive
clan vars list atlas                  # show vars for a machine
clan vars get atlas k3s-token/token   # decrypt a var: <machine> <generator>/<file>
clan vars generate                    # (re)mint vars; needs admin age key present
```

- **Never** `clan machines install` against the three live EQ13 nodes — it runs disko and **wipes the disk**. It IS the bootstrap path for a *fresh* box (see Adding a machine).
- Builds are `x86_64-linux`; a Mac can't build them. `clan machines update` takes `--build-host ultimo`. **`clan machines install` has NO `--build-host`** (only `--build-on`) — run `clan` *from ultimo* for installs (repo cloned there, `devenv shell -- clan ...`).

## Secrets / vars model

- One **shared** generator in `modules/k3s-token.nix` (`share = true`) → the
  encrypted token lives at `vars/shared/k3s-token/token/secret`. All three
  machines read `config.clan.core.vars.generators.k3s-token.files."token".path`
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
2. `machines/<name>/configuration.nix`: imports the role module
   (`k3s-agent.nix`/`k3s-server.nix`), `networking.hostName`, `system.stateVersion = "24.05"`.
   - **Non-EQ13 box:** also add `machines/<name>/hardware-configuration.nix`
     (run `nixos-generate-config --no-filesystems` on the box) and
     `modules/disko-<name>.nix` (by-id devices; UEFI → `systemd-boot` + `EF00`
     ESP, not the EQ13 grub/BIOS/`EF02`); import both from configuration.nix.
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

Create `modules/<name>.nix`, add it to `baseCommon` (all nodes) or `baseEq13`
(EQ13 only) in `flake.nix`, deploy.

## Hard rules

- **disko is load-bearing — never remove `disko.nix` or its effect.** No
  `fileSystems` exist outside it; removing it = unbootable node.
- **Don't regenerate the k3s token casually.** `clan vars generate --regenerate`
  changes the token → k3s fails with a token mismatch until you wipe
  `/var/lib/rancher/k3s` on every node and let it rejoin (a full cluster reform).
- **Deploy target is `root@<host>.local`, key-only.** No password, no doas.
  New deploy keys go in `modules/common.nix` and must be landed in a prior
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

On a node (as root): `k3s kubectl get nodes` (use `k3s kubectl`, not bare
`kubectl` — the kubeconfig is at `/etc/rancher/k3s/k3s.yaml`); Longhorn:
`k3s kubectl -n longhorn-system get pods`.
