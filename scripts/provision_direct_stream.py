"""Stage one host-local Moonlight instance from an existing paired EpicVM bundle."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil


def patch_audio_player(static: Path) -> bool:
    """Start playback when Moonlight adds its first live audio track.

    The pinned upstream player assigns an empty MediaStream at construction.
    Chrome does not autoplay it when a track is added later, leaving its audio
    element paused even though Moonlight receives Sunshine audio packets.
    """
    path = static / "stream" / "audio" / "audio_element.js"
    text = path.read_text(encoding="utf-8")
    old_track = "        this.stream.addTrack(track);\n        this.oldTrack = track;"
    new_track = ("        this.stream.addTrack(track);\n"
                 "        this.audioElement.srcObject = null;\n"
                 "        this.audioElement.srcObject = this.stream;\n"
                 "        this.audioElement.play().catch(() => {});\n"
                 "        this.oldTrack = track;")
    old_interaction = "        this.audioElement.muted = false;"
    new_interaction = ("        this.audioElement.muted = false;\n"
                       "        this.audioElement.play().catch(() => {});")
    if new_track in text and new_interaction in text:
        return False
    if text.count(old_track) != 1 or text.count(old_interaction) != 1:
        raise RuntimeError("Pinned Moonlight audio player layout changed")
    path.write_text(text.replace(old_track, new_track).replace(old_interaction, new_interaction),
                    encoding="utf-8")
    return True


def provision(*, source_data: Path, template_config: Path, package: Path,
              root: Path, route: str, address: str, sunshine_port: int,
              local_port: int, udp_port: int) -> None:
    if not route.startswith(("seat-", "vm-")) or not all(c.isalnum() or c in "-._" for c in route):
        raise ValueError("Invalid route")
    if not (1000 <= sunshine_port <= 65534 and 1024 <= local_port <= 65535
            and 1024 <= udp_port <= 65525):
        raise ValueError("Invalid port")
    data = json.loads(source_data.read_text(encoding="utf-8"))
    if len(data.get("users", {})) != 1 or len(data.get("hosts", {})) != 1:
        raise ValueError("Expected one paired user and host")
    user = next(iter(data["users"].values()))
    host = next(iter(data["hosts"].values()))
    if not host.get("pair_info"):
        raise ValueError("The source console is not paired")
    user["name"] = route
    user["password"] = None
    host["address"] = address
    host["http_port"] = sunshine_port
    for role in data.get("roles", {}).values():
        if role.get("ty") == "Admin":
            raise ValueError("An admin Moonlight role must not be exposed to a stream user")
        role.get("permissions", {})["allow_add_hosts"] = False

    config = json.loads(template_config.read_text(encoding="utf-8"))
    config["data_storage"]["path"] = "server/data.json"
    config["web_server"].update({
        "bind_address": f"127.0.0.1:{local_port}",
        "url_path_prefix": f"/EpicVM/{route}",
        "first_login_create_admin": False,
        "first_login_assign_global_hosts": False,
        "forwarded_header": {"username_header": "X-EpicVM-User",
                             "auto_create_missing_user": False, "ignore_case": False},
    })
    config["webrtc"].update({"port_range": {"min": udp_port, "max": udp_port + 10},
                             "nat_1to1": None, "network_types": ["udp4"],
                             "include_loopback_candidates": False})
    config["moonlight"]["default_http_port"] = sunshine_port
    config["log"]["file_path"] = "server/moonlight.log"

    target = root / route
    if target.exists():
        raise FileExistsError(f"Stream instance already exists: {route}")
    (target / "server").mkdir(parents=True)
    shutil.copytree(package / "static", target / "static")
    patch_audio_player(target / "static")
    shutil.copy2(package / "streamer.exe", target / "streamer.exe")
    settings = target / "static" / "default_settings.js"
    text = settings.read_text(encoding="utf-8")
    if '"videoFrameQueueSize": 3' not in text or '"canvasRenderer": false' not in text:
        raise RuntimeError("Moonlight browser settings changed")
    settings.write_text(text.replace('"videoFrameQueueSize": 3', '"videoFrameQueueSize": 1')
                            .replace('"canvasRenderer": false', '"canvasRenderer": true'), encoding="utf-8")
    (target / "server" / "data.json").write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8")
    (target / "server" / "config.json").write_text(json.dumps(config, separators=(",", ":")), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("source_data", "template_config", "package", "root"):
        parser.add_argument(name, type=Path)
    parser.add_argument("route")
    parser.add_argument("address")
    parser.add_argument("sunshine_port", type=int)
    parser.add_argument("local_port", type=int)
    parser.add_argument("udp_port", type=int)
    args = parser.parse_args()
    provision(**vars(args))
