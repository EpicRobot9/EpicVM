"""VM host/provider contracts used by the dashboard.

The first provider is deliberately small: it keeps the existing local
``epicvm`` subprocess interface intact while giving callers a host
identity that a remote provider can implement later.
"""

from __future__ import annotations

import os
import subprocess
from typing import Any, Iterable, Mapping, Protocol, Sequence


class VmHostError(RuntimeError):
    """Base error for VM host/provider failures."""


class VmHostUnavailable(VmHostError):
    """Raised when a requested VM host cannot be used or does not exist."""

    def __init__(self, message: str, *, status: int = 503, code: str = "host_unavailable"):
        super().__init__(message)
        self.status = int(status)
        self.code = str(code)


class VmHostProvider(Protocol):
    """Subprocess and inventory contract shared by VM host providers."""

    host_id: str
    host_name: str
    provider: str
    placement: str

    def command(self, *args: object) -> list[str]:
        ...

    def run_manager(
        self, *args: object, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        ...

    def check_call(self, *args: object, **kwargs: Any) -> int:
        ...

    def check_output(self, *args: object, **kwargs: Any) -> str | bytes:
        ...

    def normalize_inventory(
        self, instances: Iterable[Mapping[str, Any]]
    ) -> list[dict[str, Any]]:
        ...

    def list_vms(self) -> list[dict[str, Any]]:
        ...


class LocalDockerHost:
    """Provider for the VM manager and Docker daemon on this host.

    The provider intentionally does not shell out to Docker itself.  It wraps
    the existing manager subprocess calls so the dashboard can select a host
    without changing command arguments, subprocess options, or result types.
    """

    host_id = "local"
    host_name = "EpicVM Server"
    provider = "local-docker"
    placement = "local"

    def __init__(self, manager: str | None = None):
        self.manager = manager or self._default_manager()

    @staticmethod
    def _default_manager() -> str:
        app_root = "/opt/blobe-vm"
        manager = os.environ.get("EPICVM_MANAGER") or os.environ.get("BLOBEVM_MANAGER") or os.path.join(
            app_root, "server", "epicvm"
        )
        return manager if os.path.isfile(manager) else "epicvm"

    @property
    def id(self) -> str:
        """Compatibility alias for callers that use ``id`` for host identity."""

        return self.host_id

    @property
    def name(self) -> str:
        """Compatibility alias for callers that use ``name`` for host identity."""

        return self.host_name

    def command(self, *args: object) -> list[str]:
        """Build the manager argv without invoking a subprocess."""

        return [self.manager, *(str(arg) for arg in args)]

    def run_manager(self, *args: object, **kwargs: Any) -> subprocess.CompletedProcess[str]:
        """Run ``epicvm`` with the exact supplied subprocess options."""

        try:
            return subprocess.run(self.command(*args), **kwargs)
        except FileNotFoundError as exc:
            raise VmHostUnavailable(
                f"VM manager is unavailable: {self.manager}"
            ) from exc

    def check_call(self, *args: object, **kwargs: Any) -> int:
        """Run a manager command using ``subprocess.check_call`` semantics."""

        try:
            return subprocess.check_call(self.command(*args), **kwargs)
        except FileNotFoundError as exc:
            raise VmHostUnavailable(
                f"VM manager is unavailable: {self.manager}"
            ) from exc

    def check_output(self, *args: object, **kwargs: Any) -> str | bytes:
        """Run a manager command using ``subprocess.check_output`` semantics."""

        try:
            return subprocess.check_output(self.command(*args), **kwargs)
        except FileNotFoundError as exc:
            raise VmHostUnavailable(
                f"VM manager is unavailable: {self.manager}"
            ) from exc

    # Short aliases keep the provider useful to existing dashboard helpers
    # without exposing the manager executable path to those helpers.
    run = run_manager
    call = check_call
    output = check_output

    def create(self, name: str, **kwargs: Any) -> subprocess.CompletedProcess[str]:
        return self.run_manager("create", name, **kwargs)

    def start(self, name: str, **kwargs: Any) -> subprocess.CompletedProcess[str]:
        return self.run_manager("start", name, **kwargs)

    def stop(self, name: str, **kwargs: Any) -> int:
        return self.check_call("stop", name, **kwargs)

    def restart(self, name: str, **kwargs: Any) -> subprocess.CompletedProcess[str]:
        return self.run_manager("restart", name, **kwargs)

    def delete(self, name: str, **kwargs: Any) -> int:
        return self.check_call("delete", name, **kwargs)

    def recreate(
        self, *names: str, **kwargs: Any
    ) -> subprocess.CompletedProcess[str]:
        return self.run_manager("recreate", *names, **kwargs)

    def normalize_inventory(
        self, instances: Iterable[Mapping[str, Any]]
    ) -> list[dict[str, Any]]:
        """Add local placement metadata without removing existing fields."""

        normalized = []
        metadata = {
            "placement": self.placement,
            "host_id": self.host_id,
            "host_name": self.host_name,
            "provider": self.provider,
        }
        for instance in instances:
            item = dict(instance)
            item.update(metadata)
            normalized.append(item)
        return normalized

    def list_vms(self) -> list[dict[str, Any]]:
        """List manager inventory and normalize its legacy text format."""

        output = self.check_output("list", text=True)
        if isinstance(output, bytes):
            output = output.decode()
        instances: list[dict[str, Any]] = []
        for line in str(output).splitlines():
            if not line.startswith("- "):
                continue
            parts = [part.strip() for part in line[2:].split("->")]
            name = parts[0].split()[0] if parts and parts[0].split() else ""
            if not name:
                continue
            instances.append(
                {
                    "name": name,
                    "status": parts[1] if len(parts) > 1 else "",
                    "url": parts[2] if len(parts) > 2 else "",
                }
            )
        return self.normalize_inventory(instances)

    list_instances = list_vms


class VmHostRegistry:
    """Lookup registry for VM host providers, local by default."""

    def __init__(self, providers: Sequence[VmHostProvider] | None = None):
        if providers is None:
            providers = (LocalDockerHost(),)
        self._providers: dict[str, VmHostProvider] = {}
        for provider in providers:
            self.register(provider)

    def register(self, provider: VmHostProvider) -> VmHostProvider:
        host_id = str(getattr(provider, "host_id", "") or "").strip()
        if not host_id:
            raise VmHostError("VM host providers must define host_id")
        self._providers[host_id] = provider
        return provider

    def get(self, host_id: str = "local") -> VmHostProvider:
        key = str(host_id or "local").strip() or "local"
        try:
            return self._providers[key]
        except KeyError as exc:
            raise VmHostUnavailable(f"VM host is unavailable: {key}") from exc

    lookup = get
    get_provider = get

    def __contains__(self, host_id: object) -> bool:
        return host_id in self._providers

    @property
    def providers(self) -> dict[str, VmHostProvider]:
        return dict(self._providers)


VM_HOST_REGISTRY = VmHostRegistry()


def get_vm_host(host_id: str = "local") -> VmHostProvider:
    """Return a registered VM host provider by id."""

    return VM_HOST_REGISTRY.get(host_id)


__all__ = [
    "LocalDockerHost",
    "VM_HOST_REGISTRY",
    "VmHostError",
    "VmHostProvider",
    "VmHostRegistry",
    "VmHostUnavailable",
    "get_vm_host",
]
