"""Prepare a separate, paired Moonlight Web instance for a direct-host seat trial.

The imported pairing identity remains bound to the seat. The local
WindowsStream account supplies only the login name and password verifier.
Never print or log either input database.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def prepare(seat_data_path: Path, windows_data_path: Path, target: Path, seat: str) -> None:
    seat_data = json.loads(seat_data_path.read_text(encoding="utf-8"))
    windows_data = json.loads(windows_data_path.read_text(encoding="utf-8"))
    if len(seat_data.get("users", {})) != 1 or len(seat_data.get("hosts", {})) != 1:
        raise ValueError("Expected one paired seat user and host")
    if len(windows_data.get("users", {})) != 1:
        raise ValueError("Expected one WindowsStream login")
    seat_user = next(iter(seat_data["users"].values()))
    seat_host = next(iter(seat_data["hosts"].values()))
    windows_user = next(iter(windows_data["users"].values()))
    if not seat_host.get("pair_info") or not windows_user.get("password"):
        raise ValueError("Seat pairing or WindowsStream login is unavailable")
    seat_user["name"] = windows_user["name"]
    seat_user["password"] = windows_user["password"]
    seat_host["address"] = "127.0.0.1"
    seat_host["http_port"] = 48100

    config = {
        "data_storage": {"type": "json", "path": "server/data.json", "session_expiration_check_interval": {"secs": 300, "nanos": 0}},
        "webrtc": {
            "ice_servers": [{"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:3478"], "username": "", "credential": ""}],
            "ice_server_script": None,
            "port_range": {"min": 40011, "max": 40021},
            # The home router does not forward the trial's UDP range. Let STUN
            # advertise the actual NAT mapping rather than a false 1:1 port.
            "nat_1to1": None,
            "network_types": ["udp4"],
            "include_loopback_candidates": False,
        },
        "web_server": {
            "bind_address": "127.0.0.1:8082",
            "certificate": None,
            "url_path_prefix": f"/EpicVM/{seat}",
            "session_cookie_secure": True,
            "session_cookie_expiration": {"secs": 86400, "nanos": 0},
            "first_login_create_admin": False,
            "first_login_assign_global_hosts": False,
            "default_user_id": None,
            "default_role_id": None,
            "forwarded_header": None,
        },
        "moonlight": {"default_http_port": 48100, "pair_device_name": "EpicVMDirectSeatTrial"},
        "streamer_path": "./streamer",
        "log": {"level_filter": "INFO", "file_path": "server/direct-seat.log", "dev_venator": False},
        "default_settings": None,
    }
    server = target / "server"
    server.mkdir(parents=True, exist_ok=True)
    (server / "data.json").write_text(json.dumps(seat_data, separators=(",", ":")), encoding="utf-8")
    (server / "config.json").write_text(json.dumps(config, separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("seat_data", type=Path)
    parser.add_argument("windows_data", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("seat")
    args = parser.parse_args()
    prepare(args.seat_data, args.windows_data, args.target, args.seat)
