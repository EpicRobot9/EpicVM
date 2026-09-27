"""Bootstrap route manifests from already provisioned host-local instances."""

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "dashboard"))
from direct_stream_auth import ROUTE_RE  # noqa: E402


root = Path(sys.argv[1])
old_path = root / "routes.json"
old = json.loads(old_path.read_text(encoding="utf-8")) if old_path.exists() else {}
routes, dashboard = {}, {}
for instance in sorted(root.iterdir()):
    if not instance.is_dir() or not ROUTE_RE.fullmatch(instance.name):
        continue
    data_path = instance / "server" / "data.json"
    config_path = instance / "server" / "config.json"
    if not data_path.is_file() or not config_path.is_file():
        continue
    data = json.loads(data_path.read_text(encoding="utf-8"))
    config = json.loads(config_path.read_text(encoding="utf-8"))
    hosts = data.get("hosts") or {}
    if len(hosts) != 1 or not next(iter(hosts.values())).get("pair_info"):
        continue
    route = instance.name
    host_id = next(iter(hosts))
    address = config["web_server"]["bind_address"]
    if not address.startswith("127.0.0.1:"):
        raise ValueError(f"Instance {route} is not loopback-bound")
    port = int(address.rsplit(":", 1)[1])
    enabled = old.get(route, {}).get("enabled") is not False
    routes[route] = {"enabled": enabled, "moonlightUser": route, "localPort": port}
    dashboard[route] = {
        "enabled": enabled,
        "hostId": "epic-pc",
        "hostUrl": "https://epicbriiiii.zapto.org",
        "streamPath": f"/EpicVM/{route}/stream.html?hostId={host_id}&appId=881448767",
    }
(root / "routes.json").write_text(json.dumps(routes, indent=2), encoding="utf-8")
(root / "dashboard-manifest.json").write_text(json.dumps(dashboard, indent=2), encoding="utf-8")
print(f"prepared {len(routes)} direct stream routes")
