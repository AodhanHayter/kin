# Shared k3s node baseline (server + agents): firewall, iSCSI, atlas pin.
{
  networking.firewall = {
    allowedTCPPorts = [
      10250 # kubelet — metrics-server scrapes <node-ip>:10250
      9100 # node-exporter (hostNetwork) — Prometheus scrapes <node-ip>:9100
    ];
    allowedUDPPorts = [
      8472 # flannel vxlan
    ];
  };

  # Pin the k3s join address (serverAddr = https://atlas.local:6443) in
  # /etc/hosts so it does not depend on avahi/mDNS being up when k3s starts.
  # Requires a DHCP reservation for atlas at the router — keep in sync.
  networking.hosts."10.10.0.100" = [
    "atlas.local"
    "atlas"
  ];

  # Drain pods cleanly on reboot/shutdown (kernel bumps are frequent on a
  # test cluster; without this, pods are killed mid-write).
  services.k3s.gracefulNodeShutdown.enable = true;

  # Longhorn / iSCSI support.
  services.openiscsi = {
    enable = true;
    name = "iqn.2020-08.org.linux-iscsi.initiatorhost:nixos";
  };
}
