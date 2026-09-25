import importlib.util
import os
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PATCH_PATH = REPO_ROOT / "docker" / "moonlight-web" / "patch_stream.py"


spec = importlib.util.spec_from_file_location("epicvm_moonlight_patch_stream", PATCH_PATH)
assert spec and spec.loader
patch_stream = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_stream)


def pinned_bundle_text(*parts: str) -> str:
    return "".join(part for part in parts if part) + patch_stream.AUTO_WATCHDOG_ANCHOR + "tail"


def test_enet_close_guard_patches_the_pinned_bundle_once(tmp_path):
    bundle = tmp_path / "stream.js"
    play_gate = patch_stream.WATCHDOG_ANCHOR
    bundle.write_text(
        pinned_bundle_text("prefix" + play_gate + "middle" + play_gate + "suffix" + patch_stream.OLD),
        encoding="utf-8",
    )

    assert patch_stream.patch_file(bundle) is True
    patched = bundle.read_text(encoding="utf-8")
    assert patch_stream.OLD not in patched
    assert patch_stream.NEW in patched
    assert "readyState" in patched
    # The stream-start watchdog must arm on both video sink classes.
    assert patched.count(patch_stream.WATCHDOG_PATCHED) == 2
    assert "function epicvmArmFrameWatchdog" in patched

    # A second build step is harmless and does not duplicate the overlay.
    assert patch_stream.patch_file(bundle) is False
    assert bundle.read_text(encoding="utf-8") == patched


def test_stream_start_watchdog_arms_on_single_sink_bundles(tmp_path):
    """Some builds ship one video sink; the overlay must tolerate 1 or 2."""
    bundle = tmp_path / "stream.js"
    bundle.write_text(
        pinned_bundle_text("prefix" + patch_stream.WATCHDOG_ANCHOR + "suffix" + patch_stream.OLD),
        encoding="utf-8",
    )

    assert patch_stream.patch_file(bundle) is True
    patched = bundle.read_text(encoding="utf-8")
    assert patched.count(patch_stream.WATCHDOG_PATCHED) == 1


def test_enet_close_guard_handles_read_only_bundle_mode(tmp_path):
    bundle = tmp_path / "stream.js"
    bundle.write_text(
        pinned_bundle_text("prefix" + patch_stream.WATCHDOG_ANCHOR + patch_stream.OLD + "suffix"),
        encoding="utf-8",
    )
    bundle.chmod(0o444)

    assert patch_stream.patch_file(bundle) is True
    assert patch_stream.NEW in bundle.read_text(encoding="utf-8")
    if os.name != "nt":
        assert bundle.stat().st_mode & 0o777 == 0o444


def test_enet_close_guard_fails_closed_when_bundle_shape_changes(tmp_path):
    bundle = tmp_path / "stream.js"
    bundle.write_text("unrelated bundle", encoding="utf-8")

    try:
        patch_stream.patch_file(bundle)
    except RuntimeError as exc:
        assert "expected exactly one" in str(exc)
    else:
        raise AssertionError("bundle-shape drift must fail closed")


def test_overlay_dockerfile_is_pinned_and_preserves_nonroot_runtime():
    dockerfile = (REPO_ROOT / "docker" / "moonlight-web" / "Dockerfile").read_text(encoding="utf-8")

    assert "ARG BASE_IMAGE=" in dockerfile
    assert "@sha256:" in dockerfile
    assert "COPY --from=upstream /moonlight-web/static/stream.js" in dockerfile
    assert "COPY patch_stream.py /tmp/patch_stream.py" in dockerfile
    assert "python /tmp/patch_stream.py /tmp/stream.js" in dockerfile
    assert "chown 999:999" in dockerfile
    assert "USER 999:999" in dockerfile
