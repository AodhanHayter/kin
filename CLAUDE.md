# CLAUDE.md — kin

Guidance for working in this repo. **kin** is a [clan](https://clan.lol)-managed
NixOS cluster: three x86_64-linux Beelink EQ13 boxes (atlas, apollo, hermes)
running k3s + GlusterFS + tailscale. A test migration off the unmaintained
snowfall-lib config (`modernage` namespace, `~/development/snow`).

- **Stack:** clan-core 25.11 (`clan-core.lib.clan` wrapper), nixpkgs nixos-25.11, both pinned in `flake.nix`.
- **Topology:** atlas = k3s **server** (`clusterInit`, embedded etcd) + gluster primary; apollo/hermes = k3s **agents** joining `https://atlas.local:6443`.
- **Deployed and live.** Changes go out via `clan machines update <host>`.

## Layout & how it composes

```
flake.nix                     machines (platform + imports) + inventory (deploy.targetHost, tags)
devenv.nix / devenv.yaml      dev shell: clan-cli + git + nixfmt-rfc-style; git-hooks (shellcheck, nixfmt)
machines/<host>/configuration.nix   THIN: hostname + role module + stateVersion 24.05
modules/
  common.nix                  nix, users (aodhan + 5 ssh keys), ssh root@ key-only, sudo nopass, avahi, networkmanager, locale
  hardware-beelink-eq13.nix   kernel modules + grub /dev/sda
  disko.nix                   /dev/sda layout — LOAD-BEARING (no fileSystems anywhere else)
  k3s-token.nix               clan-vars generator: shared token (share=true, openssl rand -hex 32)
  k3s-server.nix              role=server, clusterInit, firewall, openiscsi
  k3s-agent.nix               role=agent, serverAddr=https://atlas.local:6443, firewall, openiscsi
  gluster.nix / tailscale.nix glusterfs daemon+ports / tailscale
vars/shared/k3s-token/        sops-encrypted shared token (the `secret` file)
vars/per-machine/<h>/state-version/
sops/machines/<h>/key.json    per-host age key (derived from ssh host key) = secret recipient
sops/users/aodhan/key.json    admin recipient
```

Composition: `flake.nix` builds a `base` list (`common`, `hardware-beelink-eq13`,
`disko`, `tailscale`, `gluster`, `k3s-token`) imported into every machine, plus
the per-host `configuration.nix` which adds the role module (`k3s-server.nix`
for atlas, `k3s-agent.nix` for apollo/hermes). `disko`'s module comes from
clan-core — do **not** add a `disko` flake input/import (it double-defines
`diskoLib`).

## clan workflow (inside `devenv shell`)

```bash
devenv shell                          # provides `clan`
clan machines list                    # → atlas / apollo / hermes
clan machines update atlas            # in-place nixos-rebuild switch over root@; NON-destructive
clan vars list atlas                  # show vars for a machine
clan vars get atlas k3s-token/token   # decrypt a var: <machine> <generator>/<file>
clan vars generate                    # (re)mint vars; needs admin age key present
```

- **Never** `clan machines install` — it runs disko and **wipes the disk**. These are running nodes.
- Builds are `x86_64-linux`. A Mac can't build them — deploy from a Linux host (`ultimo`) or pass `clan machines update --build-host ultimo <host>`.

## Secrets / vars model

- One **shared** generator in `modules/k3s-token.nix` (`share = true`) → the
  encrypted token lives at `vars/shared/k3s-token/token/secret`. All three
  machines read `config.clan.core.vars.generators.k3s-token.files."token".path`
  (resolves on-host to `/run/secrets/vars/k3s-token/token`).
- Each host decrypts its secrets at activation via an **age key derived from its
  ssh host key** (`sops/machines/<host>/`); `sops-install-secrets` runs during
  the switch.
- Admin recipient = user `aodhan` (`sops/users/aodhan/`). That age key
  (`~/.config/sops/age/keys.txt`) is shared between the Mac and `ultimo`, so
  both can decrypt/regenerate.
- Before a deploy, vars must be generated (already done) or the token path
  evaluates to clan's `/no-such-path` sentinel and k3s won't start.

## Adding a machine

1. `machines/<name>/configuration.nix`:
   ```nix
   { imports = [ ../../modules/k3s-agent.nix ];  # or k3s-server.nix
     networking.hostName = "<name>";
     system.stateVersion = "24.05"; }
   ```
2. In `flake.nix`, add to `machines` (`{ nixpkgs.hostPlatform = "x86_64-linux";
   imports = base ++ [ ./machines/<name>/configuration.nix ]; }`) and to
   `inventory.machines` (`{ deploy.targetHost = "root@<name>.local"; tags = [ "k3s-agent" ]; }`).
3. Register its age key + regenerate vars so it gets the shared token:
   `clan secrets machines add <name> <age-from-ssh-host-key>` then `clan vars generate`.
4. `clan machines update <name>`.

## Adding a shared module

Create `modules/<name>.nix`, add it to the `base` list in `flake.nix`, deploy.

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
`kubectl` — the kubeconfig is at `/etc/rancher/k3s/k3s.yaml`); GlusterFS:
`gluster peer status`, `gluster volume status`.
