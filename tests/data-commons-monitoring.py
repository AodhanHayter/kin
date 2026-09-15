"""Live read-only check: devenv shell -- python3 tests/data-commons-monitoring.py."""

import json
import subprocess

base = "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/"


def get(path):
    return json.loads(subprocess.check_output(["kubectl", "get", "--raw", base + path]))["data"]


targets = [
    target for target in get("targets?state=active")["activeTargets"]
    if target["labels"].get("job") == "data-commons"
]
assert targets, "No Data Commons scrape targets discovered"
for target in targets:
    assert target["health"] == "up", (target["scrapeUrl"], target["lastError"])

alerts = [
    alert for alert in get("alerts")["alerts"]
    if alert["labels"].get("job") == "data-commons"
    and alert["labels"]["alertname"] == "TargetDown"
]
assert not alerts, "Data Commons TargetDown has not cleared yet"
print("Data Commons metrics targets healthy; TargetDown cleared.")
