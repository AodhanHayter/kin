"""Validate portal spawn options; Hub RBAC is the launcher authorization gate."""


def inject_workspace_env(spawner):
    env = (spawner.user_options or {}).get("env")
    if (
        not spawner.name
        or spawner.user.name != "dc-admin"
        or not isinstance(env, dict)
        or set(env) != {"DC_API", "DC_TOKEN"}
        or env["DC_API"] != "https://data-demo.fissio.com"
        or not isinstance(env["DC_TOKEN"], str)
        or not env["DC_TOKEN"].startswith("dcd_")
        or len(env["DC_TOKEN"]) <= 4
    ):
        raise ValueError("Launch notebooks from Data Commons.")
    spawner.environment.update(env)


c.Spawner.pre_spawn_hook = inject_workspace_env  # noqa: F821 — supplied by JupyterHub
