import importlib.util
import json
import subprocess
from pathlib import Path


PATCHER = Path(__file__).resolve().parents[1] / "docker" / "moonlight-web" / "patch_defaults.py"
spec = importlib.util.spec_from_file_location("patch_defaults", PATCHER)
patch_defaults = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch_defaults)


def test_host_seat_defaults_are_scoped_and_user_preferences_remain_possible(tmp_path):
    source = tmp_path / "default_settings.js"
    source.write_text(
        'const trueDefaultSettings = {"videoFrameQueueSize": 3, "videoSize": "custom", '
        '"canvasRenderer": false, "canvasVsync": false};\n'
        'export default trueDefaultSettings;\n',
        encoding="utf-8",
    )
    assert patch_defaults.patch_file(source) is True
    assert patch_defaults.patch_file(source) is False
    script = source.read_text(encoding="utf-8").replace(
        "export default trueDefaultSettings;",
        "globalThis.result = trueDefaultSettings;",
    )
    for path, expected in [
        ("/vm/seat-" + "a" * 32 + "/stream.html", (1, "1080p", True)),
        ("/vm/astra-testmann/stream.html", (3, "custom", False)),
    ]:
        run = subprocess.run(
            ["node", "-e", "globalThis.window={location:{pathname:process.argv[1]}};"
             + script + "if(JSON.stringify([result.videoFrameQueueSize,result.videoSize,result.canvasRenderer])"
             + "!==JSON.stringify(JSON.parse(process.argv[2])))process.exit(1)",
             path, json.dumps(expected)],
            capture_output=True, text=True,
        )
        assert run.returncode == 0, run.stderr


def test_changed_upstream_defaults_fail_closed(tmp_path):
    source = tmp_path / "default_settings.js"
    source.write_text("export default settings;\n", encoding="utf-8")
    try:
        patch_defaults.patch_file(source)
    except RuntimeError as error:
        assert "refusing to patch" in str(error)
    else:
        raise AssertionError("changed upstream defaults were accepted")


def test_host_seat_image_is_pinned_and_retains_nonroot_runtime():
    dockerfile = (PATCHER.parent / "Dockerfile.host-seat").read_text(encoding="utf-8")
    assert "@sha256:4ee561ec4043526e93b0b3dba4926031c86ee3c9dab0333475a6b3c7117c701a" in dockerfile
    assert "python /tmp/patch_defaults.py /tmp/default_settings-edit.js" in dockerfile
    assert "USER 999:999" in dockerfile
