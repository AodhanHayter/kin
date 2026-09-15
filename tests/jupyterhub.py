"""Offline checks in the pinned Hub image; args: HelmChart JSON, Helm-rendered YAML."""

import asyncio
import base64
import inspect
import json
import os
from pathlib import Path
import runpy
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

import yaml
from traitlets.config import Config
from jupyterhub import orm
from jupyterhub.app import JupyterHub
from jupyterhub.apihandlers.users import UserServerAPIHandler
from jupyterhub.scopes import expand_scopes
from kubespawner import KubeSpawner
from oauthenticator.generic import GenericOAuthenticator

chart = json.loads(Path(sys.argv[1]).read_text())
values = json.loads(chart["spec"]["valuesContent"])
resources = list(yaml.safe_load_all(Path(sys.argv[2]).read_text()))
assert chart["spec"]["version"] == "4.4.2"
assert chart["spec"]["targetNamespace"] == "data-commons-workspaces"
hub = values["hub"]
assert hub["allowNamedServers"] is True
assert hub["namedServerLimitPerUser"] == 2
assert hub["db"]["type"] == "sqlite-pvc"
assert hub["db"]["pvc"]["storageClassName"] == "longhorn"
assert values["cull"]["enabled"] is False
assert values["singleuser"]["cpu"] == {"guarantee": 1, "limit": 1}
assert values["singleuser"]["memory"] == {"guarantee": "2G", "limit": "2G"}
assert values["singleuser"]["storage"]["dynamic"]["storageAccessModes"] == ["ReadWriteMany"]
assert "secretToken" not in values["proxy"]
assert "client_secret" not in hub["config"]["GenericOAuthenticator"]
assert hub["services"]["data-commons"] == {}

# Execute the chart's actual configuration, with only its Kubernetes-mounted
# files supplied in memory. No cluster or credentials are contacted.
configmap, = [r["data"] for r in resources if r and r["kind"] == "ConfigMap" and r["metadata"]["name"] == "hub"]
secret, = [r["data"] for r in resources if r and r["kind"] == "Secret" and r["metadata"]["name"] == "hub"]
secret = {key: base64.b64decode(value).decode() for key, value in secret.items()}
secret["hub.services.data-commons.apiToken"] = "offline-launcher-token"
secret["hub.config.JupyterHub.cookie_secret"] = "ab" * 32


def secret_value(key, *default):
    if key in secret:
        return secret[key]
    if default:
        return default[0]
    raise KeyError(key)


with TemporaryDirectory() as directory:
    for name in ["jupyterhub_config.py", "z2jh.py"]:
        (Path(directory) / name).write_text(configmap[name])
    sys.path.insert(0, directory)
    import z2jh
    merged = z2jh._merge_dictionaries(yaml.safe_load(secret["values.yaml"]), {
        "hub": {"config": {"GenericOAuthenticator": {"client_secret": "offline-oidc-secret"}}}
    })
    with patch.object(z2jh, "_load_config", return_value=merged), \
         patch.object(z2jh, "get_secret_value", side_effect=secret_value), \
         patch.object(z2jh, "_get_config_value", side_effect=configmap.__getitem__), \
         patch.dict(os.environ, POD_NAMESPACE="data-commons-workspaces", PROXY_API_SERVICE_PORT="8001", HUB_SERVICE_PORT="8081"):
        config = runpy.run_path(str(Path(directory) / "jupyterhub_config.py"),
                                init_globals={"get_config": Config})["c"]
for name, cls in [("JupyterHub", JupyterHub), ("GenericOAuthenticator", GenericOAuthenticator),
                  ("KubeSpawner", KubeSpawner)]:
    assert set(hub["config"][name]) <= set(cls.class_traits(config=True)), name
JupyterHub(config=config)
auth = GenericOAuthenticator(config=config)
assert asyncio.run(auth.check_allowed("dc-admin", {"admin": False}))
assert not asyncio.run(auth.check_allowed("outsider", {"admin": False}))
assert not auth.allow_existing_users
assert not auth.admin_users

# Use upstream scope expansion, not a string approximation of the user role.
scopes = expand_scopes(hub["loadRoles"]["user"]["scopes"], owner=orm.User(name="dc-admin"))
assert "access:servers!user=dc-admin" in scopes
assert not any(scope.split("!")[0] in {"servers", "delete:servers", "admin:servers", "admin:users"}
               for scope in scopes), scopes
assert all("!user=dc-admin" in scope for scope in hub["loadRoles"]["data-commons-launcher"]["scopes"])

user = SimpleNamespace(name="dc-admin", id=1, url="/user/dc-admin/")
with patch("kubespawner.spawner.load_config"), patch("kubespawner.spawner.shared_client"):
    first = KubeSpawner(config=config, user=user, orm_spawner=orm.Spawner(name="first"), _mock=True)
    second = KubeSpawner(config=config, user=user, orm_spawner=orm.Spawner(name="second"), _mock=True)
    relaunched = KubeSpawner(config=config, user=user, orm_spawner=orm.Spawner(name="third"), _mock=True)
assert first.pvc_name == second.pvc_name == relaunched.pvc_name
assert first.pod_name != second.pod_name
assert first.automount_service_account_token is False
assert first.delete_pvc is False
with patch.object(first, "_make_delete_pvc_request", side_effect=AssertionError("PVC deletion")):
    asyncio.run(first.delete_forever())

valid = {"DC_API": "https://data-demo.fissio.com", "DC_TOKEN": "dcd_test-only"}
first.user_options = {"env": valid}
first.pre_spawn_hook(first)
assert all(first.environment[key] == value for key, value in valid.items())
# Generate the actual pod, not merely the Helm inputs. Fake only Hub env that
# needs a running Hub; KubeSpawner still builds security, resources and mounts.
with patch.object(first, "get_env", return_value=first.environment):
    pod = asyncio.run(first.get_pod_manifest())
assert pod.spec.automount_service_account_token is False
assert pod.spec.security_context["fsGroup"] == 1000
assert pod.spec.security_context["seccompProfile"]["type"] == "RuntimeDefault"
container = pod.spec.containers[0]
image = values["singleuser"]["image"]
assert container.image == image["name"] + (":" + image["tag"] if image["tag"] else "")
assert container.security_context["runAsUser"] == 1000
assert container.security_context["runAsNonRoot"] is True
assert container.security_context["allowPrivilegeEscalation"] is False
assert container.resources.limits == {"cpu": 1.0, "memory": 2 * 1024 ** 3}
assert container.resources.requests == container.resources.limits
home, = [mount for mount in container.volume_mounts if mount.mount_path == "/home/jovyan"]
volume, = [volume for volume in pod.spec.volumes if volume.name == home.name]
assert volume.persistent_volume_claim["claimName"] == first.pvc_name
for env in [None, {}, {"DC_API": valid["DC_API"]}, {**valid, "S3_SECRET_ACCESS_KEY": "forbidden"},
            {**valid, "DC_API": "http://untrusted.example"}, {**valid, "DC_TOKEN": "dcd_"},
            {**valid, "DC_TOKEN": "other-token"}]:
    first.user_options = {"env": env}
    try:
        first.pre_spawn_hook(first)
    except ValueError as error:
        assert str(error) == "Launch notebooks from Data Commons."
    else:
        raise AssertionError("invalid spawn options accepted")
for name, username in [("", "dc-admin"), ("first", "outsider")]:
    denied = SimpleNamespace(name=name, user=SimpleNamespace(name=username),
                             user_options={"env": valid}, environment={})
    try:
        first.pre_spawn_hook(denied)
    except ValueError:
        assert not denied.environment
    else:
        raise AssertionError("default/other-user spawn accepted")

# Verify the installed API contract; removal is a JSON body in Hub 5.5.2.
source = inspect.getsource(UserServerAPIHandler.delete)
assert "get_json_body()" in source and ".get('remove', False)" in source
services = [r for r in resources if r and r["kind"] == "Service"]
assert all(r["spec"].get("type", "ClusterIP") == "ClusterIP" for r in services)
assert any(r["metadata"]["name"] == "proxy-public" for r in services)
assert not any(r and r["kind"] == "Ingress" for r in resources)
policies = [r for r in resources if r and r["kind"] == "NetworkPolicy"]
assert any(r["metadata"]["name"] == "singleuser" for r in policies)
hub_deploy, = [r for r in resources if r and r["kind"] == "Deployment" and r["metadata"]["name"] == "hub"]
assert hub_deploy["spec"]["strategy"]["type"] == "Recreate"
print("JupyterHub contracts pass: admin-only, portal-only launch, retained shared home, bounded resources.")
