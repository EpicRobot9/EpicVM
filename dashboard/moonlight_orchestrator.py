"""Fail-closed Moonlight Web/Sunshine orchestration for EpicVM.

The bundle is intentionally smaller than the legacy Guacamole bundle.  The
Moonlight Web database contains only its own client keys and safe host/user
metadata.  Sunshine credentials are accepted by :meth:`pair_staged` for one
request, used for the official Sunshine pairing API, and never written to the
bundle, compose file, process arguments, or logs. Optional TURN credentials
are deployment secrets used to build the protected server config for browser
media relay.
"""
from __future__ import annotations

import base64
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Mapping
from urllib import error as urlerror, request as urlrequest

try:
    from .guacamole_orchestrator import ConsoleOrchestrationError
except ImportError:  # pragma: no cover - direct source execution
    from guacamole_orchestrator import ConsoleOrchestrationError


VM_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")
TAILSCALE_IP_RE = re.compile(r"^100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}$")
SHA256_IMAGE_RE = re.compile(r"^[^@]+@sha256:[0-9a-f]{64}$")
DEFAULT_MOONLIGHT_IMAGE = "mrcreativ3001/moonlight-web-stream@sha256:82cf429ffea07bdb30d3f8bf14e9e97a0a7186b0864ec4250b680b3c0c302d2b"
MOONLIGHT_PAIR_DEVICE_NAME = "EpicVMWeb"
WEBRTC_PORT_MIN = 41000
WEBRTC_PORT_MAX = 41010


def _webrtc_port_range(name: str) -> tuple[int, int]:
    """Keep the physical-PC proxy off the VM proxy's published UDP range."""
    safe = validate_vm_name(name)
    if safe.startswith("cloudpc-"):
        return WEBRTC_PORT_MAX + 1, WEBRTC_PORT_MAX + 11
    return WEBRTC_PORT_MIN, WEBRTC_PORT_MAX


def validate_vm_name(name: str) -> str:
    value = str(name or "").strip().lower()
    if not VM_NAME_RE.fullmatch(value):
        raise ConsoleOrchestrationError("Invalid VM name.", status=400, code="invalid_name")
    return value


def validate_guest_ip(address: str) -> str:
    value = str(address or "").strip()
    if not TAILSCALE_IP_RE.fullmatch(value):
        raise ConsoleOrchestrationError("The guest address is outside the tailnet range.", status=422, code="invalid_guest_ip")
    try:
        socket.inet_aton(value)
    except OSError as exc:
        raise ConsoleOrchestrationError("The guest address is invalid.", status=422, code="invalid_guest_ip") from exc
    return value


def _yaml_quote(value: str) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def _strip_shell_quotes(value: Any) -> str:
    text = str(value or "").strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1].strip()
    return text


def validate_webrtc_nat_host(address: Any) -> str:
    value = _strip_shell_quotes(address)
    if not value:
        return ""
    try:
        parsed = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError as exc:
        raise ConsoleOrchestrationError(
            "The Moonlight WebRTC NAT host is invalid.",
            status=503,
            code="invalid_moonlight_nat_host",
        ) from exc
    # A console can deliberately advertise either the KVM host's tailnet
    # address for private-only access or its public address for Internet
    # clients. Reject every other non-routable address so an accidental LAN,
    # loopback, or link-local value cannot silently strand remote browsers.
    public_unicast = parsed.is_global and not (parsed.is_multicast or parsed.is_reserved or parsed.is_unspecified)
    if not TAILSCALE_IP_RE.fullmatch(value) and not public_unicast:
        raise ConsoleOrchestrationError(
            "The Moonlight WebRTC NAT host must be a Tailscale or public IPv4 address.",
            status=503,
            code="invalid_moonlight_nat_host",
        )
    return value


def _turn_urls(value: Any) -> list[str]:
    """Return TURN URLs in the syntax accepted by the bundled ICE client."""
    urls = []
    for item in str(value or '').split(','):
        url = item.strip()
        if not url:
            continue
        if not re.fullmatch(r'turns?:[A-Za-z0-9][A-Za-z0-9._:-]*', url):
            raise ConsoleOrchestrationError(
                'The Moonlight TURN URL is invalid.',
                status=503,
                code='invalid_moonlight_turn_url',
            )
        urls.append(url)
    return urls


@dataclass(frozen=True)
class MoonlightPlan:
    name: str
    guest_ip: str
    route_prefix: str
    compose: str
    config: str
    data: str
    sunshine_port: int = 47989


class MoonlightOrchestrator:
    """Manage one isolated Moonlight Web instance per EpicVM guest."""

    backend = "moonlight"

    def __init__(
        self,
        *,
        root: str = "/opt/epicvm/moonlight-instances",
        proxy_network: str = "proxy",
        public_host: str | None = None,
        tls_resolver: str | None = None,
        auth_middleware: str | None = None,
        router_priority: int | str | None = None,
        webrtc_nat_host: str | None = None,
        digests: Mapping[str, str] | None = None,
        tcp_probe: Callable[[str, int, float], bool] | None = None,
        disk_probe: Callable[[], bool] | None = None,
        route_owner_probe: Callable[[str], bool] | None = None,
        routing_probe: Callable[[], bool] | None = None,
        auth_status_probe: Callable[[str], bool] | None = None,
        command_runner: Callable[..., Any] | None = None,
        http_request: Callable[..., Any] | None = None,
    ):
        self.root = Path(root)
        self.proxy_network = str(proxy_network or "proxy")
        self.public_host = str(public_host or os.environ.get("EPICVM_PUBLIC_HOST", "")).strip().lower()
        self.tls_resolver = str(tls_resolver or os.environ.get("EPICVM_TRAEFIK_CERTRESOLVER", "")).strip()
        self.auth_middleware = str(auth_middleware or os.environ.get("EPICVM_TRAEFIK_AUTH_MIDDLEWARE", "")).strip()
        self.router_priority = str(router_priority or os.environ.get("EPICVM_TRAEFIK_ROUTER_PRIORITY", "")).strip()
        nat_value = webrtc_nat_host if webrtc_nat_host is not None else os.environ.get("EPICVM_MOONLIGHT_NAT_HOST", "")
        self.webrtc_nat_host = validate_webrtc_nat_host(nat_value)
        self.webrtc_turn_urls = _turn_urls(os.environ.get('EPICVM_MOONLIGHT_TURN_URLS', ''))
        self.webrtc_turn_username = _strip_shell_quotes(os.environ.get('EPICVM_MOONLIGHT_TURN_USERNAME', ''))
        self.webrtc_turn_credential = _strip_shell_quotes(os.environ.get('EPICVM_MOONLIGHT_TURN_CREDENTIAL', ''))
        if any((self.webrtc_turn_urls, self.webrtc_turn_username, self.webrtc_turn_credential)) and not all(
            (self.webrtc_turn_urls, self.webrtc_turn_username, self.webrtc_turn_credential)
        ):
            raise ConsoleOrchestrationError(
                'Moonlight TURN configuration requires URLs, username, and credential together.',
                status=503,
                code='moonlight_turn_config_required',
            )
        self.digests = dict(digests or {})
        self.tcp_probe = tcp_probe or self._tcp_probe
        self.disk_probe = disk_probe or self._disk_ready
        self.route_owner_probe = route_owner_probe or self._route_available
        self.routing_probe = routing_probe or self._routing_available
        self.auth_status_probe = auth_status_probe or self._public_auth_rejected
        self.command_runner = command_runner or subprocess.run
        # Tests inject this.  Production uses urllib directly with a private
        # Docker-network address and a short timeout.
        self.http_request = http_request

    def _image(self) -> str:
        if "moonlight" in self.digests:
            value = _strip_shell_quotes(self.digests.get("moonlight"))
        else:
            value = _strip_shell_quotes(os.environ.get("EPICVM_MOONLIGHT_IMAGE", "") or DEFAULT_MOONLIGHT_IMAGE)
        if not SHA256_IMAGE_RE.fullmatch(value):
            raise ConsoleOrchestrationError("Digest-pinned moonlight image is not configured.", status=503, code="digest_required")
        return value

    def _routing_config(self) -> tuple[str, str, int]:
        if (
            not re.fullmatch(r"[a-z0-9.-]+", self.public_host)
            or not self.tls_resolver
            or not self.router_priority.isdigit()
        ):
            raise ConsoleOrchestrationError("Verified Traefik routing configuration is unavailable.", status=503, code="routing_config_required")
        priority = int(self.router_priority)
        if priority < 1 or priority > 100000:
            raise ConsoleOrchestrationError("The Traefik router priority is invalid.", status=503, code="routing_config_invalid")
        return self.public_host, self.tls_resolver, priority

    def _disk_ready(self) -> bool:
        candidate = self.root
        while not candidate.exists() and candidate != candidate.parent:
            candidate = candidate.parent
        usage = shutil.disk_usage(candidate)
        used = ((usage.total - usage.free) / usage.total * 100) if usage.total else 100
        return usage.free >= 20 * 1024**3 and used < 85

    def _route_available(self, route_prefix: str) -> bool:
        try:
            listed = self.command_runner(["docker", "ps", "-aq"], check=True, capture_output=True, text=True)
            ids = str(getattr(listed, "stdout", "") or "").split()
            if not ids:
                return True
            inspected = self.command_runner(["docker", "inspect", *ids], check=True, capture_output=True, text=True)
            records = json.loads(str(getattr(inspected, "stdout", "[]") or "[]"))
            variants = (route_prefix, route_prefix.rstrip("/"))
            for record in records:
                labels = (((record or {}).get("Config") or {}).get("Labels") or {})
                rules = [str(v) for k, v in labels.items() if str(k).startswith("traefik.http.routers.") and str(k).endswith(".rule")]
                if any(any(variant in rule for variant in variants) for rule in rules):
                    return False
            return True
        except (OSError, subprocess.SubprocessError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ConsoleOrchestrationError("Traefik route ownership could not be verified.", status=503, code="route_probe_failed") from exc

    def _routing_available(self) -> bool:
        _, resolver, _ = self._routing_config()
        try:
            self.command_runner(["docker", "network", "inspect", self.proxy_network], check=True, capture_output=True, text=True)
            listed = self.command_runner(["docker", "ps", "-q"], check=True, capture_output=True, text=True)
            ids = str(getattr(listed, "stdout", "") or "").split()
            if not ids:
                return False
            inspected = self.command_runner(["docker", "inspect", *ids], check=True, capture_output=True, text=True)
            records = json.loads(str(getattr(inspected, "stdout", "[]") or "[]"))
            dashboard = any(
                str((record or {}).get("Name") or "").lstrip("/") == "blobedash"
                and self.proxy_network in (((record or {}).get("NetworkSettings") or {}).get("Networks") or {})
                for record in records
            )
            secure_route = any(
                any(str(k).endswith(".tls.certresolver") and str(v) == resolver for k, v in (((record or {}).get("Config") or {}).get("Labels") or {}).items())
                for record in records
            )
            return dashboard and secure_route
        except (OSError, subprocess.SubprocessError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ConsoleOrchestrationError("Traefik authentication and TLS ownership could not be verified.", status=503, code="routing_probe_failed") from exc

    @staticmethod
    def _tcp_probe(host: str, port: int, timeout: float) -> bool:
        try:
            with socket.create_connection((host, int(port)), timeout=float(timeout)):
                return True
        except OSError:
            return False

    def _public_auth_rejected(self, route_prefix: str) -> bool:
        url = f"https://{self.public_host}{route_prefix}"

        class NoRedirect(urlrequest.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        try:
            with urlrequest.build_opener(NoRedirect).open(url, timeout=8):
                return False
        except urlerror.HTTPError as exc:
            if int(exc.code) in (401, 403):
                return True
            if int(exc.code) not in (302, 303, 307, 308):
                return False
            return str(exc.headers.get("Location") or "").split("?", 1)[0].endswith("/portal/login")
        except (OSError, urlerror.URLError):
            return False

    def _instance_root(self, name: str) -> Path:
        return self.root / validate_vm_name(name)

    @staticmethod
    def _project_name(name: str) -> str:
        return f"epicvm-{validate_vm_name(name).replace('.', '-')}-moonlight"

    def build_config(self, *, name: str, route_name: str | None = None, ports: tuple[int, int] | None = None, sunshine_port: int = 47989) -> str:
        safe = validate_vm_name(name)
        route = validate_vm_name(route_name or name)
        port_min, port_max = ports or _webrtc_port_range(safe)
        nat_1to1 = {"ice_candidate_type": "host", "ips": [self.webrtc_nat_host]} if self.webrtc_nat_host else None
        ice_servers = [
            {"urls": ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:3478"], "username": "", "credential": ""}
        ]
        if self.webrtc_turn_urls and self.webrtc_turn_username and self.webrtc_turn_credential:
            ice_servers.append({
                "urls": self.webrtc_turn_urls,
                "username": self.webrtc_turn_username,
                "credential": self.webrtc_turn_credential,
            })
        value = {
            "data_storage": {"type": "json", "path": "server/data.json", "session_expiration_check_interval": {"secs": 300, "nanos": 0}},
            "webrtc": {"ice_servers": ice_servers, "ice_server_script": None, "port_range": {"min": port_min, "max": port_max}, "nat_1to1": nat_1to1, "network_types": ["udp4"], "include_loopback_candidates": False},
            "web_server": {"bind_address": "0.0.0.0:8080", "url_path_prefix": f"/vm/{route}", "session_cookie_secure": True, "session_cookie_expiration": {"secs": 86400, "nanos": 0}, "first_login_create_admin": True, "first_login_assign_global_hosts": True, "default_user_id": None, "default_role_id": None, "forwarded_header": {"username_header": "X-EpicVM-User", "auto_create_missing_user": True, "ignore_case": True}},
            "moonlight": {"default_http_port": sunshine_port, "pair_device_name": MOONLIGHT_PAIR_DEVICE_NAME},
            "streamer_path": "./streamer",
            "log": {"level_filter": "INFO", "file_path": None, "dev_venator": False},
            "default_settings": None,
        }
        return json.dumps(value, separators=(",", ":")) + "\n"

    def build_compose(self, *, name: str, route_name: str | None = None, ports: tuple[int, int] | None = None) -> str:
        safe = validate_vm_name(name)
        route = validate_vm_name(route_name or name)
        port_min, port_max = ports or _webrtc_port_range(safe)
        public_host, resolver, priority = self._routing_config()
        image = self._image()
        # Console authentication is per-VM and must go through the dashboard's
        # VM-session endpoint.  Do not inherit the legacy global middleware:
        # on the KVM host that value can point at the testre BasicAuth file,
        # which causes a second, unrelated browser credential prompt.
        auth_identity = f"epicvm-{route}-portal-auth"
        identity = f"epicvm-{route}-portal-user"
        labels = {
            "traefik.enable": "true",
            "com.blobevm.managed": "1",
            "com.epicvm.console": "moonlight",
            "com.epicvm.vm.name": safe,
            "traefik.docker.network": self.proxy_network,
            f"traefik.http.routers.epicvm-{route}.rule": f"Host(`{public_host}`) && PathPrefix(`/vm/{route}/`)",
            f"traefik.http.routers.epicvm-{route}.entrypoints": "websecure",
            f"traefik.http.routers.epicvm-{route}.tls": "true",
            f"traefik.http.routers.epicvm-{route}.tls.certresolver": resolver,
            f"traefik.http.routers.epicvm-{route}.priority": str(priority),
            f"traefik.http.routers.epicvm-{route}.service": f"epicvm-{route}",
            f"traefik.http.routers.epicvm-{route}.middlewares": f"{auth_identity},{identity}",
            f"traefik.http.middlewares.{auth_identity}.forwardauth.address": f"http://blobedash:5000/dashboard/auth/vm/{safe}",
            f"traefik.http.middlewares.{auth_identity}.forwardauth.trustForwardHeader": "true",
            f"traefik.http.middlewares.{identity}.headers.customrequestheaders.X-EpicVM-User": safe,
            f"traefik.http.services.epicvm-{route}.loadbalancer.server.port": "8080",
        }
        lines = "\n".join(f"      {key}: {_yaml_quote(value)}" for key, value in labels.items())
        nat_environment = (
            f"      WEBRTC_NAT_1TO1_HOST: {_yaml_quote(self.webrtc_nat_host)}\n"
            if self.webrtc_nat_host
            else ""
        )
        return f'''services:
  moonlight-web:
    image: {_yaml_quote(image)}
    init: true
    restart: unless-stopped
    environment:
      BIND_ADDRESS: "0.0.0.0:8080"
      PATH_PREFIX: "/vm/{route}"
      WEBRTC_PORT_RANGE: "{port_min}:{port_max}"
{nat_environment}    ports:
      - "{port_min}-{port_max}:{port_min}-{port_max}/udp"
    volumes:
      - ./server:/moonlight-web/server
    networks:
      - proxy
      - egress
    healthcheck:
      test: ["CMD-SHELL", "kill -0 1"]
      interval: 5s
      timeout: 3s
      retries: 30
      start_period: 10s
    labels:
{lines}
networks:
  proxy:
    external: true
  egress:
    driver: bridge
'''

    def _wait_for_sunshine(self, guest_ip: str, *, timeout: float = 30.0, sunshine_port: int = 47989) -> None:
        """Wait through the bounded guest-service restart window.

        A VM restart can leave RDP/WinRM reachable while Sunshine is still
        restarting. Treat that as a transient readiness condition rather than
        immediately returning the same console error the UI saw before. The
        timeout remains finite so a genuinely unreachable guest preserves the
        existing bundle and fails closed.
        """
        deadline = time.monotonic() + max(0.0, float(timeout))
        while True:
            missing = [
                port for port in (sunshine_port, sunshine_port + 1)
                if not self.tcp_probe(str(guest_ip), port, 2.0)
            ]
            if not missing:
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ConsoleOrchestrationError(
                    "Sunshine is not reachable from kvm2.",
                    status=409,
                    code="sunshine_tcp_unavailable",
                )
            time.sleep(min(1.0, remaining))

    def build_plan(
        self,
        *,
        name: str,
        guest_ip: str,
        route_name: str | None = None,
        allow_existing_owned_route: bool = False,
        sunshine_port: int = 47989,
    ) -> MoonlightPlan:
        safe = validate_vm_name(name)
        route = validate_vm_name(route_name or name)
        address = validate_guest_ip(guest_ip)
        if not 1024 <= int(sunshine_port) <= 65534:
            raise ConsoleOrchestrationError("Invalid stream port.", status=400, code="invalid_stream_port")
        self._wait_for_sunshine(address, sunshine_port=int(sunshine_port))
        route_prefix = f"/vm/{route}/"
        if not self.route_owner_probe(route_prefix):
            existing_owned_bundle = False
            if allow_existing_owned_route:
                try:
                    # The route probe sees the currently active bundle as an
                    # owner during in-place repair.  _read_plan is the stronger
                    # check here: it proves that this named bundle is owned by
                    # EpicVM before quarantine makes the requested route free.
                    self._read_plan(safe)
                    existing_owned_bundle = True
                except ConsoleOrchestrationError:
                    existing_owned_bundle = False
            if not existing_owned_bundle:
                raise ConsoleOrchestrationError("The requested console route is already owned.", status=409, code="route_collision")
        return MoonlightPlan(safe, address, route_prefix, self.build_compose(name=safe, route_name=route), self.build_config(name=safe, route_name=route, sunshine_port=int(sunshine_port)), '{"version":"3","users":{},"hosts":{},"roles":{}}\n', int(sunshine_port))

    def stage_plan(self, plan: MoonlightPlan) -> Path:
        target = self._instance_root(plan.name)
        if target.exists():
            raise ConsoleOrchestrationError("A console instance with this name already exists.", status=409, code="console_exists")
        if not self.disk_probe():
            raise ConsoleOrchestrationError("kvm2 storage is below the provisioning safety threshold.", status=507, code="storage_gate")
        if not self.routing_probe():
            raise ConsoleOrchestrationError("The verified Traefik authentication or TLS route is unavailable.", status=503, code="routing_probe_failed")
        if not self.route_owner_probe(plan.route_prefix):
            raise ConsoleOrchestrationError("The requested console route is already owned.", status=409, code="route_collision")
        target.parent.mkdir(parents=True, exist_ok=True)
        # Reserve atomically across dashboard workers, including stopped bundles.
        # Keep reservations during quarantine so repair/restart cannot steal a
        # different console's ports. Legacy bundles are discovered from config.
        ports = self._reserve_webrtc_ports(plan.name)
        route = plan.route_prefix.strip('/').split('/')[-1]
        plan = replace(plan,
                       compose=self.build_compose(name=plan.name, route_name=route, ports=ports),
                       config=self.build_config(name=plan.name, route_name=route, ports=ports, sunshine_port=plan.sunshine_port))
        # The pinned image runs as uid/gid 999.  Keep the bundle private from
        # ordinary users while allowing only that service account to traverse
        # and update Moonlight's client-key database.
        try:
            os.chmod(target.parent, 0o750)
            os.chown(target.parent, 999, 999)
        except (AttributeError, OSError):
            pass
        stage = target.parent / f".{plan.name}-{secrets.token_hex(8)}"
        stage.mkdir(mode=0o750)
        try:
            (stage / "docker-compose.yml").write_text(plan.compose, encoding="utf-8")
            server = stage / "server"
            server.mkdir(mode=0o700)
            (server / "config.json").write_text(plan.config, encoding="utf-8")
            (server / "data.json").write_text(plan.data, encoding="utf-8")
            (stage / "plan.json").write_text(json.dumps({"owner": "EpicVM", "version": 1, "backend": "moonlight", "name": plan.name, "guestIp": plan.guest_ip, "sunshinePort": plan.sunshine_port, "routePrefix": plan.route_prefix, "paired": False}, separators=(",", ":")), encoding="utf-8")
            os.chmod(stage / "docker-compose.yml", 0o600)
            os.chmod(server, 0o750)
            os.chmod(server / "config.json", 0o640)
            os.chmod(server / "data.json", 0o640)
            os.chmod(stage / "plan.json", 0o600)
            stage.rename(target)
            try:
                os.chown(target, 999, 999)
                os.chown(target / "server", 999, 999)
                os.chown(target / "server" / "config.json", 999, 999)
                os.chown(target / "server" / "data.json", 999, 999)
            except (AttributeError, OSError):
                pass
            return target
        except Exception:
            if stage.exists():
                for child in sorted(stage.rglob("*"), reverse=True):
                    if child.is_file() or child.is_symlink():
                        child.unlink(missing_ok=True)
                    elif child.is_dir():
                        child.rmdir()
                stage.rmdir()
            raise

    def _read_plan(self, name: str) -> dict[str, Any]:
        safe = validate_vm_name(name)
        target = self._instance_root(safe)
        try:
            value = json.loads((target / "plan.json").read_text(encoding="utf-8"))
            if value.get("owner") != "EpicVM" or value.get("backend") != "moonlight" or value.get("name") != safe:
                raise ValueError("ownership")
            return value
        except Exception as exc:
            raise ConsoleOrchestrationError("The named console instance is not owned by EpicVM.", status=403, code="ownership_required") from exc

    def _reserve_webrtc_ports(self, name: str) -> tuple[int, int]:
        safe = validate_vm_name(name)
        reservations = self.root / '.webrtc-ports'
        reservations.mkdir(mode=0o700, exist_ok=True)
        occupied = set()
        for config_path in self.root.glob('*/server/config.json'):
            if config_path.parent.parent.name == safe or config_path.parent.parent.name.startswith('.'):
                continue
            try:
                ports = json.loads(config_path.read_text(encoding='utf-8'))['webrtc']['port_range']
                occupied.update(range(int(ports['min']), int(ports['max']) + 1))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                raise ConsoleOrchestrationError('Console port ownership could not be verified.', status=503, code='console_port_probe_failed') from exc
        preferred, _ = _webrtc_port_range(safe)
        for reservation in reservations.iterdir():
            if reservation.name.isdigit() and reservation.read_text(encoding='utf-8') == safe:
                start = int(reservation.name)
                if not occupied.intersection(range(start, start + 11)):
                    return start, start + 10
        for start in [preferred, *range(WEBRTC_PORT_MIN, 65525, 11)]:
            end = start + 10
            if occupied.intersection(range(start, end + 1)):
                continue
            reservation = reservations / str(start)
            try:
                with reservation.open('x', encoding='utf-8') as handle:
                    handle.write(safe)
                return start, end
            except FileExistsError:
                if reservation.read_text(encoding='utf-8') == safe:
                    return start, end
        raise ConsoleOrchestrationError('No streaming UDP port range is available.', status=503, code='console_ports_exhausted')

    def _staged_webrtc_ports(self, name: str) -> tuple[int, int]:
        config = json.loads((self._instance_root(name) / 'server' / 'config.json').read_text(encoding='utf-8'))
        ports = config['webrtc']['port_range']
        return int(ports['min']), int(ports['max'])

    def _runtime_isolated(self, name: str) -> bool:
        safe = validate_vm_name(name)
        project = self._project_name(name)
        try:
            listed = self.command_runner(["docker", "ps", "--filter", f"label=com.docker.compose.project={project}", "-q"], check=True, capture_output=True, text=True)
            ids = str(getattr(listed, "stdout", "") or "").split()
            if len(ids) != 1:
                return False
            inspected = self.command_runner(["docker", "inspect", *ids], check=True, capture_output=True, text=True)
            record = json.loads(str(getattr(inspected, "stdout", "[]") or "[]"))[0]
            labels = (((record or {}).get("Config") or {}).get("Labels") or {})
            if str(labels.get("com.docker.compose.service") or "") != "moonlight-web":
                return False
            ports = (((record or {}).get("HostConfig") or {}).get("PortBindings") or {})
            port_min, port_max = self._staged_webrtc_ports(safe)
            expected_ports = {f"{port}/udp" for port in range(port_min, port_max + 1)}
            if set(str(key) for key in ports) != expected_ports:
                return False
            for container_port, mappings in ports.items():
                if not isinstance(mappings, list) or len(mappings) != 1:
                    return False
                binding = mappings[0] if isinstance(mappings[0], dict) else {}
                expected_host_port = str(container_port).split("/", 1)[0]
                if str(binding.get("HostPort") or "") != expected_host_port:
                    return False
                if str(binding.get("HostIp") or "") not in ("", "0.0.0.0"):
                    return False
            networks = set((((record or {}).get("NetworkSettings") or {}).get("Networks") or {}).keys())
            egress = any(str(value) == "egress" or str(value).endswith("_egress") for value in networks)
            return self.proxy_network in networks and egress
        except (OSError, subprocess.SubprocessError, TypeError, ValueError, json.JSONDecodeError):
            return False

    def _container_url(self, name: str, route_prefix: str | None = None) -> str:
        project = self._project_name(name)
        listed = self.command_runner(["docker", "ps", "--filter", f"label=com.docker.compose.project={project}", "-q"], check=True, capture_output=True, text=True)
        ids = str(getattr(listed, "stdout", "") or "").split()
        if len(ids) != 1:
            raise ConsoleOrchestrationError("The Moonlight service is not running.", status=502, code="console_runtime_missing")
        inspected = self.command_runner(["docker", "inspect", ids[0]], check=True, capture_output=True, text=True)
        records = json.loads(str(getattr(inspected, "stdout", "[]") or "[]"))
        networks = (((records[0] if records else {}) or {}).get("NetworkSettings") or {}).get("Networks") or {}
        address = str((networks.get(self.proxy_network) or {}).get("IPAddress") or "")
        if not address:
            raise ConsoleOrchestrationError("The Moonlight service address is unavailable.", status=502, code="console_runtime_missing")
        # Moonlight's API is mounted below the configured path prefix.  Keep
        # the internal URL path-correct; hitting the container root happens to
        # serve the UI but leaves the pairing endpoints at 404.
        route = str(route_prefix or f"/vm/{validate_vm_name(name)}").rstrip("/")
        if not route.startswith("/vm/"):
            raise ConsoleOrchestrationError("The Moonlight route prefix is invalid.", status=502, code="moonlight_route_failed")
        return f"http://{address}:8080{route}"

    def start_staged(self, name: str) -> dict[str, Any]:
        plan = self._read_plan(name)
        target = self._instance_root(name)
        self._wait_for_sunshine(str(plan["guestIp"]), timeout=30.0, sunshine_port=int(plan.get("sunshinePort") or 47989))
        try:
            self.command_runner(["docker", "compose", "-p", self._project_name(name), "up", "-d", "--wait", "--wait-timeout", "90"], cwd=str(target), check=True, capture_output=True, text=True)
        except (OSError, subprocess.SubprocessError) as exc:
            self.stop_staged(name)
            raise ConsoleOrchestrationError("The Moonlight stack failed its startup gate.", status=502, code="console_start_failed") from exc
        if not self._runtime_isolated(name):
            self.stop_staged(name)
            raise ConsoleOrchestrationError("The Moonlight stack exposed an internal service.", status=502, code="console_isolation_failed")
        auth_rejected = False
        for _ in range(10):
            if self.auth_status_probe(str(plan["routePrefix"])):
                auth_rejected = True
                break
            time.sleep(1)
        if not auth_rejected:
            self.stop_staged(name)
            raise ConsoleOrchestrationError("The public console route did not reject unauthenticated access.", status=502, code="console_auth_failed")
        return {"ok": True, "routePrefix": str(plan["routePrefix"]), "guestTcpVerified": True}

    def _http(self, method: str, url: str, *, headers: Mapping[str, str] | None = None, body: bytes | None = None, timeout: float = 15.0):
        if self.http_request is not None:
            return self.http_request(method, url, headers=dict(headers or {}), body=body, timeout=timeout)
        req = urlrequest.Request(url, data=body, headers=dict(headers or {}), method=method)
        if url.lower().startswith("https://"):
            return urlrequest.urlopen(req, timeout=timeout, context=ssl._create_unverified_context())
        return urlrequest.urlopen(req, timeout=timeout)

    @staticmethod
    def _json_line(response) -> Any:
        raw = response.readline()
        if not raw:
            raise ConsoleOrchestrationError("Moonlight pairing returned no response.", status=502, code="moonlight_pair_failed")
        try:
            return json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
        except (TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ConsoleOrchestrationError("Moonlight pairing returned an invalid response.", status=502, code="moonlight_pair_failed") from exc

    def _hosts(self, base: str, user: str) -> list[dict[str, Any]]:
        response = self._http("GET", base + "/api/hosts", headers={"X-EpicVM-User": user}, timeout=15)
        try:
            raw = response.read()
        finally:
            try:
                response.close()
            except Exception:
                pass
        if isinstance(raw, bytes):
            text = raw.decode("utf-8")
        else:
            text = str(raw or "")
        records: list[dict[str, Any]] = []
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except (TypeError, ValueError, json.JSONDecodeError) as exc:
                raise ConsoleOrchestrationError("Moonlight returned an invalid host list.", status=502, code="moonlight_host_failed") from exc
            if isinstance(value, dict) and isinstance(value.get("hosts"), list):
                records.extend(item for item in value["hosts"] if isinstance(item, dict))
            elif isinstance(value, dict):
                records.append(value)
            elif isinstance(value, list):
                records.extend(item for item in value if isinstance(item, dict))
        return records

    @staticmethod
    def _coerce_host_id(value: Any) -> int:
        try:
            host_id = int(str(value or "").strip(), 10)
        except (TypeError, ValueError) as exc:
            raise ConsoleOrchestrationError("Moonlight returned an invalid guest host id.", status=502, code="moonlight_host_failed") from exc
        if host_id < 0 or host_id > 0xFFFFFFFF:
            raise ConsoleOrchestrationError("Moonlight returned an invalid guest host id.", status=502, code="moonlight_host_failed")
        return host_id

    def _register_host(self, base: str, user: str, guest_ip: str, sunshine_port: int = 47989) -> int:
        for host in self._hosts(base, user):
            if str(host.get("address") or "") == guest_ip and str(host.get("http_port") or "47989") == str(sunshine_port):
                return self._coerce_host_id(host.get("host_id"))
        body = json.dumps({"address": guest_ip, "http_port": sunshine_port}, separators=(",", ":")).encode("utf-8")
        response = self._http("POST", base + "/api/host", headers={"Content-Type": "application/json", "X-EpicVM-User": user}, body=body, timeout=15)
        try:
            raw = response.read()
            text = raw.decode("utf-8") if isinstance(raw, bytes) else str(raw or "")
            try:
                payload = json.loads(text)
            except (TypeError, ValueError, json.JSONDecodeError):
                payload = json.loads(next((line for line in text.splitlines() if line.strip()), ""))
        except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ConsoleOrchestrationError("Moonlight could not register the guest.", status=502, code="moonlight_host_failed") from exc
        finally:
            try:
                response.close()
            except Exception:
                pass
        host = payload.get("host") if isinstance(payload, dict) else None
        host_id = (host or {}).get("host_id") if isinstance(host, dict) else None
        if host_id in (None, ""):
            raise ConsoleOrchestrationError("Moonlight did not return a guest host id.", status=502, code="moonlight_host_failed")
        return self._coerce_host_id(host_id)

    def _host_details(
        self,
        base: str,
        user: str,
        host_id: int,
        *,
        expected_guest_ip: str | None = None,
    ) -> dict[str, Any]:
        """Verify that Moonlight can perform the first authenticated host query.

        `/api/hosts` only reads Moonlight's local database and can report a host
        as paired even when Sunshine rejects the stored client certificate.  A
        real `/api/host` request is therefore the readiness boundary.
        """
        response = None
        try:
            response = self._http(
                "GET",
                f"{base}/api/host?host_id={int(host_id)}",
                headers={"X-EpicVM-User": user},
                timeout=20,
            )
            raw = response.read()
            text = raw.decode("utf-8") if isinstance(raw, bytes) else str(raw or "")
            try:
                payload = json.loads(text)
            except (TypeError, ValueError, json.JSONDecodeError) as exc:
                payload = json.loads(next((line for line in text.splitlines() if line.strip()), ""))
            host = payload.get("host") if isinstance(payload, dict) else None
            if not isinstance(host, dict) or self._coerce_host_id(host.get("host_id")) != int(host_id):
                raise ConsoleOrchestrationError("Moonlight did not return verified guest host details.", status=502, code="moonlight_host_failed")
            # A newly registered host can answer /api/host successfully before
            # pairing. Treat that response as incomplete rather than allowing
            # an unpaired record to make a stale console look healthy. Older
            # controlled test providers omitted these fields, so missing values
            # remain backwards-compatible during rollout.
            paired = host.get("paired")
            if paired is not None and str(paired).strip().lower() != "paired":
                raise ConsoleOrchestrationError("Moonlight returned an unpaired guest host.", status=502, code="moonlight_host_failed")
            address = str(host.get("address") or "").strip()
            if expected_guest_ip and address and address != str(expected_guest_ip).strip():
                raise ConsoleOrchestrationError("Moonlight returned the wrong guest host.", status=502, code="moonlight_host_failed")
            return host
        except ConsoleOrchestrationError:
            raise
        except urlerror.HTTPError as exc:
            raise ConsoleOrchestrationError("Moonlight could not verify the paired guest.", status=502, code="moonlight_host_failed") from exc
        except (OSError, urlerror.URLError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ConsoleOrchestrationError("Moonlight could not verify the paired guest.", status=502, code="moonlight_host_failed") from exc
        finally:
            if response is not None:
                try:
                    response.close()
                except Exception:
                    pass

    def _sunshine_pair(self, guest_ip: str, username: str, password: str, pin: str, vm_name: str, sunshine_port: int = 47989) -> None:
        if not username or not password:
            raise ConsoleOrchestrationError("Sunshine credentials are required for pairing.", status=400, code="sunshine_credentials_required")
        raw = f"{username}:{password}".encode("utf-8")
        auth = base64.b64encode(raw).decode("ascii")
        validate_vm_name(vm_name)
        body = json.dumps({"pin": pin, "name": MOONLIGHT_PAIR_DEVICE_NAME}, separators=(",", ":")).encode("utf-8")
        deadline = time.monotonic() + 20.0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ConsoleOrchestrationError("Sunshine did not accept the pairing request in time.", status=502, code="sunshine_pair_failed")
            response = None
            try:
                response = self._http(
                    "POST",
                    f"https://{guest_ip}:{sunshine_port + 1}/api/pin",
                    headers={"Authorization": f"Basic {auth}", "Content-Type": "application/json"},
                    body=body,
                    timeout=min(5.0, remaining),
                )
                raw_response = response.read()
                text = raw_response.decode("utf-8") if isinstance(raw_response, bytes) else str(raw_response or "")
                try:
                    payload = json.loads(text)
                except (TypeError, ValueError, json.JSONDecodeError) as exc:
                    raise ConsoleOrchestrationError("Sunshine returned an invalid pairing response.", status=502, code="sunshine_pair_failed") from exc
                status = payload.get("status") if isinstance(payload, dict) else None
                if status is True or str(status).strip().lower() == "true":
                    return
                if status is not False and str(status).strip().lower() != "false":
                    raise ConsoleOrchestrationError("Sunshine did not accept the pairing request.", status=502, code="sunshine_pair_failed")
            except urlerror.HTTPError as exc:
                code = "sunshine_auth_failed" if int(exc.code) in (401, 403) else "sunshine_pair_failed"
                raise ConsoleOrchestrationError("Sunshine rejected the pairing request.", status=409 if code == "sunshine_auth_failed" else 502, code=code) from exc
            except (OSError, urlerror.URLError) as exc:
                raise ConsoleOrchestrationError("Sunshine pairing could not be completed.", status=502, code="sunshine_pair_failed") from exc
            finally:
                if response is not None:
                    try:
                        response.close()
                    except Exception:
                        pass
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ConsoleOrchestrationError("Sunshine did not accept the pairing request in time.", status=502, code="sunshine_pair_failed")
            time.sleep(min(0.25, remaining))

    def verify_staged(
        self,
        name: str,
        *,
        guest_ip: str,
        route_name: str | None = None,
    ) -> dict[str, Any]:
        """Verify an existing console without mutating its bundle.

        The Moonlight container healthcheck only proves that PID 1 is alive.
        This probe verifies the authoritative guest address, both Sunshine
        listeners, and the authenticated ``/api/host`` call. A stale client
        certificate therefore becomes a repair decision instead of a false
        ``consoleReady`` result.
        """
        safe = validate_vm_name(name)
        guest = validate_guest_ip(guest_ip)
        route = validate_vm_name(route_name or safe)
        plan = self._read_plan(safe)
        expected_prefix = f"/vm/{route}/"
        if (
            str(plan.get("guestIp") or "") != guest
            or str(plan.get("routePrefix") or "") != expected_prefix
            or plan.get("paired") is not True
        ):
            raise ConsoleOrchestrationError(
                "The persisted Moonlight bundle does not match the authoritative VM record.",
                status=409,
                code="moonlight_stale_bundle",
            )
        sunshine_port = int(plan.get("sunshinePort") or 47989)
        self._wait_for_sunshine(guest, timeout=30.0, sunshine_port=sunshine_port)
        base = self._container_url(safe, str(plan.get("routePrefix") or expected_prefix))
        user = validate_vm_name(safe)
        # /api/hosts exposes paired state but not always the guest address.
        # Prefer an existing paired record so a stale client certificate is
        # observed and repaired. Registering a fresh host here would create an
        # unpaired record whose /api/host response is a false positive.
        candidates: list[int] = []
        for record in self._hosts(base, user):
            paired = str(record.get("paired") or "").strip().lower() == "paired"
            address = str(record.get("address") or "").strip()
            port = str(record.get("http_port") or "47989").strip()
            if paired or (address == guest and port == str(sunshine_port)):
                try:
                    candidate = self._coerce_host_id(record.get("host_id"))
                except ConsoleOrchestrationError:
                    continue
                if candidate not in candidates:
                    candidates.append(candidate)
        if not candidates:
            raise ConsoleOrchestrationError(
                "The persisted Moonlight bundle has no paired guest host.",
                status=409,
                code="moonlight_stale_bundle",
            )
        last_error: ConsoleOrchestrationError | None = None
        for host_id in candidates:
            try:
                self._host_details(base, user, host_id, expected_guest_ip=guest)
                break
            except ConsoleOrchestrationError as exc:
                last_error = exc
        else:
            if last_error is not None:
                raise last_error
            raise ConsoleOrchestrationError("Moonlight could not verify the paired guest.", status=502, code="moonlight_host_failed")
        return {
            "ok": True,
            "healthy": True,
            "repaired": False,
            "routePrefix": str(plan.get("routePrefix") or expected_prefix),
            "guestTcpVerified": True,
        }

    def pair_staged(self, name: str, *, sunshine_username: str = '', sunshine_password: str = '', pin_submitter: Callable[[str], Any] | None = None) -> dict[str, Any]:
        plan = self._read_plan(name)
        base = self._container_url(name, str(plan.get("routePrefix") or ""))
        user = validate_vm_name(name)
        sunshine_port = int(plan.get("sunshinePort") or 47989)
        host_id = self._register_host(base, user, str(plan["guestIp"]), sunshine_port)
        if not host_id:
            raise ConsoleOrchestrationError("Moonlight did not return a guest host id.", status=502, code="moonlight_host_failed")
        if plan.get("paired") is True:
            self._host_details(base, user, host_id, expected_guest_ip=str(plan.get("guestIp") or ""))
            return {"ok": True, "paired": True, "routePrefix": str(plan["routePrefix"]), "guestTcpVerified": True}
        headers = {"Content-Type": "application/json", "X-EpicVM-User": user}
        body = json.dumps({"host_id": host_id}, separators=(",", ":")).encode("utf-8")
        try:
            response = self._http("POST", base + "/api/pair", headers=headers, body=body, timeout=120)
            try:
                first = self._json_line(response)
                pin = str(first.get("Pin") or "") if isinstance(first, dict) else ""
                if not pin:
                    raise ConsoleOrchestrationError("Moonlight did not provide a pairing PIN.", status=502, code="moonlight_pair_failed")
                if pin_submitter is not None:
                    pin_submitter(pin)
                else:
                    self._sunshine_pair(str(plan["guestIp"]), str(sunshine_username), str(sunshine_password), pin, str(plan["name"]), sunshine_port)
                second = self._json_line(response)
                paired = isinstance(second, dict) and str(second.get("Paired") or "")
                if not paired:
                    raise ConsoleOrchestrationError("Moonlight did not confirm pairing.", status=502, code="moonlight_pair_failed")
            finally:
                try:
                    response.close()
                except Exception:
                    pass
        except ConsoleOrchestrationError:
            raise
        except urlerror.HTTPError as exc:
            raise ConsoleOrchestrationError("Moonlight pairing was rejected.", status=409 if int(exc.code) in (401, 403) else 502, code="moonlight_pair_failed") from exc
        except (OSError, urlerror.URLError) as exc:
            raise ConsoleOrchestrationError("Moonlight pairing could not be completed.", status=502, code="moonlight_pair_failed") from exc
        # Do not persist paired=true until the first authenticated host query
        # succeeds.  This catches stale/invalid client certificates before the
        # provisioning state machine is allowed to report a ready console.
        self._host_details(base, user, host_id, expected_guest_ip=str(plan.get("guestIp") or ""))
        target = self._instance_root(name)
        plan["paired"] = True
        plan["pairedAt"] = int(time.time())
        (target / "plan.json").write_text(json.dumps(plan, separators=(",", ":")), encoding="utf-8")
        os.chmod(target / "plan.json", 0o600)
        sunshine_username = sunshine_password = ""
        return {"ok": True, "paired": True, "routePrefix": str(plan["routePrefix"]), "guestTcpVerified": True}

    def repair_staged(
        self,
        name: str,
        *,
        guest_ip: str,
        route_name: str | None = None,
        sunshine_username: str,
        sunshine_password: str,
    ) -> dict[str, Any]:
        """Rebuild a retained Moonlight bundle without touching VM state.

        A provisioning job can be ``ready`` while its persisted Moonlight
        client certificate is stale or invalid. Repair only replaces the
        console bundle: the VM, claim, guest setup, and management checkpoints
        remain authoritative and are never rewritten here. The old bundle is
        quarantined for rollback/forensics before a fresh pairing is attempted.
        """
        safe = validate_vm_name(name)
        guest = validate_guest_ip(guest_ip)
        route = validate_vm_name(route_name or safe)
        # Build first: this verifies the authoritative guest TCP path before
        # the existing bundle is stopped or moved. A transient guest outage
        # must not destroy the last known-good console bundle.
        plan = self.build_plan(name=safe, guest_ip=guest, route_name=route, allow_existing_owned_route=True)
        quarantine = self.quarantine_staged(safe)
        try:
            self.stage_plan(plan)
            self.start_staged(safe)
            result = self.pair_staged(
                safe,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
            )
            result["repaired"] = True
            result["quarantined"] = bool(quarantine)
            return result
        except Exception:
            try:
                self.stop_staged(safe)
            except Exception:
                pass
            if quarantine is not None:
                replacement = self._instance_root(safe)
                if replacement.exists():
                    # stage_plan created this directory after the old bundle
                    # was moved.  Remove only an EpicVM-owned replacement;
                    # never delete an unrelated directory during rollback.
                    try:
                        replacement_plan = self._read_plan(safe)
                        owned = (
                            replacement_plan.get("owner") == "EpicVM"
                            and replacement_plan.get("backend") == "moonlight"
                            and replacement_plan.get("name") == safe
                        )
                        if owned:
                            shutil.rmtree(replacement)
                    except Exception:
                        pass
                if not replacement.exists():
                    # Never leave the last known-good bundle stranded in the
                    # quarantine directory.  The replacement may have failed
                    # after the new container was created, so restore the old
                    # bundle before re-raising the original, structured error.
                    try:
                        self.restore_quarantined(safe, quarantine, start=True)
                    except Exception:
                        # The old files are still restored even if Docker itself
                        # is temporarily unavailable.  The next verification
                        # request can start the retained bundle safely.
                        pass
            raise

    def restart_session(self, name: str, *, route_name: str | None = None) -> dict[str, Any]:
        """Bounce the staged Moonlight container to rebuild stream state.

        The pinned Moonlight server can answer a session start with
        ``control: the control stream hasn't successfully connected yet`` and
        then never deliver a first video frame; the browser stays black even
        though the container is healthy.  A bounded container restart gives
        the next client a fresh WebRTC endpoint without rebuilding the paired
        bundle or touching VM, guest, or claim state.  This is a stream-start
        recovery action only: readiness still requires the agent's automated
        capture, transport, route, and stream checks.
        """
        safe = validate_vm_name(name)
        route = validate_vm_name(route_name or safe)
        plan = self._read_plan(safe)
        expected_prefix = f"/vm/{route}/"
        if str(plan.get("routePrefix") or "") != expected_prefix or plan.get("paired") is not True:
            raise ConsoleOrchestrationError(
                "The persisted Moonlight bundle does not match the requested route.",
                status=409,
                code="moonlight_stale_bundle",
            )
        self.stop_staged(safe)
        self.start_staged(safe)
        return {
            "ok": True,
            "restarted": True,
            "routePrefix": str(plan.get("routePrefix") or expected_prefix),
        }

    def has_auto_login(self, name: str) -> bool:
        try:
            return bool(self._read_plan(name).get("paired"))
        except ConsoleOrchestrationError:
            return False

    def enable_auto_login(self, *, name: str, username: str, password: str, sunshine_username: str | None = None, sunshine_password: str | None = None) -> None:
        self.pair_staged(name, sunshine_username=str(sunshine_username or username), sunshine_password=str(sunshine_password or password))

    def build_json_auth_data(self, name: str, **_kwargs) -> str:
        # Compatibility hook for older callers.  Moonlight uses the dashboard
        # route and its forwarded user header; it has no Guacamole assertion.
        if not self.has_auto_login(name):
            raise ConsoleOrchestrationError("The Moonlight console is not paired.", status=409, code="console_not_paired")
        return ""

    def stop_staged(self, name: str) -> None:
        target = self._instance_root(name)
        if not target.is_dir() or not (target / "docker-compose.yml").is_file():
            return
        try:
            self.command_runner(["docker", "compose", "-p", self._project_name(name), "down", "--remove-orphans"], cwd=str(target), check=False, capture_output=True, text=True)
        except OSError:
            return

    def quarantine_staged(self, name: str) -> Path | None:
        safe = validate_vm_name(name)
        target = self._instance_root(safe)
        if not target.is_dir():
            return None
        self.stop_staged(safe)
        quarantine = target.parent / "quarantine" / f"{safe}-{int(time.time())}-{secrets.token_hex(4)}"
        quarantine.parent.mkdir(mode=0o700, exist_ok=True)
        target.rename(quarantine)
        return quarantine

    def restore_quarantined(self, name: str, quarantine: Path | str, *, start: bool = True) -> Path:
        """Restore a previously quarantined owned bundle without data loss.

        The path is accepted only from this orchestrator's private quarantine
        directory and must contain the matching EpicVM plan.  Renaming the
        directory back happens before any Docker start attempt, so a transient
        Docker failure cannot strand the bundle or turn a repair failure into
        a missing-console failure.
        """
        safe = validate_vm_name(name)
        root = self.root.resolve()
        quarantine_path = Path(quarantine)
        if not quarantine_path.is_absolute():
            quarantine_path = (self.root / quarantine_path).resolve()
        else:
            quarantine_path = quarantine_path.resolve()
        expected_parent = (root / "quarantine").resolve()
        if quarantine_path.parent != expected_parent:
            raise ConsoleOrchestrationError("The quarantine path is outside the managed store.", status=403, code="ownership_required")
        if not quarantine_path.is_dir() or quarantine_path.is_symlink():
            raise ConsoleOrchestrationError("The quarantined console bundle is unavailable.", status=404, code="console_bundle_missing")
        if not quarantine_path.name.startswith(f"{safe}-"):
            raise ConsoleOrchestrationError("The quarantined console bundle does not match the VM.", status=403, code="ownership_required")
        try:
            plan = json.loads((quarantine_path / "plan.json").read_text(encoding="utf-8"))
        except (OSError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise ConsoleOrchestrationError("The quarantined console metadata is invalid.", status=403, code="ownership_required") from exc
        if plan.get("owner") != "EpicVM" or plan.get("backend") != "moonlight" or plan.get("name") != safe:
            raise ConsoleOrchestrationError("The quarantined console instance is not owned by EpicVM.", status=403, code="ownership_required")
        target = self._instance_root(safe)
        if target.exists():
            raise ConsoleOrchestrationError("The console target already exists.", status=409, code="console_exists")
        quarantine_path.rename(target)
        if start:
            try:
                self.start_staged(safe)
            except Exception:
                # Keep the restored files in place for the next bounded
                # reconciliation attempt; never move them back to quarantine.
                raise
        return target

    def teardown(self, *, name: str, confirm_name: str, device_id: str | None = None, revoke: Callable[[str], Any] | None = None) -> dict[str, Any]:
        safe = validate_vm_name(name)
        if str(confirm_name) != safe:
            raise ConsoleOrchestrationError("Exact VM name confirmation is required.", status=400, code="confirmation_required")
        target = self._instance_root(safe)
        staged = self._read_plan(safe)
        if not target.is_dir() or not (target / "docker-compose.yml").is_file() or staged.get("name") != safe:
            raise ConsoleOrchestrationError("The named console instance is not owned by EpicVM.", status=403, code="ownership_required")
        self.command_runner(["docker", "compose", "-p", self._project_name(safe), "down", "--remove-orphans"], cwd=str(target), check=True, capture_output=True, text=True)
        if device_id and revoke is not None:
            revoke(device_id)
        quarantine = target.parent / "quarantine" / f"{safe}-{int(time.time())}"
        quarantine.parent.mkdir(mode=0o700, exist_ok=True)
        target.rename(quarantine)
        return {"ok": True, "name": safe, "quarantineUntil": int(time.time()) + 7 * 86400}
