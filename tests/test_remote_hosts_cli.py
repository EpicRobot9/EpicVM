import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import os
import stat
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
CLI_PATH = ROOT / "server" / "epicvm-remote-host"
POSIX = os.name != "nt"


def load_cli():
    loader = SourceFileLoader("epicvm_remote_host_cli_test", str(CLI_PATH))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_token_generate_is_redacted_and_add_list_stay_redacted(tmp_path, capsys):
    cli = load_cli()
    registry = tmp_path / "remote-hosts.json"
    token_file = tmp_path / "agent.token"

    assert cli.main(["token-generate", "--output", str(token_file)]) == 0
    generated = json.loads(capsys.readouterr().out)
    assert generated == {"token": "[REDACTED]", "token_file": str(token_file)}
    if POSIX:
        assert stat.S_IMODE(token_file.stat().st_mode) == 0o600

    assert cli.main([
        "--registry", str(registry), "add", "epic-pc", "Epic PC", "http://100.64.0.2:8765",
        "--token-file", str(token_file),
    ]) == 0
    added = json.loads(capsys.readouterr().out)
    assert "token" not in added
    if POSIX:
        assert stat.S_IMODE(registry.stat().st_mode) == 0o600

    assert cli.main(["--registry", str(registry), "list"]) == 0
    listed = json.loads(capsys.readouterr().out)
    assert "token" not in listed
    assert "enrollment_token" not in listed


def test_token_file_must_be_private(tmp_path):
    cli = load_cli()
    registry = tmp_path / "remote-hosts.json"
    token_file = tmp_path / "agent.token"
    token_file.write_text("secret-token\n")
    token_file.chmod(0o644)

    if not POSIX:
        pytest.skip("Windows does not expose POSIX group/world mode bits")
    with pytest.raises(SystemExit, match="token file"):
        cli.main([
            "--registry", str(registry), "add", "epic-pc", "Epic PC", "http://100.64.0.2:8765",
            "--token-file", str(token_file),
        ])


def test_enable_disable_preserve_secret_and_change_only_state(tmp_path, capsys, monkeypatch):
    cli = load_cli()
    registry = tmp_path / "remote-hosts.json"
    monkeypatch.setattr(sys, "stdin", io.StringIO("secret-token\n"))
    assert cli.main([
        "--registry", str(registry), "add", "epic-pc", "Epic PC", "http://100.64.0.2:8765",
        "--token-stdin",
    ]) == 0
    capsys.readouterr()

    assert cli.main(["--registry", str(registry), "disable", "epic-pc"]) == 0
    disabled = json.loads(capsys.readouterr().out)
    assert disabled == {"enabled": False, "id": "epic-pc"}
    assert cli.read_hosts(registry)[0]["token"] == "secret-token"
    assert cli.read_hosts(registry)[0]["enabled"] is False

    assert cli.main(["--registry", str(registry), "enable", "epic-pc"]) == 0
    enabled = json.loads(capsys.readouterr().out)
    assert enabled == {"enabled": True, "id": "epic-pc"}
def test_non_tailscale_url_is_rejected_by_default(tmp_path, monkeypatch):
    cli = load_cli()
    registry = tmp_path / "remote-hosts.json"
    token_file = tmp_path / "agent.token"
    token_file.write_text("secret-token\n")
    token_file.chmod(0o600)
    monkeypatch.delenv("EPICVM_ALLOW_NON_TAILSCALE_HOSTS", raising=False)
    with pytest.raises(SystemExit, match="Tailscale"):
        cli.main([
            "--registry", str(registry), "add", "epic-pc", "Epic PC", "http://192.0.2.10:8765",
            "--token-file", str(token_file),
        ])


def test_guided_setup_collects_enrollment_fields_and_probes(tmp_path, monkeypatch, capsys):
    cli = load_cli()
    registry = tmp_path / "remote-hosts.json"
    token_file = tmp_path / "agent.token"
    token_file.write_text("secret-token\n")
    token_file.chmod(0o600)

    class GuidedInput(io.StringIO):
        def isatty(self):
            return True

    monkeypatch.setattr(cli.sys, "stdin", GuidedInput(
        "epic-pc\nEpic PC\nhttp://100.64.0.2:8765\n" + str(token_file) + "\n"
    ))
    monkeypatch.setattr(cli, "cmd_probe", lambda args: 0)

    assert cli.main(["--registry", str(registry), "setup"]) == 0
    output = capsys.readouterr().out
    assert "secret-token" not in output
    assert cli.read_hosts(registry)[0]["id"] == "epic-pc"
    assert cli.read_hosts(registry)[0]["agent_url"] == "http://100.64.0.2:8765"
