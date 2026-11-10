# Homebridge

Homebridge runs as one k3s pod on `atlas` (`10.10.3.100`).
`kin/homebridge` deploys it through the `k3s-server` inventory tag.
The admin UI is `http://10.10.3.100:8581`. There is no public route or ingress.

The pod shares the host network so Apple Home can discover it.
A 5 GiB Longhorn persistent volume stores `/homebridge`, including plugins, credentials, and pairing data.
Updates stop the old pod before starting its replacement. There is no automatic failover to another node.

The official image is pinned to `homebridge/homebridge:2026-11-02`.
First boot generates a private pairing code and bridge identity on the volume, not in Git or the Nix store.
It sets TCP port `51826` and the `ciao` discovery service, bound to the node IP.
The container disables its Avahi service because NixOS already runs Avahi for `.local` hostnames.
Later starts preserve the configuration that you edit in the UI.

## UniFi prerequisite

Read-only inspection on 2026-11-10 found this configuration:

| Network | VLAN | Subnet | Firewall zone |
| --- | --- | --- | --- |
| WiFi | 3 | `10.10.1.0/24` | Internal |
| K3s | 4 | `10.10.3.0/24` | Homelab |

Both iPhones were on WiFi. No client was clearly identified as an Apple TV or HomePod.
Gateway mDNS Proxy was set to **Auto**. This forwards common discovery traffic between networks.
Internal-to-Homelab traffic was blocked except for three admin IPs: `10.10.1.8`, `10.10.0.252`, and `10.10.0.44`.
Those exceptions already permit access to the admin UI.

Before pairing, add this narrow UniFi firewall policy above the Internal-to-Homelab block:

| Field | Value |
| --- | --- |
| Action | Allow |
| Protocol | TCP |
| Source zone | Internal |
| Source network | WiFi (`10.10.1.0/24`) |
| Source port | Any |
| Destination zone | Homelab |
| Destination IP | `10.10.3.100` |
| Destination port | `51826` |
| Return traffic | Allow established replies |

Keep port `8581` restricted to the existing admin machines.
The NixOS host firewall opens `8581`, `51826`, and UDP `5353`; UniFi controls access between networks.
Do not enable a broad Internal-to-Homelab allow rule.

Homelab-to-Internal traffic is also blocked. Plugins that contact local devices need separate outbound rules for their device IPs and ports.
Cloud-only plugins can use the existing internet access.
Child bridges need distinct, fixed TCP ports plus corresponding NixOS and UniFi rules before pairing.
This configuration opens only the main bridge port.

No UniFi settings were changed during setup. Discovery and pairing require a live test after deployment.

## Deploy and pair

1. On an x86_64-linux admin machine, run the local checks from the repo root:

   ```fish
   python3 tests/homebridge.py
   nix eval --raw '.#nixosConfigurations.atlas.config.system.build.toplevel.drvPath'
   ```

2. When ready to deploy, update atlas from the development shell:

   ```fish
   devenv shell -- clan machines update atlas
   ```

   Pushing to `master` also triggers comin deployment. Do not push until you want this service enabled.

3. With kubectl pointed at kin, inspect the deployment:

   ```fish
   kubectl -n homebridge get pods,pvc -o wide
   kubectl -n homebridge rollout status deployment/homebridge --timeout=300s
   kubectl -n homebridge logs deployment/homebridge -c homebridge --tail=100
   ```

   The volume must be Bound and the pod must be Ready on atlas.
   First startup installs packages and requires internet access.

4. From an allowed admin machine, open `http://10.10.3.100:8581` and complete account setup.
5. Install the plugins you need in the UI. Keep the main bridge port at `51826` and the advertiser at `ciao`.
6. After the UniFi rule is active, scan the Homebridge QR code from Apple Home on your iPhone.

Keep atlas at `10.10.3.100` with a DHCP reservation.
If its address changes, update the saved bridge binding and the UniFi destination rule before restarting Homebridge.

## Data and recovery

Export a Homebridge backup from the UI before image or plugin updates.
Store it privately: it contains credentials and pairing data. Longhorn replication is not an off-cluster backup.
No scheduled backup is added by this service.

Do not delete the `homebridge` namespace or volume claim to restart the service.
The Longhorn storage class uses a Delete reclaim policy, so deleting the claim can destroy the data.
Restart without deleting storage:

```fish
kubectl -n homebridge rollout restart deployment/homebridge
```

If discovery succeeds but pairing fails, inspect the UniFi rule and TCP `51826` reachability.
If discovery fails, inspect mDNS forwarding, WiFi multicast filtering, and the saved bridge binding.
If a plugin cannot reach a local device, inspect the Homelab-to-Internal policy for that device.

The official container runs as root and uses the host network. Install only trusted plugins.
No privileged mode, host filesystem mount, or Kubernetes API token is granted.
Removing the inventory instance does not remove resources already applied by k3s.

References: [official container](https://github.com/homebridge/docker-homebridge),
[mDNS advertisers](https://github.com/homebridge/homebridge/wiki/mDNS-Options),
[UniFi mDNS proxy](https://help.ui.com/hc/en-us/articles/12648701398807-UniFi-Gateway-Multicast-DNS).
