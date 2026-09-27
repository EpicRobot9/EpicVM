"""Persistent remote-host registry for EpicVM.

Remote hosts are configuration records, not arbitrary URLs supplied by browser
clients.  The registry validates the record before creating an agent client,
refreshes when the file changes, and exposes only redacted inventory records.
"""
from __future__ import annotations

import ipaddress
import json
import base64
import hashlib
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping
from urllib.parse import urlparse

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover - production fails closed without the pinned dependency
    AESGCM = None

try:
    from .remote_agent_client import RemoteAgentHost
    from .vm_hosts import LocalDockerHost, VmHostRegistry
except ImportError:  # pragma: no cover - direct module loading
    from remote_agent_client import RemoteAgentHost
    from vm_hosts import LocalDockerHost, VmHostRegistry


HOST_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")
# Match the installer and the persistent directory mounted into the dashboard.
DEFAULT_REMOTE_HOSTS_FILE = "/opt/blobe-vm/remote-hosts.json"
_TOKEN_PREFIX = "EV1:"
_TOKEN_AAD = b"EpicVM remote host token v1"


class RemoteHostConfigError(ValueError):
    """The remote-host configuration is malformed or unsafe."""


def remote_hosts_path(path: str | os.PathLike[str] | None = None) -> Path:
    return Path(
        path
        or os.environ.get("EPICVM_REMOTE_HOSTS_FILE")
        or os.environ.get("BLOBEVM_REMOTE_HOSTS_FILE")
        or DEFAULT_REMOTE_HOSTS_FILE
    )


def _is_truthy(value: Any) -> bool:
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def _validate_agent_url(value: Any) -> str:
    url = str(value or "").strip()
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise RemoteHostConfigError("agent_url must be an http(s) URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RemoteHostConfigError("agent_url cannot contain credentials, query, or fragment")
    hostname = parsed.hostname.rstrip(".").lower()
    allowed = _is_truthy(os.environ.get("EPICVM_ALLOW_NON_TAILSCALE_HOSTS"))
    try:
        address = ipaddress.ip_address(hostname)
    except ValueError:
        address = None
    if not allowed:
        is_tailscale_ip = bool(address and ipaddress.ip_network("100.64.0.0/10").version == address.version and address in ipaddress.ip_network("100.64.0.0/10"))
        is_tailnet_name = hostname.endswith(".ts.net")
        if not (is_tailscale_ip or is_tailnet_name):
            raise RemoteHostConfigError("agent_url must target a Tailscale address")
    return url


def _token_key() -> bytes:
    secret = str(
        os.environ.get("EPICVM_REMOTE_HOST_KEY")
        or os.environ.get("DASH_V2_SECRET")
        or os.environ.get("BLOBEVM_SECRET_KEY")
        or ""
    ).strip()
    if AESGCM is None or not secret:
        raise RemoteHostConfigError("remote host token encryption is unavailable")
    return hashlib.sha256(b"EpicVM remote host tokens v1\0" + secret.encode("utf-8")).digest()


def _encrypt_token(token: str) -> str:
    value = str(token or "").strip()
    if not value or any(char.isspace() for char in value):
        raise RemoteHostConfigError("remote host token must be a single line")
    nonce = os.urandom(12)
    sealed = AESGCM(_token_key()).encrypt(nonce, value.encode("utf-8"), _TOKEN_AAD)
    return _TOKEN_PREFIX + base64.urlsafe_b64encode(nonce + sealed).decode("ascii")


def _decrypt_token(value: str) -> str:
    encoded = str(value or "")
    if not encoded.startswith(_TOKEN_PREFIX):
        if os.environ.get("EPICVM_ALLOW_PLAINTEXT_REMOTE_HOST_TOKENS") == "1":
            return encoded.strip()
        raise RemoteHostConfigError("remote host registry contains an unencrypted token")
    try:
        raw = base64.urlsafe_b64decode(encoded[len(_TOKEN_PREFIX):].encode("ascii"))
        if len(raw) <= 12:
            raise ValueError("short token envelope")
        token = AESGCM(_token_key()).decrypt(raw[:12], raw[12:], _TOKEN_AAD).decode("utf-8").strip()
    except Exception as exc:
        if isinstance(exc, RemoteHostConfigError):
            raise
        raise RemoteHostConfigError("remote host token could not be decrypted") from exc
    if not token or any(char.isspace() for char in token):
        raise RemoteHostConfigError("remote host token is invalid")
    return token


def _normalize_record(raw: Mapping[str, Any], *, persisted: bool = False) -> dict[str, Any]:
    host_id = str(raw.get("id") or "").strip().lower()
    if not HOST_ID_RE.fullmatch(host_id):
        raise RemoteHostConfigError("host id must match [a-z0-9][a-z0-9._-]{0,62}")
    if "token_enc" in raw:
        token = _decrypt_token(str(raw.get("token_enc") or ""))
    elif persisted:
        token = _decrypt_token(str(raw.get("token") or ""))
    else:
        token = str(raw.get("token") or "").strip()
    if not token:
        raise RemoteHostConfigError(f"remote host {host_id} is missing an agent token")
    try:
        timeout = max(0.5, min(float(raw.get("timeout", 2.0)), 20.0))
    except (TypeError, ValueError) as exc:
        raise RemoteHostConfigError(f"remote host {host_id} has an invalid timeout") from exc
    record = {
        "id": host_id,
        "display_name": str(raw.get("display_name") or raw.get("name") or host_id).strip()[:120],
        "platform": str(raw.get("platform") or "windows").strip().lower(),
        "provider": str(raw.get("provider") or "hyperv").strip().lower(),
        "agent_url": _validate_agent_url(raw.get("agent_url")),
        "token": token,
        "enabled": raw.get("enabled", True) is not False,
        "timeout": timeout,
    }
    if not record["display_name"]:
        raise RemoteHostConfigError(f"remote host {host_id} has an empty display name")
    return record


def _read_all_remote_host_configs(path: str | os.PathLike[str] | None = None) -> list[dict[str, Any]]:
    config_path = remote_hosts_path(path)
    if not config_path.exists():
        return []
    try:
        mode = stat.S_IMODE(config_path.stat().st_mode)
        # POSIX mode bits are authoritative on the Linux dashboard host. On
        # Windows, chmod() does not provide meaningful DACL information and
        # the agent token registry is not a supported dashboard deployment.
        if os.name != "nt" and mode & 0o077:
            raise RemoteHostConfigError("remote host registry must not be group/world readable")
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except RemoteHostConfigError:
        raise
    except OSError as exc:
        raise RemoteHostConfigError(f"cannot read remote host registry: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RemoteHostConfigError(f"invalid remote host registry JSON: {exc}") from exc
    raw_hosts = data if isinstance(data, list) else data.get("hosts", []) if isinstance(data, dict) else None
    if not isinstance(raw_hosts, list):
        raise RemoteHostConfigError("remote host registry hosts must be a list")
    result = []
    seen: set[str] = set()
    for raw in raw_hosts:
        if not isinstance(raw, Mapping):
            raise RemoteHostConfigError("each remote host must be an object")
        record = _normalize_record(raw, persisted=True)
        if record["id"] == "local" or record["id"] in seen:
            raise RemoteHostConfigError(f"duplicate or reserved remote host id: {record['id']}")
        seen.add(record["id"])
        result.append(record)
    return result


def _write_remote_host_configs(path: str | os.PathLike[str] | None, hosts: Iterable[Mapping[str, Any]]) -> None:
    config_path = remote_hosts_path(path)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{config_path.name}.", dir=str(config_path.parent), text=True)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, 0o600)
        else:
            # Windows lacks fchmod(); chmod the named temporary file before
            # opening it through the descriptor. The production dashboard is
            # Linux, where the descriptor path enforces the POSIX mode.
            os.chmod(temporary, 0o600)
        persisted_hosts = []
        for host in hosts:
            item = dict(host)
            token = str(item.pop("token", "") or "").strip()
            if not token:
                raise RemoteHostConfigError("remote host token is required")
            item.pop("token_enc", None)
            item["token_enc"] = _encrypt_token(token)
            persisted_hosts.append(item)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = None
            json.dump(persisted_hosts, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, config_path)
        os.chmod(config_path, 0o600)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def upsert_remote_host_config(raw: Mapping[str, Any], path: str | os.PathLike[str] | None = None) -> dict[str, Any]:
    """Validate and atomically upsert one host, retaining disabled records."""
    record = _normalize_record(raw)
    if record["id"] == "local":
        raise RemoteHostConfigError("local is reserved and cannot be enrolled")
    existing = _read_all_remote_host_configs(path)
    updated = [item for item in existing if item["id"] != record["id"]]
    _write_remote_host_configs(path, updated + [record])
    return dict(record)


def load_remote_host_configs(path: str | os.PathLike[str] | None = None) -> list[dict[str, Any]]:
    return [record for record in _read_all_remote_host_configs(path) if record["enabled"]]


class ConfiguredVmHostRegistry(VmHostRegistry):
    """Local provider plus validated remote providers from a JSON registry."""

    def __init__(self, local_provider: LocalDockerHost | None = None, path: str | os.PathLike[str] | None = None):
        self.local_provider = local_provider or LocalDockerHost()
        self.path = remote_hosts_path(path)
        self.inventory_cache_path = self.path.with_name(f"{self.path.name}.inventory.json")
        self._inventory_cache: dict[str, list[dict[str, Any]]] = self._load_inventory_cache()
        self._loaded_signature: tuple[int, int, int] | None = None
        self.config_error = ""
        super().__init__([self.local_provider])
        self.refresh(force=True)

    def _load_inventory_cache(self) -> dict[str, list[dict[str, Any]]]:
        if not self.inventory_cache_path.exists():
            return {}
        try:
            if os.name != "nt" and stat.S_IMODE(self.inventory_cache_path.stat().st_mode) & 0o077:
                return {}
        except OSError:
            return {}
        try:
            payload = json.loads(self.inventory_cache_path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                return {}
            return {
                str(host_id): [dict(item) for item in items if isinstance(item, Mapping)]
                for host_id, items in payload.items()
                if isinstance(items, list)
            }
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            return {}

    def remember_inventory(self, host_id: str, instances: Iterable[Mapping[str, Any]]) -> None:
        """Persist redacted VM ownership metadata for offline dashboard cards."""
        allowed = {
            "name", "status", "state", "url", "placement", "host_id",
            "host_name", "provider", "host_online", "id",
        }
        records = [
            {key: item[key] for key in allowed if key in item}
            for item in instances
            if isinstance(item, Mapping)
        ]
        self._inventory_cache[str(host_id)] = records
        self.inventory_cache_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.inventory_cache_path.with_name(f".{self.inventory_cache_path.name}.tmp")
        temporary.write_text(json.dumps(self._inventory_cache, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        os.replace(temporary, self.inventory_cache_path)

    def cached_inventory(self, host_id: str) -> list[dict[str, Any]]:
        return [dict(item) for item in self._inventory_cache.get(str(host_id), [])]

    def _signature(self) -> tuple[int, int, int] | None:
        try:
            path_stat = self.path.stat()
        except FileNotFoundError:
            return None
        return (
            int(path_stat.st_mtime_ns),
            int(path_stat.st_size),
            int(stat.S_IMODE(path_stat.st_mode)),
        )

    def refresh(self, *, force: bool = False) -> None:
        signature = self._signature()
        if not force and signature == self._loaded_signature:
            return
        providers: dict[str, Any] = {"local": self.local_provider}
        try:
            records = load_remote_host_configs(self.path)
            self.config_error = ""
        except RemoteHostConfigError as exc:
            # A malformed optional registry must not take down the dashboard;
            # keep local VMs available and surface the redacted error in the
            # host-inventory response.
            records = []
            self.config_error = str(exc)[:500]
        for record in records:
            providers[record["id"]] = RemoteAgentHost(record)
        self._providers = providers
        self._loaded_signature = signature

    def get(self, host_id: str = "local"):
        self.refresh()
        return super().get(host_id)

    @property
    def providers(self):
        self.refresh()
        return super().providers

    def public_records(self) -> list[dict[str, Any]]:
        self.refresh()
        local = {
            "id": "local",
            "display_name": getattr(self.local_provider, "host_name", "EpicVM Server"),
            "kind": "local",
            "platform": "linux",
            "provider": getattr(self.local_provider, "provider", "local-docker"),
            "transport": "local",
            "online": True,
            "capabilities": {
                "create_vm": True,
                "start": True,
                "stop": True,
                "restart": True,
                "delete": True,
                "console": True,
                "provisioning": True,
            },
            "resources": {},
            "last_error": "",
        }
        records = [local]
        for host_id, provider in self._providers.items():
            if host_id == "local":
                continue
            try:
                records.append(provider.public_record())
            except Exception as exc:  # inventory must remain useful if a host is broken
                records.append({
                    "id": host_id,
                    "display_name": getattr(provider, "host_name", host_id),
                    "kind": "remote",
                    "platform": getattr(provider, "platform", "unknown"),
                    "provider": getattr(provider, "provider", "unknown"),
                    "transport": "tailscale",
                    "online": False,
                    "capabilities": {"create_vm": False, "start": False, "stop": False, "restart": False, "delete": False, "console": False, "provisioning": False},
                    "resources": {},
                    "last_error": str(exc)[:500],
                })
        return records


def redact_host_record(record: Mapping[str, Any]) -> dict[str, Any]:
    """Return a browser-safe copy; tokens and unknown secret fields never escape."""
    allowed = {
        "id", "display_name", "kind", "platform", "provider", "agent_url",
        "transport", "online", "capabilities", "resources", "last_error",
    }
    return {key: value for key, value in record.items() if key in allowed}


__all__ = [
    "ConfiguredVmHostRegistry",
    "DEFAULT_REMOTE_HOSTS_FILE",
    "RemoteHostConfigError",
    "load_remote_host_configs",
    "redact_host_record",
    "remote_hosts_path",
    "upsert_remote_host_config",
]
