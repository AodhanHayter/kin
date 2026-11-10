"""Local checks: python3 tests/homebridge.py (requires nix and node; no deployment)."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
config = json.loads(subprocess.check_output([
    "nix", "eval", "--json", ".#nixosConfigurations", "--apply", """
    hosts: {
      manifests = hosts.atlas.config.services.k3s.manifests.homebridge.content;
      tcp = hosts.atlas.config.networking.firewall.allowedTCPPorts;
      udp = hosts.atlas.config.networking.firewall.allowedUDPPorts;
      aliasCommand = hosts.atlas.config.systemd.services.homebridge-mdns.serviceConfig.ExecStart;
      aliasWants = hosts.atlas.config.systemd.services.homebridge-mdns.wants;
      agents = map (name: {
        hasAlias = builtins.hasAttr "homebridge-mdns" hosts.${name}.config.systemd.services;
        manifests = builtins.attrNames hosts.${name}.config.services.k3s.manifests;
        tcp = hosts.${name}.config.networking.firewall.allowedTCPPorts;
      }) [ "apollo" "hermes" "lenny" "mbp" ];
    }
    """,
], cwd=root))
resources = {resource["kind"]: resource for resource in config["manifests"]}
assert set(resources) == {"Namespace", "PersistentVolumeClaim", "Deployment", "Service", "Ingress"}
service = resources["Service"]["spec"]
assert service.get("type", "ClusterIP") == "ClusterIP"
assert service["selector"] == {"app": "homebridge"}
assert service["ports"] == [{"name": "http", "port": 80, "targetPort": "ui"}]
ingress = resources["Ingress"]
assert ingress["spec"]["ingressClassName"] == "traefik"
assert ingress["metadata"]["annotations"]["traefik.ingress.kubernetes.io/router.entrypoints"] == "web"
assert ingress["spec"]["rules"] == [{
    "host": "homebridge.local",
    "http": {"paths": [{
        "path": "/",
        "pathType": "Prefix",
        "backend": {"service": {"name": "homebridge", "port": {"number": 80}}},
    }]},
}]
pvc = resources["PersistentVolumeClaim"]["spec"]
assert pvc["storageClassName"] == "longhorn"
assert pvc["accessModes"] == ["ReadWriteOnce"]
deployment = resources["Deployment"]["spec"]
assert deployment["replicas"] == 1
assert deployment["strategy"]["type"] == "Recreate"
pod = deployment["template"]["spec"]
assert pod["hostNetwork"] is True
assert pod["dnsPolicy"] == "ClusterFirstWithHostNet"
assert pod["nodeSelector"] == {"kubernetes.io/hostname": "atlas"}
assert pod["automountServiceAccountToken"] is False
container = pod["containers"][0]
assert next(port for port in container["ports"] if port["name"] == "ui")["containerPort"] == 8581
bootstrap = pod["initContainers"][0]
assert container["image"] == bootstrap["image"] == "homebridge/homebridge:2026-11-02"
assert {e["name"]: e["value"] for e in container["env"]}["ENABLE_AVAHI"] == "0"
assert container["volumeMounts"] == bootstrap["volumeMounts"] == [
    {"name": "data", "mountPath": "/homebridge"}
]
assert pod["volumes"][0]["persistentVolumeClaim"]["claimName"] == "homebridge"
assert bootstrap["env"][0]["valueFrom"]["fieldRef"]["fieldPath"] == "status.hostIP"
assert {8581, 51826} <= set(config["tcp"])
assert 5353 in config["udp"]
assert config["aliasCommand"].endswith(
    "/bin/avahi-publish-address --no-fail --no-reverse homebridge.local 10.10.3.100"
)
assert "avahi-daemon.service" in config["aliasWants"]
for agent in config["agents"]:
    assert not agent["hasAlias"]
    assert "homebridge" not in agent["manifests"]
    assert not {8581, 51826} & set(agent["tcp"])

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "config.json"
    command = ["node", "-e", bootstrap["command"][2]]
    env = {**os.environ, "HOMEBRIDGE_BIND": "10.10.3.100"}
    subprocess.run(command, cwd=directory, env=env, check=True)
    first = path.read_bytes()
    generated = json.loads(first)
    bridge = generated["bridge"]
    assert bridge["port"] == 51826
    assert bridge["advertiser"] == "ciao"
    assert bridge["bind"] == ["10.10.3.100"]
    assert re.fullmatch(r"0E(:[0-9A-F]{2}){5}", bridge["username"])
    assert re.fullmatch(r"\d{3}-\d{2}-\d{3}", bridge["pin"])
    pin = bridge["pin"].replace("-", "")
    assert len(set(pin)) > 1 and pin not in {"12345678", "87654321"}
    assert generated["platforms"][0]["port"] == 8581
    assert path.stat().st_mode & 0o777 == 0o600
    for existing in [first, b'{"bridge": "user-managed", "platforms": ["plugin"]}', b'invalid JSON']:
        path.write_bytes(existing)
        subprocess.run(command, cwd=directory, env=env, check=True)
        assert path.read_bytes() == existing, "Bootstrap overwrote existing configuration"

print("Homebridge inventory, storage, networking and first-boot checks pass.")
