"""Generate Caddy routes for the host-local EpicVM stream gateway."""

import json
from pathlib import Path
import sys


root = Path(sys.argv[1])
routes = json.loads((root / "routes.json").read_text(encoding="utf-8"))
lines = [
    "handle_path /EpicVM/auth/* {",
    "    reverse_proxy 127.0.0.1:8090",
    "}",
]
for route, record in sorted(routes.items()):
    if record.get("enabled") is not True:
        continue
    if not (route.startswith(("vm-", "seat-")) and
            all(ch.isalnum() or ch in "-._" for ch in route)):
        raise ValueError("Invalid route")
    port = int(record["localPort"])
    lines.extend([
        f"@epicvm_{route.replace('-', '_').replace('.', '_')} path /EpicVM/{route} /EpicVM/{route}/*",
        f"handle @epicvm_{route.replace('-', '_').replace('.', '_')} {{",
        "    route {",
        "        request_header -X-EpicVM-User",
        "        forward_auth 127.0.0.1:8090 {",
        "            uri /authorize",
        "            copy_headers X-EpicVM-User",
        "        }",
        f"        reverse_proxy 127.0.0.1:{port}",
        "    }",
        "}",
    ])
(root / "caddy-routes.caddy").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"wrote {len(routes)} stream routes")
