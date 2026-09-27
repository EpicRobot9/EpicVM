"""Use tested low-latency browser defaults for EpicVM host seats only."""
from __future__ import annotations

import sys
from pathlib import Path


ANCHOR = "export default trueDefaultSettings;"
PATCH = """// Host seats favor prompt input feedback. Saved user preferences override these.
if (/^\\/vm\\/seat-[0-9a-f]{32}(?:\\/|$)/.test(window.location.pathname)) {
    trueDefaultSettings.videoFrameQueueSize = 1;
    trueDefaultSettings.videoSize = "1080p";
    trueDefaultSettings.canvasRenderer = true;
    trueDefaultSettings.canvasVsync = false;
}
export default trueDefaultSettings;"""


def patch_file(path: str | Path) -> bool:
    target = Path(path)
    source = target.read_text(encoding="utf-8")
    if PATCH in source:
        return False
    required = (
        '"videoFrameQueueSize": 3',
        '"videoSize": "custom"',
        '"canvasRenderer": false',
        '"canvasVsync": false',
    )
    if source.count(ANCHOR) != 1 or any(item not in source for item in required):
        raise RuntimeError("Pinned Moonlight defaults changed; refusing to patch")
    target.write_text(source.replace(ANCHOR, PATCH, 1), encoding="utf-8")
    return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_defaults.py DEFAULT_SETTINGS_JS")
    print("patched" if patch_file(sys.argv[1]) else "already-patched")
