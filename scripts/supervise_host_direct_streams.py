"""Keep EpicVM's host-local streams registered and running after sign-in.

Only paired gaming VM and seat bundles from the EpicVM server are imported.
Pairing data stays in the private host store and is never printed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from urllib import request

import psutil

from provision_direct_stream import patch_audio_player, provision

SOURCE = "/opt/epicvm/moonlight-instances"
HOST_URL = "https://epicbriiiii.zapto.org"
HOST_ID = "epic-pc"
APP_ID = 881448767
FRAME_PROBE = "/app/complete_host_frame_probe.py"
UDP_FIRST = 40900
UDP_LAST = 41199
UDP_WIDTH = 11


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _write(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def _listener_pid(port: int) -> int | None:
    for connection in psutil.net_connections(kind="tcp"):
        if connection.status == psutil.CONN_LISTEN and connection.laddr.port == port:
            return connection.pid
    return None


def _start_gateway(root: Path) -> None:
    if _listener_pid(8090):
        return
    subprocess.Popen(
        [sys.executable, str(root / "host_stream_gateway.py"), "--key", str(root / "signing.key"),
         "--routes", str(root / "routes.json"), "--nonces", str(root / "nonces.sqlite3")],
        cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )


def _start_instance(root: Path, route: str, port: int) -> None:
    if _listener_pid(port):
        return
    target = root / route
    if not (target / "server" / "data.json").is_file():
        return
    if route.startswith("seat-"):
        _ensure_seat_udp_range(root, route)
    subprocess.Popen(
        [r"E:\Projects\WindowsStream\moonlight-web\package\web-server.exe",
         "--config-path", "server/config.json", "run"],
        cwd=target, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )


def _stop_instance(port: int) -> None:
    pid = _listener_pid(port)
    if not pid:
        return
    process = psutil.Process(pid)
    if process.name().lower() == "web-server.exe" and "--config-path" in process.cmdline():
        process.terminate()
        process.wait(timeout=10)


def _udp_range_bindable(start: int) -> bool:
    sockets = []
    try:
        for port in range(start, start + UDP_WIDTH):
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sockets.append(sock)
            sock.bind(("0.0.0.0", port))
        return True
    except OSError:
        return False
    finally:
        for sock in sockets:
            sock.close()


def _media_firewall_ready() -> bool:
    if os.name != "nt":
        return True
    command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
               "$r=Get-NetFirewallRule -DisplayName 'EpicVM Direct Streams Media UDP 40900-41199' "
               "-ErrorAction SilentlyContinue; if($r -and $r.Enabled -eq 'True' -and "
               "$r.Action -eq 'Allow' -and ($r | Get-NetFirewallPortFilter).LocalPort "
               "-eq '40900-41199'){exit 0}; exit 1"]
    try:
        return subprocess.run(command, capture_output=True, timeout=12).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _allocate_udp_range(root: Path) -> int:
    if not _media_firewall_ready():
        raise RuntimeError("The WebRTC media firewall rule is missing; run the scoped firewall installer elevated")
    occupied = set()
    for config in root.glob("*/server/config.json"):
        bounds = _read(config)["webrtc"]["port_range"]
        occupied.update(range(int(bounds["min"]), int(bounds["max"]) + 1))
    for start in range(UDP_FIRST, UDP_LAST - UDP_WIDTH + 2, UDP_WIDTH):
        if not occupied.intersection(range(start, start + UDP_WIDTH)) and _udp_range_bindable(start):
            return start
    raise RuntimeError("No free bindable WebRTC UDP range remains")


def _ensure_seat_udp_range(root: Path, route: str) -> bool:
    """Keep a seat's valid reservation; fix an unavailable one before launch."""
    path = root / route / "server" / "config.json"
    config = _read(path)
    bounds = config["webrtc"]["port_range"]
    start, end = int(bounds["min"]), int(bounds["max"])
    if (UDP_FIRST <= start and end <= UDP_LAST and end - start == UDP_WIDTH - 1
            and _udp_range_bindable(start)):
        return False
    replacement = _allocate_udp_range(root)
    backup = path.with_name(f"config.json.before-udp-refresh-{int(time.time())}")
    shutil.copy2(path, backup)
    config["webrtc"]["port_range"] = {"min": replacement, "max": replacement + UDP_WIDTH - 1}
    _write(path, config)
    print(f"Moved unavailable WebRTC UDP range for {route} to {replacement}-{replacement + UDP_WIDTH - 1}",
          flush=True)
    return True


def _seat_host_healthy(route: str, port: int, host_id: str) -> bool:
    url = f"http://127.0.0.1:{port}/EpicVM/{route}/api/host?host_id={host_id}"
    try:
        with request.urlopen(request.Request(url, headers={"X-EpicVM-User": route}), timeout=8) as response:
            host = json.load(response).get("host") or {}
            return str(host.get("host_id")) == host_id and str(host.get("paired", "")).lower() == "paired"
    except (OSError, ValueError, KeyError):
        return False


def _seat_has_active_client(port: int) -> bool:
    return any(connection.status == psutil.CONN_ESTABLISHED and
               connection.laddr.port == port
               for connection in psutil.net_connections(kind="tcp"))


def _refresh_seat_pairing(root: Path, route: str, port: int, source_data: dict) -> bool:
    """Repair only a failed local seat host using the current paired KVM2 bundle."""
    path = root / route / "server" / "data.json"
    local = _read(path)
    old_hosts, new_hosts = local.get("hosts") or {}, source_data.get("hosts") or {}
    if len(old_hosts) != 1 or len(new_hosts) != 1:
        raise ValueError("Seat pairing record must contain exactly one host")
    host_id, old = next(iter(old_hosts.items()))
    fresh = next(iter(new_hosts.values()))
    if (old.get("address") != "127.0.0.1" or old.get("http_port") != fresh.get("http_port")
            or not fresh.get("pair_info")):
        raise ValueError("Seat source does not match the local Sunshine endpoint")
    if old.get("pair_info") == fresh["pair_info"] or _seat_host_healthy(route, port, host_id):
        return False
    if _seat_has_active_client(port):
        print(f"Deferring pairing refresh while {route} has an active client", flush=True)
        return False
    backup = path.with_name(f"data.json.before-pair-refresh-{int(time.time())}")
    shutil.copy2(path, backup)
    _stop_instance(port)
    old["pair_info"] = fresh["pair_info"]
    _write(path, local)
    try:
        _start_instance(root, route, port)
        for _ in range(20):
            if _seat_host_healthy(route, port, host_id):
                return True
            time.sleep(.5)
        raise RuntimeError("The refreshed seat pairing failed authenticated host verification")
    except Exception:
        _stop_instance(port)
        shutil.copy2(backup, path)
        _start_instance(root, route, port)
        raise


def _read_source_data(source: str) -> dict:
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "kvm2",
                             "cat", f"{SOURCE}/{source}/server/data.json"],
                            capture_output=True, timeout=20, check=True)
    return json.loads(result.stdout)


def _source_names() -> set[str]:
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "kvm2",
               f"find {SOURCE} -mindepth 3 -maxdepth 3 -name data.json -printf '%h\\n'"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=True)
    return {name for line in result.stdout.splitlines()
            if (name := PurePosixPath(line).parent.name)
            if re.fullmatch(r"seat-[0-9a-f]{24}", name)
            or (re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,62}", name)
                and name not in {"quarantine"} and not name.startswith("cloudpc-"))}


def _route_name(source: str) -> str:
    return source if source.startswith("seat-") else "vm-" + source


def _verify_pending_gaming_route(root: Path, routes: dict) -> None:
    """Use actual decoded browser frames to finish pending gaming VM setup."""
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "kvm2",
               "docker", "exec", "blobedash", "python3", FRAME_PROBE, "list"]
    try:
        response = subprocess.run(command, capture_output=True, text=True,
                                  check=True, timeout=25)
        jobs = json.loads(response.stdout)
        if not isinstance(jobs, list):
            return
        for job in jobs:
            route = "vm-" + str(job.get("name") or "")
            if not routes.get(route, {}).get("enabled"):
                continue
            probe = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("diagnose_direct_stream_browser.py")),
                 str(root), route, "--video-element", "--metrics"],
                capture_output=True, text=True, timeout=60,
            )
            if probe.returncode:
                print(f"Frame probe will retry for {route}", flush=True)
                return
            line = next((line.removeprefix("frameMetrics ") for line in probe.stdout.splitlines()
                         if line.startswith("frameMetrics ")), "")
            metrics = json.loads(line) if line else None
            if not isinstance(metrics, dict):
                print(f"Frame probe found no decoded video for {route}", flush=True)
                return
            report = {"id": job["id"], "name": job["name"], "frameMetrics": metrics}
            complete_command = command[:]
            complete_command.insert(complete_command.index("exec") + 1, "-i")
            complete_command[-1] = "complete"
            completed = subprocess.run(complete_command,
                                       input=json.dumps(report), capture_output=True,
                                       text=True, timeout=90)
            print(f"Gaming stream {route}: " +
                  ("ready with decoded frames" if completed.returncode == 0 else
                   "frame completion will retry (" + completed.stdout.strip()[:80] + ")"), flush=True)
            return  # One stream per cycle keeps the supervisor responsive.
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(f"Gaming frame verification will retry: {type(exc).__name__}", flush=True)


def _import_one(root: Path, source: str, route: str, port: int, udp_port: int) -> dict | None:
    with tempfile.TemporaryDirectory(dir=root) as scratch:
        imported = Path(scratch) / "data.json"
        subprocess.run(["scp", "-q", f"kvm2:{SOURCE}/{source}/server/data.json", str(imported)],
                       capture_output=True, timeout=30, check=True)
        data = _read(imported)
        hosts = data.get("hosts") or {}
        if len(hosts) != 1 or len(data.get("users") or {}) != 1:
            return None
        host_key, host = next(iter(hosts.items()))
        if not host.get("pair_info"):
            return None
        address = "127.0.0.1" if route.startswith("seat-") else str(host.get("address") or "")
        sunshine_port = int(host.get("http_port") or 0)
        if not address or not sunshine_port:
            return None
        provision(source_data=imported,
                  template_config=root / "template-config.json",
                  package=Path(r"E:\Projects\WindowsStream\moonlight-web\package"),
                  root=root, route=route, address=address, sunshine_port=sunshine_port,
                  local_port=port, udp_port=udp_port)
        return {"hostId": str(host_key), "port": port}


def sync(root: Path) -> None:
    routes_path = root / "routes.json"
    dashboard_path = root / "dashboard-manifest.json"
    routes, dashboard = _read(routes_path), _read(dashboard_path)
    names = _source_names()
    changed = False
    for source in sorted(names):
        route = _route_name(source)
        if not route.startswith("seat-") or not routes.get(route, {}).get("enabled"):
            continue
        try:
            if _refresh_seat_pairing(root, route, int(routes[route]["localPort"]),
                                     _read_source_data(source)):
                print(f"Refreshed invalid pairing for {route}", flush=True)
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as exc:
            print(f"Seat pairing check will retry for {route}: {type(exc).__name__}", flush=True)
    for source in sorted(names):
        route = _route_name(source)
        if not (route.startswith("vm-") or route.startswith("seat-")):
            continue
        if route in routes and routes[route].get("enabled"):
            continue
        occupied = {int(item["localPort"]) for item in routes.values()}
        port = (int(routes[route]["localPort"]) if route in routes else
                next(port for port in range(8091, 8190)
                     if port not in occupied and not _listener_pid(port)))
        if route in routes:
            old_range = _read(root / route / "server" / "config.json")["webrtc"]["port_range"]
            udp = int(old_range["min"])
            if (udp < UDP_FIRST or int(old_range["max"]) > UDP_LAST
                    or not _udp_range_bindable(udp)):
                udp = _allocate_udp_range(root)
            target = root / route
            if target.exists():
                archive = root / "quarantine"
                archive.mkdir(exist_ok=True)
                target.rename(archive / f"{route}-{int(time.time())}")
        else:
            udp = _allocate_udp_range(root)
        try:
            imported = _import_one(root, source, route, port, udp)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print(f"Direct stream {route} will retry: {type(exc).__name__}", flush=True)
            continue
        if not imported:
            continue
        routes[route] = {"enabled": True, "moonlightUser": route, "localPort": port}
        dashboard[route] = {"enabled": True, "hostId": HOST_ID, "hostUrl": HOST_URL,
                            "streamPath": f"/EpicVM/{route}/stream.html?hostId={imported['hostId']}&appId={APP_ID}"}
        _start_instance(root, route, port)
        changed = True
        print(f"Registered direct stream {route}", flush=True)

    # Quarantined seats disappear from the source inventory. Deny fresh
    # requests immediately while leaving the account's Windows profile alone.
    for route, record in routes.items():
        if route.startswith("seat-") and route not in names and record.get("enabled"):
            record["enabled"] = False
            dashboard[route]["enabled"] = False
            _stop_instance(int(record["localPort"]))
            changed = True

    if changed:
        _write(routes_path, routes)
        _write(dashboard_path, dashboard)

    route_hash = hashlib.sha256(routes_path.read_bytes()).hexdigest()
    caddy_marker = root / ".caddy-applied"
    if not caddy_marker.exists() or caddy_marker.read_text() != route_hash:
        subprocess.run([sys.executable, str(Path(__file__).with_name("write_direct_stream_caddy.py")),
                        str(root)], check=True, timeout=20)
        caddy = Path(r"C:\Users\Epic\AppData\Local\Microsoft\WinGet\Packages\CaddyServer.Caddy_Microsoft.Winget.Source_8wekyb3d8bbwe\caddy.exe")
        caddyfile = Path(r"E:\Projects\WindowsStream\config\caddy\Caddyfile")
        subprocess.run([str(caddy), "validate", "--config", str(caddyfile)],
                       capture_output=True, check=True, timeout=20)
        subprocess.run([str(caddy), "reload", "--config", str(caddyfile)],
                       capture_output=True, check=True, timeout=20)
        caddy_marker.write_text(route_hash)

    manifest_hash = hashlib.sha256(dashboard_path.read_bytes()).hexdigest()
    manifest_marker = root / ".manifest-published"
    if not manifest_marker.exists() or manifest_marker.read_text() != manifest_hash:
        subprocess.run(["scp", "-q", str(dashboard_path),
                        "kvm2:/opt/blobe-vm/private/direct-streams.json.new"],
                       capture_output=True, check=True, timeout=30)
        subprocess.run(["ssh", "kvm2", "install -m 0600 /opt/blobe-vm/private/direct-streams.json.new "
                        "/opt/blobe-vm/private/direct-streams.json && "
                        "rm /opt/blobe-vm/private/direct-streams.json.new"],
                       capture_output=True, check=True, timeout=30)
        manifest_marker.write_text(manifest_hash)

    _start_gateway(root)
    for route, record in routes.items():
        if record.get("enabled"):
            patch_audio_player(root / route / "static")
            _start_instance(root, route, int(record["localPort"]))
    _verify_pending_gaming_route(root, routes)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--watch", action="store_true")
    args = parser.parse_args()
    while True:
        try:
            sync(args.root)
        except Exception as exc:
            print(f"Direct stream sync will retry: {type(exc).__name__}: {exc}", flush=True)
        if not args.watch:
            break
        time.sleep(30)
