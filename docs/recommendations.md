# kin — improvement recommendations

Goal: a k3s cluster for quickly testing deployments and infrastructure
approaches from the local environment. Audit date: 2026-06-10 (live cluster
inspected: all 4 nodes Ready, k3s v1.34.5, Longhorn 1.12.0, whoami test app
running).

## Hardware inventory (observed)

| node   | CPU                  | RAM   | disk                                  | role       |
| ------ | -------------------- | ----- | ------------------------------------- | ---------- |
| atlas  | Intel N200, 4c       | 16 GB | 477 GB SSD (100 G Longhorn, 366 G /)  | server+etcd|
| apollo | Intel N200, 4c       | 16 GB | 477 GB SSD (100 G Longhorn, 366 G /)  | agent      |
| hermes | Intel N200, 4c       | 16 GB | 477 GB SSD (100 G Longhorn, 366 G /)  | agent      |
| lenny  | 8 threads (older)    | 8 GB  | 240 GB SSD (root+Longhorn) + 1 TB HDD | agent      |

Utilization is low everywhere (~1–2 GB RAM used, <6% root disk). Plenty of
headroom for heavier test workloads.

---

## P1 — broken or risky today

### 1. Open kubelet port 10250 — metrics are broken on agents
`kubectl top nodes` returns `<unknown>` for apollo/hermes/lenny: metrics-server
scrapes `<node-ip>:10250`, which the firewall blocks (verified: connection to
apollo:10250 refused; `kubectl logs`/`exec` only work because they ride k3s'
apiserver tunnel). Add to a shared k3s module:

```nix
networking.firewall.allowedTCPPorts = [ 10250 ];
```

### 2. Node IPs are DHCP — an atlas lease change breaks the cluster
etcd on atlas is pinned to its node IP (10.10.0.100); agents/etcd also cache
it. If the router hands out a different lease, the control plane breaks and
the join path (`https://atlas.local:6443` via mDNS) is the only fallback.
Minimum fix: DHCP reservations at the router for all four MACs. Better: also
add static `networking.hosts` entries so the k3s join path doesn't depend on
avahi being up before k3s starts:

```nix
networking.hosts."10.10.0.100" = [ "atlas.local" "atlas" ];
```

### 3. Tighten agent firewall — etcd ports open for no reason
`k3s-agent.nix` opens 6443/2379/2380; agents listen on none of these (etcd
runs only on atlas, agents dial out to the server). Drop them. While here,
dedupe: server and agent modules duplicate the firewall + `services.openiscsi`
blocks — extract a `modules/k3s-common.nix` (flannel 8472/udp, 10250, iSCSI)
imported by both roles.

### 4. Tailscale is enabled but logged out (atlas verified)
Dead weight as-is. Either authenticate declaratively — mint an auth key, store
it as a clan var, point `services.tailscale.authKeyFile` at it — or remove the
module until needed. Declarative auth is the better fit: it also unlocks
running `kubectl` against the cluster from anywhere on the tailnet (see #6).

---

## P2 — the primary goal: fast test loop from the Mac

### 5. Get kubectl/helm/k9s + a kubeconfig on the Mac
Right now the Mac has no kubectl, no helm, no kubeconfig — every interaction
requires `ssh root@atlas.local k3s kubectl ...`. This is the single biggest
friction for "test deployments quickly". Two pieces:

- **Tooling in the dev shell** (`devenv.nix`): add `kubectl`, `kubernetes-helm`,
  `k9s` to `packages`. One shell for clan + cluster work.
- **Kubeconfig**: `scp root@atlas.local:/etc/rancher/k3s/k3s.yaml ~/.kube/config`
  and rewrite `server:` to `https://atlas.local:6443`.

For the TLS cert to accept that name, add a SAN in `k3s-server.nix`:

```nix
services.k3s.extraFlags = [ "--tls-san=atlas.local" ];
# later, for tailnet access: "--tls-san=atlas.<tailnet>.ts.net"
```

### 6. Pick a deployment workflow for test apps
The whoami app was deployed by hand. Options, in increasing weight:

1. **kubectl/helm from the Mac** (after #5) — zero infra, fine to start.
2. **k3s manifests dir via NixOS** — already used for Longhorn
   (`services.k3s.manifests.*`); good for cluster-level infra, wrong place for
   fast-iterating test apps (every change is a `clan machines update`).
3. **GitOps (Argo CD or Flux)** — a repo of test manifests, auto-synced. This
   is itself an "infrastructure approach to test", matches the stated goal,
   and keeps test workloads out of the NixOS layer. Recommended once #5 feels
   limiting.

Rule of thumb: NixOS/clan owns the platform (k3s, Longhorn, ingress); k8s-native
tooling owns the workloads.

### 7. Quality-of-life on the nodes
- `kubectl` is installed cluster-wide but unconfigured. On atlas set
  `environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";` so bare
  `kubectl` works for root; drop the kubectl package from agents (no
  credentials there).
- Add `services.k3s.gracefulNodeShutdown.enable = true;` — clean pod drain on
  the frequent reboots a test cluster sees (kernel bumps).
- Mac ssh papercut: `lenny.local` is missing from `~/.ssh/known_hosts`
  (BatchMode ssh fails). One `ssh root@lenny.local true` to accept it.

---

## P3 — leverage idle hardware

### 8. lenny's 1 TB HDD is completely unused
`/mnt/bulk` was provisioned as "Longhorn backup target" but Longhorn has **no
backup target configured**. Wire it up: export it over NFS from lenny and set
the Longhorn default:

```nix
# lenny: services.nfs.server.enable + export /mnt/bulk/longhorn-backups
# k3s-server.nix Longhorn values:
#   defaultSettings.backupTarget = "nfs://lenny.local:/mnt/bulk/longhorn-backups"
```

This turns on volume backup/restore/DR testing — exactly the kind of infra
approach worth rehearsing. Alternative: MinIO on lenny (S3 API) — heavier, but
more realistic and reusable for etcd snapshots (#10).

### 9. EQ13 Longhorn capacity is artificially small
Each EQ13 gives Longhorn 100 G, minus the default 30% reserve → ~68 G usable
per node (≈68 G effective at replica-3), while 350 G sits idle on `/`.
Non-destructive expansion: create `/var/lib/longhorn-extra` on the root fs and
add it as a second disk on each Longhorn node (UI or Node CR) — no
repartitioning, no disko change. Also consider whether the default
`storageReserved` (30%) is worth lowering on the dedicated 100 G partition —
that reserve exists to protect shared disks, and the partition is exclusive to
Longhorn.

### 10. etcd snapshots are local-only, single etcd member
k3s already snapshots etcd every 12 h to atlas' own disk — useless if atlas'
SSD dies. Ship them off-node: a systemd timer rsyncing
`/var/lib/rancher/k3s/server/db/snapshots/` to `lenny:/mnt/bulk/etcd/`, or
`--etcd-s3` against MinIO if #8 goes the S3 route.

### 11. Optional: promote apollo + hermes to servers (3-member etcd)
Today the control plane is a single point of failure (atlas). With 16 GB
N200s, two more `role = "server"` nodes (joining atlas, not `clusterInit`)
cost little and give a real HA control plane — both more resilient and a more
realistic testbed. Keep etcd member count odd (1 or 3). Counterpoint: for a
pure test cluster, rebuilding atlas from the installer ISO + git is an
acceptable DR story; if so, keep 1 server and rely on #10.

---

## P4 — hygiene

### 12. README is stale
README still describes a 3-node GlusterFS cluster (`gluster.nix`, brick paths,
no lenny, no Longhorn, no installer ISO). CLAUDE.md is current; sync README to
it or shrink README to a pointer.

### 13. Garbage collection + generation limits
Test clusters get deployed to a lot. Bound the accumulation on every node:

```nix
nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 14d"; };
boot.loader.grub.configurationLimit = 10;        # EQ13
boot.loader.systemd-boot.configurationLimit = 10; # lenny
```

### 14. Small trims in common.nix
- ssh on ports 22 **and** 2222 — carried over from snow; drop 2222 unless
  something still uses it.
- `initialPassword = "password"` — console-only exposure (ssh password auth is
  off) but trivial to replace with `hashedPassword` or remove post-install.

### 15. Longhorn replica count vs. test churn
`defaultClassReplicaCount: 3` triples writes (1 GbE between nodes) and divides
capacity by 3. For throwaway test volumes a second StorageClass with
`numberOfReplicas: "2"` (or even 1) speeds up the loop; keep replica-3 as the
default for anything stateful you care about.

---

## Suggested order

1. #1 + #3 (one shared k3s module: firewall fix + dedupe) — single deploy.
2. #2 DHCP reservations (router-side, no deploy).
3. #5 Mac tooling + kubeconfig + `--tls-san` — unlocks the fast loop.
4. #12/#13 hygiene in the same deploy as 1.
5. #8 + #10 (lenny backup target + etcd snapshots off-node).
6. #4 tailscale auth, then revisit #6 (GitOps) and #11 (HA) as experiments.
