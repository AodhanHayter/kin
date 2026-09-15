"""Offline contract checks; never contact Cloudflare, Keycloak or the cluster."""

import json
from pathlib import Path
import re

module = Path(__file__).resolve().parents[1] / "modules/services/data-commons"
realm = json.loads((module / "realm-demo.json").read_text())
lan_realm = json.loads((module / "realm-data-commons.json").read_text())
rules = json.loads((module / "tunnel-routes.json").read_text())["ingress"]
portal = "data-demo.fissio.com"
auth = "demo-auth.fissio.com"
files = "demo-files.fissio.com"

assert realm["registrationAllowed"] is False
assert realm["resetPasswordAllowed"] is False  # no real SMTP relay yet
assert realm["bruteForceProtected"] is True
assert realm["sslRequired"] == "all"
assert [user["username"] for user in realm["users"]] == ["dc-admin"]
assert realm["users"][0]["id"] == lan_realm["users"][0]["id"]
assert realm["users"][0]["credentials"][0]["value"] == "@DEMO_ADMIN_PASSWORD@"
clients = {client["clientId"]: client for client in realm["clients"]}
assert set(clients) == {"data-commons-portal", "jupyterhub"}
client = clients["data-commons-portal"]
assert client["publicClient"] is False
assert client["directAccessGrantsEnabled"] is False
assert client["redirectUris"] == [f"https://{portal}/auth/callback"]
assert client["webOrigins"] == [f"https://{portal}"]
assert client["attributes"]["post.logout.redirect.uris"] == f"https://{portal}/"
assert client["attributes"]["backchannel.logout.url"] == f"https://{portal}/auth/backchannel-logout"
assert "@USER_PASSWORD@" not in json.dumps(realm)
assert ".local" not in json.dumps(client)
notebooks = clients["jupyterhub"]
assert notebooks["publicClient"] is False
assert notebooks["directAccessGrantsEnabled"] is False
assert notebooks["serviceAccountsEnabled"] is False
assert notebooks["implicitFlowEnabled"] is False
assert notebooks["secret"] == "@JUPYTERHUB_CLIENT_SECRET@"
assert notebooks["redirectUris"] == ["https://demo-workspaces.fissio.com/hub/oauth_callback"]
assert notebooks["webOrigins"] == ["https://demo-workspaces.fissio.com"]
assert rules[-1] == {"service": "http_status:404"}


def route(host, path):
    for rule in rules:
        if rule.get("hostname", host) == host and re.search(rule.get("path", ""), path):
            return rule
    raise AssertionError("missing catch-all")


for host, paths, origin in [
    (portal, ["/", "/auth/callback", "/auth/backchannel-logout", "/live/websocket", "/api/user"],
     "http://data-commons.data-commons.svc.cluster.local:4000"),
    (auth, ["/realms/data-commons/.well-known/openid-configuration",
            "/realms/data-commons/protocol/openid-connect/token", "/resources/theme/login.css"],
     "http://keycloak.data-commons.svc.cluster.local:80"),
    (files, ["/data-commons/objects/a.csv"], "http://10.10.3.42:3900"),
    ("demo-workspaces.fissio.com", ["/hub/oauth_callback", "/user/dc-admin/session/api/kernels/1/channels"],
     "http://proxy-public.data-commons-workspaces.svc.cluster.local:80"),
]:
    for path in paths:
        rule = route(host, path)
        assert rule["service"] == origin, (host, path)
        assert rule["originRequest"]["httpHostHeader"] == host, (host, path)

for host, paths in [
    (portal, ["/metrics", "/metrics/", "//metrics", "///metrics", "/healthz", "//healthz"]),
    (auth, ["/", "/admin/", "/admin/realms/data-commons", "/realms/master/protocol/openid-connect/token",
            "/realms/data-commons-other/", "/health", "/metrics"]),
    (files, ["/", "/data-commons", "/data-commons-other/a", "/longhorn-backups/a", "/etcd-snapshots/a"]),
    ("unconfigured.fissio.com", ["/"]),
]:
    for path in paths:
        assert route(host, path)["service"] == "http_status:404", (host, path)

print("Invited-demo realm and tunnel route contracts pass (offline).")
