#!/usr/bin/env python3
import os, json, subprocess, shlex, base64, socket, threading, time, sqlite3, secrets, platform
import shutil
import re
import math
import ipaddress
import tempfile
from urllib import request as urlrequest, error as urlerror
from urllib.parse import quote as url_quote, unquote as url_unquote, urlparse
from html import escape as html_escape
from functools import wraps
from flask import Flask, jsonify, request, abort, send_from_directory, render_template_string, Response, send_file, redirect
from werkzeug.security import check_password_hash
import optimizer as dash_optimizer
from runtime_stats import get_docker_stats
import hmac, hashlib, time, base64
from branding import PRODUCT_NAME, DASHBOARD_TITLE, MANAGER_NAME, AUTH_REALM
try:
    from .vm_hosts import LocalDockerHost, VmHostRegistry, VmHostUnavailable
    from .remote_hosts import ConfiguredVmHostRegistry, RemoteHostConfigError, redact_host_record, upsert_remote_host_config
    from .remote_agent_client import normalize_remote_vm_record
    from .guacamole_orchestrator import GuacamoleOrchestrator, ConsoleOrchestrationError
    from .moonlight_orchestrator import MoonlightOrchestrator
    from .cloud_pc import (  # bring-your-own Sunshine PC (no agent)
        is_cloudpc as _is_cloudpc,
        load_cloud_pc as _load_cloud_pc,
        load_cloud_pcs as _load_cloud_pcs,
        create_cloudpc as _cp_create,
        pair_cloudpc as _cp_pair,
        start_cloudpc as _cp_start,
        stop_cloudpc as _cp_stop,
        delete_cloud_pc as _cp_delete,
        cloudpc_status as _cp_status,
        cloudpc_proxy_up as _cp_moonlight_proxy_up,
        CloudPcConfigError as _CloudPcConfigError,
    )
except ImportError:
    from vm_hosts import LocalDockerHost, VmHostRegistry, VmHostUnavailable
    from remote_hosts import ConfiguredVmHostRegistry, RemoteHostConfigError, redact_host_record, upsert_remote_host_config
    from remote_agent_client import normalize_remote_vm_record
    from guacamole_orchestrator import GuacamoleOrchestrator, ConsoleOrchestrationError
    from moonlight_orchestrator import MoonlightOrchestrator
    from cloud_pc import (
        is_cloudpc as _is_cloudpc,
        load_cloud_pc as _load_cloud_pc,
        load_cloud_pcs as _load_cloud_pcs,
        create_cloudpc as _cp_create,
        pair_cloudpc as _cp_pair,
        start_cloudpc as _cp_start,
        stop_cloudpc as _cp_stop,
        delete_cloud_pc as _cp_delete,
        cloudpc_status as _cp_status,
        cloudpc_proxy_up as _cp_moonlight_proxy_up,
        CloudPcConfigError as _CloudPcConfigError,
    )
try:
    import psutil
except Exception:
    psutil = None

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 2 * 1024 * 1024

_FAVICON_MAX_BYTES = 512 * 1024
_FAVICON_SIGNATURES = {
    b'\x89PNG\r\n\x1a\n': 'image/png',
    b'\xff\xd8\xff': 'image/jpeg',
    b'GIF87a': 'image/gif',
    b'GIF89a': 'image/gif',
    b'\x00\x00\x01\x00': 'image/x-icon',
}


def _validate_vm_name(name: str) -> str:
    safe = str(name or '').strip().lower()
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', safe):
        raise ValueError('Invalid VM name')
    return safe


def _detect_favicon_mimetype(content: bytes) -> str:
    for signature, mimetype in _FAVICON_SIGNATURES.items():
        if content.startswith(signature):
            return mimetype
    if len(content) >= 12 and content[:4] == b'RIFF' and content[8:12] == b'WEBP':
        return 'image/webp'
    raise ValueError('Favicon must be PNG, JPEG, GIF, WebP, or ICO')


def _read_favicon_upload(upload) -> bytes:
    if upload is None or not getattr(upload, 'filename', ''):
        raise ValueError('No file provided')
    content = upload.read(_FAVICON_MAX_BYTES + 1)
    if not content:
        raise ValueError('Favicon file is empty')
    if len(content) > _FAVICON_MAX_BYTES:
        raise ValueError('Favicon file exceeds 512 KiB')
    _detect_favicon_mimetype(content)
    return content


def _write_favicon_atomically(path: str, content: bytes) -> None:
    target = os.path.abspath(path)
    expected_root = os.path.abspath(os.path.join(_state_dir(), 'dashboard'))
    if os.path.commonpath([target, expected_root]) != expected_root:
        raise ValueError('Favicon path is outside the dashboard state directory')
    os.makedirs(expected_root, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.favicon.', dir=expected_root)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, target)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _validate_favicon_url(value: str) -> str:
    parsed = urlparse(str(value or '').strip())
    hostname = str(parsed.hostname or '').strip().lower()
    if not hostname or parsed.username or parsed.password:
        raise ValueError('Favicon URL is invalid')
    if parsed.scheme == 'http' and hostname not in {'localhost', '127.0.0.1', '::1'}:
        raise ValueError('Favicon URL must use HTTPS')
    if parsed.scheme not in {'http', 'https'}:
        raise ValueError('Favicon URL must use HTTP or HTTPS')
    if parsed.scheme == 'https':
        try:
            addresses = {item[4][0].split('%', 1)[0] for item in socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)}
        except OSError as exc:
            raise ValueError('Favicon URL host could not be resolved') from exc
        if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
            raise ValueError('Favicon URL must resolve to a public address')
    return parsed.geturl()


def _safe_favicon_reference(value: str) -> str:
    favicon = str(value or '').strip()
    if favicon.startswith('/') and not favicon.startswith('//'):
        return favicon
    try:
        return _validate_favicon_url(favicon)
    except ValueError:
        return ''


# --- Admin authentication helpers (must be defined before route decorators) ---
# BLOBEDASH_USER/PASS are the sole credentials for new installs. The legacy
# dashboard password remains read-only migration support for existing hosts.
_LOGIN_ATTEMPTS = {}
_LOGIN_LOCK = threading.Lock()

# Dashboard escalation is an expensive, state-changing AI recovery request.
# Keep the gate in-process so repeated clicks cannot launch concurrent agents.
_HERMES_ESCALATION_COOLDOWN_SECONDS = 300
_HERMES_ESCALATIONS = {}
_HERMES_ESCALATION_LOCK = threading.Lock()

def _claim_hermes_escalation(name: str, now=None):
    now = time.time() if now is None else float(now)
    with _HERMES_ESCALATION_LOCK:
        previous = _HERMES_ESCALATIONS.get(name)
        if previous is not None:
            elapsed = max(0.0, now - previous)
            remaining = int(max(0, _HERMES_ESCALATION_COOLDOWN_SECONDS - elapsed))
            if remaining > 0:
                return {'allowed': False, 'retry_after': remaining}
        _HERMES_ESCALATIONS[name] = now
    return {'allowed': True, 'retry_after': 0}

def _allow_insecure_dashboard() -> bool:
    return os.environ.get('BLOBEVM_ALLOW_INSECURE_DASHBOARD') == '1'

def _admin_credentials():
    user = os.environ.get('BLOBEDASH_USER', '').strip()
    password_hash = os.environ.get('BLOBEDASH_PASS_HASH', '').strip()
    if user and password_hash:
        return user, _account_admin_password(user, password_hash)
    password = os.environ.get('BLOBEDASH_PASS', '')
    if user and password:
        return user, _account_admin_password(user, password)
    legacy = _get_legacy_dashboard_password()
    if legacy:
        return 'admin', _account_admin_password('admin', legacy)
    return None, None

def _extra_admin_credentials():
    # Additive secondary dashboard admin (e.g. a test account) without
    # disturbing the primary BLOBEDASH_USER admin.
    user = os.environ.get('BLOBEDASH_EXTRA_USER', '').strip()
    password_hash = os.environ.get('BLOBEDASH_EXTRA_PASS_HASH', '').strip()
    if user and password_hash:
        return user, _account_admin_password(user, password_hash)
    password = os.environ.get('BLOBEDASH_EXTRA_PASS', '').strip()
    if user and password:
        return user, _account_admin_password(user, password)
    return None, None

def _valid_dashboard_admin(username: str, pw: str) -> bool:
    user, expected = _admin_credentials()
    if user and expected and hmac.compare_digest(username, user) and _admin_password_matches(pw, expected):
        return True
    eu, ep = _extra_admin_credentials()
    if eu and ep and hmac.compare_digest(username, eu) and _admin_password_matches(pw, ep):
        return True
    return False

def _admin_password_matches(candidate: str, expected: str) -> bool:
    if not expected:
        return False
    # Werkzeug hash formats look like "scrypt:32768:8:1$salt$hash" (the method
    # prefix may include parameters before the first '$'). Try hash verification
    # first and fall back to a constant-time plaintext compare if it isn't a hash.
    try:
        if check_password_hash(expected, candidate):
            return True
    except (TypeError, ValueError):
        pass
    return hmac.compare_digest(candidate, expected)

def need_auth():
    """Whether the dashboard is configured for protected access."""
    return not _allow_insecure_dashboard()

def _dashboard_secret() -> str:
    # Never mint or verify a protected session with a public/default secret.
    return os.environ.get('DASH_V2_SECRET', '').strip()


def _provisioning_defaults_path() -> str:
    return os.environ.get(
        'EPICVM_PROVISIONING_CREDENTIALS_FILE',
        '/opt/epicvm/secrets/provisioning-defaults.json',
    ).strip()


def _load_provisioning_defaults() -> dict[str, str]:
    """Load the protected dashboard-side credential bundle without logging it."""
    path = _provisioning_defaults_path()
    if not path:
        return {}
    try:
        mode = os.stat(path).st_mode & 0o777
        if os.name != 'nt' and mode & 0o077:
            return {}
        with open(path, 'r', encoding='utf-8') as handle:
            raw = json.load(handle)
        if not isinstance(raw, dict):
            return {}
        values = {
            'guest_username': str(raw.get('guestUsername') or raw.get('guest_username') or ''),
            'guest_password': str(raw.get('guestPassword') or raw.get('guest_password') or ''),
            'sunshine_username': str(raw.get('sunshineUsername') or raw.get('sunshine_username') or ''),
            'sunshine_password': str(raw.get('sunshinePassword') or raw.get('sunshine_password') or ''),
        }
        if not all(values.values()):
            return {}
        return values
    except (OSError, TypeError, ValueError, UnicodeError):
        return {}


def _default_sunshine_credentials() -> tuple[str, str] | None:
    defaults = _load_provisioning_defaults()
    if not defaults.get('sunshine_username') or not defaults.get('sunshine_password'):
        return None
    return defaults['sunshine_username'], defaults['sunshine_password']


def _default_guest_credentials() -> tuple[str, str] | None:
    defaults = _load_provisioning_defaults()
    if not defaults.get('guest_username') or not defaults.get('guest_password'):
        return None
    return defaults['guest_username'], defaults['guest_password']


def _resolve_sunshine_credentials(username: str, password: str) -> tuple[str, str] | None:
    if username and password:
        return username, password
    return _default_sunshine_credentials()


def _safe_provisioning_job(job: object) -> dict:
    """Return only non-secret provisioning metadata for browser clients."""
    if not isinstance(job, dict):
        return {}
    allowed = (
        'id', 'name', 'profile', 'state', 'errorCode', 'failureStage',
        'failureDetailCode', 'tailnetIp', 'vmId', 'consoleRoutePrefix',
        'completedStages', 'claimConsumed', 'claimUsed', 'updatedAt',
        'createdAt', 'operationId', 'consoleRetryPending', 'consoleRetryOutcome',
        'consoleRepairPending', 'consoleRepairOutcome', 'consoleRepairErrorCode', 'consoleOperationId',
        'autonomousPending', 'autonomousOperationId', 'autonomousStage',
        'autonomousOutcome', 'autonomousErrorCode',
        'cpuCount', 'memoryBytes', 'diskSizeBytes', 'gpuPartitionPercent',
        'gpuDeviceIdentity', 'gamingGpuValidated', 'gamingValidationAt',
        'omarchyGpuValidated', 'omarchyValidationAt', 'guestUsername', 'guestOs',
        'gamingCaptureConfigured', 'gamingCaptureAt',
        'consoleFrameVerified', 'consoleFrameVerifiedAt',
        'keyboardInputVerified', 'keyboardInputVerifiedAt',
        'mouseInputVerified', 'mouseInputVerifiedAt',
        'consoleVisualValidationPending',
    )
    return {key: job[key] for key in allowed if key in job and job[key] is not None}


def _gaming_provisioning_spec(payload: object) -> dict:
    """Return only initialization-time Gaming resource fields for the agent."""
    if not isinstance(payload, dict):
        return {}
    allowed = ('cpuCount', 'memoryGiB', 'memoryBytes', 'diskSizeGiB', 'diskSizeBytes', 'gpuPartitionPercent')
    return {
        key: payload[key]
        for key in allowed
        if key in payload and payload[key] not in (None, '')
    }


def _is_pending_provisioning_job(job: object) -> bool:
    if not isinstance(job, dict):
        return False
    state = str(job.get('state') or '')
    if state in {'queued', 'cloning', 'booting'}:
        return True
    if state == 'unclaimed' and not bool(job.get('claimConsumed')):
        return True
    if not bool(job.get('claimConsumed')):
        return False
    return state not in {'ready', 'failed'} and not state.startswith('setup_failed:')

def _request_is_https() -> bool:
    forwarded = request.headers.get('X-Forwarded-Proto', '').split(',', 1)[0].strip().lower()
    return bool(request.is_secure or forwarded == 'https')

def _same_origin_request() -> bool:
    origin = request.headers.get('Origin')
    if not origin:
        # Basic auth remains supported for existing scripts and non-browser CLI
        # clients. Cookie sessions require a browser Origin on mutations.
        return request.headers.get('Authorization', '').lower().startswith('basic ')
    parsed = urlparse(origin)
    return parsed.scheme in ('http', 'https') and parsed.netloc == request.host

def _csrf_token_for_session(session_token: str | None = None) -> str:
    session_token = session_token if session_token is not None else request.cookies.get('Dashboard-Auth', '')
    secret = _dashboard_secret()
    if not secret or not session_token:
        return ''
    digest = hmac.new(secret.encode('utf-8'), ('csrf:' + session_token).encode('utf-8'), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode('ascii').rstrip('=')

def _csrf_request_valid() -> bool:
    session_token = request.cookies.get('Dashboard-Auth', '')
    # Basic-auth automation has no cookie session to bind a CSRF token to.
    if not session_token:
        return request.headers.get('Authorization', '').lower().startswith('basic ')
    provided = request.headers.get('X-CSRF-Token', '')
    expected = _csrf_token_for_session(session_token)
    return bool(provided and expected and hmac.compare_digest(provided, expected))

def check_auth(header: str) -> bool:
    user_expected, password_expected = _admin_credentials()
    if not user_expected or not password_expected:
        return False
    if not header or not header.lower().startswith('basic '):
        return False
    try:
        raw = base64.b64decode(header.split(None,1)[1]).decode('utf-8')
        user, pw = raw.split(':',1)
        return hmac.compare_digest(user, user_expected) and _admin_password_matches(pw, password_expected)
    except Exception:
        return False

def admin_auth_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if request.method == 'OPTIONS':
            response = Response(status=204)
            if _same_origin_request():
                response.headers['Access-Control-Allow-Origin'] = request.headers.get('Origin', request.host_url.rstrip('/'))
                response.headers['Access-Control-Allow-Credentials'] = 'true'
                response.headers['Access-Control-Allow-Methods'] = 'GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE'
                response.headers['Access-Control-Allow-Headers'] = 'Content-Type, X-Requested-With, X-CSRF-Token'
            return response
        if _allow_insecure_dashboard():
            return fn(*args, **kwargs)
        user, password = _admin_credentials()
        if not user or not password or not _dashboard_secret():
            return jsonify({'ok': False, 'error': 'Dashboard authentication is not configured'}), 503
        basic_ok = check_auth(request.headers.get('Authorization'))
        token_ok = _verify_v2_token(request.cookies.get('Dashboard-Auth', ''))
        if not (basic_ok or token_ok):
            # The official Dashboard V2 uses its own cookie login screen.  A
            # Basic challenge here makes Chromium open a native credential
            # prompt before that UI can render; keep the JSON/HTML 401 while
            # deliberately avoiding the unrelated browser Basic-Auth flow.
            return Response('Auth required', 401)
        if request.method not in ('GET', 'HEAD', 'OPTIONS') and not _same_origin_request():
            return jsonify({'ok': False, 'error': 'Cross-origin request rejected'}), 403
        if request.method not in ('GET', 'HEAD', 'OPTIONS') and not _csrf_request_valid():
            return jsonify({'ok': False, 'error': 'CSRF validation failed'}), 403
        return fn(*args, **kwargs)
    return wrapper

# Compatibility name used by the legacy dashboard routes. New routes use the
# explicit policy name above; there is deliberately no separate v2 policy.
auth_required = admin_auth_required

@app.get('/dashboard/api/v2status')
@auth_required
def api_v2status():
    env = _read_env()
    domain = env.get('BLOBEVM_DOMAIN', '')
    running = False
    url = None
    try:
        r = subprocess.run([
            'docker', 'ps', '-q', '-f', 'name=^blobedash-v2$'
        ], capture_output=True, text=True)
        cid = r.stdout.strip()
        if cid and domain:
            running = True
            url = f'http://{domain}/Dashboard'
        else:
            # If no docker container, allow detecting a local dev server (Vite) for development.
            # Use env var DASHBOARD_DEV_PORT to override default (5173).
            try:
                dev_port = int(env.get('DASHBOARD_DEV_PORT', '5173'))
                # Prefer explicit host if provided, else detect server's outward-facing IP
                host_to_check = env.get('DASHBOARD_DEV_HOST', '')
                if not host_to_check:
                    try:
                        # determine outward-facing IP by creating a UDP socket
                        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        s.connect(('8.8.8.8', 80))
                        host_to_check = s.getsockname()[0]
                        s.close()
                    except Exception:
                        host_to_check = '127.0.0.1'
                # try connecting to host_to_check:dev_port
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s2:
                    s2.settimeout(0.5)
                    res = s2.connect_ex((host_to_check, dev_port))
                    if res == 0 and domain:
                        running = True
                        # The dashboard is being served by Vite on dev_port; report the same public domain path
                        url = f'http://{domain}/Dashboard'
            except Exception:
                pass
    except Exception:
        running = False
        url = None
    return jsonify({'running': running, 'url': url})

APP_ROOT = '/opt/blobe-vm'
MANAGER = os.environ.get('BLOBEVM_MANAGER') or os.path.join(APP_ROOT, 'server', 'blobe-vm-manager')
if not os.path.isfile(MANAGER):
    MANAGER = 'blobe-vm-manager'
HOST_DOCKER_BIN = os.environ.get('HOST_DOCKER_BIN') or '/usr/bin/docker'
CONTAINER_DOCKER_BIN = os.environ.get('CONTAINER_DOCKER_BIN') or '/usr/bin/docker'
DOCKER_VOLUME_BIND = f'{HOST_DOCKER_BIN}:{CONTAINER_DOCKER_BIN}:ro'

# The local provider is the compatibility default.  A host id may be supplied
# by newer callers, while legacy requests that only contain a VM name remain
# local by default.
LOCAL_VM_HOST = LocalDockerHost(manager=MANAGER)
VM_HOST_REGISTRY = ConfiguredVmHostRegistry(LOCAL_VM_HOST)
VM_HOSTS = VM_HOST_REGISTRY
_CONSOLE_ORCHESTRATOR = None
_LEGACY_GUACAMOLE_ORCHESTRATOR = None
_CONSOLE_RETRY_TASKS = {}
_CONSOLE_RETRY_LOCK = threading.Lock()
_CONSOLE_RETRY_TASK_TTL_SECONDS = 900
# ForwardAuth is called concurrently for Moonlight's host discovery requests.
# Coalesce those calls and cache only a successful application-level staged
# verification briefly. This never marks a Gaming job ready or persists
# browser input attestations.
_CONSOLE_AUTH_VERIFY_CACHE = {}
_CONSOLE_AUTH_VERIFY_LOCK = threading.Lock()
_CONSOLE_AUTH_VERIFY_TTL_SECONDS = 20.0
_CONSOLE_AUTH_VERIFY_WAIT_SECONDS = 11.0
_CONSOLE_APP_IDS_CACHE = {}
_CONSOLE_APP_IDS_CACHE_TTL_SECONDS = 900.0


def _safe_console_retry_code(value, default='console_failed'):
    """Normalize a worker result to a non-sensitive allowlisted code.

    The retry worker is deliberately fire-and-forget from the HTTP request,
    so its terminal result must be safe to expose later.  Never retain an
    exception string, request body, or transport response here.
    """
    code = str(value or default).strip().lower()
    if not re.fullmatch(r'[a-z][a-z0-9_]{2,63}', code):
        return default
    return code


def _prune_console_retry_tasks(now=None):
    now = time.time() if now is None else float(now)
    with _CONSOLE_RETRY_LOCK:
        stale = [
            key for key, task in _CONSOLE_RETRY_TASKS.items()
            if isinstance(task, dict)
            and task.get('status') in ('pending_visual', 'ready', 'failed')
            and task.get('status') != 'pending'
            and now - float(task.get('finishedAt') or task.get('startedAt') or now) > _CONSOLE_RETRY_TASK_TTL_SECONDS
        ]
        for key in stale:
            _CONSOLE_RETRY_TASKS.pop(key, None)


def _set_console_retry_result(key, *, status, operation_id, failure_code='', route_prefix=''):
    """Publish only safe terminal metadata for an async console worker.

    Workers persist readiness only through the agent's ``console-complete``
    transition after the trusted automated route/guest-transport gates pass.
    ``pending_visual`` is retained solely for backward-compatible overlays of
    stale records; no current worker produces it.
    """
    finished = time.time()
    normalized_status = status if status in ('pending_visual', 'ready', 'failed') else 'failed'
    with _CONSOLE_RETRY_LOCK:
        current = _CONSOLE_RETRY_TASKS.get(key) or {}
        # Keep the original operation id even if a malformed caller somehow
        # supplies a different one to a worker.
        original_operation = str(current.get('operationId') or operation_id)
        current.update({
            'operationId': original_operation,
            'status': normalized_status,
            'finishedAt': finished,
        })
        if normalized_status in ('pending_visual', 'ready'):
            current['failureCode'] = ''
            current['routeReady'] = True
            if route_prefix:
                current['routePrefix'] = str(route_prefix)
            current['visualValidationRequired'] = normalized_status == 'pending_visual'
        else:
            current['failureCode'] = _safe_console_retry_code(failure_code)
            current['routeReady'] = False
            current['visualValidationRequired'] = False
        _CONSOLE_RETRY_TASKS[key] = current
    return current


def _await_agent_handoff(operation, *args, **kwargs):
    """Retry only an explicit rejection before execution, never uncertain writes."""
    deadline = time.monotonic() + 60
    while True:
        try:
            return operation(*args, **kwargs)
        except VmHostUnavailable as exc:
            if getattr(exc, 'code', '') != 'agent_busy' or time.monotonic() >= deadline:
                raise
            time.sleep(2)


def _start_remote_moonlight_console_retry(*, host, host_id, job_id, name, guest_ip,
                                           route_name,
                                           guest_username, guest_password,
                                           sunshine_username, sunshine_password,
                                           orchestrator, operation_id):
    """Run credential-bearing console setup outside the public request.

    Cloudflare/Traefik must not hold a browser request open while the agent
    performs the bounded management handoff and Sunshine readiness checks.
    Credentials remain request-local/in-memory and are cleared when this
    worker exits; only the non-secret operation id is tracked.
    """
    key = (str(host_id), str(job_id))
    try:
        # Re-read the authoritative job immediately before handling any
        # credential-bearing operation.  A concurrent agent recovery or retry
        # may have completed the console between the public request and this
        # worker starting.  In that case the worker must be idempotent and
        # must not quarantine Moonlight or send credentials to a job that is
        # no longer waiting for them.
        current = host.provisioning_status(job_id)
        current_job = current.get('job') if isinstance(current, dict) else None
        current_state = str(current_job.get('state') or '') if isinstance(current_job, dict) else ''
        if current_state == 'ready':
            _set_console_retry_result(key, status='ready', operation_id=operation_id)
            app.logger.info('EpicVM console retry became idempotent operation=%s status=ready', operation_id)
            return
        if current_state not in ('streaming_setup', 'setup_failed:streaming', 'setup_failed:agent_restart'):
            raise ConsoleOrchestrationError(
                'The console is no longer waiting for credentials.',
                status=409,
                code='console_retry_not_allowed',
            )
        _await_agent_handoff(host.console_credentials,
            job_id,
            guest_username=guest_username,
            guest_password=guest_password,
            sunshine_username=sunshine_username,
            sunshine_password=sunshine_password,
        )
        started = orchestrator.repair_staged(
            name,
            guest_ip=guest_ip,
            route_name=route_name,
            sunshine_username=sunshine_username,
            sunshine_password=sunshine_password,
        )
        if not isinstance(started, dict) or not bool(started.get('ok')) or not bool(started.get('guestTcpVerified')):
            raise ConsoleOrchestrationError(
                'The Moonlight console did not pass automated route and guest transport verification.',
                status=502,
                code='console_verification_failed',
            )
        route_prefix = f'/vm/{route_name}/'
        completed = host.console_complete(
            job_id,
            route_prefix=route_prefix,
            guest_tcp_verified=True,
        )
        completed_job = completed.get('job') if isinstance(completed, dict) else None
        if not isinstance(completed_job, dict) or str(completed_job.get('state') or '') != 'ready':
            raise ConsoleOrchestrationError(
                'The host did not persist automated console readiness.',
                status=502,
                code='console_verification_failed',
            )
        _set_console_retry_result(
            key,
            status='ready',
            operation_id=operation_id,
            route_prefix=route_prefix,
        )
        app.logger.info('EpicVM console retry completed operation=%s status=ready route=%s', operation_id, route_prefix)
    except ConsoleOrchestrationError as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'console_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        try:
            if failure_code not in ('console_retry_not_allowed',):
                host.console_failed(job_id, code=failure_code)
        except Exception:
            pass
        app.logger.warning('EpicVM console retry failed operation=%s code=%s', operation_id, failure_code)
    except VmHostUnavailable as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'console_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        try:
            host.console_failed(job_id, code=failure_code)
        except Exception:
            pass
        app.logger.warning('EpicVM console retry failed operation=%s code=%s', operation_id, failure_code)
    except Exception:
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code='console_failed')
        try:
            host.console_failed(job_id, code='console_failed')
        except Exception:
            pass
        app.logger.warning('EpicVM console retry failed operation=%s code=console_failed', operation_id)
    finally:
        guest_username = guest_password = sunshine_username = sunshine_password = ''


def _start_remote_autonomous_provisioning(*, host, host_id, job_id, name,
                                          claim_token, guest_username,
                                          guest_password, sunshine_username,
                                          sunshine_password, orchestrator,
                                          operation_id):
    """Finish an automatic dashboard provisioning request without browser input."""
    key = (str(host_id), str(job_id))
    try:
        token = str(claim_token or '')
        if not token:
            # New agents acknowledge the queued job before hashing/cloning and
            # first boot. Keep that work outside the browser's HTTP request.
            deadline = time.monotonic() + 1200
            while True:
                current = host.provisioning_status(job_id)
                current_job = current.get('job') or {}
                current_state = str(current_job.get('state') or '')
                if current_state == 'unclaimed':
                    break
                if current_state.startswith('setup_failed:'):
                    raise ConsoleOrchestrationError('The guest could not finish initial setup.', status=422, code=current_job.get('errorCode') or 'autonomous_provisioning_failed')
                if current_state not in {'queued', 'cloning', 'booting'} or time.monotonic() >= deadline:
                    raise ConsoleOrchestrationError('The guest did not reach the claim stage.', status=504, code='guest_bootstrap_not_ready')
                with _CONSOLE_RETRY_LOCK:
                    pending_task = _CONSOLE_RETRY_TASKS.get(key)
                    if pending_task is not None:
                        pending_task['stage'] = current_state
                time.sleep(2)
            reissued = _await_agent_handoff(host.claim_reissue, job_id)
            token = str(reissued.get('claimToken') or '') if isinstance(reissued, dict) else ''
        if not token:
            raise ConsoleOrchestrationError('The host did not return a one-time claim.', status=502, code='claim_token_missing')
        claimed = _await_agent_handoff(host.claim, job_id, guest_username, guest_password, token)
        job = claimed.get('job') if isinstance(claimed, dict) else None
        state = str(job.get('state') or '') if isinstance(job, dict) else ''
        if state != 'streaming_setup':
            raise ConsoleOrchestrationError('The host did not reach the console gate.', status=422, code='console_gate_missing')
        guest_ip = str(job.get('tailnetIp') or '')
        if not guest_ip:
            raise ConsoleOrchestrationError('The host did not return a verified Tailscale address.', status=422, code='tailnet_ip_missing')
        with _CONSOLE_RETRY_LOCK:
            current = _CONSOLE_RETRY_TASKS.get(key) or {}
            current['stage'] = 'console'
            _CONSOLE_RETRY_TASKS[key] = current
        _start_remote_moonlight_console_retry(
            host=host,
            host_id=host_id,
            job_id=job_id,
            name=name,
            guest_ip=guest_ip,
            route_name=_remote_console_route_name(name, host_id),
            guest_username=guest_username,
            guest_password=guest_password,
            sunshine_username=sunshine_username,
            sunshine_password=sunshine_password,
            orchestrator=orchestrator,
            operation_id=operation_id,
        )
    except ConsoleOrchestrationError as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'autonomous_provisioning_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        app.logger.warning('EpicVM autonomous provisioning failed operation=%s code=%s', operation_id, failure_code)
    except VmHostUnavailable as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'autonomous_provisioning_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        app.logger.warning('EpicVM autonomous provisioning failed operation=%s code=%s', operation_id, failure_code)
    except Exception:
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code='autonomous_provisioning_failed')
        app.logger.warning('EpicVM autonomous provisioning failed operation=%s code=autonomous_provisioning_failed', operation_id)
    finally:
        guest_username = guest_password = sunshine_username = sunshine_password = claim_token = ''


def _start_remote_moonlight_console_repair(*, host, host_id, job_id, name, guest_ip,
                                             route_name, guest_username,
                                             guest_password, sunshine_username,
                                             sunshine_password, orchestrator,
                                             operation_id):
    """Repair only a retained Moonlight bundle for a ready/recoverable VM.

    The provisioning job is deliberately read-only here.  This worker exists
    for the case where the VM and its guest checkpoints are healthy but the
    Moonlight client certificate persisted in the console bundle is stale.
    """
    key = (str(host_id), str(job_id))
    try:
        current = host.provisioning_status(job_id)
        current_job = current.get('job') if isinstance(current, dict) else None
        current_state = str(current_job.get('state') or '') if isinstance(current_job, dict) else ''
        if current_state not in ('ready', 'streaming_setup', 'setup_failed:streaming', 'setup_failed:agent_restart', 'setup_failed:legacy_state_uncertain'):
            raise ConsoleOrchestrationError(
                'Only a ready or recoverable remote VM console can be repaired.',
                status=409,
                code='console_repair_not_allowed',
            )
        if not hasattr(host, 'console_credentials'):
            raise ConsoleOrchestrationError(
                'Automatic Sunshine setup is unavailable on this host.',
                status=503,
                code='sunshine_setup_unavailable',
            )
        profile = str(current_job.get('profile') or 'standard').strip().lower() if isinstance(current_job, dict) else 'standard'
        if profile == 'gaming' and not bool(current_job.get('gamingCaptureConfigured')):
            # Existing Gaming jobs predate the capture marker. Configure the
            # retained Sunshine path before repairing the Moonlight bundle;
            # otherwise bundle verification can succeed and the later
            # completion gate quite correctly rejects an unverified capture.
            configured = host.console_credentials(
                job_id,
                guest_username=guest_username,
                guest_password=guest_password,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
                reconcile_only=True,
            )
            configured_job = configured.get('job') if isinstance(configured, dict) else None
            capture_configured = bool(configured.get('gamingCaptureConfigured')) if isinstance(configured, dict) else False
            if isinstance(configured_job, dict):
                capture_configured = capture_configured or bool(configured_job.get('gamingCaptureConfigured'))
                if str(configured_job.get('state') or '') == 'ready':
                    current_state = 'ready'
            if not capture_configured:
                raise ConsoleOrchestrationError(
                    'Gaming Sunshine capture configuration was not verified.',
                    status=503,
                    code='gaming_capture_configuration_required',
                )
        # A normal guest restart invalidates the Moonlight client certificate,
        # but it does not normally invalidate the existing Sunshine account.
        # Repair the bundle first so the common path does not wait on a slow
        # WinRM re-handshake. If pairing reports a guest-auth/configuration
        # failure, reconcile the retained Sunshine account through the
        # stage-limited agent path and retry once. No VM reprovisioning,
        # re-enrollment, or claim mutation is allowed here.
        try:
            started = orchestrator.repair_staged(
                name,
                guest_ip=guest_ip,
                route_name=route_name,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
            )
        except ConsoleOrchestrationError as repair_error:
            if getattr(repair_error, 'code', '') not in {
                'sunshine_auth_failed',
                'sunshine_pair_failed',
                'console_verification_failed',
                'moonlight_host_failed',
            }:
                raise
            host.console_credentials(
                job_id,
                guest_username=guest_username,
                guest_password=guest_password,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
                reconcile_only=True,
            )
            started = orchestrator.repair_staged(
                name,
                guest_ip=guest_ip,
                route_name=route_name,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
            )
        if not isinstance(started, dict) or not bool(started.get('ok')) or not bool(started.get('guestTcpVerified')):
            raise ConsoleOrchestrationError(
                'The repaired Moonlight console did not pass automated route and guest transport verification.',
                status=502,
                code='console_verification_failed',
            )
        route_prefix = f'/vm/{route_name}/'
        completed = host.console_complete(
            job_id,
            route_prefix=route_prefix,
            guest_tcp_verified=True,
        )
        completed_job = completed.get('job') if isinstance(completed, dict) else None
        if not isinstance(completed_job, dict) or str(completed_job.get('state') or '') != 'ready':
            raise ConsoleOrchestrationError(
                'The host did not persist automated console readiness.',
                status=502,
                code='console_verification_failed',
            )
        _set_console_retry_result(
            key,
            status='ready',
            operation_id=operation_id,
            route_prefix=route_prefix,
        )
        app.logger.info('EpicVM console repair completed operation=%s status=ready route=%s', operation_id, route_prefix)
    except ConsoleOrchestrationError as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'console_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        app.logger.warning('EpicVM console repair failed operation=%s code=%s', operation_id, failure_code)
    except VmHostUnavailable as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'console_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        app.logger.warning('EpicVM console repair failed operation=%s code=%s', operation_id, failure_code)
    except Exception:
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code='console_failed')
        app.logger.warning('EpicVM console repair failed operation=%s code=console_failed', operation_id)
    finally:
        guest_username = guest_password = sunshine_username = sunshine_password = ''

def _start_remote_guest_network_recovery(*, host, host_id, job_id, name,
                                          route_name, guest_username,
                                          guest_password, sunshine_username,
                                          sunshine_password, orchestrator,
                                          operation_id):
    """Revalidate a retained guest network, then repair its console bundle.

    This is intentionally separate from Moonlight bundle repair. A VM can be
    Hyper-V-running while its guest Tailscale/WinRM endpoint has disappeared;
    in that case pairing cannot succeed until the retained network checkpoint
    is revalidated. The agent endpoint is stage-limited and never reissues a
    claim or persists the request credentials.
    """
    key = (str(host_id), str(job_id))
    try:
        current = host.provisioning_status(job_id)
        current_job = current.get('job') if isinstance(current, dict) else None
        current_state = str(current_job.get('state') or '') if isinstance(current_job, dict) else ''
        if current_state in ('ready', 'streaming_setup', 'setup_failed:streaming', 'setup_failed:agent_restart', 'setup_failed:legacy_state_uncertain'):
            if not hasattr(host, 'network_recovery'):
                raise ConsoleOrchestrationError(
                    'The remote host lacks the retained-network recovery boundary.',
                    status=503,
                    code='network_recovery_unavailable',
                )
            recovered = host.network_recovery(
                job_id,
                guest_username=guest_username,
                guest_password=guest_password,
                reverify=True,
            )
        else:
            raise ConsoleOrchestrationError(
                'The retained VM is no longer eligible for network recovery.',
                status=409,
                code='network_recovery_not_allowed',
            )
        recovered_job = recovered.get('job') if isinstance(recovered, dict) else None
        recovered_ip = str(recovered_job.get('tailnetIp') or '') if isinstance(recovered_job, dict) else ''
        if not recovered_ip:
            raise ConsoleOrchestrationError(
                'The remote host did not return a verified guest address after network recovery.',
                status=422,
                code='tailnet_ip_missing',
            )
        credential_result = host.console_credentials(
            job_id,
            guest_username=guest_username,
            guest_password=guest_password,
            sunshine_username=sunshine_username,
            sunshine_password=sunshine_password,
            reconcile_only=True,
        )
        credential_job = credential_result.get('job') if isinstance(credential_result, dict) else None
        credential_state = str(credential_job.get('state') or '') if isinstance(credential_job, dict) else ''
        started = orchestrator.repair_staged(
            name,
            guest_ip=recovered_ip,
            route_name=route_name,
            sunshine_username=sunshine_username,
            sunshine_password=sunshine_password,
        )
        if not isinstance(started, dict) or not bool(started.get('ok')) or not bool(started.get('guestTcpVerified')):
            raise ConsoleOrchestrationError(
                'The recovered Moonlight console did not pass automated route and guest transport verification.',
                status=502,
                code='console_verification_failed',
            )
        route_prefix = f'/vm/{route_name}/'
        completed = host.console_complete(
            job_id,
            route_prefix=route_prefix,
            guest_tcp_verified=True,
        )
        completed_job = completed.get('job') if isinstance(completed, dict) else None
        if not isinstance(completed_job, dict) or str(completed_job.get('state') or '') != 'ready':
            raise ConsoleOrchestrationError(
                'The host did not persist automated console readiness.',
                status=502,
                code='console_verification_failed',
            )
        _set_console_retry_result(
            key,
            status='ready',
            operation_id=operation_id,
            route_prefix=route_prefix,
        )
        app.logger.info('EpicVM guest network recovery completed operation=%s status=ready route=%s', operation_id, route_prefix)
    except ConsoleOrchestrationError as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'network_recovery_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        app.logger.warning('EpicVM guest network recovery failed operation=%s code=%s', operation_id, failure_code)
    except VmHostUnavailable as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'network_recovery_failed'))
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code=failure_code)
        app.logger.warning('EpicVM guest network recovery failed operation=%s code=%s', operation_id, failure_code)
    except Exception:
        _set_console_retry_result(key, status='failed', operation_id=operation_id, failure_code='network_recovery_failed')
        app.logger.warning('EpicVM guest network recovery failed operation=%s code=network_recovery_failed', operation_id)
    finally:
        guest_username = guest_password = sunshine_username = sunshine_password = ''

def _remote_console_route_name(name: str, host_id: str) -> str:
    """Return a stable route namespace for a remote host's VM name.

    VM names are scoped by provider, while Traefik paths are global on kvm2.
    Keep the user-facing VM name unchanged but include the trusted remote-host
    id in the route slug so a local VM with the same name cannot capture the
    remote console route.
    """
    safe_name = str(name or '').strip().lower()
    safe_host = re.sub(r'[^a-z0-9._-]+', '-', str(host_id or '').strip().lower()).strip('-')
    if not safe_name or not safe_host or safe_host == 'local':
        return safe_name
    candidate = f'{safe_name}--{safe_host}'
    if len(candidate) <= 63:
        return candidate
    digest = hashlib.sha256(safe_host.encode('utf-8')).hexdigest()[:10]
    keep = max(1, 63 - len(digest) - 2)
    return f'{safe_name[:keep]}--{digest}'


def _env_text(name: str, default: str = '') -> str:
    """Read an environment value while tolerating shell-style quote wrappers."""
    value = str(os.environ.get(name, default) or default).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1].strip()
    return value


def _console_orchestrator():
    global _CONSOLE_ORCHESTRATOR
    if _CONSOLE_ORCHESTRATOR is None:
        backend = _env_text('EPICVM_CONSOLE_BACKEND', 'moonlight').lower()
        common = dict(
            proxy_network=_env_text('EPICVM_TRAEFIK_NETWORK', 'proxy'),
            public_host=_env_text('EPICVM_PUBLIC_HOST', ''),
            tls_resolver=_env_text('EPICVM_TRAEFIK_CERTRESOLVER', ''),
            auth_middleware=_env_text('EPICVM_TRAEFIK_AUTH_MIDDLEWARE', ''),
            router_priority=_env_text('EPICVM_TRAEFIK_ROUTER_PRIORITY', ''),
        )
        if backend in ('moonlight', 'sunshine'):
            _CONSOLE_ORCHESTRATOR = MoonlightOrchestrator(
                root=_env_text('EPICVM_MOONLIGHT_ROOT', '/opt/epicvm/moonlight-instances'),
                **common,
            )
        else:
            _CONSOLE_ORCHESTRATOR = GuacamoleOrchestrator(
                root=_env_text('EPICVM_CONSOLE_ROOT', '/opt/epicvm/instances'),
                credential_secret=_dashboard_secret(),
                **common,
            )
    return _CONSOLE_ORCHESTRATOR


def _moonlight_console(orchestrator=None) -> bool:
    """Return true only for the explicitly selected Moonlight backend."""
    value = orchestrator if orchestrator is not None else _console_orchestrator()
    return str(getattr(value, 'backend', '')).lower() == 'moonlight'


def _console_for_vm(name: str):
    """Use Moonlight for new bundles but preserve an owned legacy Guac VM."""
    primary = _console_orchestrator()
    if not _moonlight_console(primary):
        return primary
    safe = str(name or '').strip().lower()
    if primary.has_auto_login(safe):
        return primary
    global _LEGACY_GUACAMOLE_ORCHESTRATOR
    if _LEGACY_GUACAMOLE_ORCHESTRATOR is None:
        _LEGACY_GUACAMOLE_ORCHESTRATOR = GuacamoleOrchestrator(
            root=os.environ.get('EPICVM_CONSOLE_ROOT', '/opt/epicvm/instances'),
            proxy_network=os.environ.get('EPICVM_TRAEFIK_NETWORK', 'proxy'),
            public_host=os.environ.get('EPICVM_PUBLIC_HOST', ''),
            tls_resolver=os.environ.get('EPICVM_TRAEFIK_CERTRESOLVER', ''),
            auth_middleware=os.environ.get('EPICVM_TRAEFIK_AUTH_MIDDLEWARE', ''),
            router_priority=os.environ.get('EPICVM_TRAEFIK_ROUTER_PRIORITY', ''),
            credential_secret=_dashboard_secret(),
        )
    if _LEGACY_GUACAMOLE_ORCHESTRATOR.has_auto_login(safe):
        return _LEGACY_GUACAMOLE_ORCHESTRATOR
    return primary

def _vm_host(host_id=None):
    VM_HOST_REGISTRY.refresh()
    if host_id is None:
        host_id = 'local'
        try:
            host_id = request.values.get('host_id') or request.values.get('host') or host_id
            if request.is_json:
                payload = request.get_json(silent=True) or {}
                if isinstance(payload, dict):
                    host_id = payload.get('host_id') or payload.get('host') or host_id
        except RuntimeError:
            # Helpers used by background jobs have no request context.
            pass
    return VM_HOST_REGISTRY.get(host_id)


def _console_route_host_id(name: str, forwarded_uri: str = '') -> str:
    """Resolve a Moonlight route slug back to an enrolled remote host.

    The forwarded URI is only used as a lookup key.  Never trust a host id
    supplied by the browser: the slug must match a registered remote provider
    using the same server-side route-name function that created the route.
    """
    parsed = urlparse(str(forwarded_uri or ''))
    parts = [part for part in str(parsed.path or '').split('/') if part]
    if len(parts) < 2 or parts[0].lower() != 'vm':
        return ''
    slug = str(parts[1] or '').strip().lower()
    if not slug:
        return ''
    try:
        VM_HOST_REGISTRY.refresh()
    except Exception:
        pass
    providers = getattr(VM_HOST_REGISTRY, 'providers', {})
    if not isinstance(providers, dict):
        return ''
    safe_name = str(name or '').strip().lower()
    for candidate_id, candidate in providers.items():
        if getattr(candidate, 'kind', 'local') != 'remote':
            continue
        if _remote_console_route_name(safe_name, str(candidate_id)).lower() == slug:
            return str(candidate_id)
    return ''


def _is_moonlight_host_api_request(forwarded_uri: str = '') -> bool:
    """Limit the auth preflight to Moonlight's host discovery endpoints."""
    path = str(urlparse(str(forwarded_uri or '')).path or '').rstrip('/').lower()
    return path.endswith('/api/hosts') or path.endswith('/api/host')


def _remote_console_forward_auth_verify(name: str, host_id: str) -> dict:
    """Coalesce Moonlight ForwardAuth verification for one remote console.

    Moonlight opens multiple protected API requests at once. Re-running staged
    verification for every request creates a race with the client's 12-second
    API timeout. Only successful route/application verification is cached, and
    this cache never marks a Gaming job ready or persists browser input proof.
    """
    key = (str(name or '').strip().lower(), str(host_id or '').strip())
    now = time.monotonic()
    owner = False
    event = None
    with _CONSOLE_AUTH_VERIFY_LOCK:
        stale = []
        for cache_key, cache_entry in _CONSOLE_AUTH_VERIFY_CACHE.items():
            if not isinstance(cache_entry, dict):
                stale.append(cache_key)
                continue
            verified_at = cache_entry.get('verifiedAt')
            if cache_entry.get('state') == 'verified' and verified_at is not None and now - float(verified_at) >= _CONSOLE_AUTH_VERIFY_TTL_SECONDS:
                stale.append(cache_key)
        for stale_key in stale:
            _CONSOLE_AUTH_VERIFY_CACHE.pop(stale_key, None)

        entry = _CONSOLE_AUTH_VERIFY_CACHE.get(key)
        if isinstance(entry, dict) and entry.get('state') == 'verified':
            verified_at = entry.get('verifiedAt')
            if verified_at is not None and now - float(verified_at) < _CONSOLE_AUTH_VERIFY_TTL_SECONDS:
                return dict(entry.get('result') or {})
        if isinstance(entry, dict) and entry.get('state') == 'pending':
            event = entry.get('event')
        else:
            event = threading.Event()
            _CONSOLE_AUTH_VERIFY_CACHE[key] = {'state': 'pending', 'event': event, 'startedAt': now}
            owner = True

    if not owner:
        if not isinstance(event, threading.Event) or not event.wait(_CONSOLE_AUTH_VERIFY_WAIT_SECONDS):
            raise ConsoleOrchestrationError(
                'Remote console verification is still in progress; retry shortly.',
                status=503,
                code='console_reconcile_pending',
            )
        with _CONSOLE_AUTH_VERIFY_LOCK:
            entry = _CONSOLE_AUTH_VERIFY_CACHE.get(key) or {}
            if entry.get('state') == 'verified':
                verified_at = entry.get('verifiedAt')
                if verified_at is not None and time.monotonic() - float(verified_at) < _CONSOLE_AUTH_VERIFY_TTL_SECONDS:
                    return dict(entry.get('result') or {})
            failure_code = _safe_console_retry_code(entry.get('failureCode'), 'console_reconcile_failed')
        raise ConsoleOrchestrationError(
            'Remote console verification failed safely; retry shortly.',
            status=503,
            code=failure_code,
        )

    try:
        result = _reconcile_remote_console(
            name,
            host_id,
            wait=True,
            wait_timeout=150.0,
            allow_pending_visual=True,
        )
        route_ready = bool(isinstance(result, dict) and result.get('routeReady'))
        healthy = bool(isinstance(result, dict) and result.get('healthy'))
        if not isinstance(result, dict) or not result.get('ok') or not (healthy or route_ready):
            raise ConsoleOrchestrationError(
                'Remote console verification did not reach an application-level route.',
                status=503,
                code='console_reconcile_failed',
            )
    except (ConsoleOrchestrationError, VmHostUnavailable) as exc:
        failure_code = _safe_console_retry_code(getattr(exc, 'code', 'console_reconcile_failed'), 'console_reconcile_failed')
        with _CONSOLE_AUTH_VERIFY_LOCK:
            entry = _CONSOLE_AUTH_VERIFY_CACHE.get(key)
            if isinstance(entry, dict) and entry.get('event') is event:
                entry.update({'state': 'failed', 'failureCode': failure_code, 'finishedAt': time.monotonic()})
                event.set()
        raise
    except Exception:
        with _CONSOLE_AUTH_VERIFY_LOCK:
            entry = _CONSOLE_AUTH_VERIFY_CACHE.get(key)
            if isinstance(entry, dict) and entry.get('event') is event:
                entry.update({'state': 'failed', 'failureCode': 'console_reconcile_failed', 'finishedAt': time.monotonic()})
                event.set()
        raise

    with _CONSOLE_AUTH_VERIFY_LOCK:
        entry = _CONSOLE_AUTH_VERIFY_CACHE.get(key)
        if isinstance(entry, dict) and entry.get('event') is event:
            entry.update({'state': 'verified', 'verifiedAt': time.monotonic(), 'result': dict(result)})
            event.set()
    return result


def _remote_console_job(host, name: str) -> dict:
    """Return the newest ready/recoverable job with a verified guest address."""
    if getattr(host, 'kind', 'local') != 'remote' or not hasattr(host, 'provisioning_jobs'):
        raise ConsoleOrchestrationError(
            'Only enrolled remote VM consoles can be reconciled.',
            status=409,
            code='console_repair_not_allowed',
        )
    jobs = host.provisioning_jobs()
    matching = [
        item for item in jobs
        if isinstance(item, dict)
        and str(item.get('name') or '').strip().lower() == str(name).strip().lower()
        and str(item.get('state') or '') in ('ready', 'streaming_setup', 'setup_failed:streaming', 'setup_failed:agent_restart', 'setup_failed:legacy_state_uncertain')
        and (
            str(item.get('state') or '') == 'ready'
            or 'management_handoff' in {
                str(stage) for stage in (
                    item.get('completedStages')
                    if isinstance(item.get('completedStages'), list) else []
                )
            }
        )
    ]
    matching.sort(key=lambda item: str(item.get('updatedAt') or item.get('createdAt') or ''), reverse=True)
    job = matching[0] if matching else None
    if not job:
        raise ConsoleOrchestrationError(
            'No ready or recoverable provisioning record exists for this remote VM.',
            status=409,
            code='console_repair_not_allowed',
        )
    job_id = str(job.get('id') or '').strip()
    guest_ip = str(job.get('tailnetIp') or '').strip()
    if not job_id or not guest_ip:
        raise ConsoleOrchestrationError(
            'The ready VM has no verified guest address for console reconciliation.',
            status=409,
            code='console_repair_not_allowed',
        )
    return {'job': job, 'job_id': job_id, 'guest_ip': guest_ip}


def _queue_remote_console_repair(*, host, host_id: str, job_id: str, name: str,
                                 guest_ip: str, route_name: str,
                                 orchestrator) -> dict:
    """Queue one idempotent repair for a stale remote Moonlight bundle."""
    resolved_sunshine = _default_sunshine_credentials()
    if not resolved_sunshine:
        raise ConsoleOrchestrationError(
            'The protected Sunshine default is not configured on this dashboard.',
            status=503,
            code='sunshine_credentials_unavailable',
        )
    resolved_guest = _default_guest_credentials()
    if not resolved_guest:
        raise ConsoleOrchestrationError(
            'The protected guest default is not configured on this dashboard.',
            status=503,
            code='guest_credentials_unavailable',
        )
    sunshine_username, sunshine_password = resolved_sunshine
    guest_username, guest_password = resolved_guest
    task_key = (str(host_id), str(job_id))
    _prune_console_retry_tasks()
    worker = None
    with _CONSOLE_RETRY_LOCK:
        pending = _CONSOLE_RETRY_TASKS.get(task_key)
        if isinstance(pending, dict) and str(pending.get('status') or 'pending') == 'pending':
            operation_id = str(pending.get('operationId') or '')
        elif isinstance(pending, dict) and str(pending.get('status') or '') == 'ready':
            return {
                'ok': True,
                'healthy': True,
                'pending': False,
                'repaired': True,
                'host_id': str(host_id),
                'name': str(name),
                'operationId': str(pending.get('operationId') or ''),
                'jobId': str(job_id),
                'routePrefix': f'/vm/{route_name}/',
            }
        else:
            operation_id = secrets.token_hex(16)
            _CONSOLE_RETRY_TASKS[task_key] = {
                'operationId': operation_id,
                'startedAt': time.time(),
                'status': 'pending',
                'failureCode': '',
                'routeReady': False,
                'kind': 'repair',
            }
            worker = threading.Thread(
                target=_start_remote_moonlight_console_repair,
                kwargs={
                    'host': host,
                    'host_id': str(host_id),
                    'job_id': str(job_id),
                    'name': str(name),
                    'guest_ip': str(guest_ip),
                    'route_name': str(route_name),
                    'guest_username': guest_username,
                    'guest_password': guest_password,
                    'sunshine_username': sunshine_username,
                    'sunshine_password': sunshine_password,
                    'orchestrator': orchestrator,
                    'operation_id': operation_id,
                },
                name=f'epicvm-console-reconcile-{operation_id[:8]}',
                daemon=True,
            )
    if worker is not None:
        worker.start()
    return {
        'ok': True,
        'healthy': False,
        'pending': True,
        'repaired': False,
        'host_id': str(host_id),
        'name': str(name),
        'operationId': operation_id,
        'jobId': str(job_id),
        'routePrefix': f'/vm/{route_name}/',
    }


def _queue_remote_guest_network_recovery(*, host, host_id: str, job_id: str,
                                          name: str, route_name: str,
                                          orchestrator) -> dict:
    """Queue one retained-guest network revalidation for a stale VM."""
    resolved_sunshine = _default_sunshine_credentials()
    if not resolved_sunshine:
        raise ConsoleOrchestrationError(
            'The protected Sunshine default is not configured on this dashboard.',
            status=503,
            code='sunshine_credentials_unavailable',
        )
    resolved_guest = _default_guest_credentials()
    if not resolved_guest:
        raise ConsoleOrchestrationError(
            'The protected guest default is not configured on this dashboard.',
            status=503,
            code='guest_credentials_unavailable',
        )
    sunshine_username, sunshine_password = resolved_sunshine
    guest_username, guest_password = resolved_guest
    task_key = (str(host_id), str(job_id))
    _prune_console_retry_tasks()
    worker = None
    with _CONSOLE_RETRY_LOCK:
        pending = _CONSOLE_RETRY_TASKS.get(task_key)
        if isinstance(pending, dict) and str(pending.get('status') or 'pending') == 'pending':
            operation_id = str(pending.get('operationId') or '')
            return {
                'ok': True, 'healthy': False, 'pending': True, 'repaired': False,
                'host_id': str(host_id), 'name': str(name),
                'operationId': operation_id, 'jobId': str(job_id),
                'routePrefix': f'/vm/{route_name}/',
                'failureCode': 'network_recovery_pending',
            }
        if isinstance(pending, dict) and str(pending.get('status') or '') == 'ready':
            return {
                'ok': True, 'healthy': True, 'pending': False, 'repaired': True,
                'host_id': str(host_id), 'name': str(name),
                'operationId': str(pending.get('operationId') or ''),
                'jobId': str(job_id), 'routePrefix': f'/vm/{route_name}/',
            }
        operation_id = secrets.token_hex(16)
        _CONSOLE_RETRY_TASKS[task_key] = {
            'operationId': operation_id, 'startedAt': time.time(),
            'status': 'pending', 'failureCode': '', 'routeReady': False,
            'kind': 'network_recovery',
        }
        worker = threading.Thread(
            target=_start_remote_guest_network_recovery,
            kwargs={
                'host': host, 'host_id': str(host_id), 'job_id': str(job_id),
                'name': str(name), 'route_name': str(route_name),
                'guest_username': guest_username, 'guest_password': guest_password,
                'sunshine_username': sunshine_username, 'sunshine_password': sunshine_password,
                'orchestrator': orchestrator, 'operation_id': operation_id,
            },
            name=f'epicvm-network-recovery-{operation_id[:8]}', daemon=True,
        )
    if worker is not None:
        worker.start()
    return {
        'ok': True, 'healthy': False, 'pending': True, 'repaired': False,
        'host_id': str(host_id), 'name': str(name),
        'operationId': operation_id, 'jobId': str(job_id),
        'routePrefix': f'/vm/{route_name}/',
        'failureCode': 'network_recovery_pending',
    }


def _reconcile_remote_console(name: str, host_id: str, *, wait: bool = False,
                              wait_timeout: float = 150.0,
                              allow_pending_visual: bool = False) -> dict:
    """Verify a remote Moonlight host, repairing stale client state once.

    ``wait=True`` is used by the forward-auth boundary so Moonlight never sees
    the stale certificate's 500 response.  The wait is bounded and returns a
    retryable error instead of hanging a proxy worker indefinitely.

    ``allow_pending_visual`` is restricted to the forward-auth boundary. A
    Gaming job whose agent-side capture marker is still absent may still have
    a valid, application-level Moonlight host after a bounded repair. Let the
    browser reach that host for automated video diagnostics, but keep the
    result explicitly pending and never persist ``ready`` from this path;
    readiness is decided only by the agent's trusted gates.
    """
    orchestrator = _console_orchestrator()
    if not _moonlight_console(orchestrator):
        raise ConsoleOrchestrationError(
            'Moonlight console reconciliation is unavailable on this host.',
            status=409,
            code='console_repair_not_allowed',
        )
    host = _vm_host(host_id)
    details = _remote_console_job(host, name)
    job_id = details['job_id']
    guest_ip = details['guest_ip']
    safe_name = str(details['job'].get('name') or name).strip().lower()
    route_name = _remote_console_route_name(safe_name, host_id)
    queued = None
    job_profile = str(details['job'].get('profile') or 'standard').strip().lower()
    needs_gaming_capture = job_profile == 'gaming' and not bool(details['job'].get('gamingCaptureConfigured'))
    if needs_gaming_capture:
        if allow_pending_visual:
            try:
                verified = orchestrator.verify_staged(
                    safe_name,
                    guest_ip=guest_ip,
                    route_name=route_name,
                )
                return {
                    'ok': True,
                    'healthy': False,
                    'pending': True,
                    'repaired': False,
                    'routeReady': True,
                    'visualValidationRequired': True,
                    'gamingCaptureConfigured': False,
                    'host_id': str(host_id),
                    'name': safe_name,
                    **verified,
                }
            except ConsoleOrchestrationError:
                # A stale/invalid pairing still uses the normal bounded repair
                # path below.  Do not weaken the fail-closed behavior when the
                # application-level host check itself fails.
                pass
        # Hyper-V can show the guest framebuffer while Sunshine still has no
        # usable Gaming capture target. Never trust an already-paired
        # Moonlight bundle in that state: force the retained, stage-limited
        # repair path to configure and verify Sunshine capture first.
        task_key = (str(host_id), str(job_id))
        with _CONSOLE_RETRY_LOCK:
            existing_task = _CONSOLE_RETRY_TASKS.get(task_key)
            if isinstance(existing_task, dict) and str(existing_task.get('status') or '') == 'ready':
                # A terminal repair result without the persisted capture
                # marker is stale/incomplete. Remove only that terminal
                # metadata so the next request can perform a real repair.
                _CONSOLE_RETRY_TASKS.pop(task_key, None)
        queued = _queue_remote_console_repair(
            host=host,
            host_id=str(host_id),
            job_id=job_id,
            name=safe_name,
            guest_ip=guest_ip,
            route_name=route_name,
            orchestrator=orchestrator,
        )
    else:
        try:
            verified = orchestrator.verify_staged(safe_name, guest_ip=guest_ip, route_name=route_name)
            return {
                'ok': True,
                'healthy': True,
                'pending': False,
                'repaired': False,
                'host_id': str(host_id),
                'name': safe_name,
                **verified,
            }
        except ConsoleOrchestrationError as exc:
            if getattr(exc, 'code', '') == 'sunshine_tcp_unavailable':
                queued = _queue_remote_guest_network_recovery(
                    host=host,
                    host_id=str(host_id),
                    job_id=job_id,
                    name=safe_name,
                    route_name=route_name,
                    orchestrator=orchestrator,
                )
            else:
                queued = _queue_remote_console_repair(
                    host=host,
                    host_id=str(host_id),
                    job_id=job_id,
                    name=safe_name,
                    guest_ip=guest_ip,
                    route_name=route_name,
                    orchestrator=orchestrator,
                )
    if not wait or not queued.get('pending'):
        return queued
    deadline = time.monotonic() + max(1.0, float(wait_timeout))
    task_key = (str(host_id), str(job_id))
    while time.monotonic() < deadline:
        with _CONSOLE_RETRY_LOCK:
            task = dict(_CONSOLE_RETRY_TASKS.get(task_key) or {})
        status = str(task.get('status') or 'pending')
        if status == 'ready':
            return {
                **queued,
                'healthy': True,
                'pending': False,
                'repaired': True,
                'routeReady': True,
            }
        if status == 'failed':
            code = _safe_console_retry_code(task.get('failureCode'), 'console_failed')
            raise ConsoleOrchestrationError(
                'Remote console repair failed safely; retry shortly.',
                status=503,
                code=code,
            )
        time.sleep(0.5)
    raise ConsoleOrchestrationError(
        'Remote console repair is still in progress; retry shortly.',
        status=503,
        code='console_repair_pending',
    )


def _vm_host_error_response(exc):
    """Normalize provider errors without turning remote 404/409 into 500s."""
    status = int(getattr(exc, 'status', 503) or 503)
    status = status if 400 <= status <= 599 else 503
    code = str(getattr(exc, 'code', 'host_unavailable') or 'host_unavailable')
    messages = {
        'invalid_request': 'The remote VM request is invalid.',
        'authentication_failed': 'The remote VM host rejected authentication.',
        'forbidden': 'The remote VM operation is not permitted.',
        'not_found': 'The requested remote VM resource was not found.',
        'conflict': 'The remote VM request conflicts with existing state.',
        'gaming_capacity': 'Another Gaming VM is currently being provisioned. Wait for it to finish before creating another.',
        'claim_failed': 'The one-time guest claim was rejected.',
        'invalid_credential_input': 'The credential input is empty or does not meet the request policy.',
        'claim_in_progress': 'Another request already owns this claim.',
        'claim_atomic_commit_failed': 'The claim could not be committed safely; no guest work was started.',
        'guest_configuration_unavailable': 'The secure guest configuration channel is unavailable; no claim was consumed.',
        'claim_reissue_not_allowed': 'The pending claim is no longer eligible for reissue.',
        'claim_state_invalid': 'The pending claim state is invalid.',
        'claim_reissue_failed': 'The pending claim could not be reissued safely.',
        'claim_expired': 'The pending claim has expired.',
        'provisioning_defaults_unavailable': 'The protected automatic provisioning defaults are not configured on this dashboard.',
        'sunshine_credentials_unavailable': 'The protected Sunshine default is not configured on this dashboard.',
        'claim_token_missing': 'The host did not return a one-time guest claim.',
        'console_gate_missing': 'The host did not reach the console setup gate.',
        'tailnet_ip_missing': 'The host did not return a verified Tailscale address.',
        'autonomous_provisioning_failed': 'Automatic provisioning stopped safely; the VM was retained for diagnosis.',
        'bootstrap_credential_unavailable': 'The machine bootstrap channel is unavailable.',
        'bootstrap_readiness_unavailable': 'The host lacks the secure guest-readiness check.',
        'guest_bootstrap_not_ready': 'The cloned guest did not become ready for secure setup.',
        'powershell_direct_failed': 'PowerShell Direct could not open the cloned guest.',
        'direct_service_disabled': 'The Hyper-V PowerShell Direct service is disabled.',
        'direct_service_not_ready': 'The Hyper-V PowerShell Direct service was not ready; no credential conclusion was made.',
        'direct_not_supported': 'PowerShell Direct is not available on this host.',
        'direct_open_timeout': 'PowerShell Direct did not open before the bounded timeout.',
        'direct_transport_error': 'The PowerShell Direct transport failed; no credential conclusion was made.',
        'guest_credential_rejected': 'The guest channel explicitly rejected the supplied credential.',
        'rdp_verification_failed': 'Guest RDP/NLA/firewall verification failed.',
        'guest_configuration_failed': 'Guest configuration failed at the secure setup gate.',
        'guest_account_failed': 'Guest-account setup failed after the claim was consumed.',
        'guest_account_readiness_failed': 'The desired guest account did not pass readiness verification.',
        'bootstrap_cleanup_failed': 'Guest bootstrap cleanup did not verify.',
        'bootstrap_cleanup_transport_failed': 'The guest bootstrap cleanup channel failed.',
        'tailscale_enrollment_failed': 'Tailscale guest enrollment failed after guest setup.',
        'management_handoff_failed': 'The private management handoff did not verify after Tailscale enrollment.',
        'management_transport_failed': 'The private guest management channel failed safely; the VM was retained for diagnosis.',
        'management_transport_unavailable': 'The private guest management channel is unavailable; the VM was retained for diagnosis.',
        'omarchy_not_validated': 'Omarchy Linux remains experimental until the pinned image, AMD GPU-P path, and accelerated guest pilot are verified.',
        'omarchy_provisioning_unavailable': 'Omarchy Linux provisioning is unavailable on this host.',
        'omarchy_template_invalid': 'The pinned Omarchy Linux template manifest failed validation.',
        'omarchy_bootstrap_not_ready': 'The Omarchy Linux guest did not become reachable over Tailscale SSH.',
        'omarchy_guest_configuration_unavailable': 'The Omarchy Linux guest configuration transport is unavailable.',
        'omarchy_gpu_validation_failed': 'Omarchy accelerated rendering did not pass the AMD GPU-P guest validation gate.',
        'omarchy_guest_validation_unavailable': 'The Omarchy AMD GPU and renderer validation channel is unavailable.',
        'omarchy_encoder_unavailable': 'Sunshine did not report a working hardware encoder in Omarchy Linux.',
        'omarchy_sunshine_configuration_failed': 'Sunshine hardware encoding could not be configured in Omarchy Linux.',
        'omarchy_bootstrap_cleanup_failed': 'Omarchy Linux bootstrap cleanup did not verify; readiness was withheld.',
        'streaming_setup_failed': 'Moonlight/Sunshine setup failed after guest and network setup.',
        'sunshine_setup_failed': 'Automatic Sunshine setup failed after guest and network setup.',
        'sunshine_setup_unavailable': 'Automatic Sunshine setup is unavailable on this host.',
        'sunshine_invalid_input': 'The Sunshine credential input was rejected before guest setup.',
        'sunshine_service_missing': 'The retained guest does not have the pinned Sunshine service.',
        'sunshine_executable_missing': 'The pinned Sunshine executable could not be verified in the guest.',
        'sunshine_version_mismatch': 'The guest Sunshine version does not match the pinned release.',
        'sunshine_state_path_failed': 'The Sunshine state path could not be prepared safely.',
        'sunshine_state_write_failed': 'The Sunshine credential state could not be written safely.',
        'sunshine_state_acl_failed': 'The Sunshine credential state permissions could not be verified.',
        'sunshine_firewall_failed': 'The narrow Sunshine firewall scope could not be applied.',
        'sunshine_service_restart_failed': 'The Sunshine service could not be restarted safely.',
        'sunshine_listener_failed': 'Sunshine did not pass its service/listener verification.',
        'sunshine_verification_failed': 'Sunshine configuration did not pass verification.',
        'console_retry_not_allowed': 'Only a retained failed console step may be retried.',
        'console_credentials_not_allowed': 'This provisioning job is not waiting for console credentials.',
        'console_verification_failed': 'The console route did not pass its final verification.',
        'guest_tcp_unverified': 'The server could not verify TCP reachability to the guest.',
        'legacy_state_uncertain': 'The persisted provisioning checkpoints are inconsistent; the VM was retained for diagnosis.',
        'host_unavailable': 'The remote VM host is unavailable.',
        'invalid_name': 'VM names must start with a letter or number and use only lowercase letters, numbers, dots, underscores, or hyphens.',
        'conflict': 'A VM with that name already exists.',
    }
    response = jsonify({'ok': False, 'error': messages.get(code, 'The remote VM request failed.'), 'code': code})
    response.headers['Cache-Control'] = 'no-store'
    return response, status


def _ensure_remote_vm_exists(host, name):
    """Verify a selected remote host actually owns the VM being mutated.

    A browser may select a host, but it is not authoritative for VM ownership.
    When duplicate names are visible across remote hosts, fail closed instead of
    allowing a destructive request to mutate the wrong machine.
    """
    if getattr(host, 'kind', 'local') != 'remote':
        return
    selected_id = str(getattr(host, 'host_id', '') or '')
    selected_inventory = host.list_vms()
    selected_has_vm = any(str(item.get('name', '')) == str(name) for item in selected_inventory)
    registry = VM_HOST_REGISTRY
    providers = getattr(registry, 'providers', {})
    owners = []
    provider_items = providers.items() if isinstance(providers, dict) else []
    for candidate_id, candidate in provider_items:
        candidate_id = str(candidate_id)
        if candidate_id in {'local', selected_id} or getattr(candidate, 'kind', 'remote') != 'remote':
            continue
        inventories = []
        cached_inventory = getattr(registry, 'cached_inventory', None)
        if callable(cached_inventory):
            try:
                inventories.append(cached_inventory(candidate_id))
            except Exception:
                pass
        # Do not fan out live inventory calls to every other enrolled host
        # while servicing an action for the selected host. A dead host used to
        # hold stop/start/restart open until the reverse proxy timed out. The
        # selected host remains authoritative; other hosts are checked only
        # through the redacted cache populated by normal inventory refreshes.
        if any(str(item.get('name', '')) == str(name) for inventory in inventories for item in inventory):
            owners.append(candidate_id)
    if owners:
        owner_list = ', '.join(sorted(set(owners + ([selected_id] if selected_has_vm else []))))
        raise VmHostUnavailable(
            f"VM name is ambiguous across remote hosts: {owner_list}",
            status=409,
            code='ambiguous_vm_owner',
        )
    if not selected_has_vm:
        raise VmHostUnavailable(
            f"VM is not present on host {selected_id or 'remote'}",
            status=404,
            code='not_found',
        )

TEMPLATE = r"""
<!doctype html><html><head><title>{{ title }}</title>
{% if favicon_url %}<link rel="icon" href="{{ favicon_url }}" />{% endif %}
<style>
:root{
  --bg:#0b0a10; --panel:#100e18; --panel-2:#0e0d16; --line:#26222e; --line-soft:#1b1822;
  --text:#f4ece2; --muted:#9aa3b2; --orange:#ff7a1a; --orange-2:#ffa63d; --cyan:#02bdf3;
  --green:#36d399; --red:#ff7a8a; --amber:#ffd23f; --ink:#0b0a10;
  --shadow:0 18px 50px rgba(0,0,0,.45);
}
*{box-sizing:border-box}
@keyframes dashIn{from{opacity:0;transform:translateY(-10px)}to{opacity:1;transform:none}}
@keyframes dashRowIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
@keyframes dashPop{from{opacity:0;transform:scale(.96)}to{opacity:1;transform:none}}
@keyframes dotPulse{0%,100%{box-shadow:0 0 0 0 rgba(54,211,153,.0)}50%{box-shadow:0 0 0 5px rgba(54,211,153,.18)}}
@keyframes titleGlow{0%,100%{text-shadow:0 0 0 rgba(255,122,26,0)}50%{text-shadow:0 0 22px rgba(255,122,26,.35)}}
body{
  font-family:Inter,system-ui,Arial,sans-serif;margin:0;color:var(--text);
  background:
    radial-gradient(900px 500px at 12% -8%, rgba(255,122,26,.16), transparent 60%),
    radial-gradient(800px 500px at 100% 0%, rgba(2,189,243,.12), transparent 55%),
    linear-gradient(180deg,#0b0a10 0%,#08070d 100%);
  background-attachment:fixed;min-height:100vh;
  max-width:1200px;margin:0 auto;padding:2rem 1.5rem 3rem;line-height:1.5;
  animation:dashIn .5s ease both;
}
h1#dash-title{
  margin:0 0 1.25rem;font-size:clamp(28px,4vw,40px);letter-spacing:-.02em;font-weight:800;
  display:inline-block;padding-bottom:.4rem;border-bottom:3px solid var(--orange);
  border-radius:2px;animation:titleGlow 4s ease-in-out infinite;
}
#errbox{display:none;background:#2a0d12;color:#ffd7dd;padding:.6rem .85rem;border-radius:10px;margin:.5rem 0;border:1px solid #5c1a23}
#v2status{margin:.5rem 0 1.1rem;padding:.7rem .9rem;border:1px solid var(--line);border-top:2px solid var(--cyan);border-radius:12px;background:var(--panel);color:#cfe8ff !important}
.panel,#v2status{box-shadow:var(--shadow)}
.badge{background:linear-gradient(180deg,var(--orange),var(--orange-2));color:var(--ink);padding:.2rem .5rem;border-radius:999px;font-size:.62rem;font-weight:800;text-transform:uppercase;margin-left:.3rem;letter-spacing:.04em;vertical-align:middle}
.muted{opacity:.7;color:var(--muted)}
table{border-collapse:separate;border-spacing:0;width:100%;margin:1rem 0;background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden;box-shadow:var(--shadow);animation:dashPop .5s ease both}
thead th{text-align:left;font-size:.72rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);background:#15131f;padding:.85rem 1rem;border-bottom:1px solid var(--line)}
tbody tr{transition:background .18s ease}
tbody tr:nth-child(even){background:rgba(255,255,255,.02)}
tbody tr:hover{background:rgba(255,122,26,.08)}
tbody td{padding:.8rem 1rem;border-bottom:1px solid var(--line-soft);vertical-align:middle}
tbody tr:last-child td{border-bottom:none}
tbody tr{animation:dashRowIn .45s ease both}
tbody tr:nth-child(1){animation-delay:.02s}tbody tr:nth-child(2){animation-delay:.06s}tbody tr:nth-child(3){animation-delay:.10s}tbody tr:nth-child(4){animation-delay:.14s}tbody tr:nth-child(5){animation-delay:.18s}tbody tr:nth-child(n+6){animation-delay:.22s}
a,button{
  font:inherit;font-weight:600;background:linear-gradient(180deg,var(--orange),var(--orange-2));color:var(--ink);
  border:none;padding:.45rem .9rem;border-radius:9px;text-decoration:none;cursor:pointer;
  transition:transform .14s ease, box-shadow .14s ease, filter .14s ease;box-shadow:0 6px 16px rgba(255,122,26,.22)
}
a:hover,button:hover{transform:translateY(-2px);filter:brightness(1.05);box-shadow:0 10px 22px rgba(255,122,26,.35)}
a:active,button:active{transform:translateY(0)}
.btn-red{background:linear-gradient(180deg,#ff6a7d,var(--red));box-shadow:0 6px 16px rgba(255,122,138,.22)}
.btn-red:hover{box-shadow:0 10px 22px rgba(255,122,138,.35)}
.btn-gray{background:linear-gradient(180deg,#3a3a48,#2a2a36);color:var(--text);box-shadow:0 6px 16px rgba(0,0,0,.3)}
.btn-gray:hover{box-shadow:0 10px 22px rgba(0,0,0,.45)}
input,select,textarea{
  font:inherit;color:var(--text);background:#0c0b12;border:1px solid var(--line);border-radius:9px;
  padding:.5rem .7rem;margin:.2rem .2rem .2rem 0;transition:border-color .15s ease, box-shadow .15s ease
}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--orange);box-shadow:0 0 0 3px rgba(255,122,26,.22)}
input::placeholder{color:#6b7280}
form{display:inline}
.dot{display:inline-block;width:11px;height:11px;border-radius:50%;margin-right:7px;vertical-align:middle}
.green{background:var(--green);animation:dotPulse 2.4s ease-in-out infinite}
.red{background:var(--red);box-shadow:0 0 0 0 rgba(255,122,138,0)}
.gray{background:#6b7280}
.amber{background:var(--amber);box-shadow:0 0 0 0 rgba(255,210,63,0)}
div[style*="background:#07121a"],div[style*="background:#071229"]{border-color:var(--line) !important;background:var(--panel) !important;border-radius:12px !important;box-shadow:var(--shadow) !important}
@media (max-width:640px){body{padding:1rem .75rem 2rem}table{display:block;overflow-x:auto;white-space:nowrap}}
@media (prefers-reduced-motion:reduce){*{animation:none !important;transition:none !important}}
</style>

</head><body>
<h1 id="dash-title">{{ title }}</h1>
<div id=errbox style="display:none;background:#7f1d1d;color:#fff;padding:.5rem .75rem;border-radius:4px;margin:.5rem 0"></div>
<div id=v2status style="margin:.5rem 0;padding:.5rem;border:1px dashed #233;background:#071229;border-radius:6px;color:#cfe8ff">
New dashboard status: <span id="v2state">Checking…</span>
<span id="v2link"></span>
</div>
<!-- v2 dashboard status script moved to end of body -->
</body>
<script>
async function pollV2Status() {
    try {
        const res = await fetch('/dashboard/api/v2status');
        const data = await res.json();
        const el = document.getElementById('v2state');
        const linkEl = document.getElementById('v2link');
        if (data.running) {
            el.textContent = 'Running';
            if (data.url) {
                linkEl.innerHTML = `<br><a href="${data.url}" target="_blank" style="color:#4fd1c5;font-weight:bold">Open Dashboard V2</a>`;
            } else {
                linkEl.innerHTML = '';
            }
        } else {
            el.textContent = 'Stopped';
            linkEl.innerHTML = '';
        }
    } catch (e) {
        const el = document.getElementById('v2state');
        if (el) el.textContent = 'Error';
    }
}
setInterval(pollV2Status, 3000);
window.addEventListener('DOMContentLoaded', pollV2Status);
</script>
<form method=post action="/dashboard/api/create" onsubmit="return createVM(event)">
<input name=name placeholder="name" required pattern="[a-zA-Z0-9-]+" />
<button type=submit>Create</button>
</form>
<div style="margin:.5rem 0 1rem 0">
<input id=spport placeholder="single-port (e.g., 20002)" style="width:220px" />
<button onclick="enableSinglePort()">Enable single-port mode</button>
<span class=badge>Experimental</span>
</div>
<div style="margin:.25rem 0 1.25rem 0" class=muted>
<input id=dashport placeholder="direct dash port (optional)" style="width:260px" />
<button class="btn-gray" onclick="disableSinglePort()">Disable single-port (direct mode)</button>
</div>
<table><thead><tr><th>Name</th><th>Status</th><th>Port/Path</th><th>URL</th><th>Actions</th></tr></thead><tbody id=tbody></tbody></table>
<section class="panel" style="margin-top:2rem;padding:1.25rem 1.4rem;border-top:2px solid var(--orange)">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:.5rem">
    <h2 style="margin:0;font-size:1.25rem;letter-spacing:-.01em">Accounts &amp; Access Requests</h2>
    <button onclick="loadAccounts()">Refresh</button>
  </div>
  <form id="create-user-form" style="display:flex;flex-wrap:wrap;gap:.6rem;align-items:flex-end;margin:.4rem 0 .9rem">
  <div style="display:flex;flex-direction:column;gap:.2rem">
    <label style="font-size:.72rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)">Username</label>
    <input id="cu-username" placeholder="newuser" style="width:180px" />
  </div>
  <div style="display:flex;flex-direction:column;gap:.2rem">
    <label style="font-size:.72rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)">Password</label>
    <input id="cu-password" type="password" placeholder="min 3 chars" style="width:200px" />
  </div>
  <div style="display:flex;flex-direction:column;gap:.2rem">
    <label style="font-size:.72rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)">Assign VMs (comma-sep)</label>
    <input id="cu-vms" placeholder="epic, jason" style="width:220px" />
  </div>
  <label style="display:flex;align-items:center;gap:.35rem;font-size:.85rem;color:var(--muted);margin-bottom:.4rem;cursor:pointer"><input id="cu-admin" type="checkbox" style="width:auto;margin:0" /> Admin</label>
  <button type="button" onclick="createUser()">Create User</button>
  <span id="cu-msg" class="muted" style="margin-left:.2rem"></span>
</form>
<h3 style="margin:.5rem 0 .25rem;font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)">Users</h3>
  <table><thead><tr><th>Username</th><th>Status</th><th>Admin</th><th>VMs</th><th>Actions</th></tr></thead><tbody id="accounts-tbody"><tr><td colspan=5 class=muted>Loading…</td></tr></tbody></table>
  <h3 style="margin:1rem 0 .25rem;font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)">Access Requests</h3>
  <table><thead><tr><th>User</th><th>VM</th><th>Note</th><th>Status</th><th>Actions</th></tr></thead><tbody id="requests-tbody"><tr><td colspan=5 class=muted>Loading…</td></tr></tbody></table>
</section>
<div style="margin:1rem 0 2rem 0">
        <button onclick="bulkRecreate()">Recreate ALL VMs</button>
        <button onclick="bulkRebuildAll()">Rebuild ALL VMs</button>
        <button onclick="bulkUpdateAndRebuild()">Update & Rebuild ALL VMs</button>
        <button onclick="pruneDocker()" class="btn-gray">Prune Docker</button>
        <button onclick="bulkResetAll()" class="btn-red">Reset ALL VMs</button>
        <button onclick="bulkDeleteAll()" class="btn-red">Delete ALL VMs</button>
        <span class="muted" style="margin-left: .5rem">Shift+Click Check for report-only (no auto-fix)</span>
    </div>
<div style="margin:1.5rem 0 .5rem 0">
    <span class=badge>Custom domain (merged mode):</span>
    <input id=customdomain placeholder="e.g. vms.example.com" style="width:220px" />
    <button onclick="setCustomDomain()">Set domain</button>
    <span id=domainip style="margin-left:1.5rem"></span>
</div>
<div style="margin:.5rem 0;padding:.5rem;border:1px solid #222;border-radius:6px;background:#07121a">
    <strong style="display:block;margin-bottom:.25rem">Dashboard Settings</strong>
    <input id="setting-title" placeholder="Dashboard title" style="width:320px" />
    <input id="setting-favicon" placeholder="Favicon URL (http/https)" style="width:320px;margin-left:.5rem" />
    <input id="setting-v2pw" placeholder="New Dashboard v2 admin password (leave blank to keep)" style="width:420px;display:block;margin-top:.5rem" />
    <!-- Removed favicon upload -->
    <button onclick="saveSettings()" style="margin-left:.5rem">Save</button>
    <button onclick="clearFavicon()" class="btn-gray" style="margin-left:.25rem">Clear Favicon</button>
    <div id="settings-msg" class="muted" style="margin-top:.5rem"></div>
</div>
<script>
// Debug helpers: enable extra logs with ?debug=1
const DEBUG = new URLSearchParams(window.location.search).has('debug');
const dbg = (...args) => { if (DEBUG) console.log('[BLOBEDASH]', ...args); };
window.addEventListener('error', (e) => console.error('[BLOBEDASH] window error', e.message, e.error || e));
window.addEventListener('unhandledrejection', (e) => console.error('[BLOBEDASH] unhandledrejection', e.reason));

function showErr(msg){
    try{
        const eb = document.getElementById('errbox');
        if(!eb) return;
        eb.style.display = 'block';
        eb.textContent = String(msg);
    }catch(e){ console.error('showErr error', e); }
}

function clearErr(){
    try{ const eb = document.getElementById('errbox'); if(eb){ eb.style.display='none'; eb.textContent=''; } }catch(e){}
}

let mergedMode = false, basePath = '/vm', customDomain = '', dashPort = '', dashIp = '';
let vms = [];
let availableApps = [];
async function load(){
    try {
        const [r, r2, r3, r4] = await Promise.all([
            fetch('/dashboard/api/list'),
            fetch('/dashboard/api/modeinfo'),
            fetch('/dashboard/api/apps').catch(()=>({ok:false})),
            fetch('/dashboard/api/settings').catch(()=>({ok:false}))
        ]);
        const eb = document.getElementById('errbox');
        if (!r.ok || !r2.ok) {
            const msg = `/dashboard/api/list: ${r.status} | /dashboard/api/modeinfo: ${r2.status}`;
            console.error('[BLOBEDASH] API error', msg);
            eb.style.display = 'block';
            eb.textContent = `Dashboard API error: ${msg}. If you enabled auth, ensure the same credentials are applied to API calls (refresh the page).`;
            return;
        }
        eb.style.display = 'none'; eb.textContent = '';
    const data = await r.json().catch(err => { console.error('[BLOBEDASH] list JSON error', err); return {instances:[]}; });
        const info = await r2.json().catch(err => { console.error('[BLOBEDASH] modeinfo JSON error', err); return {}; });
        const settings = (r4 && r4.ok) ? await r4.json().catch(()=>({})) : {};
        if (r3 && r3.ok) {
            const apps = await r3.json().catch(()=>({apps:[]}));
            availableApps = apps.apps || [];
        }
        dbg('modeinfo', info);
        dbg('instances', data.instances);
    mergedMode = !!info.merged;
    basePath = info.basePath||'/vm';
    // normalize basePath: ensure single leading slash and no trailing slash
    if(!basePath) basePath = '/vm';
    if(!basePath.startsWith('/')) basePath = '/' + basePath;
    basePath = basePath.replace(/\/+$/, '');
        customDomain = info.domain||'';
        dashPort = info.dashPort||'';
        dashIp = info.ip||'';
        document.getElementById('customdomain').value = customDomain;
        document.getElementById('domainip').textContent = `Point domain to: ${dashIp}`;
    vms = data.instances || [];
    const vmTitles = settings.vm_titles || {};
    const tb=document.getElementById('tbody');
        tb.innerHTML='';
             // Removed app options
    vms.forEach(i=>{
            const tr=document.createElement('tr');
            const dot = statusDot(i.status);
            let portOrPath = '';
            let openUrl = i.url;
            if(mergedMode){
                // merged: show /vm/<name> or domain
                portOrPath = `${basePath}/${i.name}`;
                if(customDomain){
                    openUrl = `http://${customDomain}${basePath}/${i.name}/`;
                }
            }else{
                // direct: show port; always build link using current browser host
                // Prefer explicit port from API, else try to parse from URL or status text
                if (i.port && String(i.port).match(/^\d+$/)) {
                    portOrPath = String(i.port);
                } else {
                    let m = i.url && i.url.match(/:(\d+)/);
                    portOrPath = m ? m[1] : '';
                }
                if (!portOrPath && i.status) {
                    const ms = i.status.match(/\(port\s+(\d+)\)/i);
                    if (ms) portOrPath = ms[1];
                }
                if (portOrPath) {
                    const proto = window.location.protocol;
                    const host = window.location.hostname;
                    openUrl = `${proto}//${host}:${portOrPath}/`;
                } else {
                    openUrl = '';
                }
            }
            dbg('row', { name: i.name, status: i.status, rawUrl: i.url, mergedMode, portOrPath, openUrl });
            const vmTitle = vmTitles[i.name] || '';
             // add cache-busting to favicon src so uploads show up immediately
             const favSrc = `/dashboard/vm-favicon/${i.name}.ico?v=${Date.now()}`;
             tr.innerHTML=`<td><img src="${favSrc}" style="width:16px;height:16px;vertical-align:middle;margin-right:6px" onerror="this.style.display='none'"/>${i.name}<div id="vmtitle-display-${i.name}" style="font-size:.85rem;color:#9ca3af;margin-top:3px">${vmTitle||''}</div></td><td>${dot}<span class=muted>${i.status||''}</span></td><td>${portOrPath}</td><td><a href="${openUrl}" target="_blank" rel="noopener noreferrer">${openUrl}</a></td>`+
                 `<td>`+
                 `<button onclick="openVM('${i.name}')">Open</button>`+
                 `<button onclick="act('start','${i.name}')">Start</button>`+
                 `<button onclick="act('stop','${i.name}')">Stop</button>`+
                 `<button onclick="act('restart','${i.name}')">Restart</button>`+
                 `<button title="Shift-click for no-fix" onclick="checkVM(event,'${i.name}')" class="btn-gray">Check</button>`+
                 `<button onclick="updateVM('${i.name}')" class="btn-gray">Update</button>`+
                 `<button onclick="recreateVM('${i.name}')">Recreate</button>`+
                 `<button onclick=\"cleanVM('${i.name}')\" class=\"btn-gray\">Clean</button>`+
                 `<button onclick="resetVM('${i.name}')" class="btn-red">Reset</button>`+
                 `<button onclick="delvm('${i.name}')" class="btn-red">Delete</button>`+
                 `<div style="margin-top:.5rem">`+
                 `<input id="vmtitle-${i.name}" placeholder="Tab title" value="${vmTitle}" style="width:220px" />`+
                 `<button onclick="saveVMTitle('${i.name}')" style="margin-left:.25rem">Save Title</button>`+
                 `</div>`+
                 `</td>`;
          tb.appendChild(tr);
        });
    } catch (err) {
        console.error('[BLOBEDASH] load() error', err);
    }
}
// Check new dashboard availability and API presence
async function checkV2(){
    const el = document.getElementById('v2state');
    if(!el) return;
    el.textContent = 'Checking…';
    try{
        const r = await fetch('/Dashboard/', {cache:'no-store'});
        if(r.ok){
            el.innerHTML = 'Available — <a href="/Dashboard/" target="_blank">Open</a>';
        }else if(r.status === 404){
            el.textContent = 'Not built (no files)';
        }else{
            const txt = await r.text().catch(()=>r.statusText||'error')
            el.textContent = `HTTP ${r.status}: ${txt.slice(0,120)}`
        }
    }catch(e){
        el.textContent = 'Error contacting /Dashboard: ' + (e && e.message ? e.message : String(e))
    }
    // Check whether v2 API endpoints exist (unauthenticated probe)
    try{
        const r2 = await fetch('/dashboard/api/vm/stats', {method:'GET', cache:'no-store'});
        if(r2.status === 401){
            el.innerHTML += ' · API: present (auth required)'
        }else if(r2.ok){
            el.innerHTML += ' · API: present'
        }else if(r2.status === 404){
            el.innerHTML += ' · API: missing (404)'
        }else{
            el.innerHTML += ' · API status: ' + r2.status
        }
    }catch(e){
        el.innerHTML += ' · API probe error: ' + (e && e.message ? e.message : String(e))
    }
    // fetch server-side info for more details (requires auth)
    try{
        const r3 = await fetch('/dashboard/api/v2/info')
        if(r3.ok){
            const j = await r3.json().catch(()=>null)
            if(j && j.info){
                const info = j.info
                if(info.last_error){
                    el.innerHTML += '<div style="margin-top:6px;color:#fbb">Build error: '+(info.last_error.length>300?info.last_error.slice(0,300)+'…':info.last_error)+'</div>'
                }else if(!info.dist_exists){
                    el.innerHTML += ' · No build artifacts found'
                }else{
                    const m = info.index_mtime ? new Date(info.index_mtime*1000).toLocaleString() : ''
                    el.innerHTML += ` · Built: ${m} · files: ${info.files_count}`
                }
            }
        }
    }catch(e){ /* ignore */ }
}

// run the v2 probe at start and periodically
setTimeout(checkV2, 500);
setInterval(checkV2, 30*1000);
function recreateVM(name){
    if(!confirm('Recreate VM '+name+'?'))return;
    fetch('/dashboard/api/recreate',{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({names:[name]})
    }).then(load);
}
function resetVM(name){
    // Strong confirmation because this permanently removes instance data
    var promptMsg = 'Reset VM ' + name + '? This will permanently remove all instance data. Type RESET to confirm.';
    var conf = prompt(promptMsg);
    if(conf !== 'RESET') return;
    try{
        fetch('/dashboard/api/reset/' + encodeURIComponent(name),{method:'POST'}).then(()=>{
            alert('Reset requested. VM will be recreated shortly.');
            load();
        }).catch(e=>{ showErr('Reset request failed: '+e); });
    }catch(e){ showErr('Reset error: '+e); }
}
function rebuildVM(name){
    if(!confirm('Rebuild (image + recreate) VM '+name+'?'))return;
    fetch('/dashboard/api/rebuild-vms',{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({names:[name]})
    }).then(load);
}
async function updateVM(name){
    if(!confirm('Update packages inside VM '+name+'?'))return;
    try{
        const r = await fetch(`/dashboard/api/update-vm/${encodeURIComponent(name)}`,{method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && (j.ok || j.started)){
            alert('Update started. Status will show as Updating…');
        }else{
            showErr('Update failed:\n'+((j && (j.error||j.output))||'unknown error'));
        }
    }catch(e){
        showErr('Update error: '+e);
    }
    load();
}

async function pruneDocker(){
    if(!confirm('Prune unused Docker data (images, containers, cache)?')) return;
    try{
        const r = await fetch('/dashboard/api/prune-docker', {method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && (j.ok || j.started)){
            alert('Docker prune started. This may take a while.');
        }else{
            showErr('Failed to start prune: ' + (j && (j.error||j.output) || 'unknown'));
        }
    }catch(e){ alert('Prune error: '+e); }
}

async function cleanVM(name){
    if(!confirm('Clean apt caches and temporary files inside VM '+name+'?')) return;
    try{
        const r = await fetch(`/dashboard/api/clean-vm/${encodeURIComponent(name)}`, {method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && j.ok){
            alert('Clean requested.');
        }else{
            alert('Clean failed:\n' + ((j && (j.error||j.output)) || 'unknown error'));
        }
    }catch(e){ alert('Clean error: ' + e); }
    load();
}
async function installChrome(name){
    if(!confirm('Install Google Chrome in VM '+name+'?'))return;
    try{
        const r = await fetch(`/dashboard/api/app-install/${encodeURIComponent(name)}/chrome`,{method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && j.ok){
            alert('Chrome installation requested.');
        }else{
            alert('Chrome install failed:\n'+((j && (j.error||j.output))||'unknown error'));
        }
    }catch(e){
        alert('Install error: '+e);
    }
    load();
}
async function installApp(name, app){
    try{
        const r = await fetch(`/dashboard/api/app-install/${encodeURIComponent(name)}/${encodeURIComponent(app)}`,{method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && j.ok){
            alert(`${app} installation requested.`);
        }else{
            alert(`${app} install failed:\n`+((j && (j.error||j.output))||'unknown error'));
        }
    }catch(e){
        alert('Install error: '+e);
    }
    load();
}
function openLink(url){
    try{
        if(!url || typeof url !== 'string'){
            alert('No URL available yet. Try again after the VM starts.');
            return;
        }
        // Basic sanity: must start with http(s)://
        if(!/^https?:\/\//i.test(url)){
            alert('Invalid URL.');
            return;
        }
        window.open(url, '_blank');
    }catch(e){
        console.error('openLink error', e);
    }
}

function openVM(name){
    try{
        // prefer the saved VM title if available, else read from input field
        const el = document.getElementById('vmtitle-' + name);
        let t = '';
        if(el && el.value) t = el.value;
        // fallback to global dashboard title
        if(!t){
            const st = document.getElementById('setting-title');
            if(st && st.value) t = st.value;
        }
        try{ if(t) document.title = t; }catch(e){}
    }catch(e){ console.error('openVM title set error', e); }
    openLink('/dashboard/vm/' + encodeURIComponent(name) + '/');
}

function openVMWithUrl(name, url){
    try{
        // set title from saved input or global
        const el = document.getElementById('vmtitle-' + name);
        let t = '';
        if(el && el.value) t = el.value;
        if(!t){ const st = document.getElementById('setting-title'); if(st && st.value) t = st.value; }
        try{ if(t) document.title = t; }catch(e){}
    }catch(e){ console.error('openVMWithUrl title set error', e); }
    try{
        // If dashboard is running in merged mode, open the dashboard's own wrapper so
        // the server-rendered per-VM title + favicon are applied. Otherwise open the
        // provided direct URL.
        if(typeof mergedMode !== 'undefined' && mergedMode){
            try{
                // use configured basePath (e.g. /vm) so we open /vm/<name>/ on dashboard origin
                const bp = (typeof basePath !== 'undefined' && basePath) ? basePath : '/vm';
                const norm = bp.replace(/\/+$/,'');
                const wrapper = window.location.origin + norm + '/' + encodeURIComponent(name) + '/';
                openLink(wrapper);
            }catch(e){ openLink(url); }
        } else {
            openLink(url);
        }
    }catch(e){ openLink(url); }
}
function selectedApp(name){
    const el = document.getElementById(`appsel-${name}`);
    return (el && el.value ? el.value.trim() : '');
}
async function installSelectedApp(name){
    const app = selectedApp(name);
    if(!app){ alert('Select an app first.'); return; }
    await installApp(name, app);
}
async function appStatusSelected(name){
    const app = selectedApp(name);
    if(!app){ alert('Select an app first.'); return; }
    try{
        const r = await fetch(`/dashboard/api/app-status/${encodeURIComponent(name)}/${encodeURIComponent(app)}`);
        const j = await r.json().catch(()=>({}));
        if(j && j.ok){
            alert(`${app} status: ${j.status||'installed'}`);
        }else{
            alert(`${app} not installed or unknown.`);
        }
    }catch(e){
        alert('Status error: '+e);
    }
}
async function uninstallSelectedApp(name){
    const app = selectedApp(name);
    if(!app){ alert('Select an app first.'); return; }
    if(!confirm(`Uninstall ${app} from ${name}?`)) return;
    try{
        const r = await fetch(`/dashboard/api/app-uninstall/${encodeURIComponent(name)}/${encodeURIComponent(app)}`,{method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && j.ok){
            alert(`${app} uninstall requested.`);
        }else{
            alert(`${app} uninstall failed:\n`+((j && (j.error||j.output))||'unknown error'));
        }
    }catch(e){
        alert('Uninstall error: '+e);
    }
    load();
}
async function reinstallSelectedApp(name){
    const app = selectedApp(name);
    if(!app){ alert('Select an app first.'); return; }
    if(!confirm(`Reinstall ${app} in ${name}? This will uninstall first.`)) return;
    try{
        const r = await fetch(`/dashboard/api/app-reinstall/${encodeURIComponent(name)}/${encodeURIComponent(app)}`,{method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && j.ok){
            alert(`${app} reinstall requested.`);
        }else{
            alert(`${app} reinstall failed:\n`+((j && (j.error||j.output))||'unknown error'));
        }
    }catch(e){
        alert('Reinstall error: '+e);
    }
    load();
}
function bulkRecreate(){
    if(!confirm('Recreate ALL VMs?'))return;
    fetch('/dashboard/api/recreate',{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({names:vms.map(x=>x.name)})
    }).then(load);
}
function bulkRebuildAll(){
    if(!confirm('Rebuild (image + recreate) ALL VMs?'))return;
    fetch('/dashboard/api/rebuild-vms',{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({names:vms.map(x=>x.name)})
    }).then(load);
}
function bulkUpdateAndRebuild(){
    if(!confirm('Update repo, rebuild image, and recreate ALL VMs?'))return;
    fetch('/dashboard/api/update-and-rebuild',{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({names:vms.map(x=>x.name)})
    }).then(load);
}
function bulkDeleteAll(){
    var conf=prompt('Delete ALL VMs? This cannot be undone. Type DELETE to confirm.');
    if(conf!=='DELETE')return;
    fetch('/dashboard/api/delete-all-instances',{
        method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({confirm:'DELETE'})
    }).then(load);
}

function bulkResetAll(){
    var promptMsg = 'Reset ALL VMs? This will permanently remove all instance data and recreate each VM. Type RESET_ALL to confirm.';
    var conf = prompt(promptMsg);
    if(conf !== 'RESET_ALL') return;
    try{
        fetch('/dashboard/api/reset-all-instances',{method:'POST'}).then(()=>{
            alert('Reset ALL requested. VMs will be recreated shortly.');
            load();
        }).catch(e=>{ showErr('Reset ALL request failed: '+e); });
    }catch(e){ showErr('Reset ALL error: '+e); }
}
async function setCustomDomain(){
    try{
        const dom = document.getElementById('customdomain').value.trim();
        if(!dom){ showErr('Enter a domain.'); return; }
        console.log('[BLOBEDASH] setCustomDomain ->', dom);
        clearErr();
        const di = document.getElementById('domainip'); if(di) di.textContent = 'Applying...';
        // Ask server to persist domain and apply merged/domain-mode settings so VMs pick it up
        const r = await fetch('/dashboard/api/set-domain?apply=1', {method:'post',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`domain=${encodeURIComponent(dom)}&apply=1`});
        const j = await r.json().catch(()=>({}));
        if(j && j.ip){
            if(di) di.textContent = `Point domain to: ${j.ip}`;
        } else {
            showErr('Saved, but could not resolve IP.');
            if(di) di.textContent = '';
        }
        if(j && j.applied){
            alert('Domain saved and merged-mode applied. VMs are being restarted in background.');
        }
    }catch(e){
        showErr('Set domain error: '+e);
    }
}
function statusDot(st){
    const s=(st||'').toLowerCase();
    let cls='gray';
    if(s.includes('rebuilding') || s.includes('updating')) cls='amber';
    else if(s.includes('up')) cls='green';
    else if(s.includes('exited')||s.includes('stopped')||s.includes('dead')) cls='red';
    return `<span class="dot ${cls}"></span>`;
}
async function act(cmd,name){await fetch(`/dashboard/api/${cmd}/${name}`,{method:'post'});load();}
async function delvm(name){if(!confirm('Delete '+name+'?'))return;await fetch(`/dashboard/api/delete/${name}`,{method:'post'});load();}
async function createVM(e){
    e.preventDefault();
    const fd=new FormData(e.target);
    try {
        const r = await fetch('/dashboard/api/create', {method:'post',body:new URLSearchParams(fd)});
        if (!r.ok) {
            const j = await r.json().catch(()=>({}));
            showErr(j.error || 'Failed to create VM.');
        }
    } catch (err) {
        showErr('Error creating VM: ' + err);
    }
    e.target.reset();
    load();
}
async function enableSinglePort(){
    const p=document.getElementById('spport').value||'20002';
    const r=await fetch('/dashboard/api/enable-single-port',{method:'post',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:`port=${encodeURIComponent(p)}`});
    const j=await r.json().catch(()=>({}));
    dbg('enable-single-port', {port: p, response: j});
    alert((j && j.message) || 'Requested. The dashboard may move to the new port soon.');
}
async function disableSinglePort(){
    const p=document.getElementById('dashport').value||'';
    const body=p?`port=${encodeURIComponent(p)}`:'';
    const r=await fetch('/dashboard/api/disable-single-port',{method:'post',headers:{'Content-Type':'application/x-www-form-urlencoded'},body});
    const j=await r.json().catch(()=>({}));
    dbg('disable-single-port', {port: p, response: j});
    alert((j && (j.message||j.error)) || 'Requested. The dashboard may move to a high port soon.');
}
async function checkVM(ev,name){
    const nofix = ev && ev.shiftKey ? 1 : 0;
    try{
        const r = await fetch(`/dashboard/api/check/${encodeURIComponent(name)}`,{method:'post',headers:{'Content-Type':'application/x-www-form-urlencoded'},body: nofix? 'nofix=1' : ''});
        const j = await r.json().catch(()=>({}));
        dbg('check', name, j);
        if(j && j.ok){
            alert(`OK ${j.code} - ${j.url}${j.fixed? ' (auto-resolved)': ''}`);
        }else{
            alert(`FAIL ${j && j.code ? j.code : ''} - ${(j && j.url) || ''}\n${(j && j.output) || ''}`);
        }
    }catch(e){
        alert('Check error: '+e);
    }
    load();
}

let _csrfToken = '';
async function getCsrf(){
  try{ const r = await fetch('/dashboard/api/auth/csrf'); const j = await r.json(); _csrfToken = j.csrfToken || ''; }catch(e){}
}
function evmEscapeHtml(v){ return String(v==null?'':v).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
async function loadAccounts(){
  try{
    await getCsrf();
    const r = await fetch('/dashboard/api/users');
    if(!r.ok) return;
    const j = await r.json();
    const at = document.getElementById('accounts-tbody');
    const rt = document.getElementById('requests-tbody');
    if(at){
      at.innerHTML = '';
      const users = j.users || [];
      if(!users.length){ at.innerHTML = '<tr><td colspan=5 class=muted>No users.</td></tr>'; }
      users.forEach(u=>{
        const st = (u.accountStatus || 'pending');
        const stColor = st==='approved' ? 'var(--green)' : (st==='rejected' ? 'var(--red)' : 'var(--amber)');
        const vmz = (u.assignedVms || []).join(', ');
        const tr = document.createElement('tr');
        tr.innerHTML = `<td><strong>${evmEscapeHtml(u.username)}</strong></td>`+
          `<td><span class=dot style="background:${stColor}"></span>${st}</td>`+
          `<td>${u.isAdmin ? 'yes' : 'no'}</td>`+
          `<td class=muted>${vmz || '—'}</td>`+
          `<td>`+
          (st!=='approved' ? `<button onclick="approveUser('${evmEscapeHtml(u.username)}')">Approve</button>` : '')+
          (st!=='rejected' ? `<button class="btn-red" onclick="rejectUser('${evmEscapeHtml(u.username)}')">Reject</button>` : '')+
          `<button class="btn-gray" onclick="deleteUser('${evmEscapeHtml(u.username)}')">Delete</button>`+
          `</td>`;
        at.appendChild(tr);
      });
    }
    if(rt){
      rt.innerHTML = '';
      const reqs = j.requests || [];
      if(!reqs.length){ rt.innerHTML = '<tr><td colspan=5 class=muted>No access requests.</td></tr>'; }
      reqs.forEach(req=>{
        const tr = document.createElement('tr');
        tr.innerHTML = `<td><strong>${evmEscapeHtml(req.username)}</strong></td>`+
          `<td>${evmEscapeHtml(req.vm_name || '')}</td>`+
          `<td class=muted>${evmEscapeHtml((req.note||'').slice(0,140))}</td>`+
          `<td>${evmEscapeHtml(req.status)}</td>`+
          `<td>`+
          (req.status==='pending' ? `<button onclick="actionRequest(${req.id},'approve')">Approve</button><button class="btn-gray" onclick="actionRequest(${req.id},'deny')">Deny</button><button class="btn-gray" onclick="actionRequest(${req.id},'dismiss')">Dismiss</button>` : '')+
          `</td>`;
        rt.appendChild(tr);
      });
    }
  }catch(e){ console.error('loadAccounts', e); }
}

async function createUser(){
  const u = document.getElementById('cu-username').value.trim();
  const p = document.getElementById('cu-password').value;
  const v = document.getElementById('cu-vms').value.trim();
  const isAdmin = document.getElementById('cu-admin').checked;
  const msg = document.getElementById('cu-msg');
  msg.textContent = '';
  if(!u){ msg.textContent = 'Username required'; return; }
  if(p.length < 3){ msg.textContent = 'Password must be at least 3 chars'; return; }
  await getCsrf();
  const body = { username: u, password: p, isAdmin: isAdmin };
  if(v) body.assignedVms = v.split(',').map(x => x.trim()).filter(Boolean);
  const r = await fetch('/dashboard/api/users', {method:'post', headers:{'Content-Type':'application/json','X-CSRF-Token':_csrfToken}, body: JSON.stringify(body)});
  const j = await r.json().catch(()=>({}));
  if(j && j.ok){ msg.textContent = 'Created '+u; document.getElementById('cu-username').value=''; document.getElementById('cu-password').value=''; document.getElementById('cu-vms').value=''; document.getElementById('cu-admin').checked=false; loadAccounts(); }
  else { msg.textContent = (j && j.error) || 'Create failed'; }
}

async function approveUser(u){
  await getCsrf();
  await fetch(`/dashboard/api/accounts/${encodeURIComponent(u)}/approve`, {method:'post', headers:{'X-CSRF-Token':_csrfToken}});
  loadAccounts();
}
async function rejectUser(u){
  if(!confirm('Reject account '+u+'?')) return;
  await getCsrf();
  await fetch(`/dashboard/api/accounts/${encodeURIComponent(u)}/reject`, {method:'post', headers:{'X-CSRF-Token':_csrfToken}});
  loadAccounts();
}
async function deleteUser(u){
  if(!confirm('Delete user '+u+'? This cannot be undone.')) return;
  await getCsrf();
  await fetch(`/dashboard/api/users/${encodeURIComponent(u)}/delete`, {method:'post', headers:{'X-CSRF-Token':_csrfToken}});
  loadAccounts();
}
async function actionRequest(id, action){
  await getCsrf();
  await fetch(`/dashboard/api/access-requests/${id}/action`, {method:'post', headers:{'Content-Type':'application/json','X-CSRF-Token':_csrfToken}, body: JSON.stringify({action})});
  loadAccounts();
}

    load();setInterval(load,8000);
    loadAccounts();

    async function loadSettings(){
        try{
            const r = await fetch('/dashboard/api/settings');
            if(!r.ok) return;
            const j = await r.json().catch(()=>({}));
            document.getElementById('setting-title').value = j.title || '';
            document.getElementById('setting-favicon').value = j.favicon_url || j.favicon || '';
            // Do not populate the v2 admin password for security; leave blank.
            const v2pwEl = document.getElementById('setting-v2pw');
            if(v2pwEl) v2pwEl.value = '';
        }catch(e){ console.error('loadSettings', e); }
    }

    async function saveSettings(){
        try{
            const title = document.getElementById('setting-title').value || '';
            const fav = document.getElementById('setting-favicon').value || '';
            const newpw = (document.getElementById('setting-v2pw') && document.getElementById('setting-v2pw').value) || '';
            const body = new URLSearchParams();
            body.append('title', title);
            body.append('favicon', fav);
            // Only send the new password when provided; empty means no change
            if(newpw !== '') body.append('new_dashboard_admin_password', newpw);
            const r = await fetch('/dashboard/api/settings', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: body});
            const j = await r.json().catch(()=>({}));
            const msg = document.getElementById('settings-msg');
            if(j && j.ok){
                if(msg) msg.textContent = 'Saved.';
                document.getElementById('dash-title').textContent = title || '{{ title }}';
                // update the browser tab title immediately
                try{ document.title = title || '{{ title }}'; }catch(e){}
                // If a favicon was saved locally, reload page to pick it up
                if(fav){
                    // small delay then reload to update favicon
                    setTimeout(()=> location.reload(), 600);
                }
            } else {
                if(msg) msg.textContent = 'Save failed';
            }
        }catch(e){ console.error('saveSettings', e); }
    }

    async function clearFavicon(){
        try{
            const title = document.getElementById('setting-title').value || '';
            const body = new URLSearchParams();
            body.append('title', title);
            body.append('favicon', '');
            const r = await fetch('/dashboard/api/settings', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: body});
            const j = await r.json().catch(()=>({}));
            if(j && j.ok){
                document.getElementById('setting-favicon').value = '';
                document.getElementById('settings-msg').textContent = 'Favicon cleared.';
                setTimeout(()=> location.reload(), 400);
            }
        }catch(e){ console.error('clearFavicon', e); }
    }

    async function uploadGlobalFavicon(){
        try{
            const inp = document.getElementById('setting-favicon-file');
            if(!inp || !inp.files || inp.files.length===0){ alert('Select a file first'); return; }
            const fd = new FormData();
            fd.append('file', inp.files[0]);
            const r = await fetch('/dashboard/api/upload-favicon', {method:'POST', body: fd});
            const j = await r.json().catch(()=>({}));
            const msg = document.getElementById('settings-msg');
            if(j && j.ok){ if(msg) msg.textContent = 'Uploaded.'; setTimeout(()=> location.reload(), 500); } else { if(msg) msg.textContent = 'Upload failed'; }
        }catch(e){ console.error('uploadGlobalFavicon', e); }
    }

    async function uploadVMFavicon(ev, name){
        try{
            const files = ev && ev.target && ev.target.files ? ev.target.files : null;
            if(!files || files.length===0){ alert('No file selected'); return; }
            const fd = new FormData();
            fd.append('file', files[0]);
            const r = await fetch('/dashboard/api/upload-vm-favicon/' + encodeURIComponent(name), {method:'POST', body: fd});
            const j = await r.json().catch(()=>({}));
            if(j && j.ok){ setTimeout(()=> location.reload(), 500); } else { alert('Upload failed'); }
        }catch(e){ console.error('uploadVMFavicon', e); }
    }

    loadSettings();

    async function saveVMTitle(name){
        try{
            const el = document.getElementById('vmtitle-' + name);
            if(!el) return;
            const title = el.value || '';
            const body = new URLSearchParams();
            body.append('title', title);
            const r = await fetch('/dashboard/api/set-vm-title/' + encodeURIComponent(name), {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body: body});
            const j = await r.json().catch(()=>({}));
            if(j && j.ok){
                el.style.border = '1px solid #10b981';
                // Update the browser tab title to the saved VM title
                try{ document.title = title || '{{ manager_name }}'; }catch(e){}
                // Update the small per-VM title display in the list
                try{ const disp = document.getElementById('vmtitle-display-' + name); if(disp) disp.textContent = title || ''; }catch(e){}
                setTimeout(()=> el.style.border='', 900);
            }
            else { alert('Save failed'); }
        }catch(e){ console.error('saveVMTitle', e); }
    }

    // Optimizer panel controls
    async function loadOptimizer(){
        try{
            const r = await fetch('/dashboard/api/optimizer/status');
            if(!r.ok) return;
            const j = await r.json();
            const el = document.getElementById('optimizer-status');
            if(el) el.textContent = JSON.stringify(j, null, 2);
            const en = document.getElementById('optimizer-enabled');
            if(en) en.checked = !!(j && j.cfg && j.cfg.enabled);
            const mg = document.getElementById('guard-memory');
            if(mg) mg.checked = !!(j && j.cfg && j.cfg.guards && j.cfg.guards.memory);
            const cg = document.getElementById('guard-cpu');
            if(cg) cg.checked = !!(j && j.cfg && j.cfg.guards && j.cfg.guards.cpu);
            const sg = document.getElementById('guard-swap');
            if(sg) sg.checked = !!(j && j.cfg && j.cfg.guards && j.cfg.guards.swap);
            const hg = document.getElementById('guard-health');
            if(hg) hg.checked = !!(j && j.cfg && j.cfg.guards && j.cfg.guards.health);
            const sm = document.getElementById('guard-strictmem');
            if(sm) sm.checked = !!(j && j.cfg && j.cfg.strictMemoryLimit);

            // Update small status spans with current values/stats
            const memStat = document.getElementById('guard-memory-stat');
            const cpuStat = document.getElementById('guard-cpu-stat');
            const swapStat = document.getElementById('guard-swap-stat');
            const healthStat = document.getElementById('guard-health-stat');
            const strictMemStat = document.getElementById('guard-strictmem-stat');
            try{
                const stats = (j && j.stats) ? j.stats : null;
                if(stats && stats.mem && stats.mem.total){
                    const used = stats.mem.used || 0; const total = stats.mem.total || 0;
                    const pct = total? Math.round(100*used/total): 0;
                    if(memStat) memStat.textContent = `${(used/1024/1024).toFixed(0)}MiB / ${(total/1024/1024).toFixed(0)}MiB (${pct}%)`;
                } else {
                    if(memStat) memStat.textContent = '';
                }
                if(stats && Array.isArray(stats.containers) && stats.containers.length){
                    // find top CPU consumer among blobevm_ containers if possible
                    let top = null;
                    for(const c of stats.containers){
                        if(!top || (c.cpu || 0) > (top.cpu || 0)) top = c;
                    }
                    if(top && cpuStat) cpuStat.textContent = `${top.name}: ${ (top.cpu||0).toFixed(1) }%`;
                } else {
                    if(cpuStat) cpuStat.textContent = '';
                }
                if(stats && stats.swap && stats.swap.total){
                    const sused = stats.swap.used || 0; const stotal = stats.swap.total || 0;
                    const spct = stotal? Math.round(100*sused/stotal): 0;
                    if(swapStat) swapStat.textContent = `${(sused/1024/1024).toFixed(0)}MiB (${spct}%)`;
                } else { if(swapStat) swapStat.textContent = ''; }
                if(j && j.cfg && j.cfg.strictMemoryLimit){
                    if(strictMemStat) strictMemStat.textContent = `limit=${j.cfg.memoryLimit||'1g'}`;
                } else { if(strictMemStat) strictMemStat.textContent = ''; }
            }catch(e){ console.error('update optimizer stats', e); }
        }catch(e){ console.error('loadOptimizer', e); }
    }

    async function optimizerSet(key, val){
        await fetch('/dashboard/api/optimizer/set', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key, val})});
        await loadOptimizer();
    }

    function setRestartInterval(){
        const el = document.getElementById('restart-interval');
        if(!el) return;
        const v = parseInt(el.value);
        if(!v || v <= 0){ showErr('Enter a positive number of hours'); return; }
        optimizerSet('restartIntervalHours', v);
    }

    async function optimizerRunOnce(){
        const r = await fetch('/dashboard/api/optimizer/run-once', {method:'POST'});
        if(r.ok) alert('Optimizer run started'); else showErr('Failed to start optimizer run');
    }

    async function optimizerTail(){
        const r = await fetch('/dashboard/api/optimizer/logs');
        if(!r.ok) return showErr('No logs');
        const t = await r.text();
        const el = document.getElementById('optimizer-logs');
        if(el) el.textContent = t;
    }

    async function optimizerCleanSystem(){
        if(!confirm('Run system cleaner (will drop caches and prune docker). Proceed?')) return;
        const r = await fetch('/dashboard/api/optimizer/clean-system', {method:'POST'});
        const j = await r.json().catch(()=>({}));
        if(j && j.started) alert('Cleaner started'); else showErr('Cleaner failed: '+(j.error||'unknown'));
    }

    // Periodically refresh optimizer panel
    loadOptimizer(); setInterval(loadOptimizer, 15000);

</script>

<div style="margin:1.5rem 0;padding:1rem;border:1px solid #333;border-radius:6px;background:#081226">
    <h2 style="margin-top:0">Optimizer Panel</h2>
    <div style="display:flex;gap:1rem;align-items:center;margin-bottom:.5rem">
        <label><input id="optimizer-enabled" type="checkbox" onchange="optimizerSet('enabled', this.checked)"> Optimizer Enabled <span id="opt-enabled-stat" class="muted"></span></label>
        <label><input id="guard-memory" type="checkbox" onchange="optimizerSet('guards', Object.assign(({}), {memory:this.checked}))"> Memory Guard <span id="guard-memory-stat" class="muted"></span></label>
        <label><input id="guard-cpu" type="checkbox" onchange="optimizerSet('guards', Object.assign(({}), {cpu:this.checked}))"> CPU Guard <span id="guard-cpu-stat" class="muted"></span></label>
        <label><input id="guard-swap" type="checkbox" onchange="optimizerSet('guards', Object.assign(({}), {swap:this.checked}))"> Swap Guard <span id="guard-swap-stat" class="muted"></span></label>
        <label><input id="guard-health" type="checkbox" onchange="optimizerSet('guards', Object.assign(({}), {health:this.checked}))"> Health Guard <span id="guard-health-stat" class="muted"></span></label>
        <label><input id="guard-strictmem" type="checkbox" onchange="optimizerSet('strictMemoryLimit', this.checked)"> Strict Memory Limits <span id="guard-strictmem-stat" class="muted"></span></label>
    </div>
    <div style="margin-bottom:.5rem">
        <button onclick="optimizerRunOnce()">Run Once</button>
        <button onclick="optimizerTail()" class="btn-gray">Show Logs</button>
        <button onclick="optimizerCleanSystem()" class="btn-red">System Cleaner</button>
    </div>
    <pre id="optimizer-status" style="background:#000;color:#9ee;padding:.5rem;border-radius:4px;max-height:180px;overflow:auto"></pre>
    <pre id="optimizer-logs" style="background:#000;color:#9ee;padding:.5rem;border-radius:4px;max-height:240px;overflow:auto;margin-top:.5rem"></pre>
</div>

</body></html>
"""

# --- Dashboard session helpers ---
def _get_legacy_dashboard_password():
    # Compatibility-only fallback for installations that predate BLOBEDASH_*.
    # The old settings endpoint no longer writes this value.
    cfg = _load_dashboard_settings()
    return cfg.get('new_dashboard_admin_password')

def _sign_v2_token(payload: str) -> str:
    secret = _dashboard_secret()
    if not secret:
        raise ValueError('Dashboard session secret is not configured')
    mac = hmac.new(secret.encode('utf-8'), payload.encode('utf-8'), hashlib.sha256).hexdigest()
    token = f"{payload}:{mac}"
    return base64.urlsafe_b64encode(token.encode('utf-8')).decode('utf-8')

def _verify_v2_token(token_b64: str) -> bool:
    try:
        secret = _dashboard_secret()
        if not secret:
            return False
        raw = base64.urlsafe_b64decode(token_b64.encode('utf-8')).decode('utf-8')
        parts = raw.rsplit(':', 1)
        if len(parts) != 2:
            return False
        payload, mac = parts
        expected = hmac.new(secret.encode('utf-8'), payload.encode('utf-8'), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(mac, expected):
            return False
        # payload format: expiry:random
        exp_str = payload.split(':',1)[0]
        exp = int(exp_str)
        return time.time() < exp and _account_dashboard_revision_valid(payload)
    except Exception:
        return False

v2_auth_required = admin_auth_required

# --- Portal / per-VM user auth helpers ---
def _portal_secret() -> str:
    return os.environ.get('BLOBEVM_USER_SECRET', '').strip()

def _users_db_path():
    return os.path.join(_state_dir(), 'dashboard_users.sqlite3')

def _users_conn():
    conn = sqlite3.connect(_users_db_path())
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys = ON')
    return conn


def _resource_key(resource_type: str, host_id: str, native_id: str) -> str:
    kind = 'cloudpc' if str(resource_type or '').lower() == 'cloudpc' else 'vm'
    host = 'external' if kind == 'cloudpc' else (str(host_id or 'local').strip().lower() or 'local')
    native = str(native_id or '').strip()
    if not native:
        raise ValueError('Resource identity is missing')
    return f'{kind}:{url_quote(host, safe="")}:{url_quote(native, safe="")}'


def _parse_resource_key(value: str):
    parts = str(value or '').split(':', 2)
    if len(parts) != 3 or parts[0] not in ('vm', 'cloudpc'):
        return None
    return {
        'resourceType': parts[0],
        'hostId': url_unquote(parts[1]),
        'nativeId': url_unquote(parts[2]),
        'resourceKey': str(value),
    }

def _init_users_db():
    conn = _users_conn()
    try:
        conn.executescript('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            is_admin INTEGER NOT NULL DEFAULT 0,
            disabled INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        );
        CREATE TABLE IF NOT EXISTS user_vm_access (
            user_id INTEGER NOT NULL,
            vm_name TEXT NOT NULL,
            PRIMARY KEY (user_id, vm_name),
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS access_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL,
            vm_name TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending',
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        );
        CREATE UNIQUE INDEX IF NOT EXISTS one_pending_access_request
        ON access_requests(username, vm_name) WHERE status = 'pending';
        CREATE TABLE IF NOT EXISTS user_resource_access (
            user_id INTEGER NOT NULL,
            resource_key TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            host_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
            PRIMARY KEY (user_id, resource_key),
            FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS resource_metadata (
            resource_key TEXT PRIMARY KEY,
            resource_type TEXT NOT NULL,
            host_id TEXT NOT NULL,
            native_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            access_mode TEXT NOT NULL DEFAULT 'restricted',
            title TEXT NOT NULL DEFAULT '',
            host_override TEXT NOT NULL DEFAULT '',
            path_override TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        );
        CREATE TABLE IF NOT EXISTS resource_owners (
            resource_key TEXT PRIMARY KEY,
            username TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        );
        CREATE TABLE IF NOT EXISTS resource_migration_issues (
            source_table TEXT NOT NULL,
            source_id TEXT NOT NULL,
            legacy_name TEXT NOT NULL,
            reason TEXT NOT NULL,
            candidates TEXT NOT NULL DEFAULT '[]',
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
            resolved_at INTEGER,
            PRIMARY KEY (source_table, source_id)
        );
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            targets TEXT NOT NULL DEFAULT '[]',
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            started_at INTEGER,
            finished_at INTEGER,
            progress TEXT NOT NULL DEFAULT '',
            output TEXT NOT NULL DEFAULT '',
            error TEXT NOT NULL DEFAULT ''
        );
        ''')
        # Public-beta signup migration: account status, contact, provisioning.
        # Idempotent; safe to run on every init. Pre-existing portal users
        # (who already had VM access before this feature) are approved; new
        # signups explicitly insert 'pending'.
        try:
            cols = {r[1] for r in conn.execute('PRAGMA table_info(users)')}
            for col, ddl in (
                ('account_status', 'TEXT'),
                ('email', "TEXT NOT NULL DEFAULT ''"),
                ('who', "TEXT NOT NULL DEFAULT ''"),
                ('vm_name', 'TEXT'),
                ('provisioning_state', 'TEXT'),
                ('session_version', 'INTEGER NOT NULL DEFAULT 1'),
                ('provisioning_job_id', 'TEXT'),
                ('provisioning_error', "TEXT NOT NULL DEFAULT ''"),
            ):
                if col not in cols:
                    conn.execute(f'ALTER TABLE users ADD COLUMN {col} {ddl}')
            # Existing rows (created before this column existed) default to NULL
            # for the nullable account_status column; treat them as approved.
            conn.execute("UPDATE users SET account_status = 'approved' WHERE account_status IS NULL OR account_status = ''")
            # Account-state transitions are handled by explicit actions.  A
            # schema initializer must never repeatedly promote pending users.
            req_cols = {r[1] for r in conn.execute('PRAGMA table_info(access_requests)')}
            for col, ddl in (
                ('resource_key', 'TEXT'),
                ('resource_type', 'TEXT'),
                ('host_id', 'TEXT'),
            ):
                if col not in req_cols:
                    conn.execute(f'ALTER TABLE access_requests ADD COLUMN {col} {ddl}')
            conn.execute('DROP INDEX IF EXISTS one_pending_access_request')
            conn.execute('''CREATE UNIQUE INDEX IF NOT EXISTS one_pending_resource_request
                            ON access_requests(username, resource_key)
                            WHERE status = 'pending' AND resource_key IS NOT NULL''')
        except Exception:
            pass
        conn.commit()
    finally:
        conn.close()

def _hash_user_password(password: str, salt: str | None = None) -> str:
    if salt is None:
        salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 260000)
    return f"pbkdf2_sha256${salt}${base64.b64encode(dk).decode('ascii')}"

def _verify_user_password(password: str, stored: str) -> bool:
    try:
        algo, salt, digest = stored.split('$', 2)
        if algo != 'pbkdf2_sha256':
            return False
        actual = _hash_user_password(password, salt).split('$', 2)[2]
        return hmac.compare_digest(actual, digest)
    except Exception:
        return False

def _normalize_vm_names(vms):
    out = []
    seen = set()
    for vm in (vms or []):
        name = str(vm or '').strip()
        if not name or name in seen:
            continue
        seen.add(name)
        out.append(name)
    return out


def _resource_capabilities(item, *, resource_type='vm', classification='managed'):
    supplied = item.get('capabilities') if isinstance(item, dict) else None
    if isinstance(supplied, dict):
        caps = dict(supplied)
    else:
        caps = {}
    if resource_type == 'cloudpc':
        defaults = {
            'streamStart': True, 'streamStop': True, 'pair': True,
            'powerStart': False, 'powerStop': False, 'restart': False,
            'logs': False, 'exec': False, 'recover': False,
            'optimizer': False, 'deletePhysicalPc': False,
        }
    else:
        remote = str(item.get('placement') or '').lower() == 'remote'
        protected = classification in ('template', 'protected', 'external')
        defaults = {
            'powerStart': not protected,
            'powerStop': not protected,
            'restart': not protected,
            'logs': True,
            'exec': not remote and not protected,
            'recover': not protected,
            'optimizer': not remote and not protected,
            'delete': not protected,
        }
    return {**defaults, **caps}


def _classify_vm_resource(item):
    name = str(item.get('name') or '')
    lowered = name.lower()
    profile = str(item.get('profile') or '').lower()
    if 'template' in lowered or profile in ('template', 'builder'):
        return 'template'
    if item.get('protected') is True:
        return 'protected'
    if item.get('managed') is False:
        return 'external'
    return 'managed'


def _resource_inventory(*, include_cloudpcs=True, persist_metadata=True):
    """Return provider-qualified resources plus provider availability.

    Resource arrays and provider errors are intentionally separate.  A failed
    host can therefore be shown as unavailable without implying its resources
    or grants were deleted.
    """
    VM_HOST_REGISTRY.refresh()
    resources, providers = [], []
    for host_id, provider in (getattr(VM_HOST_REGISTRY, 'providers', {}) or {}).items():
        host_name = getattr(provider, 'host_name', host_id)
        try:
            listed = manager_json_list() if host_id == 'local' else manager_json_list(host_id)
            providers.append({'hostId': host_id, 'hostName': host_name, 'available': True, 'error': None})
        except Exception as exc:
            providers.append({'hostId': host_id, 'hostName': host_name, 'available': False, 'error': str(exc)})
            continue
        for item in listed:
            name = str(item.get('name') or '').strip()
            if not name:
                continue
            placement = str(item.get('placement') or ('local' if host_id == 'local' else 'remote')).lower()
            native_id = name if host_id == 'local' else str(item.get('id') or item.get('Id') or item.get('vm_id') or name)
            key = _resource_key('vm', host_id, native_id)
            classification = _classify_vm_resource(item)
            host_online = item.get('host_online') is not False
            resource = dict(item)
            resource.update({
                'resourceKey': key,
                'resourceType': 'vm',
                'nativeId': native_id,
                'name': name,
                'hostId': host_id,
                'host_id': host_id,
                'hostName': item.get('host_name') or host_name,
                'placement': placement,
                'classification': classification,
                'available': bool(host_online),
                'stale': not bool(host_online),
            })
            resource['capabilities'] = _resource_capabilities(resource, classification=classification)
            resources.append(resource)
    if include_cloudpcs:
        try:
            cloud_pcs = _load_cloud_pcs(include_disabled=True)
        except TypeError:  # compatibility with older test doubles
            cloud_pcs = _load_cloud_pcs()
        for pc in cloud_pcs:
            pc_id = str(pc.get('id') or '').strip()
            if not pc_id:
                continue
            key = _resource_key('cloudpc', 'external', pc_id)
            enabled = pc.get('enabled', True) is not False
            resources.append({
                'resourceKey': key,
                'resourceType': 'cloudpc',
                'nativeId': pc_id,
                'name': pc_id,
                'title': pc.get('display_name') or pc_id,
                'hostId': 'external',
                'host_id': 'external',
                'hostName': 'User-owned PC',
                'placement': 'external',
                'classification': 'external',
                'owner': pc.get('owner') or '',
                'paired': bool(pc.get('paired')),
                'enabled': enabled,
                'available': enabled,
                'stale': False,
                'capabilities': _resource_capabilities(pc, resource_type='cloudpc', classification='external'),
            })
    if persist_metadata:
        _sync_resource_metadata(resources)
    return resources, providers


def _sync_resource_metadata(resources):
    _init_users_db()
    conn = _users_conn()
    try:
        for resource in resources:
            key = resource['resourceKey']
            existing = conn.execute('SELECT resource_key FROM resource_metadata WHERE resource_key = ?', (key,)).fetchone()
            if existing:
                conn.execute('''UPDATE resource_metadata SET resource_type = ?, host_id = ?, native_id = ?,
                                display_name = ?, updated_at = strftime('%s','now') WHERE resource_key = ?''',
                             (resource['resourceType'], resource['hostId'], resource['nativeId'], resource['name'], key))
                continue
            if resource['resourceType'] == 'vm' and resource['hostId'] == 'local':
                access_mode = str(_instance_meta(resource['name']).get('access_mode') or 'public').lower()
                if access_mode not in ('public', 'restricted'):
                    access_mode = 'restricted'
            else:
                access_mode = 'restricted'
            conn.execute('''INSERT INTO resource_metadata
                            (resource_key, resource_type, host_id, native_id, display_name, access_mode, title)
                            VALUES (?, ?, ?, ?, ?, ?, ?)''',
                         (key, resource['resourceType'], resource['hostId'], resource['nativeId'],
                          resource['name'], access_mode, str(resource.get('title') or '')))
        conn.commit()
    finally:
        conn.close()


def _migrate_legacy_resource_access(resources):
    by_name = {}
    for resource in resources:
        if resource.get('resourceType') == 'vm':
            by_name.setdefault(resource['name'], []).append(resource)
    _init_users_db()
    conn = _users_conn()
    try:
        legacy = conn.execute('SELECT user_id, vm_name FROM user_vm_access ORDER BY user_id, vm_name').fetchall()
        for row in legacy:
            already = conn.execute('SELECT 1 FROM user_resource_access WHERE user_id = ? AND display_name = ?',
                                   (row['user_id'], row['vm_name'])).fetchone()
            if already:
                continue
            candidates = by_name.get(row['vm_name'], [])
            if len(candidates) == 1:
                candidate = candidates[0]
                conn.execute('''INSERT OR IGNORE INTO user_resource_access
                                (user_id, resource_key, resource_type, host_id, display_name)
                                VALUES (?, ?, ?, ?, ?)''',
                             (row['user_id'], candidate['resourceKey'], 'vm', candidate['hostId'], row['vm_name']))
            else:
                unresolved_key = _resource_key('vm', 'unresolved', row['vm_name'])
                conn.execute('''INSERT OR IGNORE INTO user_resource_access
                                (user_id, resource_key, resource_type, host_id, display_name)
                                VALUES (?, ?, 'vm', 'unresolved', ?)''',
                             (row['user_id'], unresolved_key, row['vm_name']))
                source_id = f"{row['user_id']}:{row['vm_name']}"
                reason = 'ambiguous_name' if len(candidates) > 1 else 'resource_unavailable'
                conn.execute('''INSERT OR REPLACE INTO resource_migration_issues
                                (source_table, source_id, legacy_name, reason, candidates, created_at, resolved_at)
                                VALUES ('user_vm_access', ?, ?, ?, ?, strftime('%s','now'), NULL)''',
                             (source_id, row['vm_name'], reason,
                              json.dumps([candidate['resourceKey'] for candidate in candidates])))
        # Only pending requests require an actionable resource identity.
        # Historical approved/denied/dismissed rows remain as audit history;
        # they must not generate permanent migration warnings or retroactive
        # grants when the old bare VM name no longer exists.
        conn.execute('''UPDATE resource_migration_issues SET resolved_at = strftime('%s','now')
                        WHERE source_table = 'access_requests' AND resolved_at IS NULL
                          AND source_id IN (
                              SELECT CAST(id AS TEXT) FROM access_requests WHERE status <> 'pending'
                          )''')
        request_rows = conn.execute('''SELECT id, vm_name, resource_key FROM access_requests
                                       WHERE status = 'pending'
                                         AND (resource_key IS NULL OR resource_key = '')''').fetchall()
        for row in request_rows:
            candidates = by_name.get(row['vm_name'], [])
            if len(candidates) == 1:
                candidate = candidates[0]
                conn.execute('''UPDATE access_requests SET resource_key = ?, resource_type = 'vm', host_id = ? WHERE id = ?''',
                             (candidate['resourceKey'], candidate['hostId'], row['id']))
            else:
                source_id = str(row['id'])
                reason = 'ambiguous_name' if len(candidates) > 1 else 'resource_unavailable'
                conn.execute('''INSERT OR REPLACE INTO resource_migration_issues
                                (source_table, source_id, legacy_name, reason, candidates, created_at, resolved_at)
                                VALUES ('access_requests', ?, ?, ?, ?, strftime('%s','now'), NULL)''',
                             (source_id, row['vm_name'], reason,
                              json.dumps([candidate['resourceKey'] for candidate in candidates])))
        conn.commit()
    finally:
        conn.close()


def _resolve_resource(value, *, host_id=None, resources=None, resource_type=None):
    resources = resources if resources is not None else _resource_inventory()[0]
    value = str(value or '').strip()
    parsed = _parse_resource_key(value)
    if parsed:
        matches = [r for r in resources if r['resourceKey'] == value]
    else:
        matches = [r for r in resources if r['name'] == value]
        if host_id:
            matches = [r for r in matches if r['hostId'] == host_id]
        if resource_type:
            matches = [r for r in matches if r['resourceType'] == resource_type]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise ValueError('Ambiguous resource name; use a provider-qualified resource key')
    return None

def _known_vm_names():
    """Return VM names from every configured provider.

    Portal account assignment used to query only the local provider.  That
    made every remote-managed VM appear unknown even though the remote host
    registry had a live inventory, blocking authenticated portal access tests
    and real users from being assigned those VMs.  Inventory remains
    best-effort: a dead remote host must not prevent assignments to known
    local/other-host VMs.
    """
    names = set()
    providers = getattr(VM_HOST_REGISTRY, 'providers', {}) or {}
    if isinstance(providers, dict) and providers:
        for host_id in providers:
            try:
                listed = manager_json_list(host_id)
            except Exception:
                continue
            names.update(
                str(item.get('name') or '').strip().lower()
                for item in listed
                if isinstance(item, dict) and str(item.get('name') or '').strip()
            )
        return names
    try:
        return {
            str(item.get('name') or '').strip().lower()
            for item in manager_json_list()
            if isinstance(item, dict) and str(item.get('name') or '').strip()
        }
    except Exception:
        return set()

def _validate_known_vm_names(names):
    names = _normalize_vm_names(names)
    if not names:
        return
    known = _known_vm_names()
    missing = sorted(set(names) - known)
    if missing:
        raise ValueError('Unknown VM: ' + ', '.join(missing))

def _job_row_to_dict(row):
    result = dict(row)
    result['targets'] = json.loads(result.get('targets') or '[]')
    return result

def _create_job(job_type: str, targets=None):
    _init_users_db()
    job_id = secrets.token_urlsafe(18)
    now = int(time.time())
    conn = _users_conn()
    try:
        conn.execute(
            'INSERT INTO jobs (id, type, targets, status, created_at, progress) VALUES (?, ?, ?, ?, ?, ?)',
            (job_id, job_type, json.dumps(_normalize_vm_names(targets)), 'queued', now, 'Queued'),
        )
        conn.commit()
    finally:
        conn.close()
    return job_id

def _update_job(job_id: str, *, status=None, progress=None, output=None, error=None):
    fields, values = [], []
    for key, value in (('status', status), ('progress', progress), ('output', output), ('error', error)):
        if value is not None:
            fields.append(f'{key} = ?')
            values.append(str(value)[:16000])
    if status == 'running':
        fields.append('started_at = ?')
        values.append(int(time.time()))
    if status in ('succeeded', 'failed'):
        fields.append('finished_at = ?')
        values.append(int(time.time()))
    if not fields:
        return
    _init_users_db()
    conn = _users_conn()
    try:
        conn.execute(f"UPDATE jobs SET {', '.join(fields)} WHERE id = ?", [*values, job_id])
        conn.commit()
    finally:
        conn.close()

def _start_job(job_type: str, targets, work):
    job_id = _create_job(job_type, targets)
    def runner():
        _update_job(job_id, status='running', progress='Running')
        try:
            result = work()
            if isinstance(result, tuple):
                ok, output = result
            else:
                ok, output = True, result or ''
            _update_job(job_id, status='succeeded' if ok else 'failed', progress='Completed' if ok else 'Failed', output=output or '', error='' if ok else output or 'Operation failed')
        except Exception as exc:
            _update_job(job_id, status='failed', progress='Failed', error=str(exc))
    threading.Thread(target=runner, daemon=True).start()
    return job_id

def _resource_access_row_to_dict(row):
    return {
        'resourceKey': row['resource_key'],
        'resourceType': row['resource_type'],
        'hostId': row['host_id'],
        'name': row['display_name'],
        'resolved': row['host_id'] != 'unresolved',
    }


def _user_row_to_dict(row, resource_access=None, vm_names=None):
    assigned_resources = list(resource_access or [])
    assigned_names = [item['name'] for item in assigned_resources]
    if not assigned_names:
        assigned_names = _normalize_vm_names(vm_names or [])
    return {
        'id': row['id'],
        'username': row['username'],
        'isAdmin': bool(row['is_admin']),
        'disabled': bool(row['disabled']),
        'createdAt': int(row['created_at'] or 0),
        'assignedVms': sorted(_normalize_vm_names(assigned_names)),
        'assignedResources': sorted(assigned_resources, key=lambda item: (item['name'].lower(), item['hostId'])),
        'accountStatus': str(row['account_status'] or 'pending') if 'account_status' in row.keys() else 'pending',
        'email': (row['email'] or '') if 'email' in row.keys() else '',
        'who': (row['who'] or '') if 'who' in row.keys() else '',
        'vmName': (row['vm_name'] or '') if 'vm_name' in row.keys() else '',
        'provisioningState': (row['provisioning_state'] or None) if 'provisioning_state' in row.keys() else None,
        'provisioningJobId': (row['provisioning_job_id'] or None) if 'provisioning_job_id' in row.keys() else None,
        'provisioningError': (row['provisioning_error'] or '') if 'provisioning_error' in row.keys() else '',
        'realm': 'portal',
        'role': 'portal-admin' if bool(row['is_admin']) else 'portal-user',
    }

def _list_users():
    _init_users_db()
    conn = _users_conn()
    try:
        rows = conn.execute('SELECT * FROM users ORDER BY username COLLATE NOCASE').fetchall()
        access = conn.execute('''SELECT user_id, resource_key, resource_type, host_id, display_name
                                 FROM user_resource_access ORDER BY display_name COLLATE NOCASE''').fetchall()
        legacy = conn.execute('SELECT user_id, vm_name FROM user_vm_access ORDER BY vm_name COLLATE NOCASE').fetchall()
        resource_map, vm_map = {}, {}
        for item in access:
            resource_map.setdefault(item['user_id'], []).append(_resource_access_row_to_dict(item))
        for item in legacy:
            vm_map.setdefault(item['user_id'], []).append(item['vm_name'])
        return [_user_row_to_dict(r, resource_map.get(r['id'], []), vm_map.get(r['id'], [])) for r in rows]
    finally:
        conn.close()

def _get_user_by_username(username: str):
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        if not row:
            return None
        resources = [_resource_access_row_to_dict(r) for r in conn.execute(
            '''SELECT resource_key, resource_type, host_id, display_name FROM user_resource_access
               WHERE user_id = ? ORDER BY display_name COLLATE NOCASE''', (row['id'],)).fetchall()]
        vms = [r['vm_name'] for r in conn.execute('SELECT vm_name FROM user_vm_access WHERE user_id = ? ORDER BY vm_name COLLATE NOCASE', (row['id'],)).fetchall()]
        return _user_row_to_dict(row, resources, vms) | { 'password_hash': row['password_hash'], 'sessionVersion': int(row['session_version'] or 1) if 'session_version' in row.keys() else 1 }
    finally:
        conn.close()

def _normalize_resource_assignments(values, *, existing=None):
    values = _normalize_vm_names(values)
    if not values:
        return []
    resources, _ = _resource_inventory()
    by_key = {item['resourceKey']: item for item in resources}
    existing_by_key = {item['resourceKey']: item for item in (existing or [])}
    normalized = []
    for value in values:
        resource = by_key.get(value) or existing_by_key.get(value)
        if resource is None and not _parse_resource_key(value):
            resource = _resolve_resource(value, resources=resources, resource_type='vm')
        if resource is None:
            raise ValueError(f'Unknown or unavailable resource: {value}')
        if resource.get('resourceType') == 'cloudpc':
            raise ValueError('Cloud PC ownership cannot be changed through VM grants')
        normalized.append({
            'resourceKey': resource['resourceKey'],
            'resourceType': resource.get('resourceType') or 'vm',
            'hostId': resource.get('hostId') or 'local',
            'name': resource.get('name') or value,
        })
    return list({item['resourceKey']: item for item in normalized}.values())


def _replace_user_resource_access(conn, user_id, assignments):
    conn.execute('DELETE FROM user_resource_access WHERE user_id = ?', (user_id,))
    conn.executemany('''INSERT INTO user_resource_access
                        (user_id, resource_key, resource_type, host_id, display_name)
                        VALUES (?, ?, ?, ?, ?)''',
                     [(user_id, item['resourceKey'], item['resourceType'], item['hostId'], item['name'])
                      for item in assignments])


def _create_user(username: str, password: str, assigned_vms=None, is_admin: bool=False, assigned_resources=None):
    if not re.fullmatch(r'[A-Za-z0-9_.-]{3,64}', username or ''):
        raise ValueError('Username must be 3-64 chars using letters, numbers, dot, underscore, or dash')
    if not password or len(password) < 3:
        raise ValueError('Password must be at least 3 characters')
    requested = assigned_resources if assigned_resources is not None else assigned_vms
    assignments = _normalize_resource_assignments(requested or [])
    _init_users_db()
    conn = _users_conn()
    try:
        collision = conn.execute('SELECT username FROM users WHERE lower(username) = lower(?)', (username,)).fetchone()
        if collision:
            raise ValueError(f'Username conflicts with existing account {collision["username"]}; usernames are case-insensitive for new accounts')
        cur = conn.execute('INSERT INTO users (username, password_hash, is_admin, account_status) VALUES (?, ?, ?, ?)', (username, _hash_user_password(password), 1 if is_admin else 0, 'approved'))
        uid = cur.lastrowid
        _replace_user_resource_access(conn, uid, assignments)
        conn.commit()
    except sqlite3.IntegrityError:
        raise ValueError('Username already exists')
    finally:
        conn.close()
    return _get_user_by_username(username)

def _update_user(username: str, assigned_vms=None, password=None, disabled=None, *, assigned_resources=None,
                 account_status=None, is_admin=None):
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        if not row:
            raise ValueError('User not found')
        if password is not None:
            if len(password) < 3:
                raise ValueError('Password must be at least 3 characters')
            conn.execute('UPDATE users SET password_hash = ?, session_version = session_version + 1 WHERE id = ?', (_hash_user_password(password), row['id']))
        if disabled is not None:
            value = 1 if disabled else 0
            if value != int(row['disabled'] or 0):
                conn.execute('UPDATE users SET disabled = ?, session_version = session_version + 1 WHERE id = ?', (value, row['id']))
        if account_status is not None:
            account_status = str(account_status).strip().lower()
            if account_status not in ('pending', 'approved', 'rejected'):
                raise ValueError('Invalid account status')
            if account_status != str(row['account_status'] or 'pending'):
                conn.execute('UPDATE users SET account_status = ?, session_version = session_version + 1 WHERE id = ?', (account_status, row['id']))
        if is_admin is not None:
            value = 1 if is_admin else 0
            if value != int(row['is_admin'] or 0):
                conn.execute('UPDATE users SET is_admin = ?, session_version = session_version + 1 WHERE id = ?', (value, row['id']))
        requested = assigned_resources if assigned_resources is not None else assigned_vms
        if requested is not None:
            existing_rows = conn.execute('''SELECT resource_key, resource_type, host_id, display_name
                                            FROM user_resource_access WHERE user_id = ?''', (row['id'],)).fetchall()
            existing = [_resource_access_row_to_dict(item) for item in existing_rows]
            assignments = _normalize_resource_assignments(requested, existing=existing)
            _replace_user_resource_access(conn, row['id'], assignments)
        conn.commit()
    finally:
        conn.close()
    return _get_user_by_username(username)

def _delete_user(username: str):
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('SELECT id FROM users WHERE username = ?', (username,)).fetchone()
        if not row:
            return False
        try:
            cloud_pc_records = _load_cloud_pcs(include_disabled=True)
        except TypeError:
            cloud_pc_records = _load_cloud_pcs()
        owned_cloud_pcs = [pc.get('id') for pc in cloud_pc_records if pc.get('owner') == username]
        if owned_cloud_pcs:
            raise ValueError('User owns Cloud PC records; disable the account or explicitly resolve ownership first')
        conn.execute('DELETE FROM user_vm_access WHERE user_id = ?', (row['id'],))
        conn.execute('DELETE FROM user_resource_access WHERE user_id = ?', (row['id'],))
        conn.execute('DELETE FROM access_requests WHERE username = ?', (username,))
        conn.execute('DELETE FROM users WHERE id = ?', (row['id'],))
        conn.commit()
        return True
    finally:
        conn.close()

def _create_portal_token(username: str, is_admin: bool=False) -> str:
    secret = _portal_secret()
    if not secret:
        raise ValueError('Portal session secret is not configured')
    exp = int(time.time() + 30*24*3600)
    user = _get_user_by_username(username)
    payload = json.dumps({'u': username, 'exp': exp, 'admin': bool(is_admin), 'sv': int((user or {}).get('sessionVersion') or 1)}, separators=(',', ':'))
    mac = hmac.new(secret.encode('utf-8'), payload.encode('utf-8'), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{payload}.{mac}".encode('utf-8')).decode('utf-8')

def _verify_portal_token(token: str, *, require_approved=True):
    try:
        secret = _portal_secret()
        if not secret:
            return None
        raw = base64.urlsafe_b64decode(token.encode('utf-8')).decode('utf-8')
        payload, mac = raw.rsplit('.', 1)
        expected = hmac.new(secret.encode('utf-8'), payload.encode('utf-8'), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(mac, expected):
            return None
        data = json.loads(payload)
        if int(data.get('exp') or 0) < int(time.time()):
            return None
        user = _get_user_by_username(data.get('u') or '')
        if not user or user.get('disabled'):
            return None
        if int(data.get('sv') or 1) != int(user.get('sessionVersion') or 1):
            return None
        if require_approved and str(user.get('accountStatus') or 'pending') != 'approved':
            return None
        return user
    except Exception:
        return None

def _current_portal_user(*, require_approved=True):
    token = request.cookies.get('Portal-Auth')
    if not token:
        return None
    return _verify_portal_token(token, require_approved=require_approved)

def portal_auth_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        user = _current_portal_user()
        if not user:
            return jsonify({'ok': False, 'error': 'Unauthorized'}), 401
        if request.method not in ('GET', 'HEAD', 'OPTIONS') and not _same_origin_request():
            return jsonify({'ok': False, 'error': 'Cross-origin request rejected'}), 403
        request.portal_user = user
        return fn(*args, **kwargs)
    return wrapper

def _resource_key_for_name(name: str, *, host_id=None, resource_type='vm'):
    if _parse_resource_key(name):
        return name
    if resource_type == 'cloudpc' or _is_cloudpc(name):
        return _resource_key('cloudpc', 'external', name)
    _init_users_db()
    conn = _users_conn()
    try:
        sql = 'SELECT resource_key FROM resource_metadata WHERE resource_type = ? AND display_name = ?'
        params = [resource_type, name]
        if host_id:
            sql += ' AND host_id = ?'
            params.append(host_id)
        rows = conn.execute(sql, params).fetchall()
    finally:
        conn.close()
    if len(rows) == 1:
        return rows[0]['resource_key']
    if host_id == 'local' or (not host_id and not rows):
        return _resource_key('vm', 'local', name)
    return None


def _vm_access_mode(name: str, *, host_id=None, resource_key=None) -> str:
    key = resource_key or _resource_key_for_name(name, host_id=host_id)
    if key:
        _init_users_db()
        conn = _users_conn()
        try:
            row = conn.execute('SELECT access_mode FROM resource_metadata WHERE resource_key = ?', (key,)).fetchone()
        finally:
            conn.close()
        if row and str(row['access_mode']).lower() in ('public', 'restricted'):
            return str(row['access_mode']).lower()
    if (host_id or 'local') == 'local' and not _is_cloudpc(name):
        mode = str(_instance_meta(name).get('access_mode') or 'public').strip().lower()
        return mode if mode in ('public', 'restricted') else 'restricted'
    return 'restricted'


def _admin_vm_sso_enabled() -> bool:
    """Whether a valid Dashboard-Auth session may open restricted VMs."""
    cfg = _load_dashboard_settings()
    value = cfg.get('admin_vm_sso', True) if isinstance(cfg, dict) else True
    return value is not False


def _admin_vm_sso_authenticated() -> bool:
    return _admin_vm_sso_enabled() and _verify_v2_token(request.cookies.get('Dashboard-Auth', ''))


def _user_can_access_vm(user, name: str, *, host_id=None, resource_key=None) -> bool:
    key = resource_key or _resource_key_for_name(name, host_id=host_id)
    mode = (_vm_access_mode(name, host_id=host_id, resource_key=key)
            if host_id or resource_key else _vm_access_mode(name))
    if mode == 'public':
        return True
    if not user:
        return False
    if user.get('disabled') or str(user.get('accountStatus') or 'pending') != 'approved':
        return False
    if user.get('isAdmin'):
        return True
    if _is_cloudpc(name):
        pc = _load_cloud_pc(name)
        return bool(pc and pc.get('owner') == user.get('username'))
    assigned_keys = {item.get('resourceKey') for item in (user.get('assignedResources') or [])}
    if key and key in assigned_keys:
        return True
    # Compatibility for a pre-migration, uniquely named local assignment.
    return not key and name in set(user.get('assignedVms') or [])

def _portal_login_redirect(next_url: str):
    prefix = '/EpicVM' if request.path.startswith('/EpicVM/portal') else ''
    return redirect(prefix + '/portal/login?next=' + urlrequest.quote(_safe_portal_next(next_url), safe='/:?=&%'))

def _safe_portal_next(next_url: str) -> str:
    value = str(next_url or '/portal')
    parsed = urlparse(value)
    if not value.startswith('/') or value.startswith('//') or parsed.scheme or parsed.netloc:
        return '/portal'
    return value

def _render_vm_denied(name: str, user):
    next_url = request.path
    if request.query_string:
        next_url += '?' + request.query_string.decode('utf-8', 'ignore')
    # Keep the local-only return target safe in both URL and inline-script
    # contexts.  JSON permits angle brackets, but an HTML parser would still
    # treat a user-controlled </script> sequence as the end of this block.
    next_js = (json.dumps(_safe_portal_next(next_url))
               .replace('<', '\\u003c')
               .replace('>', '\\u003e')
               .replace('&', '\\u0026'))
    page = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EpicVM Login</title><style>body{{margin:0;font-family:Inter,system-ui,Arial;background:radial-gradient(circle at top,#101933 0%,#050816 58%,#03050d 100%);color:#e7f0f4;display:grid;place-items:center;min-height:100vh;padding:24px}}.card{{max-width:430px;width:100%;box-sizing:border-box;background:#071117;border:1px solid #1a2b33;border-top:2px solid #02bdf3;border-radius:5px;padding:34px;box-shadow:none}}.brand{{display:flex;align-items:center;gap:11px;border-bottom:1px solid #1a2b33;padding-bottom:20px;margin-bottom:26px}}.brand-mark{{display:grid;place-items:center;width:32px;height:32px;border-radius:5px;background:#02bdf3;color:#00131b;font-weight:900}}.brand-name{{font-size:18px;font-weight:700}}h1{{margin:0 0 8px;font-size:26px;font-weight:500;letter-spacing:-.025em}}.muted{{color:#9fb0b8;line-height:1.55}}input,button{{width:100%;box-sizing:border-box;padding:12px 14px;border-radius:4px;border:1px solid #29404a;background:#061016;color:#e7f0f4;margin-top:10px;font:inherit}}input:focus{{outline:2px solid rgba(2,189,243,.25);border-color:#02bdf3}}button{{background:#02bdf3;color:#00131b;border-color:#34cdf8;cursor:pointer;font-weight:700}}button:hover{{background:#35cdf6}}#err{{color:#ff9ab0!important;margin-top:10px}}</style></head><body><div class=card><div class=brand><span class=brand-mark>E</span><span class=brand-name>EpicVM</span></div><h1>VM Login</h1><div class=muted>Sign in to access restricted EpicVM instances.</div><form onsubmit="return doLogin(event)"><input id=u placeholder="Username" autocomplete="username" /><input id=p type=password placeholder="Password" autocomplete="current-password" /><button>Sign in</button><div id=err style="color:#fca5a5;margin-top:10px"></div></form></div><script>async function doLogin(e){{e.preventDefault();const r=await fetch('/portal/api/auth/login',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{username:document.getElementById('u').value,password:document.getElementById('p').value}})}});const j=await r.json().catch(()=>({{}}));if(j.ok){{location.href={next_js};return false}}document.getElementById('err').textContent=j.error||'Login failed';return false}}</script></body></html>'''
    return Response(page, mimetype='text/html')

def _enforce_vm_user_access(name: str, *, host_id=None, resource_key=None):
    host_id = host_id or str(request.values.get('host_id') or request.values.get('host') or '').strip() or None
    access_mode = (_vm_access_mode(name, host_id=host_id, resource_key=resource_key)
                   if host_id or resource_key else _vm_access_mode(name))
    if access_mode == 'public' or _admin_vm_sso_authenticated():
        return None
    user = _current_portal_user()
    next_url = request.path
    if request.query_string:
        next_url += '?' + request.query_string.decode('utf-8', 'ignore')
    if not user:
        return _portal_login_redirect(next_url)
    allowed = (_user_can_access_vm(user, name, host_id=host_id, resource_key=resource_key)
               if host_id or resource_key else _user_can_access_vm(user, name))
    if not allowed:
        return _render_vm_denied(name, user)
    request.portal_user = user
    return None

def _portal_vm_payload(name: str):
    items = [i for i in manager_json_list() if i.get('name') == name]
    vm = items[0] if items else {'name': name, 'status': 'Unknown', 'url': _build_vm_url(name)}
    vm['accessMode'] = _vm_access_mode(name, host_id=vm.get('host_id'))
    return vm

def _state_dir():
    return os.environ.get('BLOBEDASH_STATE', '/opt/blobe-vm')

def _repo_manager_path():
    # Fallback path to the repo-managed CLI inside the mounted state dir
    return os.path.join(_state_dir(), 'server', 'blobe-vm-manager')

def _inst_dir():
    return os.path.join(_state_dir(), 'instances')


def _instance_meta_path(name: str):
    return os.path.join(_inst_dir(), name, 'instance.json')


def _instance_meta(name: str):
    path = _instance_meta_path(name)
    try:
        if os.path.isfile(path):
            with open(path, 'r') as f:
                data = json.load(f)
                return data if isinstance(data, dict) else {}
    except Exception:
        pass
    return {}


def _set_instance_meta(name: str, key: str, value):
    path = _instance_meta_path(name)
    data = _instance_meta(name)
    if value in (None, ''):
        data.pop(key, None)
    else:
        data[key] = value
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    return data


def _guess_icon_mimetype(path: str) -> str:
    try:
        with open(path, 'rb') as f:
            header = f.read(16)
        if header.startswith(b'\x89PNG\r\n\x1a\n'):
            return 'image/png'
        if header.startswith(b'\xff\xd8\xff'):
            return 'image/jpeg'
        if header[:4] == b'RIFF' and header[8:12] == b'WEBP':
            return 'image/webp'
        if header.startswith(b'GIF87a') or header.startswith(b'GIF89a'):
            return 'image/gif'
        if header[:4] == b'\x00\x00\x01\x00':
            return 'image/x-icon'
    except Exception:
        pass
    return 'application/octet-stream'


def _send_icon_file(path: str):
    mimetype = _guess_icon_mimetype(path)
    if mimetype == 'application/octet-stream':
        abort(415)
    resp = send_file(path, mimetype=mimetype, conditional=False)
    resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    resp.headers['Pragma'] = 'no-cache'
    resp.headers['Expires'] = '0'
    return resp

def _flag_path(name: str, flag: str) -> str:
    return os.path.join(_inst_dir(), name, f'.{flag}')

def _set_flag(name: str, flag: str, on: bool = True):
    try:
        p = _flag_path(name, flag)
        if on:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, 'w') as f:
                f.write(str(int(time.time())))
        else:
            if os.path.isfile(p):
                os.remove(p)
    except Exception:
        pass

def _has_flag(name: str, flag: str, max_age_sec: int = 6*3600) -> bool:
    try:
        p = _flag_path(name, flag)
        if not os.path.isfile(p):
            return False
        if max_age_sec is None:
            return True
        st = os.stat(p)
        return (time.time() - st.st_mtime) < max_age_sec
    except Exception:
        return False

def _run_manager(*args):
    """Run the selected host manager with given args.

    If the primary manager doesn't support the command (prints Usage/unknown),
    fall back to the repo script. Returns (ok, stdout, stderr, returncode).
    """
    host = _vm_host()
    try:
        r = host.run_manager(*args, capture_output=True, text=True)
    except VmHostUnavailable:
        r = subprocess.CompletedProcess(host.command(*args), 127, '', 'not found')
    ok = (r.returncode == 0)
    errtxt = (r.stderr or '') + ('' if ok else ('\n' + (r.stdout or '')))
    # Heuristic: if command not recognized or prints usage, try fallback
    need_fallback = (
        (not ok) and (
            'Usage: blobe-vm-manager' in errtxt or
            'unknown' in errtxt.lower() or
            'not found' in errtxt.lower()
        )
    )
    if need_fallback:
        alt = _repo_manager_path()
        if os.path.isfile(alt):
            # If not executable, try invoking via bash
            cmd = [alt, *args] if os.access(alt, os.X_OK) else ['bash', alt, *args]
            r2 = subprocess.run(cmd, capture_output=True, text=True)
            return (r2.returncode == 0, (r2.stdout or '').strip(), (r2.stderr or '').strip(), r2.returncode)
    return (ok, (r.stdout or '').strip(), (r.stderr or '').strip(), r.returncode)

def _is_direct_mode():
    env = _read_env()
    return env.get('NO_TRAEFIK', '0') == '1'

def _request_host():
    try:
        host = request.headers.get('X-Forwarded-Host') or request.host or ''
        return (host.split(',')[0].strip().split(':')[0] if host else '')
    except Exception:
        return ''


def _external_base_url():
    try:
        proto = (request.headers.get('X-Forwarded-Proto') or request.scheme or 'http').split(',')[0].strip()
        host = (request.headers.get('X-Forwarded-Host') or request.headers.get('Host') or request.host or '').split(',')[0].strip()
        if host:
            return f'{proto}://{host}'
    except Exception:
        pass
    return ''

def _vm_host_port(cname: str) -> str:
    try:
        r = _docker('port', cname, '3000/tcp')
        if r.returncode == 0 and r.stdout:
            line = r.stdout.strip().splitlines()[0]
            parts = line.rsplit(':', 1)
            if len(parts) == 2 and parts[1].strip().isdigit():
                return parts[1].strip()
    except Exception:
        pass
    return ''

def _vm_backend_url(name: str, subpath: str = '') -> str:
    prefix = _vm_path_prefix(name)
    suffix = '/' + (subpath or '').lstrip('/') if subpath else '/'
    return f'http://127.0.0.1:20000{prefix}{suffix}' if _is_direct_mode() else f'http://127.0.0.1:3000{prefix}{suffix}'

def _vm_path_prefix(name: str) -> str:
    base_path = _read_env().get('BASE_PATH', '/vm') or '/vm'
    if not base_path.startswith('/'):
        base_path = '/' + base_path
    base_path = base_path.rstrip('/')
    inst_dir = os.path.join(_state_dir(), 'instances', name)
    override = ''
    try:
        meta = os.path.join(inst_dir, '.meta.json')
        if os.path.isfile(meta):
            data = json.load(open(meta, 'r'))
            override = (data.get('path_override') or '').strip()
    except Exception:
        override = ''
    prefix = override or f'{base_path}/{name}'
    if not prefix.startswith('/'):
        prefix = '/' + prefix
    return prefix.rstrip('/')


def _build_vm_embed_url(name: str) -> str:
    if _is_direct_mode():
        return _build_vm_url(name)
    base = _external_base_url()
    root = f"{base}/vmraw/{name}" if base else f"/vmraw/{name}"
    return f"{root}/vnc/index.html?autoconnect=1&resize=remote&clipboard_up=true&clipboard_down=true&clipboard_seamless=true&show_control_bar=true&path=/vmraw/{name}/websockify"


def _build_vm_url(name: str, host_id: str | None = None) -> str:
    """Build a browser URL for a local VM or a host-qualified RemoteVM."""
    if host_id and host_id != 'local':
        prefix = _vm_path_prefix(name)
        base = _external_base_url()
        root = f'{base}{prefix}' if base else prefix
        return f'{root}/?host_id={url_quote(str(host_id), safe="")}'
    if _is_direct_mode():
        host = _request_host()
        if not host:
            return ''
        cname = f'blobevm_{name}'
        hp = _vm_host_port(cname)
        if hp:
            return f'http://{host}:{hp}/'
    prefix = _vm_path_prefix(name)
    base = _external_base_url()
    if base:
        return f'{base}{prefix}/'
    return f'{prefix}/'


def _build_remote_console_url(name: str, host_id: str, route_prefix: str) -> str:
    """Build a Moonlight URL only from an exact, ready-owned route."""
    safe_name = str(name or '').strip().lower()
    route = str(route_prefix or '').strip()
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', safe_name):
        return _build_vm_url(name, host_id=host_id)
    expected = f'/vm/{safe_name}/'
    if route == expected:
        route_name = safe_name
    else:
        scoped = f'/vm/{safe_name}--'
        if not route.startswith(scoped) or not route.endswith('/'):
            return _build_vm_url(name, host_id=host_id)
        route_name = route[4:-1]
        if not re.fullmatch(rf'{re.escape(safe_name)}--[a-z0-9][a-z0-9._-]{{0,62}}', route_name):
            return _build_vm_url(name, host_id=host_id)
    base = _external_base_url()
    root = f'{base}{route}' if base else route
    return f'{root}?host_id={url_quote(str(host_id), safe="")}'


def _build_remote_console_warmup_url(name: str, host_id: str) -> str:
    """Build the non-Moonlight recovery page for a remote VM.

    A remote inventory record may be Running before its guest management and
    streaming path is usable.  Never point that state at the generic VM page:
    that page is a permanent unreachable screen and cannot transition to
    Moonlight.  The recovery endpoint is deliberately same-origin and carries
    only the host selector.
    """
    base = _external_base_url()
    safe_name = url_quote(str(name or '').strip().lower(), safe='')
    safe_host = url_quote(str(host_id or '').strip(), safe='')
    path = f'/dashboard/console/{safe_name}/'
    root = f'{base}{path}' if base else path
    return f'{root}?host_id={safe_host}'

def manager_json_list(host_id=None):
    """Return a list of instances with best-effort status and URL.
    Tries the selected provider's manager list first. Falls back to scanning
    the instances directory and asking the provider for each URL individually.
    """
    host_provider = _vm_host(host_id)
    # _vm_host(None) resolves request values for callers such as
    # /dashboard/api/list. Preserve that resolved identity when constructing
    # links; otherwise remote cards silently receive localhost URLs.
    effective_host_id = str(host_id or getattr(host_provider, 'host_id', 'local') or 'local').strip() or 'local'
    is_remote_host = getattr(host_provider, 'kind', 'local') == 'remote' and effective_host_id != 'local'
    instances = []
    try:
        # Fast path: let the provider parse its inventory while preserving the
        # existing manager command and output format.
        instances = host_provider.list_vms()
        if is_remote_host:
            # A remote provider owns its inventory; never fall back to the
            # dashboard server's local instance directory for an empty result.
            normalized = host_provider.normalize_inventory(instances)
            for item in normalized:
                if item.get('name'):
                    if item.get('consoleReady') and item.get('consoleRoutePrefix'):
                        item['url'] = _build_remote_console_url(item['name'], effective_host_id, item.get('consoleRoutePrefix'))
                    else:
                        item['url'] = _build_remote_console_warmup_url(item['name'], effective_host_id)
            if hasattr(VM_HOST_REGISTRY, 'remember_inventory'):
                try:
                    VM_HOST_REGISTRY.remember_inventory(effective_host_id, normalized)
                except Exception:
                    pass
            return normalized
        if instances:
            # In direct mode, override URL with host:published-port (or manager port) to avoid container IPs
            if _is_direct_mode():
                host = _request_host()
                for it in instances:
                    cname = f"blobevm_{it['name']}"
                    hp = _vm_host_port(cname)
                    if not hp:
                        try:
                            hp = host_provider.check_output('port', it['name'], text=True).strip()
                        except Exception:
                            hp = ''
                    # Record explicit port for frontend
                    if hp and hp.isdigit():
                        it['port'] = hp
                    if hp and host:
                        it['url'] = f"http://{host}:{hp}/"
            else:
                for it in instances:
                    it['url'] = _build_vm_url(it['name'])
            # Apply transient statuses (e.g., rebuilding/updating)
            for it in instances:
                try:
                    if _has_flag(it['name'], 'rebuilding'):
                        it['status'] = 'Rebuilding...'
                    elif _has_flag(it['name'], 'updating'):
                        it['status'] = 'Updating...'
                except Exception:
                    pass
            return host_provider.normalize_inventory(instances)
    except VmHostUnavailable:
        # A remote host owns its inventory. Falling back to this server's
        # instance directory would relabel local VMs as remote and can send
        # later actions to the wrong destination.
        if is_remote_host:
            cached = VM_HOST_REGISTRY.cached_inventory(effective_host_id) if hasattr(VM_HOST_REGISTRY, 'cached_inventory') else []
            if cached:
                for item in cached:
                    item['host_online'] = False
                    item['status'] = 'offline'
                    if item.get('name'):
                        if item.get('consoleReady') and item.get('consoleRoutePrefix'):
                            item['url'] = _build_remote_console_url(item['name'], effective_host_id, item.get('consoleRoutePrefix'))
                        else:
                            item['url'] = _build_remote_console_warmup_url(item['name'], effective_host_id)
                return cached
            raise
    except Exception:
        # Local discovery remains best-effort for legacy deployments. A remote
        # provider must never fall back to this server's instance directory.
        if is_remote_host:
            raise
        # likely docker CLI or manager is not present -> fall back
        pass

    # Fallback: scan instance folders and resolve URL per instance
    inst_root = os.path.join(_state_dir(), 'instances')
    try:
        names = [n for n in os.listdir(inst_root) if os.path.isdir(os.path.join(inst_root, n))]
    except Exception:
        names = []
    # Cache docker ps output if docker exists
    docker_status = {}
    try:
        out = _docker('ps', '-a', '--format', '{{.Names}} {{.Status}}')
        if out.returncode == 0:
            for line in out.stdout.splitlines():
                if not line.strip():
                    continue
                parts = line.split(None, 1)
                if parts:
                    docker_status[parts[0]] = parts[1] if len(parts) > 1 else ''
    except Exception:
        pass
    for name in sorted(names):
        url = ''
        cname = f'blobevm_{name}'
        status = docker_status.get(cname, '') or ''
        if not status:
            status = '(unknown)'
        port = ''
        # In direct mode, compute URL using host published port
        if _is_direct_mode():
            host = _request_host()
            hp = _vm_host_port(cname)
            if not hp:
                try:
                    hp = host_provider.check_output('port', name, text=True).strip()
                except Exception:
                    hp = ''
            if hp and host:
                url = f"http://{host}:{hp}/"
            else:
                # Fallback to manager per-VM URL (may be container IP, but last resort)
                try:
                    url = host_provider.check_output('url', name, text=True).strip()
                except Exception:
                    url = ''
            if hp and hp.isdigit():
                port = hp
        else:
            url = _build_vm_url(name)
        # Transient status override
        if _has_flag(name, 'rebuilding'):
            status = 'Rebuilding...'
        elif _has_flag(name, 'updating'):
            status = 'Updating...'
        inst = {'name': name, 'status': status, 'url': url}
        if port:
            inst['port'] = port
        instances.append(inst)
    return host_provider.normalize_inventory(instances)

def _read_env():
    env_path = os.path.join(_state_dir(), '.env')
    data = {}
    try:
        with open(env_path, 'r') as f:
            for line in f:
                if not line.strip() or line.strip().startswith('#'):
                    continue
                if '=' in line:
                    k, v = line.split('=', 1)
                    v = v.strip().strip('\n').strip().strip("'\"")
                    data[k.strip()] = v
    except Exception:
        pass
    return data

def _write_env_kv(updates: dict):
    env_path = os.path.join(_state_dir(), '.env')
    existing = _read_env()
    existing.update({k: str(v) for k, v in updates.items()})
    # Write back preserving simple KEY='VAL' format
    lines = []
    for k, v in existing.items():
        if v is None:
            v = ''
        # single-quote with escaping
        vq = "'" + str(v).replace("'", "'\\''") + "'"
        lines.append(f"{k}={vq}")
    try:
        with open(env_path, 'w') as f:
            f.write("\n".join(lines) + "\n")
        return True
    except Exception:
        return False

def _docker(*args):
    return subprocess.run(['docker', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def _docker_inspect_vm(name: str):
    cname = f'blobevm_{name}'
    r = _docker('inspect', cname)
    if r.returncode != 0:
        return None, r.stderr.strip() or 'inspect failed'
    try:
        data = json.loads(r.stdout or '[]')
        if not data:
            return None, 'not-found'
        return data[0], None
    except Exception as e:
        return None, str(e)


def _vm_status_payload(name: str, *, include_optimizer: bool = True):
    info, err = _docker_inspect_vm(name)
    url = _build_vm_url(name) or ''
    payload = {
        'ok': True,
        'name': name,
        'url': url,
        'exists': False,
        'running': False,
        'healthy': False,
        'state': 'not-found',
        'status': 'not-found',
        'detail': err or 'VM container was not found',
        'crashed': False,
        'startedAt': None,
        'finishedAt': None,
        'exitCode': None,
        'error': '',
        'port': _vm_host_port(f'blobevm_{name}') or ''
    }
    if not info:
        return payload
    state = (info.get('State') or {}) if isinstance(info, dict) else {}
    payload['exists'] = True
    payload['running'] = bool(state.get('Running'))
    payload['healthy'] = (state.get('Health') or {}).get('Status') == 'healthy' if isinstance(state.get('Health'), dict) else payload['running']
    payload['status'] = state.get('Status') or ('running' if payload['running'] else 'stopped')
    payload['state'] = payload['status']
    payload['detail'] = state.get('Error') or state.get('Status') or ''
    payload['startedAt'] = state.get('StartedAt')
    payload['finishedAt'] = state.get('FinishedAt')
    payload['exitCode'] = state.get('ExitCode')
    payload['error'] = state.get('Error') or ''
    oomkilled = bool(state.get('OOMKilled'))
    restarting = bool(state.get('Restarting'))
    payload['oomKilled'] = oomkilled
    payload['restarting'] = restarting
    payload['crashed'] = (not payload['running']) and (
        (payload['exitCode'] not in (None, 0)) or
        oomkilled or
        bool(payload['error']) or
        restarting or
        payload['status'] == 'dead'
    )
    if include_optimizer:
        try:
            opt = dash_optimizer.status()
            vm_states = ((opt.get('stats') or {}).get('vmStates') or []) if isinstance(opt, dict) else []
            vm_meta = next((v for v in vm_states if v.get('name') == name), None)
            if vm_meta:
                payload['optimizer'] = vm_meta
                payload['recoveryState'] = vm_meta.get('recoveryState')
                payload['protectedVm'] = bool(vm_meta.get('protected'))
                payload['activityClass'] = vm_meta.get('activityClass')
                payload['profile'] = vm_meta.get('profile')
                payload['unstable'] = bool(vm_meta.get('unstable'))
            try:
                payload['notifications'] = dash_optimizer.get_vm_notifications(name)
            except Exception:
                payload['notifications'] = []
        except Exception:
            pass
    return payload


def _vm_status_payload_bounded(name: str, *, timeout_s: float = 6):
    """Portal-safe status lookup. Skips the heavy optimizer gather (the portal
    does not need it) and guarantees the call returns within timeout_s by
    running in a daemon thread with a join guard."""
    result = {}

    def worker():
        try:
            result['payload'] = _vm_status_payload(name, include_optimizer=False)
        except Exception as exc:
            result['error'] = exc

    th = threading.Thread(target=worker, daemon=True)
    th.start()
    th.join(timeout_s)
    if 'payload' in result:
        return result['payload']
    if 'error' in result:
        raise result['error']
    # Timed out: return a best-effort "loading" payload so the list never hangs.
    return {
        'ok': False, 'name': name, 'url': _build_vm_url(name) or '',
        'exists': True, 'running': False, 'healthy': False,
        'state': 'loading', 'status': 'loading', 'detail': 'status pending',
        'crashed': False, 'recoveryState': 'healthy', 'profile': 'desktop',
    }


def _tail_vm_logs(name: str, lines: int = 160) -> str:
    cname = f'blobevm_{name}'
    try:
        r = _docker('logs', '--tail', str(lines), cname)
        if r.returncode == 0:
            return (r.stdout or '') + (("\n" + r.stderr) if r.stderr else '')
        return r.stderr.strip() or r.stdout.strip() or ''
    except Exception as e:
        return str(e)


def _recover_vm(name: str, source: str = 'manual', aggressive: bool = True, mode: str = 'standard'):
    attempts = []
    host = _vm_host()
    def current_status():
        if getattr(host, 'kind', 'local') == 'remote':
            envelope = host.status(name)
            raw = envelope.get('vm') if isinstance(envelope, dict) else envelope
            vm = normalize_remote_vm_record(raw if isinstance(raw, dict) else {})
            return {
                **vm, 'ok': True, 'placement': 'remote', 'host_id': host.host_id,
                'host_name': host.host_name, 'healthy': bool(vm.get('running')),
                'exists': True,
            }
        return _vm_status_payload_bounded(name)
    before = current_status()
    recovery_state = str(before.get('recoveryState') or '').lower()
    protected_vm = bool(before.get('protectedVm'))
    if before.get('running') and not before.get('crashed'):
        return {'ok': True, 'recovered': True, 'attempts': attempts, 'status': before, 'message': 'VM already running', 'mode': mode}
    if mode == 'cautious' or protected_vm:
        sequence = ['start']
        if before.get('crashed'):
            sequence.append('restart')
    elif mode == 'aggressive' or recovery_state == 'restart-loop':
        sequence = ['start', 'restart', 'recreate']
    else:
        sequence = ['start']
        if before.get('crashed') or aggressive:
            sequence.append('restart')
        if aggressive:
            sequence.append('recreate')
    for action in sequence:
        try:
            proc = host.run_manager(action, name, capture_output=True, text=True, timeout=60)
            attempt = {
                'action': action,
                'ok': proc.returncode == 0,
                'stdout': (proc.stdout or '').strip()[-2000:],
                'stderr': (proc.stderr or '').strip()[-2000:],
                'returncode': proc.returncode,
            }
        except Exception as e:
            attempt = {'action': action, 'ok': False, 'stdout': '', 'stderr': str(e), 'returncode': None}
        attempts.append(attempt)
        time.sleep(2.5)
        current = current_status()
        if current.get('running') and (current.get('healthy') or current.get('state') == 'running'):
            return {'ok': True, 'recovered': True, 'attempts': attempts, 'status': current, 'message': f'VM recovered via {action}', 'source': source, 'mode': mode}
        # Chain actions only when needed: if this action succeeded but the VM
        # is not yet healthy, give it a short grace period before the next
        # step; if it failed outright, continue to the next recovery action.
        if attempt['ok'] and action == 'start':
            # start worked but not marked healthy yet; wait a little longer
            # before deciding to escalate to restart/recreate.
            time.sleep(6)
            current = current_status()
            if current.get('running') and (current.get('healthy') or current.get('state') == 'running'):
                return {'ok': True, 'recovered': True, 'attempts': attempts, 'status': current, 'message': f'VM recovered via {action}', 'source': source, 'mode': mode}
    final = current_status()
    return {'ok': False, 'recovered': False, 'attempts': attempts, 'status': final, 'message': 'VM recovery failed', 'source': source, 'mode': mode}


def _escalate_vm_to_hermes(name: str, reason: str, extra=None):
    """Queue a Hermes recovery escalation.

    The dashboard container cannot run the host's ``hermes`` CLI directly, so
    this only writes the ticket + a 'queued' status file. A host-side watcher
    (epicvm-escalation-watcher) picks up the ticket, runs ``hermes`` on the
    host where the binary actually lives, and writes the final status.
    """
    extra = extra or {}
    ts = int(time.time())
    payload = {
        'vm': name,
        'reason': reason,
        'status': _vm_status_payload_bounded(name),
        'logs': _tail_vm_logs(name, 120),
        'extra': extra,
        'ts': ts,
        'host': socket.gethostname(),
    }
    esc_dir = os.path.join(_state_dir(), 'dashboard', 'escalations')
    os.makedirs(esc_dir, exist_ok=True)
    esc_path = os.path.join(esc_dir, f"{name}-{ts}.json")
    status_path = os.path.join(esc_dir, f"{name}-{ts}.status.json")
    with open(esc_path, 'w') as f:
        json.dump(payload, f, indent=2)
    _write_escalation_status(status_path, {'state': 'queued', 'startedAt': ts, 'hostHandoff': True})
    return {'ok': True, 'queued': True, 'state': 'queued', 'path': esc_path, 'statusPath': status_path, 'payload': payload}


def _write_escalation_status(status_path: str, data: dict):
    try:
        with open(status_path, 'w') as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass

@app.get('/dashboard/api/modeinfo')
@auth_required
def api_modeinfo():
    env = _read_env()
    merged = env.get('NO_TRAEFIK', '0') == '0'
    base_path = env.get('BASE_PATH', '/vm')
    domain = env.get('BLOBEVM_DOMAIN', '')
    dash_port = env.get('DASHBOARD_PORT', '')
    # Show the host the user used to reach the dashboard
    ip = _request_host() or ''
    return jsonify({'merged': merged, 'basePath': base_path, 'domain': domain, 'dashPort': dash_port, 'ip': ip})


def _settings_path():
    return os.path.join(_state_dir(), 'dashboard_settings.json')


def _load_dashboard_settings():
    p = _settings_path()
    try:
        if os.path.isfile(p):
            with open(p, 'r') as f:
                data = json.load(f)
                if isinstance(data, dict):
                    data['favicon'] = _safe_favicon_reference(data.get('favicon', ''))
                    return data
    except Exception:
        pass
    # defaults
    return {'title': DASHBOARD_TITLE, 'favicon': ''}


def _save_dashboard_settings(cfg: dict):
    p = _settings_path()
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w') as f:
            json.dump(cfg, f)
        return True
    except Exception:
        return False


@app.get('/dashboard/favicon.ico')
def dashboard_favicon():
    # Serve a saved favicon if present under state_dir/dashboard/favicon.ico
    fav_path = os.path.join(_state_dir(), 'dashboard', 'favicon.ico')
    if os.path.isfile(fav_path):
        return _send_icon_file(fav_path)
    # If no local file, try to redirect to configured favicon URL
    cfg = _load_dashboard_settings()
    if cfg.get('favicon'):
        favicon = str(cfg.get('favicon') or '').strip()
        if favicon.startswith('/') and not favicon.startswith('//'):
            safe_favicon = favicon
        else:
            try:
                safe_favicon = _validate_favicon_url(favicon)
            except ValueError:
                abort(404)
        return '', 302, {'Location': safe_favicon, 'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0', 'Pragma': 'no-cache', 'Expires': '0'}
    # Not found
    abort(404)


@app.get('/dashboard/api/settings')
@auth_required
def api_get_settings():
    cfg = _load_dashboard_settings()
    # Provide a favicon URL that the template can consume: prefer local served path if file exists
    fav_local = os.path.join(_state_dir(), 'dashboard', 'favicon.ico')
    if os.path.isfile(fav_local):
        cfg['favicon_url'] = '/dashboard/favicon.ico'
    else:
        cfg['favicon_url'] = cfg.get('favicon','')
    return jsonify(cfg)


@app.post('/dashboard/api/settings')
@auth_required
def api_set_settings():
    if request.content_length and request.content_length > _FAVICON_MAX_BYTES:
        return jsonify({'ok': False, 'error': 'Request exceeds 512 KiB'}), 413
    data = request.get_json(silent=True) if request.is_json else None
    data = data if isinstance(data, dict) else request.values
    title = str(data.get('title','') or '').strip()
    favicon = str(data.get('favicon','') or '').strip()
    cfg = _load_dashboard_settings()
    if title:
        cfg['title'] = title
    if 'adminVmSso' in data or 'admin_vm_sso' in data:
        raw_sso = data.get('adminVmSso', data.get('admin_vm_sso'))
        if isinstance(raw_sso, str):
            raw_sso = raw_sso.strip().lower() in ('1', 'true', 'yes', 'on')
        cfg['admin_vm_sso'] = bool(raw_sso)
    # Allow setting the v2 dashboard admin password from the old dashboard settings UI
    # Do not write the legacy dashboard password. New credentials are managed
    # exclusively by BLOBEDASH_USER/BLOBEDASH_PASS in /opt/blobe-vm/.env.
    # If favicon is empty string, clear both saved file and url
    if favicon == '':
        cfg['favicon'] = ''
        # remove local file if exists
        try:
            fav_local = os.path.join(_state_dir(), 'dashboard', 'favicon.ico')
            if os.path.isfile(fav_local):
                os.remove(fav_local)
        except Exception:
            pass
    else:
        if favicon.startswith('/') and not favicon.startswith('//'):
            cfg['favicon'] = favicon
        else:
            try:
                cfg['favicon'] = _validate_favicon_url(favicon)
            except ValueError as exc:
                return jsonify({'ok': False, 'error': str(exc)}), 400
        
    ok = _save_dashboard_settings(cfg)
    return jsonify({'ok': bool(ok)})


# Upload endpoints: accept multipart file uploads for global and per-VM favicons
@app.post('/dashboard/api/upload-favicon')
@auth_required
def api_upload_favicon():
    try:
        f = request.files.get('file')
        content = _read_favicon_upload(f)
        ddir = os.path.join(_state_dir(), 'dashboard')
        os.makedirs(ddir, exist_ok=True)
        outp = os.path.join(ddir, 'favicon.ico')
        _write_favicon_atomically(outp, content)
        # clear stored URL in settings so local file is preferred
        cfg = _load_dashboard_settings()
        cfg['favicon'] = ''
        _save_dashboard_settings(cfg)
        return jsonify({'ok': True})
    except ValueError as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    except Exception:
        app.logger.exception('failed to upload dashboard favicon')
        return jsonify({'ok': False, 'error': 'Unable to save favicon'}), 500


@app.post('/dashboard/api/upload-vm-favicon/<name>')
@auth_required
def api_upload_vm_favicon(name):
    try:
        safe = _validate_vm_name(name)
        f = request.files.get('file')
        content = _read_favicon_upload(f)
        ddir = os.path.join(_state_dir(), 'dashboard', 'vm-fav')
        os.makedirs(ddir, exist_ok=True)
        outp = os.path.join(ddir, f"{safe}.ico")
        _write_favicon_atomically(outp, content)
        return jsonify({'ok': True})
    except ValueError as e:
        return jsonify({'ok': False, 'error': str(e)}), 400
    except Exception:
        app.logger.exception('failed to upload VM favicon')
        return jsonify({'ok': False, 'error': 'Unable to save favicon'}), 500


    # Serve dashboard v2 production assets requested from absolute `/assets/*` paths
    @app.route('/assets/<path:path>')
    def serve_dashboard_v2_root_assets(path):
        base = os.path.join(_state_dir(), 'dashboard_v2')
        assets_dir = os.path.join(base, 'dist', 'assets')
        cand = os.path.join(assets_dir, path)
        if os.path.isfile(cand):
            return send_from_directory(assets_dir, path)
        # not found here - 404 and let other handlers handle it if needed
        return 'Not found', 404


    # Also handle requests that include the Dashboard prefix explicitly
    @app.route('/Dashboard/assets/<path:path>')
    def serve_dashboard_v2_prefixed_assets(path):
        base = os.path.join(_state_dir(), 'dashboard_v2')
        assets_dir = os.path.join(base, 'dist', 'assets')
        cand = os.path.join(assets_dir, path)
        if os.path.isfile(cand):
            return send_from_directory(assets_dir, path)
        return 'Not found', 404


@app.get('/dashboard/auth/vm/<name>')
def dashboard_vm_forward_auth(name):
    if name.startswith('seat-'):
        record = globals().get('_host_game_stream_record', lambda _name: None)(name)
        user = _current_portal_user()
        admin = _admin_vm_sso_authenticated()
        if not record or not (admin or (user and record['realm'] == 'portal' and record['username'] == user['username'])):
            return Response('Game session is unavailable.', 403, {'Cache-Control': 'no-store'})
        if not _console_orchestrator().has_auto_login(name):
            return Response('Game stream is preparing.', 503, {'Cache-Control': 'no-store', 'Retry-After': '3'})
        return Response('OK', 200, {'Cache-Control': 'no-store'})
    if _admin_vm_sso_authenticated():
        authenticated = True
    else:
        user = _current_portal_user()
        next_url = request.headers.get('X-Forwarded-Uri') or request.args.get('next') or f'/dashboard/vm/{name}/'
        ext_base = _external_base_url()
        if not user:
            login_path = '/portal/login?next=' + urlrequest.quote(next_url, safe='/:?=&%')
            login_url = f'{ext_base}{login_path}' if ext_base else login_path
            return Response('', 302, {'Location': login_url})
        if not _user_can_access_vm(user, name):
            # Cloud PCs are owner-scoped (not in assignedVms); allow the owner.
            if _is_cloudpc(name):
                pc = _load_cloud_pc(name)
                if pc and pc['owner'] == user['username']:
                    authenticated = True
                else:
                    denied_path = '/dashboard/vm/' + urlrequest.quote(name, safe='') + '/'
                    denied_url = f'{ext_base}{denied_path}' if ext_base else denied_path
                    return Response('', 302, {'Location': denied_url})
            else:
                denied_path = '/dashboard/vm/' + urlrequest.quote(name, safe='') + '/'
                denied_url = f'{ext_base}{denied_path}' if ext_base else denied_path
                return Response('', 302, {'Location': denied_url})
        else:
            authenticated = True
    if authenticated:
        # Cloud PC stream gate: ensure the owner's proxy is up and paired.
        if _is_cloudpc(name):
            pc = _load_cloud_pc(name)
            if not pc or not pc.get('paired'):
                response = Response('Cloud PC is not paired yet.', status=503)
                response.headers['Retry-After'] = '5'
                response.headers['Cache-Control'] = 'no-store'
                response.headers['X-EpicVM-Console-Code'] = 'console_not_paired'
                return response
            # Best-effort: ensure proxy container is running before granting.
            try:
                if not _cp_moonlight_proxy_up(name):
                    _cp_start(name)
            except Exception:
                pass
            return Response('OK', 200)
        forwarded_uri = request.headers.get('X-Forwarded-Uri', '')
        if _is_moonlight_host_api_request(forwarded_uri):
            host_id = _console_route_host_id(name, forwarded_uri)
            if host_id:
                try:
                    _remote_console_forward_auth_verify(name, host_id)
                except (ConsoleOrchestrationError, VmHostUnavailable) as exc:
                    response = Response('Remote console is recovering; retry shortly.', status=503)
                    response.headers['Retry-After'] = '3'
                    response.headers['Cache-Control'] = 'no-store'
                    response.headers['X-EpicVM-Console-Code'] = _safe_console_retry_code(getattr(exc, 'code', 'console_reconcile_failed'), 'console_reconcile_failed')
                    return response
                except Exception:
                    response = Response('Remote console is recovering; retry shortly.', status=503)
                    response.headers['Retry-After'] = '3'
                    response.headers['Cache-Control'] = 'no-store'
                    response.headers['X-EpicVM-Console-Code'] = 'console_reconcile_failed'
                    return response
        return Response('OK', 200)
    return Response('OK', 200)


@app.get('/dashboard/console/<name>/')
@admin_auth_required
def dashboard_console_entry(name):
    safe = str(name or '').strip().lower()
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', safe):
        return Response('Invalid VM name.', 400)

    # Remote inventory is authoritative for power state, but Running is not
    # equivalent to a usable guest/stream.  Send the card to this bounded
    # warm-up endpoint instead of the generic VM page, which otherwise remains
    # on the permanent "unreachable" screen and never transitions to Moonlight.
    requested_host_id = str(request.args.get('host_id') or '').strip()
    if requested_host_id and requested_host_id != 'local':
        try:
            reconciled = _reconcile_remote_console(safe, requested_host_id, wait=False)
            route_prefix = str(reconciled.get('routePrefix') or '').strip()
            if reconciled.get('healthy') and route_prefix:
                response = redirect(_build_remote_console_url(safe, requested_host_id, route_prefix))
                response.headers['Cache-Control'] = 'no-store'
                response.headers['Referrer-Policy'] = 'no-referrer'
                return response
            code = _safe_console_retry_code(
                reconciled.get('failureCode') or 'console_repair_pending',
                'console_repair_pending',
            )
        except (ConsoleOrchestrationError, VmHostUnavailable) as exc:
            code = _safe_console_retry_code(
                getattr(exc, 'code', 'console_repair_pending'),
                'console_repair_pending',
            )
        except Exception:
            code = 'console_reconcile_failed'
        retry_path = f'/dashboard/console/{url_quote(safe, safe="")}/'
        retry_url = f'{retry_path}?host_id={url_quote(requested_host_id, safe="")}'
        safe_code = html_escape(code, quote=True)
        safe_name = html_escape(safe, quote=True)
        safe_retry_url = html_escape(retry_url, quote=True)
        page = (
            '<!doctype html><html><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<meta http-equiv="refresh" content="3;url=' + safe_retry_url + '">'
            '<title>Remote console recovering</title>'
            '<style>body{margin:0;background:#050816;color:#e7f0f4;font:15px system-ui;display:grid;place-items:center;min-height:100vh}'
            '.card{width:min(560px,calc(100vw - 48px));background:#071117;border:1px solid #1a2b33;padding:28px;box-sizing:border-box}'
            '.muted{color:#9db2bb}code{color:#7ee7ff}</style></head><body><main class="card">'
            '<h1>Remote console warming up</h1>'
            '<p>The VM is running, but its guest management or streaming path is still initializing.</p>'
            '<p class="muted">EpicVM will retry automatically. This is a readiness state, not a failed VM.</p>'
            '<p class="muted">VM: <strong>' + safe_name + '</strong> · code: <code>' + safe_code + '</code></p>'
            '<script>setTimeout(()=>location.replace(' + json.dumps(retry_url) + '),3000)</script>'
            '</main></body></html>'
        )
        response = Response(page, status=200, mimetype='text/html')
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        response.headers['Retry-After'] = '3'
        response.headers['X-EpicVM-Console-Code'] = code
        return response

    orchestrator = _console_for_vm(safe)
    if _moonlight_console(orchestrator) and orchestrator.has_auto_login(safe):
        return redirect(f'/vm/{url_quote(safe, safe="")}/')
    return redirect(f'/dashboard/console/{url_quote(safe, safe="")}/setup')


@app.get('/dashboard/console/<name>/launch')
def dashboard_console_launch(name):
    denied = _enforce_vm_user_access(name)
    if denied is not None:
        return denied
    try:
        safe = str(name or '').strip().lower()
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', safe):
            return Response('Invalid VM name.', 400)
        orchestrator = _console_for_vm(safe)
        if not orchestrator.has_auto_login(safe):
            if _admin_vm_sso_authenticated():
                return redirect(f'/dashboard/console/{url_quote(safe, safe="")}/setup')
            return Response('Automatic console login must be configured by an administrator.', 409)
        if _moonlight_console(orchestrator):
            response = redirect(f'/vm/{url_quote(safe, safe="")}/')
            response.headers['Cache-Control'] = 'no-store'
            response.headers['Referrer-Policy'] = 'no-referrer'
            return response
        data = orchestrator.build_json_auth_data(safe)
        client_id = base64.urlsafe_b64encode(f'{safe}\0c\0json'.encode('utf-8')).decode('ascii').rstrip('=')
        prefix = f'/vm/{url_quote(safe, safe="")}'
        token_endpoint = f'{prefix}/api/tokens'
        target = f'{prefix}/#/client/{client_id}'
        # Exchange the short-lived JSON assertion before navigation, then keep
        # it out of browser history.  Guacamole's resulting session token is
        # sufficient for ordinary refreshes of the clean client URL.
        response = Response(
            '<!doctype html><meta charset="utf-8"><title>Opening console</title>'
            '<body style="background:#000;color:#ddd;font:16px system-ui">Opening secure console…'
            '<script>(async()=>{'
            'localStorage.removeItem("GUAC_AUTH_TOKEN");sessionStorage.removeItem("GUAC_AUTH_TOKEN");'
            f'const body=new URLSearchParams({{data:{json.dumps(data)}}});'
            f'const response=await fetch({json.dumps(token_endpoint)},{{method:"POST",headers:{{"Content-Type":"application/x-www-form-urlencoded"}},body}});'
            'const result=await response.json();if(!response.ok||!result.authToken)throw new Error("authentication failed");'
            'localStorage.setItem("GUAC_AUTH_TOKEN",JSON.stringify(result.authToken));'
            f'location.replace({json.dumps(target)});'
            '})().catch(()=>{document.body.textContent="Secure console authentication failed. Return to EpicVM and try again."});</script>',
            mimetype='text/html',
        )
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        response.headers['Referrer-Policy'] = 'no-referrer'
        return response
    except ConsoleOrchestrationError as exc:
        return Response(str(exc), int(getattr(exc, 'status', 502) or 502))


@app.get('/dashboard/console/<name>/setup')
@admin_auth_required
def dashboard_console_setup(name):
    safe = str(name or '').strip().lower()
    csrf = _csrf_token_for_session()
    orchestrator = _console_for_vm(safe)
    if orchestrator.has_auto_login(safe):
        return redirect(f'/dashboard/console/{url_quote(safe, safe="")}/launch')
    if _moonlight_console(orchestrator):
        return Response(f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pair Sunshine console</title><style>body{{margin:0;background:#050816;color:#e7f0f4;font:15px Inter,system-ui;display:grid;place-items:center;min-height:100vh}}form{{width:min(460px,calc(100vw - 48px));background:#071117;border:1px solid #1a2b33;padding:30px}}input,button{{display:block;box-sizing:border-box;width:100%;margin-top:12px;padding:12px;background:#061016;color:#e7f0f4;border:1px solid #29404a}}button{{background:#02bdf3;color:#00131b;font-weight:700}}#error{{color:#ff9ab0;margin-top:12px}}</style></head><body><form id="setup"><h1>Pair Sunshine</h1><p>Enter the existing Sunshine web account for this VM. The credentials are used only for this pairing request and are never stored by EpicVM.</p><input id="sunshineUsername" autocomplete="username" placeholder="Sunshine username" required><input id="sunshinePassword" type="password" autocomplete="current-password" placeholder="Sunshine password" required><button>Pair and open desktop</button><div id="error"></div></form><script>document.getElementById('setup').addEventListener('submit',async(e)=>{{e.preventDefault();const u=document.getElementById('sunshineUsername'),p=document.getElementById('sunshinePassword');const r=await fetch('/dashboard/api/console-credentials/{url_quote(safe, safe="")}',{{method:'POST',headers:{{'Content-Type':'application/json','X-CSRF-Token':'{csrf}'}},body:JSON.stringify({{sunshineUsername:u.value,sunshinePassword:p.value}})}});const j=await r.json().catch(()=>({{}}));p.value='';if(r.ok&&j.ok)location.href=j.launchUrl;else document.getElementById('error').textContent=j.error?.message||j.error||'Pairing failed';}});</script></body></html>''', mimetype='text/html', headers={'Cache-Control':'no-store','Referrer-Policy':'no-referrer'})
    return Response(f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Enable automatic console login</title><style>body{{margin:0;background:#050816;color:#e7f0f4;font:15px Inter,system-ui;display:grid;place-items:center;min-height:100vh}}form{{width:min(420px,calc(100vw - 48px));background:#071117;border:1px solid #1a2b33;padding:30px}}input,button{{display:block;box-sizing:border-box;width:100%;margin-top:12px;padding:12px;background:#061016;color:#e7f0f4;border:1px solid #29404a}}button{{background:#02bdf3;color:#00131b;font-weight:700}}#error{{color:#ff9ab0;margin-top:12px}}</style></head><body><form id="setup"><h1>Enable automatic login</h1><p>Enter the Windows credentials once. EpicVM will encrypt them at rest and use short-lived Guacamole launch tokens.</p><input id="username" autocomplete="username" placeholder="Windows username" required><input id="password" type="password" autocomplete="current-password" placeholder="Windows password" required><button>Enable and open desktop</button><div id="error"></div></form><script>document.getElementById('setup').addEventListener('submit',async(e)=>{{e.preventDefault();const r=await fetch('/dashboard/api/console-credentials/{url_quote(safe, safe="")}',{{method:'POST',headers:{{'Content-Type':'application/json','X-CSRF-Token':'{csrf}'}},body:JSON.stringify({{username:document.getElementById('username').value,password:document.getElementById('password').value}})}});const j=await r.json().catch(()=>({{}}));document.getElementById('password').value='';if(r.ok&&j.ok)location.href=j.launchUrl;else document.getElementById('error').textContent=j.error?.message||j.error||'Setup failed';}});</script></body></html>''', mimetype='text/html', headers={'Cache-Control':'no-store','Referrer-Policy':'no-referrer'})


@app.post('/dashboard/api/console-credentials/<name>')
@admin_auth_required
def dashboard_console_credentials(name):
    if not _request_is_https():
        return jsonify({'ok': False, 'error': 'Automatic console login setup requires HTTPS'}), 426
    payload = request.get_json(silent=True) or {}
    username = str(payload.get('username') or '')
    password = str(payload.get('password') or '')
    sunshine_username = str(payload.get('sunshineUsername') or payload.get('sunshine_username') or '')
    sunshine_password = str(payload.get('sunshinePassword') or payload.get('sunshine_password') or '')
    try:
        orchestrator = _console_for_vm(name)
        if _moonlight_console(orchestrator):
            resolved_sunshine = _resolve_sunshine_credentials(sunshine_username, sunshine_password)
            if not resolved_sunshine:
                return jsonify({'ok': False, 'error': {'code': 'sunshine_credentials_unavailable', 'message': 'The protected Sunshine default is not configured on this dashboard.'}}), 503
            sunshine_username, sunshine_password = resolved_sunshine
            orchestrator.enable_auto_login(name=name, username='', password='', sunshine_username=sunshine_username, sunshine_password=sunshine_password)
        else:
            orchestrator.enable_auto_login(name=name, username=username, password=password)
        response = jsonify({'ok': True, 'launchUrl': f'/dashboard/console/{url_quote(str(name).lower(), safe="")}/launch'})
        response.headers['Cache-Control'] = 'no-store'
        return response
    except ConsoleOrchestrationError as exc:
        response = jsonify({'ok': False, 'error': {'code': str(getattr(exc, 'code', 'console_error')), 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 502) or 502)
    finally:
        username = password = sunshine_username = sunshine_password = ''


@app.post('/portal/api/auth/login')
def portal_login_api():
    data = request.get_json(silent=True) or {}
    username = str(data.get('username') or '').strip()
    password = str(data.get('password') or '')
    remote = request.remote_addr or 'unknown'
    now = time.time()
    with _LOGIN_LOCK:
        attempt = _LOGIN_ATTEMPTS.get(remote, {'count': 0, 'until': 0})
        if attempt['until'] > now:
            return jsonify({'ok': False, 'error': 'Try again shortly'}), 429
    if not _same_origin_request():
        return jsonify({'ok': False, 'error': 'Cross-origin request rejected'}), 403
    user = _get_user_by_username(username)
    if not user or user.get('disabled') or not _verify_user_password(password, user.get('password_hash') or ''):
        with _LOGIN_LOCK:
            count = _LOGIN_ATTEMPTS.get(remote, {}).get('count', 0) + 1
            _LOGIN_ATTEMPTS[remote] = {'count': count, 'until': now + min(30, 2 ** min(count, 5))}
        return jsonify({'ok': False, 'error': 'invalid'}), 401
    with _LOGIN_LOCK:
        _LOGIN_ATTEMPTS.pop(remote, None)
    try:
        token = _create_portal_token(user['username'], bool(user.get('isAdmin')))
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 503
    approved = str(user.get('accountStatus') or 'pending') == 'approved'
    resp = jsonify({'ok': True, 'accessGranted': approved, 'statusOnly': not approved,
                    'user': {k:v for k,v in user.items() if k != 'password_hash'}})
    resp.set_cookie('Portal-Auth', token, httponly=True, samesite='Strict', secure=_request_is_https(), max_age=30*24*3600, path='/')
    return resp

@app.post('/portal/api/auth/logout')
def portal_logout_api():
    if not _same_origin_request():
        return jsonify({'ok': False, 'error': 'Cross-origin request rejected'}), 403
    resp = jsonify({'ok': True})
    resp.delete_cookie('Portal-Auth', path='/')
    return resp

@app.get('/portal/api/auth/status')
def portal_auth_status_api():
    user = _current_portal_user(require_approved=False)
    approved = bool(user and str(user.get('accountStatus') or 'pending') == 'approved')
    return jsonify({'ok': bool(user), 'accessGranted': approved, 'statusOnly': bool(user and not approved),
                    'user': ({k:v for k,v in user.items() if k != 'password_hash'} if user else None)})

# --- Public beta signup + account status (EpicVM landing front door) ---
@app.post('/EpicVM/api/signup')
def epicvm_signup_api():
    # Public, unauthenticated. Server-side validation only.
    data = request.get_json(silent=True) or {}
    username = str(data.get('username') or '').strip()
    password = str(data.get('password') or '')
    display_name = str(data.get('displayName') or data.get('name') or '').strip()
    email = str(data.get('email') or '').strip().lower()
    who = str(data.get('who') or '').strip()
    if not re.fullmatch(r'[A-Za-z0-9_.-]{3,64}', username):
        return jsonify({'ok': False, 'error': 'Username must be 3-64 characters (letters, numbers, dot, underscore, dash).'}), 400
    if not password or len(password) < 3:
        return jsonify({'ok': False, 'error': 'Password must be at least 3 characters.'}), 400
    if email and not re.fullmatch(r'[^@\s]+@[^@\s]+\.[^@\s]+', email):
        return jsonify({'ok': False, 'error': 'Enter a valid email or leave it blank.'}), 400
    _init_users_db()
    conn = _users_conn()
    try:
        existing = conn.execute('SELECT id, username FROM users WHERE lower(username) = lower(?)', (username,)).fetchone()
        if existing:
            return jsonify({'ok': False, 'error': 'That username conflicts with an existing account. Usernames are case-insensitive for new accounts.'}), 409
        # account_status starts 'pending'; admin must approve before VM access.
        conn.execute(
            'INSERT INTO users (username, password_hash, is_admin, account_status, email, who) VALUES (?, ?, ?, ?, ?, ?)',
            (username, _hash_user_password(password), 0, 'pending', email, (display_name or who)),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        return jsonify({'ok': False, 'error': 'That username is already taken.'}), 409
    finally:
        conn.close()
    created = _get_user_by_username(username)
    resp = jsonify({'ok': True, 'status': 'pending', 'authenticated': True,
                    'message': 'Access request received. Your account is waiting for approval.'})
    if created:
        token = _create_portal_token(created['username'], False)
        resp.set_cookie('Portal-Auth', token, httponly=True, samesite='Strict', secure=_request_is_https(), max_age=30*24*3600, path='/')
    return resp


@app.get('/EpicVM/api/me')
def epicvm_public_me_api():
    user = _current_portal_user(require_approved=False)
    if not user:
        return jsonify({'ok': False, 'authenticated': False})
    payload = {k: v for k, v in user.items() if k != 'password_hash'}
    payload['authenticated'] = True
    return jsonify({'ok': True, **payload})


@app.get('/portal/api/vms')
@portal_auth_required
def portal_vms_api():
    user = request.portal_user
    resources, providers = _resource_inventory(include_cloudpcs=True)
    _migrate_legacy_resource_access(resources)
    user = _get_user_by_username(user['username']) or user
    all_resources = {item['resourceKey']: item for item in resources}
    vms = []
    for grant in user.get('assignedResources') or []:
        if grant.get('resourceType') != 'vm':
            continue
        inventory = all_resources.get(grant['resourceKey'])
        if not inventory:
            vms.append({
                'resourceKey': grant['resourceKey'], 'name': grant['name'],
                'host_id': grant['hostId'], 'host_name': grant['hostId'],
                'type': 'unknown', 'profile': 'unknown', 'os': 'Unknown',
                'status': 'Unavailable', 'state': 'unavailable', 'running': False,
                'healthy': False, 'exists': False, 'available': False, 'stale': True,
                'readiness': 'unavailable', 'allowed': False,
                'unavailableReason': 'The assigned provider or resource is not currently available.',
                'capabilities': {},
            })
            continue
        name = inventory['name']
        is_remote = inventory.get('placement') == 'remote'
        if is_remote:
            status = inventory
            meta = inventory
        else:
            try:
                status = _vm_status_payload_bounded(name, timeout_s=6)
            except Exception:
                status = {'ok': False, 'name': name, 'status': 'unknown', 'state': 'unknown', 'running': False, 'healthy': False, 'crashed': False, 'exists': False}
            meta = _instance_meta(name) or {}
        # Classify machine type from profile/platform metadata when present.
        profile = str((status.get('profile') or meta.get('profile') or 'standard')).strip().lower()
        os_kind = str((meta.get('os') or meta.get('platform') or status.get('os') or status.get('guest_os') or '')).strip().lower()
        if 'windows' in os_kind or profile in ('windows', 'gaming'):
            vm_type = 'windows'
        elif profile == 'gaming':
            vm_type = 'gaming'
        elif profile == 'omarchy':
            vm_type = 'omarchy'
        else:
            vm_type = 'linux'
        state = str(status.get('state') or status.get('status') or 'unknown').lower()
        host_online = inventory.get('host_online') is not False and inventory.get('available', True) is not False
        running = bool(status.get('running')) and host_online
        provisioning_state = str(status.get('provisioning_state') or status.get('provisioningState') or state).lower()
        provisioning = provisioning_state in (
            'queued', 'creating', 'configuring', 'starting', 'provisioning', 'loading',
            'streaming_setup', 'gaming_guest', 'gaming_network', 'gaming_gpu', 'omarchy_setup',
        )
        automated_ready = status.get('ready') is True or provisioning_state == 'ready'
        if not host_online:
            readiness = 'unavailable'
        elif state == 'failed' or provisioning_state.startswith('failed') or provisioning_state.startswith('setup_failed') or status.get('crashed'):
            readiness = 'failed'
        elif provisioning:
            readiness = 'provisioning'
        elif running and automated_ready:
            readiness = 'ready'
        elif running:
            readiness = 'running-unready'
        elif state in ('stopping',):
            readiness = 'stopping'
        elif state in ('stopped', 'exited', 'dead'):
            readiness = 'stopped'
        else:
            readiness = 'stopped'
        item = {
            'resourceKey': inventory['resourceKey'],
            'resourceType': 'vm',
            'name': name,
            'url': inventory.get('url') or _build_vm_url(name),
            'wrapperUrl': (
                _build_vm_url(name, host_id=str(inventory.get('host_id') or ''))
                if str(inventory.get('placement') or '').lower() == 'remote'
                else f'/vm/{name}/'
            ),
            'accessMode': _vm_access_mode(name, host_id=inventory['hostId'], resource_key=inventory['resourceKey']),
            'allowed': True,
            'placement': inventory.get('placement') or 'local',
            'host_id': inventory.get('host_id') or 'local',
            'host_name': inventory.get('host_name') or '',
            'provider': inventory.get('provider') or '',
            'type': vm_type,
            'os': os_kind or ('Windows' if vm_type == 'windows' else ('Omarchy Linux' if vm_type == 'omarchy' else 'Linux')),
            'profile': profile,
            'status': status.get('status') or status.get('state') or 'Unknown',
            'state': state,
            'running': running,
            'powerRunning': bool(status.get('running')),
            'hostReachable': host_online,
            'healthy': bool(status.get('healthy', status.get('running', False))) and host_online,
            'crashed': bool(status.get('crashed')),
            'exists': bool(status.get('exists', True)),
            'recoveryState': status.get('recoveryState') or 'healthy',
            'readiness': readiness,
            'provisioningState': provisioning_state,
            'available': host_online,
            'stale': bool(inventory.get('stale')),
            'capabilities': inventory.get('capabilities') or {},
            'title': meta.get('title') or '',
            'cpu': meta.get('cpu') or status.get('cpu') or '',
            'memory': meta.get('memory') or status.get('memory') or '',
        }
        vms.append(item)
    # Cloud PCs the caller owns are surfaced as first-class machines.
    for pc in _load_cloud_pcs():
        if pc['owner'] != (user.get('username') or ''):
            continue
        st = _cp_status(pc['id'], tailnet_ip=pc['tailnet_ip'])
        vms.append({
            'resourceKey': _resource_key('cloudpc', 'external', pc['id']),
            'resourceType': 'cloudpc',
            'name': pc['id'],
            'url': _build_vm_url(pc['id']),
            'wrapperUrl': f'/vm/{pc["id"]}/',
            'accessMode': 'restricted',
            'allowed': True,
            'type': 'cloudpc',
            'os': 'Your PC',
            'profile': 'cloudpc',
            'status': st['readiness'],
            'state': st['readiness'],
            'running': st['running'],
            'healthy': st['healthy'],
            'crashed': False,
            'exists': True,
            'recoveryState': 'healthy',
            'readiness': st['readiness'],
            'title': pc.get('display_name') or pc['id'],
            'cpu': '',
            'memory': '',
            'owner': pc['owner'],
            'paired': pc.get('paired', False),
            'available': pc.get('enabled', True) is not False,
            'capabilities': _resource_capabilities(pc, resource_type='cloudpc', classification='external'),
        })
    # Provisioning summary for the dashboard header.
    summary = {
        'total': len(vms),
        'ready': sum(1 for v in vms if v['readiness'] == 'ready'),
        'provisioning': sum(1 for v in vms if v['readiness'] == 'provisioning'),
        'stopped': sum(1 for v in vms if v['readiness'] == 'stopped'),
        'failed': sum(1 for v in vms if v['readiness'] == 'failed'),
    }
    return jsonify({'ok': True, 'user': {k:v for k,v in user.items() if k != 'password_hash'},
                    'vms': vms, 'summary': summary, 'providers': providers})

@app.post('/portal/api/start/<name>')
@portal_auth_required
def portal_start_vm(name):
    data = request.get_json(silent=True) or {}
    # Resolve kind before generic ACL logic.  Cloud PCs have stream lifecycle
    # operations, not VM power operations, and are always owner/admin scoped.
    if _is_cloudpc(name):
        pc = _load_cloud_pc(name)
        if not pc:
            return jsonify({'ok': False, 'error': 'Cloud PC not found'}), 404
        if pc['owner'] != request.portal_user['username'] and not request.portal_user.get('isAdmin') and not _admin_vm_sso_authenticated():
            return jsonify({'ok': False, 'error': 'Forbidden'}), 403
        try:
            _cp_start(name)
        except _CloudPcConfigError as exc:
            return jsonify({'ok': False, 'error': str(exc)}), 400
        return jsonify({'ok': True, 'resourceType': 'cloudpc', 'operation': 'stream-start',
                        'wrapperUrl': f'/vm/{name}/', 'openUrl': _build_vm_url(name)})
    try:
        resource = _resolve_resource(data.get('resourceKey') or name, host_id=data.get('hostId') or data.get('host_id'), resource_type='vm')
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc), 'code': 'ambiguous_resource'}), 409
    if not resource:
        return jsonify({'ok': False, 'error': 'VM not found'}), 404
    if not _user_can_access_vm(request.portal_user, resource['name'], host_id=resource['hostId'], resource_key=resource['resourceKey']):
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    if not resource.get('capabilities', {}).get('powerStart', False):
        return jsonify({'ok': False, 'error': 'Start is unsupported for this resource', 'code': 'capability_unsupported'}), 409
    try:
        _vm_host(resource['hostId']).check_call('start', resource['name'])
        try:
            dash_optimizer.note_vm_activity(name, 'portal-start')
        except Exception:
            pass
        return jsonify({'ok': True, 'resourceKey': resource['resourceKey'],
                        'wrapperUrl': _build_vm_url(resource['name'], host_id=resource['hostId']),
                        'openUrl': _build_vm_url(resource['name'], host_id=resource['hostId'])})
    except subprocess.CalledProcessError as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/portal/api/stop/<name>')
@portal_auth_required
def portal_stop_vm(name):
    data = request.get_json(silent=True) or {}
    if _is_cloudpc(name):
        pc = _load_cloud_pc(name)
        if not pc:
            return jsonify({'ok': False, 'error': 'Cloud PC not found'}), 404
        if pc['owner'] != request.portal_user['username'] and not request.portal_user.get('isAdmin') and not _admin_vm_sso_authenticated():
            return jsonify({'ok': False, 'error': 'Forbidden'}), 403
        try:
            _cp_stop(name)
        except _CloudPcConfigError as exc:
            return jsonify({'ok': False, 'error': str(exc)}), 400
        return jsonify({'ok': True, 'resourceType': 'cloudpc', 'operation': 'stream-stop'})
    try:
        resource = _resolve_resource(data.get('resourceKey') or name, host_id=data.get('hostId') or data.get('host_id'), resource_type='vm')
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc), 'code': 'ambiguous_resource'}), 409
    if not resource:
        return jsonify({'ok': False, 'error': 'VM not found'}), 404
    if not _user_can_access_vm(request.portal_user, resource['name'], host_id=resource['hostId'], resource_key=resource['resourceKey']):
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    if not resource.get('capabilities', {}).get('powerStop', False):
        return jsonify({'ok': False, 'error': 'Stop is unsupported for this resource', 'code': 'capability_unsupported'}), 409
    try:
        host = _vm_host(resource['hostId'])
        host.check_call('stop', resource['name'])
        _stop_remote_console_after_vm(host, resource['name'])
        return jsonify({'ok': True})
    except subprocess.CalledProcessError as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


# --- Cloud PC (bring-your-own Sunshine over Tailscale) -------------------------------
# A Cloud PC is an owner-scoped record; the dashboard stands up a per-PC Moonlight
# Web proxy and pairs it to the user's Sunshine.  No EpicVM agent is installed.

def _cloudpc_owner_ok(name):
    """Return the record if the caller owns it (or is an admin via SSO), else None."""
    pc = _load_cloud_pc(name)
    if not pc:
        return None
    if pc['owner'] == request.portal_user['username'] or request.portal_user.get('isAdmin') or _admin_vm_sso_authenticated():
        return pc
    return False  # owned by someone else


@app.post('/portal/api/cloudpc')
@portal_auth_required
def portal_cloudpc_create():
    data = request.get_json(silent=True) or {}
    display_name = str(data.get('displayName') or '').strip()
    tailnet_ip = str(data.get('tailnet_ip') or data.get('tailnetIp') or '').strip()
    if not display_name:
        return jsonify({'ok': False, 'error': 'displayName is required'}), 400
    if not tailnet_ip:
        return jsonify({'ok': False, 'error': 'tailnet_ip is required'}), 400
    su = str(data.get('sunshineUsername') or data.get('sunshine_username') or '')
    sp = str(data.get('sunshinePassword') or data.get('sunshine_password') or '')
    try:
        rec = _cp_create(
            owner=request.portal_user['username'],
            display_name=display_name,
            tailnet_ip=tailnet_ip,
            sunshine_username=su,
            sunshine_password=sp,
        )
    except _CloudPcConfigError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 400
    return jsonify({'ok': True, 'cloudpc': rec})


@app.post('/portal/api/cloudpc/<name>/pair')
@portal_auth_required
def portal_cloudpc_pair(name):
    owned = _cloudpc_owner_ok(name)
    if owned is None:
        return jsonify({'ok': False, 'error': 'Cloud PC not found'}), 404
    if owned is False:
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    data = request.get_json(silent=True) or {}
    su = str(data.get('sunshineUsername') or data.get('sunshine_username') or '')
    sp = str(data.get('sunshinePassword') or data.get('sunshine_password') or '')
    try:
        rec = _cp_pair(name, sunshine_username=su, sunshine_password=sp)
    except _CloudPcConfigError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 400
    return jsonify({'ok': True, 'cloudpc': rec})


@app.post('/portal/api/cloudpc/<name>/start')
@portal_auth_required
def portal_cloudpc_start(name):
    owned = _cloudpc_owner_ok(name)
    if owned is None:
        return jsonify({'ok': False, 'error': 'Cloud PC not found'}), 404
    if owned is False:
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    try:
        _cp_start(name)
    except _CloudPcConfigError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 400
    return jsonify({'ok': True, 'wrapperUrl': f'/vm/{name}/'})


@app.post('/portal/api/cloudpc/<name>/stop')
@portal_auth_required
def portal_cloudpc_stop(name):
    owned = _cloudpc_owner_ok(name)
    if owned is None:
        return jsonify({'ok': False, 'error': 'Cloud PC not found'}), 404
    if owned is False:
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    try:
        _cp_stop(name)
    except _CloudPcConfigError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 400
    return jsonify({'ok': True})


@app.delete('/portal/api/cloudpc/<name>')
@portal_auth_required
def portal_cloudpc_delete(name):
    owned = _cloudpc_owner_ok(name)
    if owned is None:
        return jsonify({'ok': False, 'error': 'Cloud PC not found'}), 404
    if owned is False:
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    try:
        _cp_stop(name)
    except Exception:
        pass
    removed = _cp_delete(name)
    return jsonify({'ok': bool(removed)})


@app.get('/portal/api/vm/<name>/status')
@portal_auth_required
def portal_vm_status(name):
    """Rich VM state for the portal console wrapper (Portal-Auth cookie)."""
    if not _user_can_access_vm(request.portal_user, name):
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    try:
        host = _vm_host()
        if getattr(host, 'kind', 'local') == 'remote':
            envelope = host.status(name)
            envelope = dict(envelope) if isinstance(envelope, dict) else {}
            raw_vm = envelope.get('vm') if isinstance(envelope.get('vm'), dict) else envelope
            vm = normalize_remote_vm_record(raw_vm)
            envelope.update({
                'ok': bool(envelope.get('ok', True)),
                'vm': vm,
                'placement': 'remote',
                'host_id': host.host_id,
                'host_name': host.host_name,
                'state': vm.get('state', 'Unknown'),
                'status': vm.get('status', 'Unknown'),
                'provider_status': vm.get('provider_status', ''),
                'running': bool(vm.get('running', False)),
                'vm_id': vm.get('id', vm.get('Id', '')),
                'profile': vm.get('profile', 'standard'),
            })
            return jsonify(envelope)
        return jsonify(_vm_status_payload_bounded(name))
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/portal/api/vm/<name>/recover')
@portal_auth_required
def portal_vm_recover(name):
    if not _user_can_access_vm(request.portal_user, name):
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    try:
        data = request.get_json(silent=True) or {}
        aggressive = bool(data.get('aggressive', False)) if isinstance(data, dict) else False
        mode = (data.get('mode') if isinstance(data, dict) else None) or 'standard'
        result = _recover_vm(name, source='portal', aggressive=aggressive, mode=mode)
        return jsonify(result), (200 if result.get('ok') else 500)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/portal/api/vm/<name>/escalate')
@portal_auth_required
def portal_vm_escalate(name):
    if not _user_can_access_vm(request.portal_user, name):
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', name or ''):
        return jsonify({'ok': False, 'error': 'Invalid VM name'}), 400
    claim = _claim_hermes_escalation(name)
    if not claim['allowed']:
        return jsonify({
            'ok': False,
            'error': 'Hermes is already handling this VM',
            'retryAfter': claim['retry_after'],
        }), 429
    try:
        data = request.get_json(silent=True) or {}
        reason = data.get('reason') if isinstance(data, dict) else None
        if not reason:
            reason = 'Portal recovery help requested by user'
        rec = _recover_vm(name, source='hermes-escalation', aggressive=False)
        esc = _escalate_vm_to_hermes(name, reason, {'recovery': rec, 'request': data})
        return jsonify({'ok': True, 'queued': True, 'state': esc.get('state', 'queued'), 'recovery': rec, 'escalation': esc})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/portal/api/vm/<name>/escalation-status')
@portal_auth_required
def portal_vm_escalation_status(name):
    """Poll the most recent escalation status for this VM (non-blocking)."""
    if not _user_can_access_vm(request.portal_user, name):
        return jsonify({'ok': False, 'error': 'Forbidden'}), 403
    esc_dir = os.path.join(_state_dir(), 'dashboard', 'escalations')
    try:
        matches = [p for p in os.listdir(esc_dir) if p.startswith(f"{name}-") and p.endswith('.status.json')]
    except Exception:
        matches = []
    if not matches:
        return jsonify({'ok': True, 'state': 'none'})
    latest = sorted(matches)[-1]
    try:
        with open(os.path.join(esc_dir, latest)) as f:
            st = json.load(f)
    except Exception:
        st = {'state': 'unknown'}
    return jsonify({'ok': True, 'state': st.get('state', 'unknown'), 'detail': st})


@app.post('/portal/api/request-access/<name>')
@portal_auth_required
def portal_request_access(name):
    user = request.portal_user
    data = request.get_json(silent=True) or {}
    try:
        resource = _resolve_resource(data.get('resourceKey') or name,
                                     host_id=data.get('hostId') or data.get('host_id'),
                                     resource_type='vm')
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc), 'code': 'ambiguous_resource'}), 409
    if not resource:
        return jsonify({'ok': False, 'error': 'VM not found'}), 404
    if _user_can_access_vm(user, resource['name'], host_id=resource['hostId'], resource_key=resource['resourceKey']):
        return jsonify({'ok': False, 'error': 'You already have access'}), 400
    note = str(data.get('note') or '').strip()[:1000]
    _init_users_db()
    conn = _users_conn()
    try:
        existing = conn.execute('SELECT id FROM access_requests WHERE username = ? AND resource_key = ? AND status = ?',
                                (user['username'], resource['resourceKey'], 'pending')).fetchone()
        if existing:
            return jsonify({'ok': True, 'alreadyPending': True})
        conn.execute('''INSERT INTO access_requests
                        (username, vm_name, resource_key, resource_type, host_id, note, status)
                        VALUES (?, ?, ?, 'vm', ?, ?, 'pending')''',
                     (user['username'], resource['name'], resource['resourceKey'], resource['hostId'], note))
        conn.commit()
    finally:
        conn.close()
    return jsonify({'ok': True})

@app.get('/portal')
@app.get('/portal/')
def portal_home():
    user = _current_portal_user()
    if not user:
        prefix = '/EpicVM' if request.path.startswith('/EpicVM/portal') else ''
        return _portal_login_redirect(prefix + '/portal/')
    page = '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VM Portal</title><style>:root{color-scheme:dark}body{margin:0;font-family:Inter,system-ui,Arial;background:radial-gradient(circle at top,#101933 0%,#050816 58%,#03050d 100%);color:#eef4ff;padding:24px;min-height:100vh;box-sizing:border-box}.wrap{max-width:1180px;margin:0 auto}.top{display:flex;justify-content:space-between;gap:12px;align-items:center;flex-wrap:wrap;margin-bottom:18px}.eyebrow{letter-spacing:.18em;text-transform:uppercase;font-size:12px;color:#93c5fd;margin-bottom:8px}.hero{padding:24px;border-radius:24px;border:1px solid rgba(255,255,255,.1);background:linear-gradient(180deg,rgba(255,255,255,.07),rgba(255,255,255,.03));box-shadow:0 30px 80px rgba(0,0,0,.34)}h1{margin:0 0 8px;font-size:clamp(32px,5vw,50px)}.sub{color:#b9c7e5;max-width:780px;line-height:1.6}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:18px;margin-top:24px}.card{background:linear-gradient(180deg,rgba(255,255,255,.06),rgba(255,255,255,.03));border:1px solid rgba(255,255,255,.08);border-radius:20px;padding:20px;box-shadow:0 18px 50px rgba(0,0,0,.24)}.muted{opacity:.78}.status{display:inline-flex;padding:8px 11px;border-radius:999px;font-size:12px;font-weight:700;letter-spacing:.03em;background:rgba(255,255,255,.07);margin-bottom:12px}.status.live{color:#bbf7d0;background:rgba(22,163,74,.18)}.status.down{color:#fde68a;background:rgba(245,158,11,.16)}button,a.btn{display:inline-block;margin:10px 10px 0 0;padding:11px 14px;border-radius:12px;border:none;background:linear-gradient(135deg,#3b82f6,#7c3aed);color:#fff;text-decoration:none;cursor:pointer;font-weight:700}.alt{background:rgba(255,255,255,.08)}.ghost{background:transparent;border:1px solid rgba(255,255,255,.12)}.home-style{color:#e7f0f4}.hero{border-radius:5px;border:1px solid #1a2b33;border-top:2px solid #02bdf3;background:#071117;box-shadow:none;padding:28px}.card{border-radius:5px;background:#071117;border:1px solid #1a2b33;box-shadow:none}.eyebrow{color:#6e8791;letter-spacing:.18em}.sub,.muted{color:#9fb0b8;opacity:1}.status{border-radius:4px;background:#0b1820;border:1px solid #263b44}.status.live{color:#83eb9b;background:#0b1d17}.status.down{color:#f7c948;background:#17170f}button,a.btn{border-radius:4px;background:#02bdf3;color:#00131b;box-shadow:none}button:hover,a.btn:hover{background:#35cdf6}.alt,.ghost{background:#0b1820;color:#dce7ec;border:1px solid #29404a}.top{border-bottom:1px solid #1a2b33;padding-bottom:20px}.grid{gap:16px}.card h3{font-weight:600}.card strong{color:#e7f0f4}input,button{font:inherit}@media (max-width:720px){body{padding:14px}.hero,.card{padding:18px}}</style></head><body><div class=wrap><div class=top><div class=hero style="flex:1 1 740px"><div class=eyebrow>VM Portal</div><h1>Your VMs</h1><div class=sub id=welcome>Loading your VM access…</div></div><div><button class="alt" onclick="logoutUser()">Log out</button></div></div><div id=list class=grid></div></div><script>async function logoutUser(){await fetch('/portal/api/auth/logout',{method:'POST'}).catch(()=>null);location.href='/portal/login'} function esc(s){return String(s??'').replace(/[&<>\"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]))} function actionButton(label, cls, act, name){return '<button'+(cls?' class="'+cls+'"':'')+' onclick='+JSON.stringify("vmAction('"+act+"', "+JSON.stringify(String(name))+")")+'>'+label+'</button>'} async function load(){const r=await fetch('/portal/api/vms'); if(r.status===401){location.href='/portal/login'; return} const j=await r.json().catch(()=>({})); const user=(j.user&&j.user.username)||'user'; document.getElementById('welcome').textContent='Signed in as '+user+'. Open, start, or stop any VM your account can access.'; const list=document.getElementById('list'); list.innerHTML=''; const vms=(j.vms||[]); if(!vms.length){list.innerHTML='<div class="card"><h3 style="margin-top:0">No VMs available</h3><div class="muted">You do not currently have any public or assigned VMs available in the portal.</div></div>'; return} vms.forEach(vm=>{const div=document.createElement('div'); div.className='card'; const live=String(vm.status||'').toLowerCase()==='running' || vm.running; const actions=['<a class="btn" href="/vm/'+encodeURIComponent(vm.name)+'/">Open</a>']; if(vm.allowed){actions.push(actionButton('Start','', 'start', vm.name)); actions.push(actionButton('Stop','alt', 'stop', vm.name))} div.innerHTML='<div class="status '+(live?'live':'down')+'">'+(live?'Online':'Offline')+'</div><h3 style="margin:0 0 8px">'+esc(vm.name)+'</h3><div class="muted">Access mode: '+esc(vm.accessMode||'public')+'</div><div class="muted" style="margin-top:6px">Current state: '+esc(vm.status||'Unknown')+'</div><div>'+actions.join('')+'</div>'; list.appendChild(div)})} async function waitForVm(name,maxMs){const deadline=Date.now()+(maxMs||45000); while(Date.now()<deadline){ try{ const r=await fetch('/dashboard/api/vm/'+encodeURIComponent(name)+'/status',{cache:'no-store'}); const j=await r.json().catch(()=>({})); if(j && j.ok && j.running) return true; }catch(_){ } await new Promise(r=>setTimeout(r,1500)); } return false } async function vmAction(act,name){const r=await fetch('/portal/api/'+act+'/'+encodeURIComponent(name),{method:'POST'}); const j=await r.json().catch(()=>({})); if(!j.ok){ alert('Failed: '+(j.error||r.status)); load(); return } if(act==='start'){ const ready=await waitForVm(name,45000); const target=j.wrapperUrl||('/vm/'+encodeURIComponent(name)+'/'); if(!ready){ alert('VM start request sent. Opening the wrapper while it finishes waking up.'); } window.location.href=target; return } alert(act+' request sent'); load()} load()</script></body></html>'''
    return Response(page, mimetype='text/html')

@app.get('/portal/login')
def portal_login_page():
    if _current_portal_user():
        return redirect(_safe_portal_next(request.args.get('next')))
    next_url = _safe_portal_next(request.args.get('next'))
    next_js = json.dumps(next_url)
    page = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>EpicVM Login</title><style>body{{margin:0;font-family:Inter,system-ui,Arial;background:radial-gradient(circle at top,#101933 0%,#050816 58%,#03050d 100%);color:#e7f0f4;display:grid;place-items:center;min-height:100vh;padding:24px}}.card{{max-width:430px;width:100%;box-sizing:border-box;background:#071117;border:1px solid #1a2b33;border-top:2px solid #02bdf3;border-radius:5px;padding:34px;box-shadow:none}}.brand{{display:flex;align-items:center;gap:11px;border-bottom:1px solid #1a2b33;padding-bottom:20px;margin-bottom:26px}}.brand-mark{{display:grid;place-items:center;width:32px;height:32px;border-radius:5px;background:#02bdf3;color:#00131b;font-weight:900}}.brand-name{{font-size:18px;font-weight:700}}h1{{margin:0 0 8px;font-size:26px;font-weight:500;letter-spacing:-.025em}}.muted{{color:#9fb0b8;line-height:1.55}}input,button{{width:100%;box-sizing:border-box;padding:12px 14px;border-radius:4px;border:1px solid #29404a;background:#061016;color:#e7f0f4;margin-top:10px;font:inherit}}input:focus{{outline:2px solid rgba(2,189,243,.25);border-color:#02bdf3}}button{{background:#02bdf3;color:#00131b;border-color:#34cdf8;cursor:pointer;font-weight:700}}button:hover{{background:#35cdf6}}#err{{color:#ff9ab0!important;margin-top:10px}}</style></head><body><div class=card><div class=brand><span class=brand-mark>E</span><span class=brand-name>EpicVM</span></div><h1>VM Login</h1><div class=muted>Sign in to access restricted EpicVM instances.</div><form onsubmit="return doLogin(event)"><input id=u placeholder="Username" autocomplete="username" /><input id=p type=password placeholder="Password" autocomplete="current-password" /><button>Sign in</button><div id=err style="color:#fca5a5;margin-top:10px"></div></form></div><script>async function doLogin(e){{e.preventDefault();const r=await fetch('/portal/api/auth/login',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{username:document.getElementById('u').value,password:document.getElementById('p').value}})}});const j=await r.json().catch(()=>({{}}));if(j.ok){{location.href={next_js};return false}}document.getElementById('err').textContent=j.error||'Login failed';return false}}</script></body></html>'''
    return Response(page, mimetype='text/html')

# --- EpicVM namespace aliases for the existing portal (no duplicated logic) ---
@app.get('/EpicVM/portal')
@app.get('/EpicVM/portal/')
def epicvm_portal_home():
    # Render the stylized SPA portal; the SPA gates anon/pending/rejected users.
    base = os.path.join(_state_dir(), 'epicvm_web')
    dist = os.path.join(base, 'dist')
    indexcand = os.path.join(dist, 'index.html')
    if os.path.isfile(indexcand):
        return send_from_directory(dist, 'index.html')
    return portal_home()


@app.get('/EpicVM/portal/login')
def epicvm_portal_login_page():
    return portal_login_page()


@app.get('/dashboard/api/users')
@v2_auth_required
def dashboard_users_list():
    resources, providers = _resource_inventory(include_cloudpcs=True)
    _migrate_legacy_resource_access(resources)
    _init_users_db()
    conn = _users_conn()
    try:
        limit = min(200, max(1, int(request.args.get('limit') or 50)))
        offset = max(0, int(request.args.get('offset') or 0))
        reqs = [dict(r) for r in conn.execute('''SELECT id, username, vm_name, resource_key, resource_type,
                                                       host_id, note, status, created_at
                                                FROM access_requests ORDER BY created_at DESC LIMIT ? OFFSET ?''',
                                                 (limit, offset)).fetchall()]
        request_count = int(conn.execute('SELECT COUNT(*) FROM access_requests').fetchone()[0])
        metadata = {r['resource_key']: dict(r) for r in conn.execute('SELECT * FROM resource_metadata').fetchall()}
        grants = conn.execute('''SELECT a.resource_key, u.username FROM user_resource_access a
                                 JOIN users u ON u.id = a.user_id ORDER BY u.username COLLATE NOCASE''').fetchall()
        assigned = {}
        for grant in grants:
            assigned.setdefault(grant['resource_key'], []).append(grant['username'])
        issues = [dict(r) for r in conn.execute('''SELECT source_table, source_id, legacy_name, reason, candidates, created_at
                                                   FROM resource_migration_issues WHERE resolved_at IS NULL
                                                   ORDER BY created_at, source_table, source_id''').fetchall()]
    finally:
        conn.close()
    for resource in resources:
        meta = metadata.get(resource['resourceKey'], {})
        resource['accessMode'] = meta.get('access_mode') or 'restricted'
        resource['title'] = meta.get('title') or resource.get('title') or ''
        resource['assignedUsers'] = assigned.get(resource['resourceKey'], [])
    config_admins = []
    for username, source in ((_admin_credentials()[0], 'primary-config'), (_extra_admin_credentials()[0], 'secondary-config')):
        if username:
            config_admins.append({
                'username': username, 'realm': 'dashboard-config', 'role': 'dashboard-admin',
                'source': source, 'protected': True, 'readOnly': True,
            })
    users = _list_users()
    folded_counts = {}
    for user in users:
        folded_counts[user['username'].casefold()] = folded_counts.get(user['username'].casefold(), 0) + 1
    for user in users:
        user['caseCollision'] = folded_counts.get(user['username'].casefold(), 0) > 1
    return jsonify({
        'ok': True,
        'users': users,
        'adminIdentities': config_admins,
        'requests': reqs,
        'requestPage': {'offset': offset, 'limit': limit, 'total': request_count},
        'vms': resources,
        'resources': resources,
        'providers': providers,
        'migrationIssues': issues,
    })

@app.post('/dashboard/api/users')
@v2_auth_required
def dashboard_users_create():
    data = request.get_json(silent=True) or {}
    try:
        is_admin = bool(data.get('isAdmin')) if isinstance(data.get('isAdmin'), bool) else str(data.get('isAdmin') or '').strip().lower() in ('1', 'true', 'yes', 'on')
        user = _create_user(str(data.get('username') or '').strip(), str(data.get('password') or ''),
                            data.get('assignedVms') or [], is_admin=is_admin,
                            assigned_resources=(data.get('assignedResources') if 'assignedResources' in data else None))
        return jsonify({'ok': True, 'user': {k:v for k,v in user.items() if k != 'password_hash'}})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.post('/dashboard/api/users/<username>')
@v2_auth_required
def dashboard_users_update(username):
    data = request.get_json(silent=True) or {}
    try:
        user = _update_user(
            username,
            assigned_vms=(data.get('assignedVms') if 'assignedVms' in data else None),
            assigned_resources=(data.get('assignedResources') if 'assignedResources' in data else None),
            password=(str(data.get('password')) if data.get('password') else None),
            disabled=(data.get('disabled') if 'disabled' in data else None),
            is_admin=(data.get('isAdmin') if 'isAdmin' in data else None),
        )
        return jsonify({'ok': True, 'user': {k:v for k,v in user.items() if k != 'password_hash'}})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 400

@app.post('/dashboard/api/users/<username>/delete')
@v2_auth_required
def dashboard_users_delete(username):
    try:
        ok = _delete_user(username)
        return jsonify({'ok': ok})
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc), 'code': 'cloudpc_ownership_requires_resolution'}), 409

@app.post('/dashboard/api/access-requests/<int:req_id>/action')
@v2_auth_required
def dashboard_access_request_action(req_id):
    data = request.get_json(silent=True) or {}
    action = str(data.get('action') or '').strip().lower()
    if action not in ('approve', 'deny', 'dismiss'):
        return jsonify({'ok': False, 'error': 'Invalid action'}), 400
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('''SELECT id, username, vm_name, resource_key, resource_type, host_id, note, status
                              FROM access_requests WHERE id = ?''', (req_id,)).fetchone()
        if not row:
            return jsonify({'ok': False, 'error': 'Request not found'}), 404
        if row['status'] != 'pending':
            if ((action == 'approve' and row['status'] == 'approved') or
                    (action == 'deny' and row['status'] == 'denied') or
                    (action == 'dismiss' and row['status'] == 'dismissed')):
                return jsonify({'ok': True, 'status': row['status'], 'repeated': True})
            return jsonify({'ok': False, 'error': f"Request is already {row['status']}"}), 409
        if action == 'approve':
            user_row = conn.execute('SELECT id FROM users WHERE username = ?', (row['username'],)).fetchone()
            if not user_row:
                return jsonify({'ok': False, 'error': 'User no longer exists'}), 404
            if not row['resource_key']:
                return jsonify({'ok': False, 'error': 'Legacy request has no unambiguous resource identity'}), 409
            meta = conn.execute('SELECT resource_key, resource_type, host_id, display_name FROM resource_metadata WHERE resource_key = ?',
                                (row['resource_key'],)).fetchone()
            if not meta:
                return jsonify({'ok': False, 'error': 'Requested resource is unavailable or was deleted'}), 409
            conn.execute('''INSERT OR IGNORE INTO user_resource_access
                            (user_id, resource_key, resource_type, host_id, display_name)
                            VALUES (?, ?, ?, ?, ?)''',
                         (user_row['id'], meta['resource_key'], meta['resource_type'], meta['host_id'], meta['display_name']))
            new_status = 'approved'
        elif action == 'deny':
            new_status = 'denied'
        else:
            new_status = 'dismissed'
        conn.execute('UPDATE access_requests SET status = ? WHERE id = ?', (new_status, req_id))
        conn.commit()
        return jsonify({'ok': True, 'status': new_status, 'request': {
            'id': row['id'], 'username': row['username'], 'vm_name': row['vm_name'],
            'resource_key': row['resource_key'], 'host_id': row['host_id'],
        }})
    finally:
        conn.close()

# --- Public beta account approval (approve / reject) ---
# Reuses the existing portal user table + (on approve) auto-provisions the
# user's default Linux VM via the host manager, then grants access.
def _safe_linux_vm_name(username: str) -> str:
    base = re.sub(r'[^a-z0-9._-]', '', username.lower()) or 'user'
    return (base[:32] or 'user').lower()


def _provisioning_vm_name(username: str):
    base = _safe_linux_vm_name(username)
    resources, _ = _resource_inventory(include_cloudpcs=False)
    local_by_name = {r['name']: r for r in resources if r['hostId'] == 'local'}
    _init_users_db()
    conn = _users_conn()
    try:
        case_collision = conn.execute('''SELECT 1 FROM users WHERE lower(username) = lower(?) AND username <> ?''',
                                      (username, username)).fetchone()
        existing = local_by_name.get(base)
        if existing:
            owner = conn.execute('SELECT username FROM resource_owners WHERE resource_key = ?',
                                 (existing['resourceKey'],)).fetchone()
            if owner and owner['username'] == username:
                return base, existing, True
        if case_collision or existing:
            suffix = hashlib.sha256(username.encode('utf-8')).hexdigest()[:6]
            base = f'{base[:25]}-{suffix}'
            existing = local_by_name.get(base)
            if existing:
                owner = conn.execute('SELECT username FROM resource_owners WHERE resource_key = ?',
                                     (existing['resourceKey'],)).fetchone()
                if not owner or owner['username'] != username:
                    raise ValueError('Provisioning target already exists and is not owned by this account')
                return base, existing, True
        return base, existing, False
    finally:
        conn.close()


def _start_user_linux_provisioning(username: str, *, host_id='local', profile='standard'):
    """Start a durable, idempotent account provisioning job.

    Account approval and VM creation are separate state transitions.  The
    public-beta default is explicitly local + standard Linux; unsupported
    provider/profile selections fail rather than silently falling back.
    """
    if host_id != 'local' or profile != 'standard':
        raise ValueError('Account auto-provisioning currently supports host local with profile standard')
    vm_name, existing, owned = _provisioning_vm_name(username)
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('SELECT id, provisioning_job_id, provisioning_state FROM users WHERE username = ?', (username,)).fetchone()
        if not row:
            raise ValueError('User not found')
        if row['provisioning_job_id'] and str(row['provisioning_state'] or '') in ('queued', 'creating', 'created', 'ready'):
            return row['provisioning_job_id'], str(row['provisioning_state']), vm_name
    finally:
        conn.close()

    def work():
        try:
            if not owned:
                ok, out, err, _rc = _run_manager('create', vm_name)
                if not ok:
                    message = str(err or out or 'VM create failed')
                    conn = _users_conn()
                    try:
                        conn.execute('''UPDATE users SET provisioning_state = 'failed', provisioning_error = ?
                                        WHERE username = ?''', (message[:2000], username))
                        conn.commit()
                    finally:
                        conn.close()
                    return False, message
            _set_instance_meta(vm_name, 'access_mode', 'restricted')
            key = _resource_key('vm', 'local', vm_name)
            conn = _users_conn()
            try:
                user_row = conn.execute('SELECT id FROM users WHERE username = ?', (username,)).fetchone()
                if not user_row:
                    return False, 'User was deleted during provisioning'
                conn.execute('''INSERT OR REPLACE INTO resource_metadata
                                (resource_key, resource_type, host_id, native_id, display_name, access_mode, updated_at)
                                VALUES (?, 'vm', 'local', ?, ?, 'restricted', strftime('%s','now'))''',
                             (key, vm_name, vm_name))
                conn.execute('''INSERT OR REPLACE INTO resource_owners (resource_key, username, source)
                                VALUES (?, ?, 'account-provisioning')''', (key, username))
                conn.execute('''INSERT OR IGNORE INTO user_resource_access
                                (user_id, resource_key, resource_type, host_id, display_name)
                                VALUES (?, ?, 'vm', 'local', ?)''', (user_row['id'], key, vm_name))
                conn.execute('''UPDATE users SET provisioning_state = 'created', provisioning_error = '', vm_name = ?
                                WHERE id = ?''', (vm_name, user_row['id']))
                conn.commit()
            finally:
                conn.close()
            return True, f'Created {vm_name}' if not owned else f'Linked owned resource {vm_name}'
        except Exception as exc:
            conn = _users_conn()
            try:
                conn.execute('''UPDATE users SET provisioning_state = 'failed', provisioning_error = ?
                                WHERE username = ?''', (str(exc)[:2000], username))
                conn.commit()
            finally:
                conn.close()
            return False, str(exc)

    job_id = _create_job('account-provision', [_resource_key('vm', 'local', vm_name)])
    conn = _users_conn()
    try:
        conn.execute('''UPDATE users SET provisioning_job_id = ?, provisioning_state = 'queued',
                        provisioning_error = '', vm_name = ? WHERE username = ?''',
                     (job_id, vm_name, username))
        conn.commit()
    finally:
        conn.close()
    def runner():
        _update_job(job_id, status='running', progress='Creating account VM')
        try:
            ok, output = work()
            _update_job(job_id, status='succeeded' if ok else 'failed',
                        progress='Completed' if ok else 'Failed', output=output if ok else '',
                        error='' if ok else output)
        except Exception as exc:
            _update_job(job_id, status='failed', progress='Failed', error=str(exc))
    threading.Thread(target=runner, daemon=True).start()
    return job_id, 'queued', vm_name


def _provision_user_linux_vm(username: str) -> str:
    """Compatibility wrapper returning the durable provisioning state."""
    try:
        return _start_user_linux_provisioning(username)[1]
    except Exception as exc:
        app.logger.warning('EpicVM auto-provision error for %s: %s', username, exc)
        return 'failed'


@app.post('/dashboard/api/accounts/<username>/approve')
@v2_auth_required
def dashboard_account_approve(username):
    data = request.get_json(silent=True) or {}
    should_provision = data.get('provision', True) is not False
    host_id = str(data.get('hostId') or 'local').strip().lower()
    profile = str(data.get('profile') or 'standard').strip().lower()
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('''SELECT id, username, account_status, provisioning_job_id, provisioning_state
                              FROM users WHERE username = ?''', (username,)).fetchone()
        if not row:
            return jsonify({'ok': False, 'error': 'User not found'}), 404
        if str(row['account_status'] or 'pending') != 'approved':
            conn.execute('''UPDATE users SET account_status = 'approved', session_version = session_version + 1
                            WHERE id = ?''', (row['id'],))
        conn.commit()
    finally:
        conn.close()
    job_id = row['provisioning_job_id']
    provisioning_state = row['provisioning_state']
    if should_provision:
        try:
            job_id, provisioning_state, _vm_name = _start_user_linux_provisioning(username, host_id=host_id, profile=profile)
        except ValueError as exc:
            return jsonify({'ok': False, 'error': str(exc), 'status': 'approved', 'code': 'provisioning_not_started'}), 409
    user = _get_user_by_username(username)
    return jsonify({'ok': True, 'status': 'approved', 'provisioningState': provisioning_state,
                    'provisioningJobId': job_id,
                    'user': {k:v for k,v in user.items() if k != 'password_hash'}})


@app.post('/dashboard/api/accounts/<username>/reject')
@v2_auth_required
def dashboard_account_reject(username):
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('SELECT id FROM users WHERE username = ?', (username,)).fetchone()
        if not row:
            return jsonify({'ok': False, 'error': 'User not found'}), 404
        conn.execute('''UPDATE users SET account_status = ?, provisioning_state = ?,
                        session_version = session_version + 1 WHERE id = ?''', ('rejected', None, row['id']))
        conn.commit()
        user = _get_user_by_username(username)
    finally:
        conn.close()
    return jsonify({'ok': True, 'status': 'rejected', 'user': {k:v for k,v in user.items() if k != 'password_hash'}})


# --- Dashboard v2 auth routes (top-level) ---
@app.post('/Dashboard/api/auth/login')
def dashboard_v2_login_public():
    try:
        data = request.get_json(force=True)
    except Exception:
        return jsonify({'ok': False}), 400
    if not _same_origin_request():
        return jsonify({'ok': False, 'error': 'Cross-origin request rejected'}), 403
    if _allow_insecure_dashboard():
        return jsonify({'ok': True, 'authRequired': False})
    user, expected_password = _admin_credentials()
    if not user or not expected_password or not _dashboard_secret():
        return jsonify({'ok': False, 'error': 'Dashboard authentication is not configured'}), 503
    username = str(data.get('username', '')) if isinstance(data, dict) else ''
    pw = str(data.get('password', '')) if isinstance(data, dict) else ''
    remote = request.remote_addr or 'unknown'
    now = time.time()
    with _LOGIN_LOCK:
        attempt = _LOGIN_ATTEMPTS.get(remote, {'count': 0, 'until': 0})
        if attempt['until'] > now:
            return jsonify({'ok': False, 'error': 'Try again shortly'}), 429
    if not _valid_dashboard_admin(username, pw):
        with _LOGIN_LOCK:
            count = _LOGIN_ATTEMPTS.get(remote, {}).get('count', 0) + 1
            _LOGIN_ATTEMPTS[remote] = {'count': count, 'until': now + min(30, 2 ** min(count, 5))}
        return jsonify({'ok': False, 'error': 'invalid'}), 401
    with _LOGIN_LOCK:
        _LOGIN_ATTEMPTS.pop(remote, None)
    exp = int(time.time() + 24*3600)
    payload = _account_dashboard_payload(username)
    token = _sign_v2_token(payload)
    resp = jsonify({'ok': True, 'expiry': exp, 'authRequired': True})
    resp.set_cookie('Dashboard-Auth', token, httponly=True, samesite='Strict', secure=_request_is_https(), max_age=24*3600, path='/')
    return resp


@app.get('/Dashboard/api/auth/status')
def dashboard_v2_status_public():
    if _allow_insecure_dashboard():
        return jsonify({'ok': True, 'authRequired': False})
    user, password = _admin_credentials()
    if not user or not password or not _dashboard_secret():
        return jsonify({'ok': False, 'authRequired': True, 'configured': False}), 503
    token = request.cookies.get('Dashboard-Auth')
    ok = bool(token and _verify_v2_token(token))
    identity = None
    if ok:
        payload = base64.urlsafe_b64decode(token).decode().rsplit(':', 1)[0]
        identity = _account_dashboard_identity(payload)
    return jsonify({'ok': ok, 'authRequired': True, 'configured': True, 'username': identity})


@app.get('/dashboard/api/auth/csrf')
@auth_required
def dashboard_v2_csrf():
    token = _csrf_token_for_session()
    response = jsonify({'ok': bool(token), 'csrfToken': token if token else None})
    response.headers['Cache-Control'] = 'no-store'
    return response

@app.post('/Dashboard/api/auth/logout')
def dashboard_v2_logout_public():
    if not _same_origin_request():
        return jsonify({'ok': False, 'error': 'Cross-origin request rejected'}), 403
    resp = jsonify({'ok': True})
    resp.delete_cookie('Dashboard-Auth', path='/')
    return resp


@app.route('/EpicVM')
@app.route('/EpicVM/', defaults={'path': ''})
@app.route('/EpicVM/<path:path>')
def serve_epicvm_public(path=''):
    """Serve the public EpicVM beta front door (separate Vite build, base /EpicVM/)."""
    base = os.path.join(_state_dir(), 'epicvm_web')
    dist = os.path.join(base, 'dist')
    if path:
        cand = os.path.join(dist, path)
        if os.path.isfile(cand):
            return send_from_directory(dist, path)
    indexcand = os.path.join(dist, 'index.html')
    if os.path.isfile(indexcand):
        return send_from_directory(dist, 'index.html')
    return 'EpicVM web not built', 404


# --- Dashboard v2 static page routes (top-level) ---
@app.route('/Dashboard')
@app.route('/Dashboard/', defaults={'path': ''})
@app.route('/Dashboard/<path:path>')
def serve_dashboard_v2_public(path=''):
    base = os.path.join(_state_dir(), 'dashboard_v2')
    dist = os.path.join(base, 'dist')
    if path:
        cand = os.path.join(dist, path)
        if os.path.isfile(cand):
            return send_from_directory(dist, path)
        static_dir = os.path.join(base, 'src')
        cand2 = os.path.join(static_dir, path)
        if os.path.isfile(cand2):
            return send_from_directory(static_dir, path)
    indexcand = os.path.join(dist, 'index.html')
    if os.path.isfile(indexcand):
        return send_from_directory(dist, 'index.html')
    dev_index = os.path.join(base, 'index.html')
    if os.path.isfile(dev_index):
        return send_from_directory(base, 'index.html')
    return 'Dashboard v2 not built', 404


@app.route('/assets/<path:path>')
def serve_dashboard_v2_root_assets_public(path):
    base = os.path.join(_state_dir(), 'dashboard_v2')
    assets_dir = os.path.join(base, 'dist', 'assets')
    cand = os.path.join(assets_dir, path)
    if os.path.isfile(cand):
        return send_from_directory(assets_dir, path)
    return 'Not found', 404


@app.route('/Dashboard/assets/<path:path>')
def serve_dashboard_v2_prefixed_assets_public(path):
    base = os.path.join(_state_dir(), 'dashboard_v2')
    assets_dir = os.path.join(base, 'dist', 'assets')
    cand = os.path.join(assets_dir, path)
    if os.path.isfile(cand):
        return send_from_directory(assets_dir, path)
    return 'Not found', 404


# --- EpicVM namespace: operator console served at /EpicVM/Dashboard ---
@app.route('/EpicVM/Dashboard')
@app.route('/EpicVM/Dashboard/', defaults={'path': ''})
@app.route('/EpicVM/Dashboard/<path:path>')
def serve_epicvm_dashboard_v2(path=''):
    base = os.path.join(_state_dir(), 'dashboard_v2')
    dist = os.path.join(base, 'dist')
    if path:
        cand = os.path.join(dist, path)
        if os.path.isfile(cand):
            return send_from_directory(dist, path)
    indexcand = os.path.join(dist, 'index.html')
    if os.path.isfile(indexcand):
        return send_from_directory(dist, 'index.html')
    return 'Dashboard v2 not built', 404


@app.route('/EpicVM/Dashboard/assets/<path:path>')
def serve_epicvm_dashboard_v2_assets(path):
    base = os.path.join(_state_dir(), 'dashboard_v2')
    assets_dir = os.path.join(base, 'dist', 'assets')
    cand = os.path.join(assets_dir, path)
    if os.path.isfile(cand):
        return send_from_directory(assets_dir, path)
    return 'Not found', 404


@app.route('/EpicVM/Dashboard/api/<path:subpath>', methods=['GET', 'HEAD', 'OPTIONS', 'POST', 'PUT', 'PATCH', 'DELETE'])
def epicvm_dashboard_api(subpath):
    """Proxy the operator Dashboard API under the /EpicVM namespace."""
    from werkzeug.exceptions import NotFound
    adapter = app.url_map.bind_to_environ(request.environ)
    try:
        endpoint, values = adapter.match('/dashboard/api/' + subpath, method=request.method)
    except NotFound:
        return jsonify({'ok': False, 'error': 'Not found'}), 404
    view = app.view_functions.get(endpoint)
    if view is None:
        return jsonify({'ok': False, 'error': 'Not found'}), 404
    return view(**values)


@app.post('/dashboard/api/set-vm-title/<name>')
@auth_required
def api_set_vm_title(name):
    title = request.values.get('title','').strip()
    cfg = _load_dashboard_settings()
    vm_titles = cfg.get('vm_titles', {}) if isinstance(cfg.get('vm_titles', {}), dict) else {}
    if title:
        vm_titles[name] = title
    else:
        # clear title
        if name in vm_titles:
            vm_titles.pop(name, None)
    cfg['vm_titles'] = vm_titles
    ok = _save_dashboard_settings(cfg)
    # Attempt to propagate the title into instance metadata so the VM container
    # can be recreated with updated TITLE env. This uses the `blobe-vm-manager`
    # CLI if available. Run asynchronously and tolerate failures.
    def _propagate_title(n, t):
        try:
            mgr = shutil.which(MANAGER) or '/usr/local/bin/blobe-vm-manager' or os.path.join(APP_ROOT,'server','blobe-vm-manager')
            if not mgr or not os.path.exists(mgr):
                # manager not found; nothing to do
                return
            # Call manager set-title; allow empty title to clear
            # Use Popen so we don't block the request
            subprocess.Popen(_vm_host().command('set-title', n, t), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    try:
        # Fire-and-forget propagation
        threading.Thread(target=_propagate_title, args=(name, title), daemon=True).start()
    except Exception:
        pass

    return jsonify({'ok': bool(ok)})


@app.get('/dashboard/api/vm-settings/<name>')
@auth_required
def api_get_vm_settings(name):
    requested_host_id = str(request.values.get('host_id') or request.values.get('host') or 'local').strip() or 'local'
    resources, providers = _resource_inventory(include_cloudpcs=False)
    try:
        resource = _resolve_resource(request.args.get('resourceKey') or name, host_id=requested_host_id,
                                     resources=resources, resource_type='vm')
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc), 'code': 'ambiguous_resource'}), 409
    if not resource and requested_host_id != 'local':
        try:
            host = _vm_host(requested_host_id)
            envelope = host.status(name)
            raw_vm = envelope.get('vm') if isinstance(envelope, dict) else envelope
            vm = normalize_remote_vm_record(raw_vm if isinstance(raw_vm, dict) else {})
            native_id = str(vm.get('id') or vm.get('Id') or name)
            resource = {
                **vm, 'resourceKey': _resource_key('vm', requested_host_id, native_id),
                'resourceType': 'vm', 'nativeId': native_id, 'name': name,
                'hostId': requested_host_id, 'host_id': requested_host_id,
                'hostName': getattr(host, 'host_name', requested_host_id),
                'placement': 'remote', 'available': True, 'stale': False,
                'classification': _classify_vm_resource(vm),
            }
            resource['capabilities'] = _resource_capabilities(resource, classification=resource['classification'])
            _sync_resource_metadata([resource])
        except Exception as exc:
            return jsonify({'ok': False, 'error': str(exc)}), 502
    if not resource:
        return jsonify({'ok': False, 'error': 'VM not found'}), 404
    _init_users_db()
    conn = _users_conn()
    try:
        meta = conn.execute('SELECT * FROM resource_metadata WHERE resource_key = ?', (resource['resourceKey'],)).fetchone()
        assigned_users = [r['username'] for r in conn.execute('''SELECT u.username FROM user_resource_access a
                                                                  JOIN users u ON u.id = a.user_id
                                                                  WHERE a.resource_key = ? ORDER BY u.username COLLATE NOCASE''',
                                                               (resource['resourceKey'],)).fetchall()]
    finally:
        conn.close()
    safe = re.sub(r'[^A-Za-z0-9_-]', '_', name)
    fav_path = os.path.join(_state_dir(), 'dashboard', 'vm-fav', f"{safe}.ico")
    return jsonify({
        'ok': True,
        'resourceKey': resource['resourceKey'],
        'resourceType': resource['resourceType'],
        'name': name,
        'placement': resource.get('placement'),
        'host_id': resource['hostId'],
        'host_name': resource.get('hostName') or resource['hostId'],
        'title': (meta['title'] if meta else '') or resource.get('title') or '',
        'hostOverride': meta['host_override'] if meta else '',
        'pathOverride': meta['path_override'] if meta else '',
        'faviconUrl': f'/dashboard/vm-favicon/{name}' if requested_host_id == 'local' and os.path.isfile(fav_path) else '',
        'accessMode': (meta['access_mode'] if meta else 'restricted'),
        'assignedUsers': assigned_users,
        'state': resource.get('state') or 'Unknown',
        'status': resource.get('status') or 'Unknown',
        'running': bool(resource.get('running')) and resource.get('host_online') is not False,
        'available': resource.get('available', True),
        'stale': resource.get('stale', False),
        'profile': resource.get('profile') or 'standard',
        'vm_id': resource.get('id') or resource.get('Id') or resource.get('nativeId'),
        'capabilities': resource.get('capabilities') or {},
        'providers': providers,
    })


@app.post('/dashboard/api/vm-settings/<name>')
@auth_required
def api_set_vm_settings(name):
    try:
        data = request.get_json(silent=True) or {}
        requested_host_id = str((data.get('host_id') if isinstance(data, dict) else None) or request.values.get('host_id') or 'local').strip() or 'local'
        resources, _providers = _resource_inventory(include_cloudpcs=False)
        resource = _resolve_resource(data.get('resourceKey') or name, host_id=requested_host_id,
                                     resources=resources, resource_type='vm')
        if not resource and requested_host_id != 'local':
            host = _vm_host(requested_host_id)
            matching = [vm for vm in host.list_vms() if str(vm.get('name') or '') == name]
            if len(matching) == 1:
                vm = normalize_remote_vm_record(matching[0])
                native_id = str(vm.get('id') or vm.get('Id') or name)
                resource = {
                    **vm, 'resourceKey': _resource_key('vm', requested_host_id, native_id),
                    'resourceType': 'vm', 'nativeId': native_id, 'name': name,
                    'hostId': requested_host_id, 'host_id': requested_host_id,
                    'hostName': getattr(host, 'host_name', requested_host_id),
                    'placement': 'remote', 'classification': _classify_vm_resource(vm),
                }
                resource['capabilities'] = _resource_capabilities(resource, classification=resource['classification'])
                _sync_resource_metadata([resource])
        if not resource:
            return jsonify({'ok': False, 'error': 'VM not found'}), 404
        host_override = (data.get('hostOverride') if isinstance(data, dict) else None)
        title = (data.get('title') if isinstance(data, dict) else None)
        access_mode = (data.get('accessMode') if isinstance(data, dict) else None)
        changed_runtime = False

        _init_users_db()
        conn = _users_conn()
        try:
            updates, values = [], []
            if title is not None:
                updates.append('title = ?')
                values.append(str(title).strip())
            if host_override is not None:
                updates.append('host_override = ?')
                values.append(str(host_override).strip())
            if access_mode is not None:
                access_mode = str(access_mode).strip().lower()
                if access_mode not in ('public', 'restricted'):
                    return jsonify({'ok': False, 'error': 'Invalid access mode'}), 400
                updates.append('access_mode = ?')
                values.append(access_mode)
            if updates:
                values.extend([int(time.time()), resource['resourceKey']])
                conn.execute(f"UPDATE resource_metadata SET {', '.join(updates)}, updated_at = ? WHERE resource_key = ?", values)
                conn.commit()
        finally:
            conn.close()

        if title is not None and requested_host_id == 'local':
            cfg = _load_dashboard_settings()
            vm_titles = cfg.get('vm_titles', {}) if isinstance(cfg.get('vm_titles', {}), dict) else {}
            title = str(title).strip()
            if title:
                vm_titles[name] = title
            else:
                vm_titles.pop(name, None)
            cfg['vm_titles'] = vm_titles
            _save_dashboard_settings(cfg)
            _set_instance_meta(name, 'title', title)
            changed_runtime = True

        if host_override is not None and requested_host_id == 'local':
            host_override = str(host_override).strip()
            _set_instance_meta(name, 'host_override', host_override)
            changed_runtime = True

        if access_mode is not None:
            if requested_host_id == 'local':
                _set_instance_meta(name, 'access_mode', access_mode)

        if changed_runtime:
            ok, out, err, rc = _run_manager('recreate', name)
            if not ok:
                return jsonify({'ok': False, 'error': err or out or 'Failed recreating VM with updated settings', 'returncode': rc}), 500

        return jsonify({'ok': True, 'resourceKey': resource['resourceKey'], 'name': name,
                        'host_id': requested_host_id, 'accessMode': access_mode,
                        'title': str(title or ''), 'hostOverride': str(host_override or '')})
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/vm-favicon/<name>')
@app.get('/dashboard/vm-favicon/<name>.ico')
def dashboard_vm_favicon(name):
    # Serve per-VM favicon if exists, otherwise redirect to main favicon (which may itself redirect)
    ddir = os.path.join(_state_dir(), 'dashboard', 'vm-fav')
    try:
        safe = _validate_vm_name(name)
    except ValueError:
        abort(404)
    candidate = os.path.join(ddir, f"{safe}.ico")
    if os.path.isfile(candidate):
        return _send_icon_file(candidate)
    # fallback to global favicon route
    return '', 302, {'Location': '/dashboard/favicon.ico', 'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0', 'Pragma': 'no-cache', 'Expires': '0'}


# --- Console launch preference (Steam Big Picture) -------------------------
def _get_console_bp_pref(name: str) -> bool:
    try:
        cfg = _load_dashboard_settings()
        m = cfg.get('vm_console_bigpicture')
        if isinstance(m, dict):
            v = m.get(str(name or '').strip().lower())
            if v is not None:
                return bool(v)
    except Exception:
        pass
    # Desktop is the reliable baseline; Big Picture remains available as an
    # explicit per-VM preference or appId URL.
    return False


def _set_console_bp_pref(name: str, enabled: bool):
    cfg = _load_dashboard_settings()
    m = cfg.get('vm_console_bigpicture')
    if not isinstance(m, dict):
        m = {}
    m[str(name or '').strip().lower()] = bool(enabled)
    cfg['vm_console_bigpicture'] = m
    _save_dashboard_settings(cfg)


def _console_app_ids(name: str, host_id: str):
    """Best-effort {title: app_id} from the guest Sunshine via bundle backends."""
    orch = _console_orchestrator()
    route_name = _remote_console_route_name(name, host_id)
    prefix = f'/vm/{route_name}/'
    bases = []
    try:
        ext = _external_base_url() or request.url_root.rstrip('/')
        pub = ext.rstrip('/') + prefix.rstrip('/')
        exp = int(time.time() + 600)
        dash_cookie = 'Dashboard-Auth=' + _sign_v2_token(f'{exp}:{os.urandom(8).hex()}')
        if pub:
            bases.append((pub, {'Cookie': dash_cookie}))
    except Exception:
        pass
    for candidate in dict.fromkeys([route_name, str(name or '').strip().lower()]):
        try:
            bases.append(orch._container_url(candidate, prefix))
            break
        except Exception:
            continue
    try:
        listed = orch.command_runner(['docker', 'ps', '--filter',
                                      f'label=com.epicvm.vm.name={name}',
                                      '--format', '{{.ID}}'],
                                     check=True, capture_output=True, text=True)
        cid = str(getattr(listed, 'stdout', '') or '').split()
        if cid:
            inspected = orch.command_runner(['docker', 'inspect', cid[0]],
                                            check=True, capture_output=True, text=True)
            recs = json.loads(str(getattr(inspected, 'stdout', '') or '[]'))
            nets = ((recs[0] if recs else {}).get('NetworkSettings') or {}).get('Networks') or {}
            proxy_name = str(getattr(orch, 'proxy_network', '') or 'proxy')
            ip = str((nets.get(proxy_name) or {}).get('IPAddress') or '')
            if not ip:
                for net in nets.values():
                    ip = str((net or {}).get('IPAddress') or '')
                    if ip:
                        break
            if ip:
                bases.append(f'http://{ip}:8080{prefix}')
    except Exception:
        pass

    host_qs = ''
    try:
        datafile = os.path.join(orch._instance_root(name), 'server', 'data.json')
        with open(datafile, 'r', encoding='utf-8') as fh:
            dj = json.load(fh)
        hosts = (dj.get('hosts') or {})
        if isinstance(hosts, dict) and hosts:
            host_qs = '?host_id=' + str(next(iter(hosts)))
    except Exception:
        pass

    out = {}
    last_err = ''
    for entry in bases:
        try:
            base, extra_headers = (entry if isinstance(entry, tuple) else (entry, {}))
            url = base.rstrip('/') + '/api/apps' + host_qs
            headers = {'X-EpicVM-User': str(name)}
            headers.update(extra_headers or {})
            resp = orch._http('GET', url, headers=headers, timeout=30)
            raw = resp.read()
            data = json.loads(raw.decode('utf-8') if isinstance(raw, bytes) else raw)
            for a in (data.get('apps') or []):
                aid = a.get('app_id') or a.get('id')
                title = str(a.get('title') or '')
                if aid is not None and title:
                    try:
                        out[title] = int(aid)
                    except (TypeError, ValueError):
                        continue
            if out:
                _CONSOLE_APP_IDS_CACHE[(str(host_id), str(name).strip().lower())] = (time.monotonic(), dict(out))
                return out
        except Exception as exc:
            last_err = f'{type(exc).__name__}: {str(exc)[:80]}'
    cached = _CONSOLE_APP_IDS_CACHE.get((str(host_id), str(name).strip().lower()))
    if cached and time.monotonic() - cached[0] < _CONSOLE_APP_IDS_CACHE_TTL_SECONDS:
        print(f'[console-apps] using cached apps for {name}', flush=True)
        return dict(cached[1])
    print(f'[console-apps] no apps for {name}: {last_err}', flush=True)
    return out


@app.get('/portal/api/vm/<name>/console-apps')
def portal_console_apps(name):
    gate = _enforce_vm_user_access(name)
    if gate is not None:
        return gate
    host_id = request.args.get('host_id', 'epic-pc').strip() or 'epic-pc'
    apps = _console_app_ids(name, host_id)
    return jsonify({'ok': True,
                    'apps': [{'title': t, 'app_id': i} for t, i in apps.items()]})


@app.get('/portal/api/vm/<name>/console-pref')
def portal_console_pref_get(name):
    gate = _enforce_vm_user_access(name)
    if gate is not None:
        return gate
    return jsonify({'ok': True, 'bigpicture': _get_console_bp_pref(name)})


@app.post('/portal/api/vm/<name>/console-pref')
def portal_console_pref_set(name):
    gate = _enforce_vm_user_access(name)
    if gate is not None:
        return gate
    payload = request.get_json(silent=True) or {}
    if 'bigpicture' not in payload:
        return jsonify({'ok': False, 'error': 'bigpicture is required'}), 400
    _set_console_bp_pref(name, bool(payload.get('bigpicture')))
    return jsonify({'ok': True, 'bigpicture': bool(payload.get('bigpicture'))})


@app.get('/EpicVM/vm/<name>/')
def epicvm_vm_wrapper(name):
    """Console wrapper served directly under the /EpicVM namespace (the VM detail URL opens the actual console)."""
    return dashboard_vm_wrapper(name)


@app.get('/dashboard/vm/<name>/')
def dashboard_vm_wrapper(name):
        gate = _enforce_vm_user_access(name)
        if gate is not None:
                return gate
        try:
                from .direct_stream import configured_streams
        except ImportError:
                from direct_stream import configured_streams
        direct_route = 'vm-' + str(name).lower()
        direct = configured_streams().get(direct_route)
        selected_host = str(request.args.get('host_id') or '').strip().lower()
        if (selected_host == 'epic-pc' and
                ((isinstance(direct, dict) and direct.get('enabled') is True) or
                 _console_orchestrator().has_auto_login(name))):
                return redirect('/EpicVM/stream-launch/' + direct_route, code=302)
        try:
                dash_optimizer.note_vm_activity(name, 'wrapper-open')
        except Exception:
                pass
        # Public wrapper page that opens the VM inside an iframe while setting the tab title and favicon.
        # We render a small client-side React app that will show either the iframe (when VM is running)
        # or a full-screen fallback UI when the VM is stopped/unreachable.
        host_id = str(request.args.get('host_id') or 'local').strip().lower()
        is_remote_wrapper = host_id != 'local'
        if is_remote_wrapper:
                remote_running = False
                moonlight_host_id = ''
                moonlight_user_id = ''
                try:
                        remote_host = _vm_host(host_id)
                        remote_status_fn = getattr(remote_host, 'status', None)
                        if not callable(remote_status_fn):
                                raise RuntimeError('selected remote host does not support status')
                        remote_response = remote_status_fn(name)
                        remote_vm = remote_response.get('vm') if isinstance(remote_response, dict) else {}
                        remote_vm = remote_vm if isinstance(remote_vm, dict) else {}
                        remote_state = str(remote_vm.get('state') or remote_vm.get('status') or 'unknown')
                        remote_running = remote_state.lower() in {'running', 'on', 'poweredon', 'started'}
                        initial_status = {
                                'ok': bool(remote_response.get('ok', True)) if isinstance(remote_response, dict) else True,
                                'name': name,
                                'url': '',
                                'exists': bool(remote_vm),
                                'running': remote_running,
                                'healthy': remote_running,
                                'state': remote_state,
                                'status': str(remote_vm.get('status') or remote_state),
                                'detail': str(remote_vm.get('status') or remote_state),
                                'crashed': False,
                                'host_id': host_id,
                                'placement': 'remote',
                                'consoleAvailable': False,
                        }
                except Exception as exc:
                        initial_status = {
                                'ok': False,
                                'name': name,
                                'url': '',
                                'exists': False,
                                'running': False,
                                'healthy': False,
                                'state': 'unavailable',
                                'status': 'RemoteVM unavailable',
                                'detail': str(exc)[:300],
                                'crashed': False,
                                'host_id': host_id,
                                'placement': 'remote',
                                'consoleAvailable': False,
                        }
                if remote_running:
                        try:
                                orchestrator = _console_orchestrator()
                                datafile = os.path.join(orchestrator._instance_root(name), 'server', 'data.json')
                                with open(datafile, 'r', encoding='utf-8') as handle:
                                        data = json.load(handle)
                                hosts = data.get('hosts') if isinstance(data, dict) else {}
                                if isinstance(hosts, dict) and hosts:
                                        moonlight_host_id = str(next(iter(hosts)))
                                users = data.get('users') if isinstance(data, dict) else {}
                                if isinstance(users, dict) and users:
                                        moonlight_user_id = str(next(iter(users)))
                        except Exception:
                                moonlight_host_id = ''
                                moonlight_user_id = ''
                url = ''
                if remote_running:
                        route_prefix = f'/vm/{_remote_console_route_name(name, host_id)}/'
                        url = _build_remote_console_url(name, host_id, route_prefix)
                        initial_status['url'] = url
                        initial_status['consoleAvailable'] = True
                # Steam launch-mode preference: deep-link straight into
                # stream.html with the preferred appId.
                try:
                        if url and '?host_id=' in url and remote_running:
                                ids = _console_app_ids(name, host_id)
                                bp = _get_console_bp_pref(name)
                                want = 'Steam Big Picture' if bp else 'Desktop'
                                aid = ids.get(want)
                                if aid is None and ids and bp:
                                        for t, i in ids.items():
                                                if 'steam' in t.lower():
                                                        aid = i
                                                        break
                                if aid is not None:
                                        root_part, hid_part = url.split('?host_id=', 1)
                                        host_query = f'&hostId={url_quote(moonlight_host_id, safe="")}' if moonlight_host_id else ''
                                        url = f'{root_part.rstrip("/")}/stream.html?host_id={hid_part}{host_query}&appId={aid}'
                                        initial_status['url'] = url
                except Exception:
                        pass
        else:
                url = _build_vm_embed_url(name) or ''
                # Keep the page-render path bounded. Optimizer/docker metadata
                # is available from the explicit status endpoint and must not
                # delay the VM page behind a slow control-plane probe.
                initial_status = _vm_status_payload(name, include_optimizer=False)
        cfg = _load_dashboard_settings()
        vm_titles = cfg.get('vm_titles', {}) if isinstance(cfg.get('vm_titles', {}), dict) else {}
        title = vm_titles.get(name) or f"EpicVM - {name}"
        vm_fav_path = os.path.join(_state_dir(), 'dashboard', 'vm-fav', f"{re.sub(r'[^A-Za-z0-9_-]', '_', name)}.ico")
        if os.path.isfile(vm_fav_path):
                fav_url = f'/dashboard/vm-favicon/{name}?v={int(time.time())}'
        else:
                fav_local = os.path.join(_state_dir(), 'dashboard', 'favicon.ico')
                if os.path.isfile(fav_local):
                        fav_url = '/dashboard/favicon.ico'
                else:
                        fav_url = cfg.get('favicon','')

        asset_ver = str(int(time.time()))
        # Safely embed necessary values for the client script
        try:
                js_title = json.dumps(title)
                js_fav = json.dumps(fav_url)
                js_url = json.dumps(url)
                js_name = json.dumps(name)
                js_status = json.dumps(initial_status)
                js_bp = json.dumps(_get_console_bp_pref(name))
                js_host_id = json.dumps(moonlight_host_id if is_remote_wrapper else '')
                js_user_id = json.dumps(moonlight_user_id if is_remote_wrapper else '')
        except Exception:
                js_title = '"%s"' % (title.replace('"','\"'))
                js_fav = '"%s"' % (fav_url.replace('"','\"'))
                js_url = '"%s"' % (url.replace('"','\"'))
                js_name = '"%s"' % (name.replace('"','\"'))
                js_status = '{"ok":true,"status":"unknown","state":"unknown","running":false,"healthy":false,"crashed":false,"exists":false}'
                js_host_id = '""'
                js_user_id = '""'

        # The page includes React + Babel via CDN so we can write a compact React component
        # for the fallback UI without changing the project's build pipeline.
        fav_link = ''
        if fav_url:
                fav_link = (
                        f'<link rel="icon" href="{fav_url}" />'
                        f'<link rel="shortcut icon" href="{fav_url}" />'
                        f'<link rel="apple-touch-icon" href="{fav_url}" />'
                )
        tmpl = '''<!doctype html>
    <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>__TITLE__</title>
            __FAV__
            <style>
                :root{color-scheme:dark;--bg:#050816;--bg2:#0b1226;--card:rgba(12,18,38,.72);--line:rgba(255,255,255,.08);--text:#eef4ff;--muted:#9db0d1;--primary:#ff7a1a;--primary2:#ffa63d;--danger:#ff5c7a;--success:#22c55e;--warning:#f59e0b}
                html,body,#root{height:100%;margin:0}
                body{font-family:Inter,system-ui,Arial,sans-serif;background:radial-gradient(circle at top,#101933 0%,#050816 58%,#03050d 100%);color:var(--text);overflow:hidden}
                .vm-iframe{position:fixed;top:-2px;left:-2px;width:calc(100vw + 4px);height:calc(100vh + 4px);display:block;border:none;background:#000;overflow:hidden;scrollbar-width:none;-ms-overflow-style:none}
                .vm-controls-handle{position:fixed;right:18px;bottom:18px;z-index:58;width:46px;height:46px;border-radius:16px;border:1px solid rgba(255,255,255,.12);background:linear-gradient(180deg,rgba(12,18,38,.78),rgba(5,8,22,.82));color:#eef4ff;display:flex;align-items:center;justify-content:center;font-size:21px;font-weight:900;cursor:pointer;box-shadow:0 16px 34px rgba(0,0,0,.28);backdrop-filter:blur(16px);opacity:.68;transition:transform .18s ease, box-shadow .18s ease, opacity .18s ease}
                .vm-controls-handle:hover{transform:translateY(-1px);box-shadow:0 20px 42px rgba(0,0,0,.34);opacity:.92}
                .vm-fullscreen-cta{position:fixed;left:50%;bottom:18px;z-index:59;transform:translateX(-50%);padding:10px 15px;border-radius:999px;border:1px solid rgba(255,255,255,.18);background:rgba(5,8,22,.82);color:#eef4ff;font:700 13px Inter,system-ui,sans-serif;cursor:pointer;box-shadow:0 12px 30px rgba(0,0,0,.32);backdrop-filter:blur(16px);opacity:.82;transition:opacity .18s ease,background .18s ease}
                .vm-fullscreen-cta:hover{opacity:1;background:rgba(12,18,38,.94)}
                .vm-controls-shell{position:fixed;right:18px;bottom:76px;z-index:60;pointer-events:none}
                .vm-controls-panel{width:min(420px,calc(100vw - 32px));padding:18px;border-radius:22px;border:1px solid rgba(255,255,255,.12);background:linear-gradient(180deg,rgba(10,16,34,.88),rgba(6,10,22,.92));backdrop-filter:blur(24px);box-shadow:0 24px 80px rgba(0,0,0,.42);color:var(--text);pointer-events:auto;transform-origin:top right;transition:opacity .2s ease, transform .2s ease}
                .vm-controls-panel.open{opacity:1;transform:translateY(0) scale(1)}
                .vm-controls-panel.closed{opacity:0;transform:translateY(-10px) scale(.96);pointer-events:none}
                .vm-controls-title{font-size:16px;font-weight:800;margin:0 0 6px}
                .vm-controls-copy{font-size:13px;color:var(--muted);line-height:1.45;margin-bottom:14px}
                .vm-controls-row{display:flex;flex-wrap:wrap;gap:10px}
                .vm-toast{margin-top:12px;padding:10px 12px;border-radius:14px;font-size:13px;line-height:1.4;border:1px solid rgba(255,255,255,.08)}
                .vm-toast.ok{background:rgba(22,101,52,.35);color:#dcfce7}
                .vm-toast.err{background:rgba(127,29,29,.45);color:#ffe4e6}
                .fallback{display:flex;align-items:center;justify-content:center;height:100%;padding:28px;background:radial-gradient(circle at 20% 20%,rgba(255,122,26,.14),transparent 35%),radial-gradient(circle at 80% 0%,rgba(255,166,61,.12),transparent 28%),linear-gradient(180deg,var(--bg2),var(--bg));color:var(--text)}
                .shell{width:min(100%,1040px);position:relative}
                .status-pill{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--line);background:rgba(255,255,255,.05);padding:10px 14px;border-radius:999px;font-size:13px;color:#dbeafe;backdrop-filter:blur(16px);margin-bottom:18px;box-shadow:0 12px 30px rgba(0,0,0,.25)}
                .hero-card{position:relative;overflow:hidden;padding:32px;border-radius:28px;border:1px solid var(--line);background:linear-gradient(180deg,rgba(255,255,255,.08),rgba(255,255,255,.03));backdrop-filter:blur(22px);box-shadow:0 30px 80px rgba(0,0,0,.42)}
                .hero-content{position:relative;z-index:2}
                .orb{position:absolute;border-radius:50%;filter:blur(14px);opacity:.6}
                .orb-a{width:220px;height:220px;right:-50px;top:-40px;background:radial-gradient(circle,#ff7a1a,transparent 65%)}
                .orb-b{width:260px;height:260px;left:-80px;bottom:-120px;background:radial-gradient(circle,#ffa63d,transparent 65%)}
                .vm-name{font-size:14px;letter-spacing:.24em;text-transform:uppercase;color:#b6c7e6;margin-bottom:10px}
                .hero-title{font-size:clamp(32px,5vw,56px);line-height:1.02;margin:0 0 14px;font-weight:800}
                .hero-subtitle{max-width:760px;font-size:17px;line-height:1.6;color:var(--muted);margin:0 0 18px}
                .meta-row{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 24px}
                .meta-chip{padding:10px 12px;border-radius:999px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.06);font-size:13px;color:#dce8ff}
                .actions{display:flex;flex-wrap:wrap;gap:12px}
                .btn{appearance:none;border:none;border-radius:14px;padding:13px 18px;font-size:15px;font-weight:700;cursor:pointer;transition:transform .18s ease,opacity .18s ease,box-shadow .18s ease}
                .btn:hover{transform:translateY(-1px)}
                .btn-primary{background:linear-gradient(135deg,var(--primary),var(--primary2));color:white;box-shadow:0 18px 40px rgba(94,162,255,.22)}
                .btn-secondary{background:rgba(255,255,255,.08);color:#eef4ff;border:1px solid rgba(255,255,255,.08)}
                .btn-ghost{background:transparent;color:#d8e6ff;border:1px solid rgba(255,255,255,.12)}
                .btn-danger{background:linear-gradient(135deg,#fb7185,var(--danger));color:white;box-shadow:0 18px 40px rgba(255,92,122,.2)}
                .loading-wrap{display:flex;flex-direction:column;align-items:flex-start;gap:8px;padding:16px 0}
                .loading-title{font-size:18px;font-weight:700}
                .loading-subtitle{color:var(--muted)}
                .spinner{width:52px;height:52px;border-radius:50%;border:5px solid rgba(255,255,255,.12);border-top-color:var(--primary);animation:spin 1s linear infinite;margin:6px 0}
                .error-box,.sent-box,.details-box{margin-top:18px}
                .error-box,.sent-box{padding:16px 18px;border-radius:18px;border:1px solid rgba(255,255,255,.08)}
                .error-box{background:linear-gradient(180deg,rgba(127,29,29,.55),rgba(60,12,20,.7));color:#ffe4e6}
                .sent-box{background:linear-gradient(180deg,rgba(22,101,52,.45),rgba(8,35,25,.7));color:#dcfce7}
                .error-title{font-weight:800;font-size:16px;margin-bottom:8px}
                .error-message{white-space:pre-wrap;line-height:1.5}
                .subactions{margin-top:14px}
                .details-box{padding:14px 16px;white-space:pre-wrap;overflow:auto;max-height:240px;border-radius:18px;background:rgba(3,8,23,.75);border:1px solid rgba(255,255,255,.07);color:#d9e7ff}
                .tone-crashed .status-pill{border-color:rgba(255,92,122,.25);color:#ffd5de}
                .tone-down .status-pill{border-color:rgba(245,158,11,.25);color:#ffe8ba}
                .tone-live .status-pill{border-color:rgba(34,197,94,.25);color:#dcfce7}
                @keyframes spin{to{transform:rotate(360deg)}}
                .dashboard-style{--surface:#071117;--line-home:#1a2b33}
                .fallback{background:radial-gradient(circle at 10% 0%,rgba(255,122,26,.10),transparent 30%),#02080c;padding:30px;color:#e7f0f4}
                .shell{width:min(100%,1180px);padding:0 0 34px}
                .fallback-topbar{padding:0 0 20px;margin-bottom:24px;border-bottom:1px solid #1a2b33}
                .brand{color:#e7f0f4;font-size:14px;letter-spacing:.01em}.brand-mark{width:32px;height:32px;border-radius:5px;background:#ff7a1a;color:#00131b;box-shadow:none}
                .checked-at{color:#788991;font-size:12px}.checked-dot{background:#83eb9b;box-shadow:none}
                .status-pill{border-radius:4px;background:#0b1820;border-color:#263b44;box-shadow:none;padding:7px 10px;margin-bottom:12px;letter-spacing:.05em}
                .hero-card{padding:28px;border-radius:5px;border:1px solid #1a2b33;border-top:2px solid var(--primary);background:#071117;backdrop-filter:none;box-shadow:none}
                .orb{display:none}.vm-name{color:#6e8791;letter-spacing:.18em}.vm-name-value{color:#e7f0f4;font-size:18px}.state-summary{color:#788991}
                .hero-title{font-size:clamp(30px,5vw,48px);font-weight:500;letter-spacing:-.035em}.hero-subtitle{color:#9fb0b8;font-size:15px;line-height:1.55}
                .meta-grid{gap:0;margin:18px 0 24px;border:1px solid #1a2b33}.meta-card{border:0;border-right:1px solid #1a2b33;border-radius:0;background:#08141b;padding:14px}.meta-card:last-child{border-right:0}.meta-card span{color:#6e8791}.meta-card strong{color:#e7f0f4}
                .actions{gap:9px}.btn{border-radius:4px;padding:11px 15px;font-size:14px}.btn-primary{background:#ff7a1a;color:#00131b;box-shadow:none}.btn-primary:hover{background:#ffa63d}.btn-secondary{background:#0b1820;color:#dce7ec;border:1px solid #29404a}.btn-ghost{color:#9fb0b8;border:1px solid #29404a}.btn-danger{background:#8d2841;box-shadow:none}
                .meaning-card{border-radius:4px;border-color:rgba(245,158,11,.3);background:#17170f;padding:14px}.meaning-card p{color:#b9b08c}.meaning-note{color:#8f896d}
                .loading-wrap{border-top:1px solid #1a2b33;border-bottom:1px solid #1a2b33;padding:18px 0;margin:8px 0}.spinner{border-top-color:#ff7a1a}.loading-subtitle{color:#788991}
                .error-box,.sent-box{border-radius:4px;box-shadow:none}.details-box{border-radius:4px;background:#030a0e;border-color:#1a2b33;color:#b8d2da}
                @media (max-width: 720px){.fallback{padding:20px 16px}.shell{padding-top:0}.fallback-topbar{margin-bottom:20px}.checked-at{font-size:12px}.hero-card{padding:22px;border-radius:24px}.vm-heading-row{display:block}.state-summary{text-align:left;margin-top:7px}.meta-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.actions{flex-direction:column}.btn{width:100%}.hero-subtitle{font-size:15px}.vm-controls-shell{right:12px;left:12px;bottom:68px}.vm-controls-panel{width:auto}.vm-controls-handle{right:12px;bottom:12px;width:46px;height:46px;border-radius:14px}.vm-fullscreen-cta{bottom:12px}}
                @media (max-width: 720px){.fallback{padding:16px}.hero-card{padding:20px;border-radius:22px}.actions{flex-direction:column}.btn{width:100%}.hero-subtitle{font-size:15px}.vm-controls-shell{right:12px;left:12px;bottom:68px}.vm-controls-panel{width:auto}.vm-controls-handle{right:12px;bottom:12px;width:46px;height:46px;border-radius:14px}}
            </style>
        </head>
        <body>
            <div id="root"></div>
            <iframe id="vmframe" class="vm-iframe" src="about:blank" data-vm-src=__JS_URL__ style="display:none" scrolling="no" allow="fullscreen; autoplay; clipboard-read; clipboard-write" allowfullscreen sandbox="allow-scripts allow-same-origin allow-forms allow-modals allow-downloads allow-pointer-lock allow-popups"></iframe>
            <script>
              window.__VM_WRAPPER_INIT = { vmname: __JS_NAME__, vmurl: __JS_URL__, initialStatus: __JS_STATUS__, moonlightHostId: __JS_HOST_ID__, moonlightUserId: __JS_USER_ID__ };
              window.__VM_WRAPPER_BP = __JS_BP__;
              window.__VM_WRAPPER_FAVICON = __JS_FAVICON__;
              (function(){
                try {
                  var href = window.__VM_WRAPPER_FAVICON;
                  if(!href) return;
                  var rels = ['icon', 'shortcut icon', 'apple-touch-icon'];
                  rels.forEach(function(rel){
                    var link = document.querySelector('link[rel="' + rel + '"]');
                    if(!link){
                      link = document.createElement('link');
                      link.setAttribute('rel', rel);
                      document.head.appendChild(link);
                    }
                    link.setAttribute('href', href);
                  });
                } catch(e) {}
              })();
            </script>
            <script crossorigin src="https://unpkg.com/react@18/umd/react.development.js"></script>
            <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.development.js"></script>
            <script src="https://unpkg.com/babel-standalone@6.26.0/babel.min.js"></script>
            <script>window.__VM_WRAPPER_ASSET_VER = Date.now().toString();</script>
            <script type="text/babel" src="/static/js/api/vms.js?v=__ASSET_VER__"></script>
            <script type="text/babel" src="/static/js/hooks/useVMStatus.js?v=__ASSET_VER__"></script>
            <script type="text/babel" src="/static/js/components/VMFallback.jsx?v=__ASSET_VER__"></script>
            <script type="text/babel" src="/static/js/main_vm_wrapper.jsx?v=__ASSET_VER__"></script>
        </body>
    </html>
    '''
        page = tmpl.replace('__TITLE__', title).replace('__FAV__', fav_link).replace('__JS_URL__', js_url).replace('__JS_NAME__', js_name).replace('__JS_FAVICON__', json.dumps(fav_url)).replace('__JS_STATUS__', js_status).replace('__JS_BP__', js_bp).replace('__JS_HOST_ID__', js_host_id).replace('__JS_USER_ID__', js_user_id).replace('__ASSET_VER__', asset_ver)
        resp = Response(page, mimetype='text/html')
        resp.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
        resp.headers['Pragma'] = 'no-cache'
        resp.headers['Expires'] = '0'
        return resp


# Register an alias route under the configured base path (e.g. /vm/<name>/) so merged-mode
# users who visit /vm/<name>/ get the same wrapper behaviour. We read BASE_PATH from state .env
# and add a rule at import time after the function exists.
try:
    try:
        envbp = _read_env().get('BASE_PATH', '/vm')
    except Exception:
        envbp = '/vm'
    if not envbp:
        envbp = '/vm'
    bp = envbp.rstrip('/')
    if not bp.startswith('/'):
        bp = '/' + bp
    # Avoid adding duplicate rule for same path
    alias_rule = f"{bp}/<name>/"
    # Only add if different from /dashboard/vm
    if alias_rule != '/dashboard/vm/<name>/':
        try:
            app.add_url_rule(alias_rule, endpoint=f'dashboard_vm_wrapper_alias', view_func=dashboard_vm_wrapper, methods=['GET'])
        except Exception:
            pass
except Exception:
    pass


def python_gather_stats():
    out = {'mem': {}, 'swap': {}, 'containers': []}
    try:
        free = subprocess.check_output(['free', '-b'], text=True)
        lines = free.split('\n')
        memLine = next((l for l in lines if l.lower().startswith('mem:')), '')
        parts = re.split(r'\s+', memLine.strip()) if memLine else []
        if len(parts) >= 3:
            out['mem']['total'] = int(parts[1])
            out['mem']['used'] = int(parts[2])
        swapLine = next((l for l in lines if l.lower().startswith('swap:')), '')
        sp = re.split(r'\s+', swapLine.strip()) if swapLine else []
        if len(sp) >= 3:
            out['swap']['total'] = int(sp[1])
            out['swap']['used'] = int(sp[2])
    except Exception:
        pass
    # Docker stats are shared with the VM endpoint and optimizer.
    try:
        for record in get_docker_stats():
            memusage = str(record['mem_usage'])
            m = re.search(r'([0-9.]+)\s*([KMG]i?)B', memusage)
            memBytes = 0
            if m:
                n = float(m.group(1)); u = m.group(2).upper()
                mul = 1024
                if u.startswith('M'):
                    mul = 1024*1024
                elif u.startswith('G'):
                    mul = 1024*1024*1024
                memBytes = int(n * mul)
            out['containers'].append({'name': record['name'], 'cpu': record['cpu_percent'],
                                      'memperc': record['mem_percent'], 'memBytes': memBytes})
    except Exception:
        pass
    return out

@app.post('/dashboard/api/set-domain')
@auth_required
def api_set_domain():
    dom = request.values.get('domain','').strip()
    if not dom:
        return jsonify({'ok': False, 'error': 'No domain'}), 400
    # Persist the domain
    _write_env_kv({'BLOBEVM_DOMAIN': dom})
    # Start/stop v2 dashboard container based on domain
    dashboard_v2_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'dashboard_v2'))
    dist_path = os.path.join(dashboard_v2_path, 'dist')
    def start_v2_dashboard():
        # Build if needed
        if not os.path.isdir(dist_path) or not os.path.isfile(os.path.join(dist_path, 'index.html')):
            try:
                subprocess.run(['npm', 'install'], cwd=dashboard_v2_path, check=True)
                subprocess.run(['npm', 'run', 'build'], cwd=dashboard_v2_path, check=True)
            except Exception as e:
                print(f"Failed to build dashboard_v2: {e}")
        # Remove any existing container
        subprocess.run(['docker', 'rm', '-f', 'blobedash-v2'], check=False)
        # Start container
        subprocess.run([
            'docker', 'run', '-d', '--name', 'blobedash-v2', '--restart', 'unless-stopped',
            '-p', '4173:4173',
            '-v', f'{dist_path}:/usr/share/nginx/html:ro',
            'nginx:alpine'
        ], check=False)
        # Also attempt to start a dev compose service if present so Traefik labels are applied
        dev_compose = os.path.join(dashboard_v2_path, 'docker-compose.dev.yml')
        if os.path.isfile(dev_compose):
            try:
                # ensure proxy network exists
                r = _docker('network', 'inspect', 'proxy')
                if r.returncode != 0:
                    _docker('network', 'create', 'proxy')
                # run docker compose to start the dev service (detached)
                envc = os.environ.copy()
                envc['BLOBEVM_DOMAIN'] = dom
                subprocess.run(['docker', 'compose', '-f', 'docker-compose.dev.yml', 'up', '--build', '-d'], cwd=dashboard_v2_path, check=False, env=envc)
            except Exception as e:
                print(f"Failed to start dashboard_v2 dev compose: {e}")
    def stop_v2_dashboard():
        subprocess.run(['docker', 'rm', '-f', 'blobedash-v2'], check=False)
        # Also try to stop any dev compose service
        try:
            dc = os.path.join(dashboard_v2_path, 'docker-compose.dev.yml')
            if os.path.isfile(dc):
                envc = os.environ.copy()
                envc['BLOBEVM_DOMAIN'] = ''
                subprocess.run(['docker', 'compose', '-f', 'docker-compose.dev.yml', 'down', '-v'], cwd=dashboard_v2_path, check=False, env=envc)
        except Exception:
            pass
    if dom:
        start_v2_dashboard()
    else:
        stop_v2_dashboard()
    # If caller requested, also apply merged/domain-mode settings so domain routing will be used.
    apply_mode = request.values.get('apply') in ('1','true','yes')
    if apply_mode:
        # Set merged-mode env vars that manager expects. Do not modify routing code itself.
        _write_env_kv({
            'NO_TRAEFIK': '0',
            'MERGED_MODE': '1',
            'TRAEFIK_NETWORK': 'proxy',
            'ENABLE_DASHBOARD': '1',
        })
        # Run background worker to ensure proxy network exists and restart VMs so they pick up new mode
        def worker_apply(domain_name):
            try:
                # Ensure network exists
                r = _docker('network', 'inspect', 'proxy')
                if r.returncode != 0:
                    _docker('network', 'create', 'proxy')
                # Restart all instances so they reattach with updated labels/mode
                inst_root = os.path.join(_state_dir(), 'instances')
                try:
                    names = [n for n in os.listdir(inst_root) if os.path.isdir(os.path.join(inst_root, n))]
                except Exception:
                    names = []
                for name in names:
                    cname = f'blobevm_{name}'
                    # remove container and start via manager to ensure labels/networks are applied
                    _docker('rm', '-f', cname)
                    try:
                        _vm_host().run_manager('start', name, check=False)
                    except Exception:
                        pass
            except Exception:
                pass
        threading.Thread(target=worker_apply, args=(dom,), daemon=True).start()
    # Best-effort IP hint: show the host the user is using to reach the dashboard
    ip = _request_host() or ''
    if not ip:
        try:
            ip = socket.gethostbyname(socket.gethostname())
        except Exception:
            ip = ''
    return jsonify({'ok': True, 'domain': dom, 'ip': ip, 'applied': apply_mode})

def _enable_single_port(port: int):
    """Enable single-port mode by launching a tiny Traefik and reattaching services.
    - Creates network 'proxy' if missing
    - Starts traefik on host port <port>
    - Recreates dashboard joined to 'proxy' with labels for /dashboard
    - Recreates VM containers via manager so they carry labels and join the network
    """
    # Persist env changes for manager url rendering
    _write_env_kv({
        'NO_TRAEFIK': '0',
        'HTTP_PORT': str(port),
        'TRAEFIK_NETWORK': 'proxy',
        'ENABLE_DASHBOARD': '1',
        'BASE_PATH': _read_env().get('BASE_PATH', '/vm'),
        'MERGED_MODE': '1',
    })

    # Ensure network exists
    r = _docker('network', 'inspect', 'proxy')
    if r.returncode != 0:
        _docker('network', 'create', 'proxy')

    # Start or recreate Traefik
    # Map chosen host port -> container :80
    ps_names = _docker('ps', '-a', '--format', '{{.Names}}').stdout.splitlines()
    if 'traefik' in ps_names:
        _docker('rm', '-f', 'traefik')
    _docker('run', '-d', '--name', 'traefik', '--restart', 'unless-stopped',
            '-p', f'{port}:80',
            '-v', '/var/run/docker.sock:/var/run/docker.sock:ro',
            '--network', 'proxy',
            'traefik:v2.11',
            '--providers.docker=true',
            '--providers.docker.exposedbydefault=false',
            '--entrypoints.web.address=:80',
            '--api.dashboard=true')

    # Start an additional dashboard container joined to proxy with labels
    # Keep the current one running to avoid killing this process mid-flight
    if 'blobedash-proxy' in ps_names:
        _docker('rm', '-f', 'blobedash-proxy')
    _docker('run', '-d', '--name', 'blobedash-proxy', '--restart', 'unless-stopped',
            '-v', f'{_state_dir()}:/opt/blobe-vm',
            '-v', '/usr/local/bin/epicvm:/usr/local/bin/epicvm:ro',
            '-v', '/var/run/docker.sock:/var/run/docker.sock',
            '-v', DOCKER_VOLUME_BIND,
            '-v', f'{_state_dir()}/dashboard:/app:ro',
            '-e', f'BLOBEDASH_USER={os.environ.get("BLOBEDASH_USER","")}',
            '-e', f'BLOBEDASH_PASS={os.environ.get("BLOBEDASH_PASS","")}',
            '-e', f'HOST_DOCKER_BIN={HOST_DOCKER_BIN}',
            '--network', 'proxy',
            '--label', 'traefik.enable=true',
            '--label', 'traefik.http.routers.blobe-dashboard.rule=PathPrefix(`/dashboard`)',
            '--label', 'traefik.http.routers.blobe-dashboard.entrypoints=web',
            '--label', 'traefik.http.services.blobe-dashboard.loadbalancer.server.port=5000',
            'python:3.11-slim',
            'bash', '-c', 'pip install --no-cache-dir flask gunicorn && gunicorn --bind 0.0.0.0:5000 --workers 1 --threads 4 --timeout 60 --access-logfile - --error-logfile - wsgi:app')

    # Recreate VM containers into proxy network
    inst_root = os.path.join(_state_dir(), 'instances')
    names = []
    try:
        names = [n for n in os.listdir(inst_root) if os.path.isdir(os.path.join(inst_root, n))]
    except Exception:
        pass
    for name in names:
        cname = f'blobevm_{name}'
        _docker('rm', '-f', cname)
        try:
            _vm_host().run_manager('start', name, check=False)
        except Exception:
            pass

def _disable_single_port(dash_port: int | None):
    # Persist env toggles
    env = _read_env()
    direct_start = int(env.get('DIRECT_PORT_START', '20000') or '20000')
    updates = {
        'NO_TRAEFIK': '1',
        'ENABLE_DASHBOARD': '1',
        'DASHBOARD_PORT': str(dash_port) if dash_port else env.get('DASHBOARD_PORT',''),
        'MERGED_MODE': '0',
    }
    _write_env_kv(updates)

    # Stop traefik and proxy dashboard if present
    _docker('rm', '-f', 'blobedash-proxy')
    _docker('rm', '-f', 'traefik')

    # Recreate VMs into direct mode (exposed ports)
    inst_root = os.path.join(_state_dir(), 'instances')
    try:
        names = [n for n in os.listdir(inst_root) if os.path.isdir(os.path.join(inst_root, n))]
    except Exception:
        names = []
    for name in names:
        cname = f'blobevm_{name}'
        _docker('rm', '-f', cname)
        try:
            _vm_host().run_manager('start', name, check=False)
        except Exception:
            pass

    # Start/recreate v2 dashboard as a Docker container in production mode
    port = dash_port or direct_start
    # Remove any existing v2 dashboard container
    _docker('rm', '-f', 'blobedash-v2')
    # Build the v2 dashboard if not already built (optional: could be handled elsewhere)
    dashboard_v2_path = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'dashboard_v2'))
    dist_path = os.path.join(dashboard_v2_path, 'dist')
    if not os.path.isdir(dist_path) or not os.path.isfile(os.path.join(dist_path, 'index.html')):
        # Try to build if not present
        try:
            subprocess.run(['npm', 'install'], cwd=dashboard_v2_path, check=True)
            subprocess.run(['npm', 'run', 'build'], cwd=dashboard_v2_path, check=True)
        except Exception as e:
            print(f"Failed to build dashboard_v2: {e}")
    # Start the v2 dashboard container to serve static files
    _docker('run', '-d', '--name', 'blobedash-v2', '--restart', 'unless-stopped',
        '-p', f'{port}:4173',
        '-v', f'{dist_path}:/usr/share/nginx/html:ro',
        'nginx:alpine')


@app.get('/dashboard')
@auth_required
def root():
    cfg = _load_dashboard_settings()
    fav = ''
    fav_local = os.path.join(_state_dir(), 'dashboard', 'favicon.ico')
    if os.path.isfile(fav_local):
        fav = '/dashboard/favicon.ico'
    else:
        fav = cfg.get('favicon','')
    title = cfg.get('title', DASHBOARD_TITLE)

    # Only show v2 dashboard link if custom domain is set and container is running
    dashboard_v2_url = None
    try:
        env = _read_env()
        domain = env.get('BLOBEVM_DOMAIN', '')
        if domain:
            # Check if container is running
            r = subprocess.run([
                'docker', 'ps', '-q', '-f', 'name=^blobedash-v2$'
            ], capture_output=True, text=True)
            cid = r.stdout.strip()
            if cid:
                dashboard_v2_url = f'http://{domain}/Dashboard'
    except Exception:
        dashboard_v2_url = None

    return render_template_string(TEMPLATE, title=title, manager_name=MANAGER_NAME, favicon_url=fav, dashboard_v2_url=dashboard_v2_url)


def manager_json_fleet_list():
    """Return VM inventory from every configured host, omitting unavailable hosts."""
    VM_HOST_REGISTRY.refresh()
    instances = []
    for host_id in VM_HOST_REGISTRY.providers:
        try:
            # Keep the no-argument local call as a compatibility seam for
            # existing overview tests and integrations; remote providers need
            # an explicit host id.
            listed = manager_json_list(host_id)
            for item in listed:
                name = str(item.get('name') or '')
                native_id = name if host_id == 'local' else str(item.get('id') or item.get('Id') or item.get('vm_id') or name)
                classification = _classify_vm_resource(item)
                item['resourceKey'] = _resource_key('vm', host_id, native_id)
                item['resourceType'] = 'vm'
                item['nativeId'] = native_id
                item['hostId'] = host_id
                item['classification'] = classification
                item['available'] = item.get('host_online') is not False
                item['stale'] = item.get('host_online') is False
                item['capabilities'] = _resource_capabilities(item, classification=classification)
                instances.append(item)
        except VmHostUnavailable:
            continue
        except Exception:
            # A single remote host must not make local inventory disappear.
            if host_id == 'local':
                raise
    return instances


@app.get('/dashboard/api/list')
@auth_required
def api_list():
    # Historical callers receive the local manager inventory exactly as
    # before.  The modern placement-aware dashboard opts into fleet mode so
    # legacy action URLs cannot accidentally act on a remote card as local.
    if request.args.get('fleet', '').lower() in {'1', 'true', 'yes'}:
        return jsonify({'instances': manager_json_fleet_list()})
    return jsonify({'instances': manager_json_list()})


@app.get('/dashboard/api/hosts')
@auth_required
def api_hosts():
    """Return redacted local/remote host inventory for dashboard placement UI."""
    try:
        VM_HOST_REGISTRY.refresh()
        hosts = [redact_host_record(record) for record in VM_HOST_REGISTRY.public_records()]
        payload = {'ok': True, 'hosts': hosts}
        if getattr(VM_HOST_REGISTRY, 'config_error', ''):
            payload['warning'] = VM_HOST_REGISTRY.config_error
        return jsonify(payload)
    except RemoteHostConfigError as exc:
        return jsonify({'ok': False, 'hosts': [], 'error': str(exc)}), 500


@app.get('/dashboard/api/games')
@auth_required
def api_games():
    """Proxy the gaming host's shared-library game catalog to the dashboard UI."""
    try:
        host = _vm_host('epic-pc')
        if host is None:
            return jsonify({'ok': True, 'games': []})
        # RemoteAgentHost wraps the raw client: agent calls go through
        # host.client._request (or the list_games helper), never host itself.
        if hasattr(host, 'list_games'):
            games = host.list_games()
        elif hasattr(host, 'client'):
            result = host.client._request('GET', '/v1/games', timeout=15)
            games = result.get('games', []) if isinstance(result, dict) else []
        else:
            result = host._request('GET', '/v1/games', timeout=15)
            games = result.get('games', []) if isinstance(result, dict) else []
        return jsonify({'ok': True, 'games': games})
    except Exception:
        app.logger.exception("failed to proxy /v1/games from epic-pc")
        return jsonify({'ok': True, 'games': []})


@app.route('/dashboard/api/hosts/enroll', methods=['POST', 'OPTIONS'], provide_automatic_options=False)
@app.route('/dashboard/api/remote-hosts/enroll', methods=['POST', 'OPTIONS'], provide_automatic_options=False)
@auth_required
def api_remote_host_enroll():
    """Enroll or replace a RemoteVM host from an authenticated dashboard upload."""
    if request.content_length and request.content_length > 32768:
        return jsonify({'ok': False, 'error': 'Enrollment payload is too large'}), 413
    try:
        host_id = str(request.form.get('host_id', '')).strip().lower()
        display_name = str(request.form.get('display_name', '')).strip()
        agent_url = str(request.form.get('agent_url', '')).strip()
        token_upload = request.files.get('token_file')
        if token_upload is not None:
            token_bytes = token_upload.stream.read(4097)
            if len(token_bytes) > 4096:
                return jsonify({'ok': False, 'error': 'Token file is too large'}), 413
            token = token_bytes.decode('utf-8').strip()
        else:
            token = str(request.form.get('token', '')).strip()
        if not token or any(char.isspace() for char in token):
            return jsonify({'ok': False, 'error': 'A single-line agent token file is required'}), 400
        record = upsert_remote_host_config({
            'id': host_id,
            'display_name': display_name,
            'agent_url': agent_url,
            'token': token,
            'provider': 'hyperv',
            'platform': 'windows',
        }, VM_HOST_REGISTRY.path)
        VM_HOST_REGISTRY.refresh(force=True)
        return jsonify({'ok': True, 'host': redact_host_record(record)}), 201
    except UnicodeDecodeError:
        return jsonify({'ok': False, 'error': 'Token file must be UTF-8 text'}), 400
    except RemoteHostConfigError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 400
    except OSError:
        return jsonify({'ok': False, 'error': 'Unable to store remote host enrollment'}), 500


@app.get('/dashboard/api/overview')
@auth_required
def api_overview():
    # Progressive loading: `?parts=host` returns only the cheap host/stats/
    # activity block (no VM manager shell-out), so the dashboard can paint
    # immediately and fill in the fleet from a second `?parts=instances` call.
    parts = {p.strip() for p in (request.args.get('parts') or '').split(',') if p.strip()}
    try:
        if not parts or parts == {'all'}:
            return jsonify({'ok': True, **_dashboard_overview_payload()})
        payload = {'ok': True, 'partial': True, 'parts': sorted(parts)}
        if 'host' in parts:
            payload.update(_dashboard_overview_host_payload())
        if 'instances' in parts:
            payload['instances'] = manager_json_fleet_list()
        return jsonify(payload)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.route('/Dashboard/api/<path:subpath>', methods=['GET', 'HEAD', 'OPTIONS', 'POST', 'PUT', 'PATCH', 'DELETE'])
def dashboard_api_case_compat(subpath):
    """Dispatch capitalized public API paths to legacy lower-case routes.

    The public deployment is mounted at /Dashboard, while older routes use
    /dashboard. Keep both spellings functional without duplicating every
    route decorator or changing legacy URLs.
    """
    from werkzeug.exceptions import NotFound
    adapter = app.url_map.bind_to_environ(request.environ)
    try:
        endpoint, values = adapter.match('/dashboard/api/' + subpath, method=request.method)
    except NotFound:
        return jsonify({'ok': False, 'error': 'Not found'}), 404
    view = app.view_functions.get(endpoint)
    if view is None:
        return jsonify({'ok': False, 'error': 'Not found'}), 404
    return view(**values)


@app.post('/dashboard/api/create')
@auth_required
def api_create():
    payload = request.get_json(silent=True) if request.is_json else None
    payload = payload if isinstance(payload, dict) else request.form.to_dict(flat=True)
    name = str(payload.get('name', '')).strip()
    if not name:
        return jsonify({'ok': False, 'error': 'No name provided'}), 400
    requested_host_id = str(payload.get('host_id') or payload.get('host') or 'local').strip() or 'local'
    requested_placement = str(payload.get('placement') or ('local' if requested_host_id == 'local' else 'remote')).strip().lower()
    if requested_placement not in {'local', 'remote'}:
        return jsonify({'ok': False, 'error': 'placement must be local or remote'}), 400
    if (requested_placement == 'local') != (requested_host_id == 'local'):
        return jsonify({'ok': False, 'error': 'placement and host_id do not agree'}), 400
    try:
        host = _vm_host(requested_host_id)
        if getattr(host, 'kind', 'local') == 'remote':
            host_record = next(
                (item for item in VM_HOST_REGISTRY.public_records() if item.get('id') == requested_host_id),
                None,
            )
            if not host_record or not host_record.get('online'):
                return jsonify({'ok': False, 'error': 'Selected VM host is offline.', 'code': 'host_offline'}), 409
            if not (host_record.get('capabilities') or {}).get('create_vm'):
                return jsonify({'ok': False, 'error': 'Selected VM host cannot create VMs.', 'code': 'capability_unavailable'}), 409
            spec = {
                key: payload[key]
                for key in ('image', 'cpu', 'memory', 'disk', 'profile')
                if payload.get(key) not in (None, '')
            }
            result = host.create(name, spec)
        else:
            result = host.run_manager('create', name, capture_output=True, text=True)
        if result.returncode == 125:
            # Docker exit 125: container name conflict or similar
            msg = result.stderr.strip() or 'VM already exists or container conflict.'
            # Try to start anyway
            host.run_manager('start', name, capture_output=True)
            return jsonify({'ok': False, 'error': msg})
        elif result.returncode != 0:
            return jsonify({'ok': False, 'error': result.stderr.strip() or 'Error creating VM.'}), 500
        # Preserve the local manager's auto-start behavior for remote agents.
        host.run_manager('start', name, capture_output=True)
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except FileNotFoundError:
        return jsonify({'ok': False, 'error': 'blobe-vm-manager not found in container. Make sure it is installed and mounted.'}), 500
    except Exception as e:
        return jsonify({'ok': False, 'error': f'Error creating VM: {e}'}), 500
    return jsonify({'ok': True, 'host_id': getattr(host, 'host_id', 'local'), 'placement': getattr(host, 'kind', 'local')})


@app.post('/dashboard/api/provisioning-jobs')
@auth_required
def api_provisioning_job_create():
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or payload.get('host') or '').strip()
    name = str(payload.get('name') or '').strip()
    profile = str(payload.get('profile') or 'standard').strip().lower()
    mode = str(payload.get('mode') or 'claim').strip().lower()
    if not host_id or not name or profile not in {'standard', 'gaming', 'omarchy'} or mode not in {'claim', 'automatic'}:
        response = jsonify({'ok': False, 'error': 'host_id, name, and a valid profile are required'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 400
    try:
        host = _vm_host(host_id)
        if getattr(host, 'kind', 'local') != 'remote' or not hasattr(host, 'provision'):
            message = 'Provisioning is available only on an enrolled remote Hyper-V host'
            if profile == 'omarchy':
                message = 'Omarchy Linux provisioning is available only on an enrolled remote Hyper-V host'
            response = jsonify({'ok': False, 'error': message})
            response.headers['Cache-Control'] = 'no-store'
            return response, 409
        host_record = host.public_record() if hasattr(host, 'public_record') else {}
        capability_key = {'omarchy': 'omarchy_provisioning', 'gaming': 'gaming_provisioning'}.get(profile, 'provisioning')
        if not (host_record.get('online') and (host_record.get('capabilities') or {}).get(capability_key)):
            message = 'Provisioning prerequisites are not ready on this host'
            code = 'omarchy_provisioning_unavailable' if profile == 'omarchy' else 'provisioning_unavailable'
            if profile == 'omarchy':
                message = 'Omarchy Linux prerequisites are not ready on this host; the experimental AMD GPU-P pilot remains gated.'
            response = jsonify({'ok': False, 'error': message, 'code': code})
            response.headers['Cache-Control'] = 'no-store'
            return response, 409
        guest_credentials = None
        sunshine_credentials = None
        orchestrator = None
        if mode == 'automatic':
            guest_credentials = _default_guest_credentials()
            if not guest_credentials:
                response = jsonify({'ok': False, 'error': {'code': 'provisioning_defaults_unavailable', 'message': 'The protected automatic provisioning defaults are not configured on this dashboard.'}})
                response.headers['Cache-Control'] = 'no-store'
                return response, 503
            orchestrator = _console_orchestrator()
            if _moonlight_console(orchestrator):
                sunshine_credentials = _default_sunshine_credentials()
                if not sunshine_credentials:
                    response = jsonify({'ok': False, 'error': {'code': 'sunshine_credentials_unavailable', 'message': 'The protected Sunshine default is not configured on this dashboard.'}})
                    response.headers['Cache-Control'] = 'no-store'
                    return response, 503
            else:
                sunshine_credentials = ('', '')
        profile_spec = _gaming_provisioning_spec(payload) if profile in {'gaming', 'omarchy'} else None
        if profile_spec is not None:
            result = host.provision(
                name,
                profile,
                spec=profile_spec,
                idempotency_key=request.headers.get('Idempotency-Key'),
            )
        else:
            result = host.provision(name, profile, idempotency_key=request.headers.get('Idempotency-Key'))
        if mode == 'automatic':
            job = result.get('job') if isinstance(result, dict) else None
            job_id = str(job.get('id') or '') if isinstance(job, dict) else ''
            if not job_id:
                raise ConsoleOrchestrationError('The host did not return a provisioning job id.', status=502, code='autonomous_provisioning_failed')
            operation_id = secrets.token_hex(16)
            task_key = (host_id, job_id)
            task_created = False
            with _CONSOLE_RETRY_LOCK:
                existing = _CONSOLE_RETRY_TASKS.get(task_key)
                if not (isinstance(existing, dict) and str(existing.get('status') or 'pending') == 'pending' and existing.get('autonomous')):
                    _CONSOLE_RETRY_TASKS[task_key] = {
                        'operationId': operation_id,
                        'startedAt': time.time(),
                        'status': 'pending',
                        'failureCode': '',
                        'routeReady': False,
                        'autonomous': True,
                        'stage': 'claim',
                    }
                    task_created = True
                else:
                    operation_id = str(existing.get('operationId') or operation_id)
            if task_created:
                worker = threading.Thread(
                    target=_start_remote_autonomous_provisioning,
                    kwargs={
                        'host': host,
                        'host_id': host_id,
                        'job_id': job_id,
                        'name': str(job.get('name') or name) if isinstance(job, dict) else name,
                        'claim_token': str(result.get('claimToken') or '') if isinstance(result, dict) else '',
                        'guest_username': guest_credentials[0],
                        'guest_password': guest_credentials[1],
                        'sunshine_username': sunshine_credentials[0],
                        'sunshine_password': sunshine_credentials[1],
                        'orchestrator': orchestrator,
                        'operation_id': operation_id,
                    },
                    name=f'epicvm-autonomous-provision-{operation_id[:8]}',
                    daemon=True,
                )
                worker.start()
            safe_job = _safe_provisioning_job(job)
            safe_job.update({
                'autonomousPending': True,
                'autonomousOperationId': operation_id,
                'autonomousStage': 'claim',
            })
            response = jsonify({
                'ok': True,
                'host_id': host_id,
                'mode': mode,
                'pending': True,
                'operationId': operation_id,
                'job': safe_job,
            })
        else:
            response = jsonify({'ok': True, 'host_id': host_id, 'mode': mode, **result})
        response.headers['Cache-Control'] = 'no-store'
        return response, 202
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to start the provisioning job'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.get('/dashboard/api/provisioning-jobs/pending')
@auth_required
def api_provisioning_jobs_pending():
    """List safe, unfinished remote jobs so the dashboard can recover itself."""
    entries = []
    try:
        VM_HOST_REGISTRY.refresh()
        providers = getattr(VM_HOST_REGISTRY, 'providers', {})
        provider_items = providers.items() if isinstance(providers, dict) else []
        for provider_id, host in provider_items:
            provider_id = str(provider_id)
            if provider_id == 'local' or getattr(host, 'kind', 'remote') != 'remote':
                continue
            if not hasattr(host, 'provisioning_jobs'):
                continue
            try:
                jobs = host.provisioning_jobs()
            except VmHostUnavailable:
                continue
            for raw_job in jobs if isinstance(jobs, list) else []:
                safe_job = _safe_provisioning_job(raw_job)
                task = None
                with _CONSOLE_RETRY_LOCK:
                    task = _CONSOLE_RETRY_TASKS.get((provider_id, str(safe_job.get('id') or '')))
                awaiting_visual = bool(task and task.get('status') == 'pending_visual')
                if not _is_pending_provisioning_job(raw_job) and not awaiting_visual:
                    continue
                if awaiting_visual:
                    safe_job.update({
                        'consoleVisualValidationPending': True,
                        'consoleRoutePrefix': str(task.get('routePrefix') or ''),
                        'consoleRepairOutcome': 'pending_visual',
                    })
                if task and task.get('autonomous'):
                    safe_job.update({
                        'autonomousPending': str(task.get('status') or 'pending') == 'pending',
                        'autonomousOperationId': str(task.get('operationId') or ''),
                        'autonomousStage': str(task.get('stage') or 'claim'),
                    })
                safe_job['claimAvailable'] = (
                    str(safe_job.get('state') or '') == 'unclaimed'
                    and not bool(safe_job.get('claimConsumed'))
                    and not bool(safe_job.get('autonomousPending'))
                )
                entries.append({
                    'host_id': provider_id,
                    'host_name': str(getattr(host, 'host_name', provider_id) or provider_id),
                    'job': safe_job,
                })
        entries.sort(key=lambda item: str(item.get('job', {}).get('updatedAt') or ''), reverse=True)
        response = jsonify({
            'ok': True,
            'jobs': entries,
            'sunshineDefaultConfigured': bool(_default_sunshine_credentials()),
        })
        response.headers['Cache-Control'] = 'no-store'
        return response
    except VmHostUnavailable:
        response = jsonify({'ok': True, 'jobs': [], 'sunshineDefaultConfigured': bool(_default_sunshine_credentials())})
        response.headers['Cache-Control'] = 'no-store'
        return response
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to list pending provisioning jobs'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.post('/dashboard/api/provisioning-jobs/recover')
@auth_required
def api_provisioning_job_recover():
    """Reissue a lost one-use claim for an unclaimed exact-name job.

    The agent replaces the stored verifier and returns the new claim only in
    this authenticated response. No claim value is persisted or returned by
    ordinary status/inventory endpoints.
    """
    if not _request_is_https():
        return jsonify({'ok': False, 'error': 'Claim recovery requires HTTPS'}), 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or '').strip()
    requested_job_id = str(payload.get('job_id') or payload.get('jobId') or '').strip()
    name = str(payload.get('name') or '').strip().lower()
    if not host_id or (not requested_job_id and not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', name)):
        return jsonify({'ok': False, 'error': 'host_id and either a valid job_id or VM name are required'}), 400
    if requested_job_id and not re.fullmatch(r'[A-Za-z0-9._:-]{1,128}', requested_job_id):
        return jsonify({'ok': False, 'error': 'job_id is invalid'}), 400
    try:
        host = _vm_host(host_id)
        if not hasattr(host, 'provisioning_jobs') or not hasattr(host, 'claim_reissue'):
            return jsonify({'ok': False, 'error': 'Claim recovery is unavailable on this host'}), 409
        jobs = [item for item in host.provisioning_jobs() if isinstance(item, dict)]
        candidates = [
            item for item in jobs
            if str(item.get('state') or '') == 'unclaimed'
            and not bool(item.get('claimConsumed'))
            and (
                str(item.get('id') or '') == requested_job_id
                if requested_job_id
                else str(item.get('name') or '').lower() == name
            )
        ]
        if not candidates:
            return jsonify({'ok': False, 'error': {'code': 'claim_recovery_not_available', 'message': 'No unclaimed pending job exists for this VM.'}}), 404
        candidates.sort(key=lambda item: str(item.get('updatedAt') or ''), reverse=True)
        job = candidates[0]
        job_id = str(job.get('id') or '')
        result = host.claim_reissue(job_id)
        claim_token = str(result.get('claimToken') or '') if isinstance(result, dict) else ''
        if not claim_token:
            return jsonify({'ok': False, 'error': 'The host did not return a new claim.'}), 502
        response = jsonify({'ok': True, 'host_id': host_id, 'job': result.get('job') or job, 'claimToken': claim_token})
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to recover the pending claim'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.get('/dashboard/api/provisioning-jobs/<job_id>')
@auth_required
def api_provisioning_job_status(job_id):
    host_id = str(request.args.get('host_id') or '').strip()
    if not host_id:
        return jsonify({'ok': False, 'error': 'host_id is required'}), 400
    try:
        host = _vm_host(host_id)
        if not hasattr(host, 'provisioning_status'):
            return jsonify({'ok': False, 'error': 'Provisioning is unavailable on this host'}), 409
        status = host.provisioning_status(job_id)
        _prune_console_retry_tasks()
        pending = None
        with _CONSOLE_RETRY_LOCK:
            pending = _CONSOLE_RETRY_TASKS.get((host_id, str(job_id)))
        if pending and isinstance(status, dict) and isinstance(status.get('job'), dict):
            status = dict(status)
            status['job'] = dict(status['job'])
            task_status = str(pending.get('status') or 'pending')
            task_kind = str(pending.get('kind') or 'retry')
            if task_kind == 'repair':
                # A repair is deliberately read-only against the provisioning
                # job. Never overlay a ready job as streaming_setup while the
                # Moonlight bundle is being rebuilt.
                if task_status == 'pending':
                    status['job'].update({
                        'consoleRepairPending': True,
                        'consoleOperationId': pending['operationId'],
                    })
                elif task_status == 'failed':
                    status['job'].update({
                        'consoleRepairPending': False,
                        'consoleRepairOutcome': 'failed',
                        'consoleOperationId': pending['operationId'],
                        'consoleRepairErrorCode': _safe_console_retry_code(pending.get('failureCode')),
                    })
                elif task_status == 'ready':
                    status['job'].update({
                        'consoleRepairPending': False,
                        'consoleRepairOutcome': 'ready',
                        'consoleOperationId': pending['operationId'],
                    })
                elif task_status == 'pending_visual':
                    status['job'].update({
                        'consoleRepairPending': False,
                        'consoleRepairOutcome': 'pending_visual',
                        'consoleVisualValidationPending': True,
                        'consoleRoutePrefix': str(pending.get('routePrefix') or status['job'].get('consoleRoutePrefix') or ''),
                        'consoleOperationId': pending['operationId'],
                    })
            elif pending.get('autonomous'):
                status['job'].update({
                    'autonomousPending': task_status == 'pending',
                    'autonomousOperationId': pending['operationId'],
                    'autonomousStage': str(pending.get('stage') or 'claim'),
                })
                if task_status == 'failed':
                    status['job'].update({
                        'autonomousOutcome': 'failed',
                        'autonomousErrorCode': _safe_console_retry_code(pending.get('failureCode'), 'autonomous_provisioning_failed'),
                    })
                elif task_status == 'ready':
                    status['job']['autonomousOutcome'] = 'ready'
                elif task_status == 'pending_visual':
                    status['job'].update({
                        'autonomousOutcome': 'pending_visual',
                        'consoleVisualValidationPending': True,
                        'consoleRoutePrefix': str(pending.get('routePrefix') or status['job'].get('consoleRoutePrefix') or ''),
                    })
            elif task_status == 'pending':
                # The agent may still show setup_failed:streaming until its
                # credential-bearing request completes. Overlay only safe,
                # non-secret pending metadata for this dashboard process.
                status['job'].update({
                    'state': 'streaming_setup',
                    'consoleRetryPending': True,
                    'consoleOperationId': pending['operationId'],
                })
            elif task_status == 'failed':
                # A host update can fail while the background worker is
                # finishing (for example during a transient agent restart).
                # Keep the safe terminal outcome visible instead of silently
                # returning the old retry form with no explanation.
                status['job'].update({
                    'consoleRetryPending': False,
                    'consoleRetryOutcome': 'failed',
                    'consoleOperationId': pending['operationId'],
                    'errorCode': _safe_console_retry_code(pending.get('failureCode')),
                })
            elif task_status == 'ready':
                # The agent is authoritative for the persisted ready state;
                # expose only the safe correlation/result metadata here.
                status['job'].update({
                    'consoleRetryPending': False,
                    'consoleRetryOutcome': 'ready',
                    'consoleOperationId': pending['operationId'],
                })
            elif task_status == 'pending_visual':
                status['job'].update({
                    'consoleRetryPending': False,
                    'consoleRetryOutcome': 'pending_visual',
                    'consoleVisualValidationPending': True,
                    'consoleRoutePrefix': str(pending.get('routePrefix') or status['job'].get('consoleRoutePrefix') or ''),
                    'consoleOperationId': pending['operationId'],
                })
        response = jsonify({'ok': True, 'host_id': host_id, **status})
        response.headers['Cache-Control'] = 'no-store'
        return response
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to read the provisioning job'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.post('/dashboard/api/provisioning-jobs/<job_id>/claim')
@auth_required
def api_provisioning_job_claim(job_id):
    if not _request_is_https():
        response = jsonify({'ok': False, 'error': 'Guest claims require HTTPS'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or '').strip()
    username = str(payload.get('username') or '')
    password = str(payload.get('password') or '')
    claim_token = str(payload.get('claimToken') or payload.get('claim_token') or '')
    # Claim mode accepts the guest account credentials for the selected profile. Sunshine
    # pairing always uses the protected dashboard default; client-supplied
    # Sunshine fields are ignored rather than treated as an override.
    sunshine_username = ''
    sunshine_password = ''
    if not host_id or not username or not password or not claim_token:
        response = jsonify({'ok': False, 'error': 'host_id and claim fields are required'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 400
    orchestrator = _console_orchestrator()
    if _moonlight_console(orchestrator):
        resolved_sunshine = _resolve_sunshine_credentials(sunshine_username, sunshine_password)
        if not resolved_sunshine:
            response = jsonify({'ok': False, 'error': {'code': 'sunshine_credentials_unavailable', 'message': 'The protected Sunshine default is not configured on this dashboard.'}})
            response.headers['Cache-Control'] = 'no-store'
            return response, 503
        sunshine_username, sunshine_password = resolved_sunshine
    try:
        host = _vm_host(host_id)
        if not hasattr(host, 'claim'):
            response = jsonify({'ok': False, 'error': 'Guest claiming is unavailable on this host'})
            response.headers['Cache-Control'] = 'no-store'
            return response, 409
        result = host.claim(job_id, username, password, claim_token)
        job = result.get('job') if isinstance(result, dict) else None
        if not isinstance(job, dict) or job.get('state') != 'streaming_setup':
            guest_os = 'Omarchy Linux' if isinstance(job, dict) and str(job.get('profile') or '').lower() == 'omarchy' else 'Windows'
            raise ConsoleOrchestrationError(f'The {guest_os} host did not reach the console gate.', status=422, code='console_gate_missing')
        guest_ip = str(job.get('tailnetIp') or '')
        name = str(job.get('name') or '')
        if _moonlight_console(orchestrator):
            if not hasattr(host, 'console_credentials'):
                raise ConsoleOrchestrationError('Automatic Sunshine setup is unavailable on this host.', status=503, code='sunshine_setup_unavailable')
            host.console_credentials(
                job_id,
                guest_username=username,
                guest_password=password,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
            )
            route_name = _remote_console_route_name(name, host_id) if getattr(host, 'kind', 'local') == 'remote' else name
            plan = orchestrator.build_plan(name=name, guest_ip=guest_ip, route_name=route_name)
        else:
            plan = orchestrator.build_plan(name=name, guest_ip=guest_ip, username=username, password=password)
        orchestrator.stage_plan(plan)
        started = orchestrator.start_staged(name)
        if _moonlight_console(orchestrator):
            started = orchestrator.pair_staged(name, sunshine_username=sunshine_username, sunshine_password=sunshine_password)
        route_prefix = str(plan.route_prefix)
        guest_tcp_verified = bool(started.get('guestTcpVerified'))
        status_result = host.provisioning_status(job_id) if hasattr(host, 'provisioning_status') else {}
        pending_job = status_result.get('job') if isinstance(status_result, dict) else None
        safe_job = _safe_provisioning_job(pending_job if isinstance(pending_job, dict) else job)
        safe_job.update({
            'consoleRoutePrefix': route_prefix,
            'consoleVisualValidationPending': True,
        })
        response = jsonify({
            'ok': True,
            'host_id': host_id,
            'pendingVisualValidation': True,
            'consoleRoutePrefix': route_prefix,
            'guestTcpVerified': guest_tcp_verified,
            'job': safe_job,
        })
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response
    except ConsoleOrchestrationError as exc:
        try:
            if 'orchestrator' in locals() and 'name' in locals():
                orchestrator.stop_staged(name)
            if 'host' in locals() and hasattr(host, 'console_failed'):
                host.console_failed(job_id, code=str(getattr(exc, 'code', 'console_failed')))
        except Exception:
            pass
        response = jsonify({'ok': False, 'error': {'code': str(getattr(exc, 'code', 'console_failed')), 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 502) or 502)
    except VmHostUnavailable as exc:
        response, status = _vm_host_error_response(exc)
        response.headers['Cache-Control'] = 'no-store'
        return response, status
    except Exception:
        # Never reflect exception text from a credential-bearing request.
        try:
            if 'orchestrator' in locals() and 'name' in locals():
                orchestrator.stop_staged(name)
            if 'host' in locals() and hasattr(host, 'console_failed'):
                host.console_failed(job_id, code='console_failed')
        except Exception:
            pass
        response = jsonify({'ok': False, 'error': 'Unable to complete the one-time guest claim'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502
    finally:
        # Drop local references after the transport call. The request body is
        # never logged or returned, and the agent owns the one-time verifier.
        username = password = claim_token = sunshine_username = sunshine_password = ''


@app.post('/dashboard/api/provisioning-jobs/<job_id>/console-verify')
@auth_required
def api_provisioning_job_console_verify(job_id):
    """Compatibility endpoint for automated route and guest transport completion."""
    if not _request_is_https():
        response = jsonify({'ok': False, 'error': 'Console verification requires HTTPS'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or '').strip()
    route_prefix = str(payload.get('routePrefix') or payload.get('route_prefix') or '').strip()
    if not host_id or not route_prefix:
        return jsonify({'ok': False, 'error': 'host_id and routePrefix are required'}), 400
    if payload.get('guestTcpVerified') is not True:
        return jsonify({'ok': False, 'error': 'Guest transport evidence is required'}), 422
    frame_metrics = payload.get('frameMetrics')
    if not isinstance(frame_metrics, dict):
        return jsonify({'ok': False, 'error': 'Decoded video frame evidence is required'}), 422
    try:
        host = _vm_host(host_id)
        if not hasattr(host, 'console_complete') or not hasattr(host, 'provisioning_status'):
            return jsonify({'ok': False, 'error': 'Console verification is unavailable on this host'}), 409
        current = host.provisioning_status(job_id)
        current_job = current.get('job') if isinstance(current, dict) else None
        if not isinstance(current_job, dict):
            return jsonify({'ok': False, 'error': 'Provisioning job was not found'}), 404
        result = host.console_complete(
            job_id,
            route_prefix=route_prefix,
            guest_tcp_verified=True,
            frame_metrics=frame_metrics,
        )
        task_key = (host_id, str(job_id))
        with _CONSOLE_RETRY_LOCK:
            pending = _CONSOLE_RETRY_TASKS.get(task_key)
        if isinstance(pending, dict):
            _set_console_retry_result(
                task_key,
                status='ready',
                operation_id=str(pending.get('operationId') or ''),
                route_prefix=route_prefix,
            )
        result_job = result.get('job') if isinstance(result, dict) else None
        safe_job = _safe_provisioning_job(result_job if isinstance(result_job, dict) else current_job)
        safe_job['consoleVisualValidationPending'] = False
        response = jsonify({
            'ok': True,
            'host_id': host_id,
            'visualValidationComplete': True,
            'consoleRoutePrefix': route_prefix,
            'job': safe_job,
        })
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response
    except ConsoleOrchestrationError as exc:
        response = jsonify({'ok': False, 'error': {'code': str(getattr(exc, 'code', 'console_verification_failed')), 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 422) or 422)
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to persist browser-KVM console evidence'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.post('/dashboard/api/provisioning-jobs/<job_id>/retry-console')
@auth_required
def api_provisioning_job_retry_console(job_id):
    if not _request_is_https():
        response = jsonify({'ok': False, 'error': 'Console retry requires HTTPS'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or '').strip()
    username = str(payload.get('username') or '')
    password = str(payload.get('password') or '')
    # Retained console retries use the protected Sunshine default as well;
    # only the Windows credentials are accepted from the browser.
    sunshine_username = ''
    sunshine_password = ''
    if not host_id or not username or not password:
        return jsonify({'ok': False, 'error': 'host_id and console credentials are required'}), 400
    orchestrator = _console_orchestrator()
    if _moonlight_console(orchestrator):
        resolved_sunshine = _resolve_sunshine_credentials(sunshine_username, sunshine_password)
        if not resolved_sunshine:
            return jsonify({'ok': False, 'error': {'code': 'sunshine_credentials_unavailable', 'message': 'The protected Sunshine default is not configured on this dashboard.'}}), 503
        sunshine_username, sunshine_password = resolved_sunshine
    try:
        host = _vm_host(host_id)
        current = host.provisioning_status(job_id)
        job = current.get('job') if isinstance(current, dict) else None
        current_state = str(job.get('state') or '') if isinstance(job, dict) else ''
        if current_state == 'ready':
            # A concurrent retry may have completed the retained console while
            # this request was in flight.  Treat that outcome as idempotent;
            # never turn a successful console back into a failure.
            response = jsonify({'ok': True, 'host_id': host_id, 'job': job})
            response.headers['Cache-Control'] = 'no-store'
            return response
        if current_state != 'setup_failed:streaming':
            raise ConsoleOrchestrationError('Only a failed console step may be retried.', status=409, code='console_retry_not_allowed')
        name = str(job.get('name') or '')
        guest_ip = str(job.get('tailnetIp') or '')
        task_key = (host_id, str(job_id))
        if _moonlight_console(orchestrator) and getattr(host, 'kind', 'local') == 'remote':
            with _CONSOLE_RETRY_LOCK:
                pending = _CONSOLE_RETRY_TASKS.get(task_key)
                if isinstance(pending, dict) and str(pending.get('status') or 'pending') == 'pending':
                    raise ConsoleOrchestrationError(
                        'Console setup is already running for this VM.',
                        status=409,
                        code='console_retry_in_progress',
                    )
                operation_id = secrets.token_hex(16)
                _CONSOLE_RETRY_TASKS[task_key] = {
                    'operationId': operation_id,
                    'startedAt': time.time(),
                    'status': 'pending',
                    'failureCode': '',
                    'routeReady': False,
                }
            worker = threading.Thread(
                target=_start_remote_moonlight_console_retry,
                kwargs={
                    'host': host,
                    'host_id': host_id,
                    'job_id': job_id,
                    'name': name,
                    'guest_ip': guest_ip,
                    'route_name': _remote_console_route_name(name, host_id),
                    'guest_username': username,
                    'guest_password': password,
                    'sunshine_username': sunshine_username,
                    'sunshine_password': sunshine_password,
                    'orchestrator': orchestrator,
                    'operation_id': operation_id,
                },
                name=f'epicvm-console-retry-{operation_id[:8]}',
                daemon=True,
            )
            worker.start()
            response = jsonify({
                'ok': True,
                'pending': True,
                'host_id': host_id,
                'operationId': operation_id,
                'job': {
                    **job,
                    'state': 'streaming_setup',
                    'consoleRetryPending': True,
                    'consoleOperationId': operation_id,
                },
            })
            response.headers['Cache-Control'] = 'no-store'
            response.headers['Pragma'] = 'no-cache'
            return response, 202
        orchestrator.quarantine_staged(name)
        if _moonlight_console(orchestrator):
            if not hasattr(host, 'console_credentials'):
                raise ConsoleOrchestrationError('Automatic Sunshine setup is unavailable on this host.', status=503, code='sunshine_setup_unavailable')
            host.console_credentials(
                job_id,
                guest_username=username,
                guest_password=password,
                sunshine_username=sunshine_username,
                sunshine_password=sunshine_password,
            )
            route_name = _remote_console_route_name(name, host_id) if getattr(host, 'kind', 'local') == 'remote' else name
            plan = orchestrator.build_plan(name=name, guest_ip=guest_ip, route_name=route_name)
        else:
            plan = orchestrator.build_plan(name=name, guest_ip=guest_ip, username=username, password=password)
        orchestrator.stage_plan(plan)
        started = orchestrator.start_staged(name)
        if _moonlight_console(orchestrator):
            started = orchestrator.pair_staged(name, sunshine_username=sunshine_username, sunshine_password=sunshine_password)
        route_prefix = str(plan.route_prefix)
        guest_tcp_verified = bool(started.get('guestTcpVerified'))
        status_result = host.provisioning_status(job_id) if hasattr(host, 'provisioning_status') else {}
        pending_job = status_result.get('job') if isinstance(status_result, dict) else None
        safe_job = _safe_provisioning_job(pending_job if isinstance(pending_job, dict) else job)
        safe_job.update({
            'state': 'streaming_setup',
            'consoleRoutePrefix': route_prefix,
            'consoleVisualValidationPending': True,
        })
        response = jsonify({
            'ok': True,
            'host_id': host_id,
            'pendingVisualValidation': True,
            'consoleRoutePrefix': route_prefix,
            'guestTcpVerified': guest_tcp_verified,
            'job': safe_job,
        })
        response.headers['Cache-Control'] = 'no-store'
        return response
    except ConsoleOrchestrationError as exc:
        failure_code = str(getattr(exc, 'code', 'console_failed') or 'console_failed')
        try:
            if 'orchestrator' in locals() and 'name' in locals():
                orchestrator.stop_staged(name)
            # A retry-state conflict is read-only.  In particular, do not
            # convert a transient in-progress/ready race into a new failed
            # state or overwrite the diagnostic code from the winning request.
            if failure_code not in ('console_retry_not_allowed', 'console_retry_in_progress') and 'host' in locals() and hasattr(host, 'console_failed'):
                host.console_failed(job_id, code=failure_code)
        except Exception:
            pass
        response = jsonify({'ok': False, 'error': {'code': failure_code, 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 502) or 502)
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        try:
            if 'orchestrator' in locals() and 'name' in locals():
                orchestrator.stop_staged(name)
            if 'host' in locals() and hasattr(host, 'console_failed'):
                host.console_failed(job_id, code='console_failed')
        except Exception:
            pass
        response = jsonify({'ok': False, 'error': 'Unable to retry console configuration'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502
    finally:
        username = password = sunshine_username = sunshine_password = ''


@app.post('/dashboard/api/provisioning-jobs/<job_id>/restart-session')
@auth_required
def api_provisioning_job_restart_session(job_id):
    """Bounded stream-start recovery for a black first-frame session.

    The pinned Moonlight server intermittently answers a session start with
    ``control: the control stream hasn't successfully connected yet`` and then
    delivers no video; the client stays black while every health probe stays
    green.  This endpoint restarts only the console container so the next
    browser attempt gets a fresh WebRTC endpoint.  It never mutates VM, guest,
    claim, or readiness evidence: a restarted session still has to produce
    real frame, keyboard, and mouse proof before the job may become ready.
    """
    if not _request_is_https():
        response = jsonify({'ok': False, 'error': 'Session restart requires HTTPS'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or '').strip()
    route_prefix = str(payload.get('routePrefix') or payload.get('route_prefix') or '').strip()
    if not host_id or not route_prefix:
        return jsonify({'ok': False, 'error': 'host_id and routePrefix are required'}), 400
    orchestrator = _console_orchestrator()
    try:
        host = _vm_host(host_id)
        current = host.provisioning_status(job_id)
        job = current.get('job') if isinstance(current, dict) else None
        if not isinstance(job, dict):
            return jsonify({'ok': False, 'error': 'Provisioning job was not found'}), 404
        name = str(job.get('name') or '')
        if hasattr(orchestrator, 'restart_session'):
            route_name = _remote_console_route_name(name, host_id) if getattr(host, 'kind', 'local') == 'remote' else name
            result = orchestrator.restart_session(name, route_name=route_name)
        else:
            raise ConsoleOrchestrationError(
                'Stream restart is unavailable on this backend.',
                status=503,
                code='restart_session_unavailable',
            )
        status_result = host.provisioning_status(job_id) if hasattr(host, 'provisioning_status') else {}
        fresh_job = status_result.get('job') if isinstance(status_result, dict) else None
        safe_job = _safe_provisioning_job(fresh_job if isinstance(fresh_job, dict) else job)
        response = jsonify({
            'ok': True,
            'host_id': host_id,
            'consoleRoutePrefix': route_prefix,
            'job': safe_job,
            **result,
        })
        response.headers['Cache-Control'] = 'no-store'
        return response
    except ConsoleOrchestrationError as exc:
        response = jsonify({'ok': False, 'error': {'code': str(getattr(exc, 'code', 'restart_session_failed')), 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 502) or 502)
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to restart the streaming session'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.post('/dashboard/api/provisioning-jobs/<job_id>/repair-console')
@auth_required
def api_provisioning_job_repair_console(job_id):
    """Repair a broken Moonlight bundle without reprovisioning the VM."""
    if not _request_is_https():
        response = jsonify({'ok': False, 'error': 'Console repair requires HTTPS'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or '').strip()
    sunshine_username = str(payload.get('sunshineUsername') or payload.get('sunshine_username') or '')
    sunshine_password = str(payload.get('sunshinePassword') or payload.get('sunshine_password') or '')
    if not host_id:
        return jsonify({'ok': False, 'error': 'host_id is required'}), 400
    orchestrator = _console_orchestrator()
    if not _moonlight_console(orchestrator):
        return jsonify({'ok': False, 'error': {'code': 'console_repair_not_allowed', 'message': 'Moonlight console repair is unavailable on this host.'}}), 409
    resolved_sunshine = _resolve_sunshine_credentials(sunshine_username, sunshine_password)
    if not resolved_sunshine:
        return jsonify({'ok': False, 'error': {'code': 'sunshine_credentials_unavailable', 'message': 'The protected Sunshine default is not configured on this dashboard.'}}), 503
    sunshine_username, sunshine_password = resolved_sunshine
    resolved_guest = _default_guest_credentials()
    if not resolved_guest:
        return jsonify({'ok': False, 'error': {'code': 'guest_credentials_unavailable', 'message': 'The protected guest default is not configured on this dashboard.'}}), 503
    guest_username, guest_password = resolved_guest
    try:
        host = _vm_host(host_id)
        if getattr(host, 'kind', 'local') != 'remote':
            raise ConsoleOrchestrationError(
                'Only a retained remote VM console can be repaired.',
                status=409,
                code='console_repair_not_allowed',
            )
        current = host.provisioning_status(job_id)
        job = current.get('job') if isinstance(current, dict) else None
        current_state = str(job.get('state') or '') if isinstance(job, dict) else ''
        completed_stages = job.get('completedStages') if isinstance(job, dict) else []
        completed_stages = completed_stages if isinstance(completed_stages, list) else []
        recoverable_state = current_state == 'ready' or (
            current_state == 'setup_failed:streaming' and
            'management_handoff' in {str(stage) for stage in completed_stages}
        )
        if not recoverable_state:
            raise ConsoleOrchestrationError(
                'Only a ready or recoverable remote VM console can be repaired.',
                status=409,
                code='console_repair_not_allowed',
            )
        name = str(job.get('name') or '').strip().lower()
        guest_ip = str(job.get('tailnetIp') or '').strip()
        if not name or not guest_ip:
            raise ConsoleOrchestrationError(
                'The ready VM has no verified guest address for console repair.',
                status=409,
                code='console_repair_not_allowed',
            )
        task_key = (host_id, str(job_id))
        with _CONSOLE_RETRY_LOCK:
            pending = _CONSOLE_RETRY_TASKS.get(task_key)
            if isinstance(pending, dict) and str(pending.get('status') or 'pending') == 'pending':
                raise ConsoleOrchestrationError(
                    'Console setup is already running for this VM.',
                    status=409,
                    code='console_retry_in_progress',
                )
            operation_id = secrets.token_hex(16)
            _CONSOLE_RETRY_TASKS[task_key] = {
                'operationId': operation_id,
                'startedAt': time.time(),
                'status': 'pending',
                'failureCode': '',
                'routeReady': False,
                'kind': 'repair',
            }
        worker = threading.Thread(
            target=_start_remote_moonlight_console_repair,
            kwargs={
                'host': host,
                'host_id': host_id,
                'job_id': job_id,
                'name': name,
                'guest_ip': guest_ip,
                'route_name': _remote_console_route_name(name, host_id),
                'guest_username': guest_username,
                'guest_password': guest_password,
                'sunshine_username': sunshine_username,
                'sunshine_password': sunshine_password,
                'orchestrator': orchestrator,
                'operation_id': operation_id,
            },
            name=f'epicvm-console-repair-{operation_id[:8]}',
            daemon=True,
        )
        worker.start()
        response = jsonify({
            'ok': True,
            'pending': True,
            'host_id': host_id,
            'operationId': operation_id,
            'job': {
                **job,
                'consoleRepairPending': True,
                'consoleOperationId': operation_id,
            },
        })
        response.headers['Cache-Control'] = 'no-store'
        response.headers['Pragma'] = 'no-cache'
        return response, 202
    except ConsoleOrchestrationError as exc:
        response = jsonify({'ok': False, 'error': {'code': str(getattr(exc, 'code', 'console_repair_failed')), 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 502) or 502)
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to start the console repair'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502
    finally:
        sunshine_username = sunshine_password = ''


@app.post('/dashboard/api/deprovisioning-jobs')
@auth_required
def api_deprovisioning_job_create():
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or payload.get('host') or '').strip()
    name = str(payload.get('name') or '').strip()
    confirm_name = str(payload.get('confirmName') or payload.get('confirm_name') or '')
    if not host_id or not name or confirm_name != name:
        response = jsonify({'ok': False, 'error': 'Exact VM name confirmation is required'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 400
    try:
        host = _vm_host(host_id)
        if not hasattr(host, 'deprovision'):
            response = jsonify({'ok': False, 'error': 'Teardown is unavailable on this host'})
            response.headers['Cache-Control'] = 'no-store'
            return response, 409
        # Remove the externally reachable route first. The orchestrator only
        # accepts exact EpicVM-owned bundle directories and quarantines rather
        # than deleting their volumes.
        _console_for_vm(name).teardown(name=name, confirm_name=confirm_name)
        result = host.deprovision(name, confirm_name=confirm_name, idempotency_key=request.headers.get('Idempotency-Key'))
        response = jsonify({'ok': True, 'host_id': host_id, **result})
        response.headers['Cache-Control'] = 'no-store'
        return response, 202
    except ConsoleOrchestrationError as exc:
        response = jsonify({'ok': False, 'error': {'code': str(getattr(exc, 'code', 'console_teardown_failed')), 'message': str(exc)}})
        response.headers['Cache-Control'] = 'no-store'
        return response, int(getattr(exc, 'status', 502) or 502)
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to start the teardown job'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.get('/dashboard/api/deprovisioning-jobs/<job_id>')
@auth_required
def api_deprovisioning_job_status(job_id):
    host_id = str(request.args.get('host_id') or '').strip()
    if not host_id:
        return jsonify({'ok': False, 'error': 'host_id is required'}), 400
    try:
        host = _vm_host(host_id)
        if not hasattr(host, 'deprovisioning_status'):
            return jsonify({'ok': False, 'error': 'Teardown is unavailable on this host'}), 409
        response = jsonify({'ok': True, 'host_id': host_id, **host.deprovisioning_status(job_id)})
        response.headers['Cache-Control'] = 'no-store'
        return response
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': 'Unable to read the teardown job'})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502

@app.post('/dashboard/api/start/<name>')
@auth_required
def api_start(name):
    force = request.values.get('force') in ('1', 'true', 'yes', 'on')
    try:
        host = _vm_host()
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    is_remote = getattr(host, 'kind', 'local') == 'remote'
    # Safe-start: reject if already running
    if not is_remote:
        try:
            cname = f'blobevm_{name}'
            r = _docker('ps', '-q', '-f', f'name=^{cname}$')
            if r.returncode == 0 and r.stdout.strip():
                return jsonify({'ok': False, 'error': 'VM already running'})
        except Exception:
            pass
        # Optimizer admission control (bounded so a slow/hung optimizer can
        # never block or time out a user-initiated start). Only block when the
        # optimizer positively returns a denial within the time budget.
        if not force:
            try:
                import threading as _th
                _opt_res = {}
                def _opt_check():
                    try:
                        st = dash_optimizer.status()
                        stats = st.get('stats') or {}
                        profiles = (stats.get('profiles') or {}) if isinstance(stats, dict) else {}
                        profile = profiles.get(name, 'desktop')
                        _opt_res['deny'] = dash_optimizer._can_start_vm(
                            st.get('cfg') or {},
                            stats.get('vmStates') or [],
                            stats.get('hostPressure') or {},
                            profile=profile, force=False,
                        )
                    except Exception as _e:
                        _opt_res['err'] = str(_e)
                _t = _th.Thread(target=_opt_check, daemon=True)
                _t.start()
                _t.join(6)
                if 'deny' in _opt_res and not _opt_res['deny'].get('ok'):
                    return jsonify({'ok': False, 'error': _opt_res['deny'].get('reason') or 'Start blocked by optimizer', 'code': _opt_res['deny'].get('code'), 'optimizer': _opt_res['deny']}), 409
                # If it timed out or errored, fall through and allow the start
                # (mirrors the portal start path, which does no optimizer gate).
            except Exception:
                pass
    try:
        _ensure_remote_vm_exists(host, name)
        result = host.run_manager('start', name, capture_output=True, text=True)
        if result.returncode != 0:
            return jsonify({'ok': False, 'error': result.stderr.strip() or 'Failed to start VM'}), 500
        try:
            dash_optimizer.note_vm_activity(name, 'api-start')
        except Exception:
            pass
        return jsonify({'ok': True})
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except FileNotFoundError:
        return jsonify({'ok': False, 'error': 'blobe-vm-manager not found'}), 500
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/vm/<name>/status')
@auth_required
def api_vm_status(name):
    """Return rich state for the selected local or remote VM."""
    try:
        host = _vm_host()
        if getattr(host, 'kind', 'local') == 'remote':
            envelope = host.status(name)
            envelope = dict(envelope) if isinstance(envelope, dict) else {}
            raw_vm = envelope.get('vm') if isinstance(envelope.get('vm'), dict) else envelope
            vm = normalize_remote_vm_record(raw_vm)
            envelope.update({
                'ok': bool(envelope.get('ok', True)),
                'vm': vm,
                'placement': 'remote',
                'host_id': host.host_id,
                'host_name': host.host_name,
                # Keep the legacy wrapper contract flat while retaining the
                # full normalized agent record under ``vm``.
                'state': vm.get('state', 'Unknown'),
                'status': vm.get('status', 'Unknown'),
                'provider_status': vm.get('provider_status', ''),
                'running': bool(vm.get('running', False)),
                'vm_id': vm.get('id', vm.get('Id', '')),
                'profile': vm.get('profile', 'standard'),
            })
            return jsonify(envelope)
        return jsonify(_vm_status_payload(name))
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/vm/<name>/console-reconcile')
@auth_required
def api_vm_console_reconcile(name):
    """Verify or safely repair a ready remote VM's Moonlight bundle.

    The inventory's ``consoleReady`` flag is a provisioning checkpoint, not a
    live Sunshine certificate check. This endpoint is the last-mile boundary
    used before opening a remote console. It returns immediately when the
    authenticated host query passes, and schedules a bounded repair when the
    persisted bundle is stale. Guest TCP is checked before any quarantine.
    """
    if not _request_is_https():
        return jsonify({'ok': False, 'error': 'Console reconciliation requires HTTPS'}), 426
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or payload.get('host') or '').strip()
    if not host_id:
        return jsonify({'ok': False, 'error': 'host_id is required'}), 400
    try:
        result = _reconcile_remote_console(name, host_id, wait=False)
        response = jsonify(result)
        response.headers['Cache-Control'] = 'no-store'
        if result.get('pending'):
            response.headers['Pragma'] = 'no-cache'
            return response, 202
        return response
    except ConsoleOrchestrationError as exc:
        code = _safe_console_retry_code(getattr(exc, 'code', 'console_reconcile_failed'), 'console_reconcile_failed')
        if code == 'sunshine_tcp_unavailable':
            message = 'The remote guest is not reachable on the Sunshine listeners; the existing console bundle was preserved.'
            status = 409
        elif code == 'console_repair_pending':
            message = 'Remote console repair is still in progress; retry shortly.'
            status = 503
        else:
            message = str(exc) if code == 'console_repair_not_allowed' else 'Remote console reconciliation failed safely.'
            status = int(getattr(exc, 'status', 502) or 502)
            status = status if 400 <= status <= 599 else 502
        response = jsonify({'ok': False, 'healthy': False, 'error': {'code': code, 'message': message}})
        response.headers['Cache-Control'] = 'no-store'
        return response, status
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception:
        response = jsonify({'ok': False, 'error': {'code': 'console_reconcile_failed', 'message': 'Remote console reconciliation failed safely.'}})
        response.headers['Cache-Control'] = 'no-store'
        return response, 502


@app.post('/dashboard/api/vm/<name>/gpu-partition')
@auth_required
def api_vm_gpu_partition(name):
    """Change only the live GPU-P partition percentage for a managed GPU-P VM."""
    payload = request.get_json(silent=True) if request.is_json else request.form.to_dict(flat=True)
    payload = payload if isinstance(payload, dict) else {}
    host_id = str(payload.get('host_id') or payload.get('host') or '').strip()
    raw_percent = payload.get('percent')
    if not host_id or raw_percent in (None, ''):
        return jsonify({'ok': False, 'error': 'host_id and percent are required'}), 400
    try:
        percent = int(raw_percent)
    except (TypeError, ValueError):
        return jsonify({'ok': False, 'error': 'percent must be an integer between 1 and 100'}), 400
    if percent < 1 or percent > 100:
        return jsonify({'ok': False, 'error': 'percent must be between 1 and 100'}), 400
    try:
        host = _vm_host(host_id)
        if getattr(host, 'kind', 'local') != 'remote' or not callable(getattr(host, 'set_gaming_gpu_percent', None)):
            return jsonify({'ok': False, 'error': 'GPU-P partition updates are available only on an enrolled remote Hyper-V host'}), 409
        _ensure_remote_vm_exists(host, name)
        result = host.set_gaming_gpu_percent(
            name,
            percent,
            idempotency_key=request.headers.get('Idempotency-Key'),
        )
        if getattr(result, 'returncode', 0) != 0:
            return jsonify({'ok': False, 'error': 'The remote GPU-P partition update failed'}), 502
        return jsonify({'ok': True, 'host_id': host_id, 'name': name, 'percent': percent})
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except ValueError as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 400
    except Exception:
        return jsonify({'ok': False, 'error': 'Unable to update the GPU-P partition'}), 502


@app.post('/dashboard/api/vm/<name>/recover')
@auth_required
def api_vm_recover(name):
    try:
        data = request.get_json(silent=True) or {}
        aggressive = bool(data.get('aggressive', False)) if isinstance(data, dict) else False
        mode = (data.get('mode') if isinstance(data, dict) else None) or 'standard'
        result = _recover_vm(name, source='dashboard', aggressive=aggressive, mode=mode)
        return jsonify(result), (200 if result.get('ok') else 500)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/vm/<name>/escalate')
@auth_required
def api_vm_escalate(name):
    if not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', name or ''):
        return jsonify({'ok': False, 'error': 'Invalid VM name'}), 400
    claim = _claim_hermes_escalation(name)
    if not claim['allowed']:
        return jsonify({
            'ok': False,
            'error': 'Hermes is already handling this VM',
            'retryAfter': claim['retry_after'],
        }), 429
    try:
        data = request.get_json(silent=True) or {}
        reason = data.get('reason') if isinstance(data, dict) else None
        if not reason:
            reason = 'Dashboard recovery help requested by user'
        rec = _recover_vm(name, source='hermes-escalation', aggressive=True)
        esc = _escalate_vm_to_hermes(name, reason, {'recovery': rec, 'request': data})
        return jsonify({'ok': True, 'recovery': rec, 'escalation': esc})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

def _stop_remote_console_after_vm(host, name):
    if getattr(host, 'kind', 'local') != 'remote':
        return
    orchestrator = _console_orchestrator()
    if _moonlight_console(orchestrator):
        # Each gaming bundle reserves the VM UDP range. Release it when the
        # VM stops, while retaining pairing data for the next start.
        orchestrator.stop_staged(name)


@app.post('/dashboard/api/stop/<name>')
@auth_required
def api_stop(name):
    try:
        host = _vm_host()
        _ensure_remote_vm_exists(host, name)
        result = host.run_manager('stop', name, capture_output=True, text=True)
        if getattr(result, 'returncode', 0) != 0:
            return jsonify({'ok': False, 'error': getattr(result, 'stderr', '') or getattr(result, 'stdout', '') or 'Failed to stop VM'}), 502
        _stop_remote_console_after_vm(host, name)
        return jsonify({'ok': True})
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 500

@app.post('/dashboard/api/delete/<name>')
@auth_required
def api_delete(name):
    try:
        host = _vm_host()
        _ensure_remote_vm_exists(host, name)
        host.check_call('delete', name)
        return jsonify({'ok': True})
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception as exc:
        return jsonify({'ok': False, 'error': str(exc)}), 500


def _read_proc_stat_cpu():
    try:
        with open('/proc/stat', 'r') as f:
            for line in f:
                if line.startswith('cpu '):
                    parts = line.split()[1:]
                    vals = list(map(int, parts))
                    return vals
    except Exception:
        return None


def _calc_cpu_percent(interval=0.08):
    a = _read_proc_stat_cpu()
    if not a:
        return None
    time.sleep(interval)
    b = _read_proc_stat_cpu()
    if not b:
        return None
    suma = sum(a)
    sumb = sum(b)
    idle_a = a[3] if len(a) > 3 else 0
    idle_b = b[3] if len(b) > 3 else 0
    busy = (sumb - suma) - (idle_b - idle_a)
    total = sumb - suma
    try:
        pct = (busy / total) * 100.0 if total > 0 else 0.0
    except Exception:
        pct = 0.0
    return round(pct, 2)


def _get_system_stats():
    # Return a dict with cpu, memory, disk, network, uptime, temps
    try:
        stats = {}
        # CPU
        if psutil:
            per = psutil.cpu_percent(interval=0.08, percpu=True)
            stats['cpu'] = {
                'cores': psutil.cpu_count(logical=True),
                'usage': round(sum(per)/len(per),2) if per else 0.0,
                'per_core': [round(p,2) for p in per]
            }
        else:
            pct = _calc_cpu_percent()
            cores = os.cpu_count() or 1
            stats['cpu'] = {'cores': cores, 'usage': pct or 0.0, 'per_core': []}

        # Memory
        if psutil:
            vm = psutil.virtual_memory()
            stats['memory'] = {'total': vm.total, 'available': vm.available, 'used': vm.used, 'percent': vm.percent}
        else:
            mem = {}
            try:
                with open('/proc/meminfo','r') as f:
                    for line in f:
                        k,v = line.split(':',1)
                        mem[k.strip()] = int(re.findall(r'\d+', v)[0]) * 1024
                total = mem.get('MemTotal',0)
                free = mem.get('MemFree',0) + mem.get('Buffers',0) + mem.get('Cached',0)
                used = total - free
                pct = round((used/total)*100,2) if total>0 else 0.0
                stats['memory'] = {'total': total, 'available': free, 'used': used, 'percent': pct}
            except Exception:
                stats['memory'] = {'total': 0, 'available':0, 'used':0, 'percent':0}

        # Disk: list root and mounted partitions
        disks = []
        try:
            if psutil:
                for part in psutil.disk_partitions(all=False):
                    try:
                        u = psutil.disk_usage(part.mountpoint)
                        disks.append({'mountpoint': part.mountpoint, 'total': u.total, 'used': u.used, 'free': u.free, 'percent': u.percent})
                    except Exception:
                        pass
            else:
                root = shutil.disk_usage('/')
                disks.append({'mountpoint': '/', 'total': root.total, 'used': root.used, 'free': root.free, 'percent': round((root.used/root.total)*100,2) if root.total>0 else 0})
        except Exception:
            disks = []
        stats['disk'] = disks

        # Network
        try:
            if psutil:
                net = psutil.net_io_counters(pernic=False)
                stats['network'] = {'rx_bytes': net.bytes_recv, 'tx_bytes': net.bytes_sent}
            else:
                rx = 0; tx = 0
                with open('/proc/net/dev','r') as f:
                    for line in f.readlines()[2:]:
                        parts = line.split()
                        if len(parts) < 17:
                            continue
                        iface = parts[0].strip(':')
                        if iface == 'lo':
                            continue
                        rx += int(parts[1]); tx += int(parts[9])
                stats['network'] = {'rx_bytes': rx, 'tx_bytes': tx}
        except Exception:
            stats['network'] = {'rx_bytes':0,'tx_bytes':0}

        # Uptime and loadavg
        try:
            if psutil:
                stats['uptime'] = int(time.time() - psutil.boot_time())
            else:
                with open('/proc/uptime','r') as f:
                    stats['uptime'] = int(float(f.readline().split()[0]))
        except Exception:
            stats['uptime'] = 0
        try:
            stats['loadavg'] = list(os.getloadavg())
        except Exception:
            stats['loadavg'] = []

        # Temperatures: try psutil sensors, otherwise read thermal zones
        temps = {}
        try:
            if psutil:
                try:
                    st = psutil.sensors_temperatures()
                    for k,v in st.items():
                        temps[k] = [{'label': t.label or '', 'current': t.current} for t in v]
                except Exception:
                    temps = {}
            else:
                tzs = []
                base = '/sys/class/thermal'
                if os.path.isdir(base):
                    for name in os.listdir(base):
                        if name.startswith('thermal_zone'):
                            try:
                                p = os.path.join(base, name, 'temp')
                                with open(p,'r') as f:
                                    v = int(f.read().strip())
                                    temps[name] = [{'label':'', 'current': v/1000.0}]
                            except Exception:
                                pass
        except Exception:
            temps = {}
        stats['temps'] = temps

        return stats
    except Exception:
        return {'cpu':{}, 'memory':{}, 'disk':[], 'network':{}, 'uptime':0, 'loadavg':[], 'temps':{}}


def _read_os_release():
    values = {}
    try:
        with open('/etc/os-release', encoding='utf-8') as handle:
            for line in handle:
                key, separator, value = line.partition('=')
                if separator:
                    values[key.strip()] = value.strip().strip('"')
    except Exception:
        pass
    return values.get('PRETTY_NAME') or values.get('NAME') or 'Unknown OS'


def _kernel_release():
    try:
        return platform.release() or 'Unknown kernel'
    except Exception:
        return 'Unknown kernel'


def _dashboard_overview_host_payload():
    """Host/stats/activity only — cheap, no VM manager subprocess.

    Reads the optimizer's history/last-run files directly instead of calling
    dash_optimizer.status(), which gathers per-VM docker stats (~3s) that the
    overview never uses.
    """
    activity = []
    try:
        history = (dash_optimizer._history_state() or {}).get('events') or []
    except Exception:
        history = []
    try:
        with open(dash_optimizer.LAST_RUN_PATH, 'r') as handle:
            recent = (json.load(handle) or {}).get('events') or []
    except Exception:
        recent = []
    activity = [event for event in [*history, *recent] if isinstance(event, dict)]
    activity.sort(key=lambda event: int(event.get('ts') or 0), reverse=True)
    host_stats = _get_system_stats()
    return {
        'host': {
            'hostname': platform.node() or 'Unknown host',
            'os': _read_os_release(),
            'kernel': _kernel_release(),
            'uptimeSeconds': (host_stats or {}).get('uptime', 0),
        },
        'stats': host_stats,
        'activity': activity[:8],
    }


def _dashboard_overview_payload():
    payload = _dashboard_overview_host_payload()
    payload['instances'] = manager_json_fleet_list()
    return payload


@app.get('/Dashboard/api/stats')
@v2_auth_required
def dashboard_v2_stats():
    s = _get_system_stats()
    return jsonify(s)


@app.get('/dashboard/api/stats')
@v2_auth_required
def dashboard_v2_stats_alias():
    return dashboard_v2_stats()


@app.post('/dashboard/api/auth/login')
def dashboard_v2_login_alias():
    return dashboard_v2_login_public()


@app.get('/dashboard/api/auth/status')
def dashboard_v2_status_alias():
    return dashboard_v2_status_public()


@app.get('/Dashboard/api/vm/logs/<name>')
@v2_auth_required
def dashboard_v2_vm_logs(name):
    # Remote agents own their VM logs; local VMs retain the Docker path.
    try:
        host = _vm_host()
        _ensure_remote_vm_exists(host, name)
        if getattr(host, 'kind', 'local') == 'remote':
            return jsonify({'ok': True, 'logs': host.logs(name), 'placement': 'remote', 'host_id': host.host_id})
    except VmHostUnavailable as exc:
        return jsonify({'ok': False, 'error': str(exc), 'logs': ''}), getattr(exc, 'status', 503)
    # Return last 400 lines of docker logs for the named VM container (blobevm_<name>)
    cname = f'blobevm_{name}'
    try:
        out = subprocess.check_output(['docker', 'logs', '--tail', '400', cname], stderr=subprocess.STDOUT, text=True)
        return jsonify({'ok': True, 'logs': out})
    except subprocess.CalledProcessError as e:
        # Return whatever output available
        return jsonify({'ok': False, 'error': str(e), 'logs': getattr(e, 'output', '')}), 500
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/vm/logs/<name>')
@v2_auth_required
def dashboard_v2_vm_logs_alias(name):
    return dashboard_v2_vm_logs(name)


@app.get('/Dashboard/api/vm/stats')
@v2_auth_required
def dashboard_v2_vm_stats():
    """Return per-VM CPU and memory percentages by calling `docker stats --no-stream`.
    The result maps VM name (without the `blobevm_` prefix) to {'cpu_percent': float, 'mem_percent': float}.
    """
    stats = {}
    try:
        for record in get_docker_stats():
            cname = record['name']
            if not cname.startswith('blobevm_'):
                continue
            cpu = record['cpu_percent']
            mem = record['mem_percent']
            # Normalize VM name if container is named blobevm_<name>
            vmname = cname
            if vmname.startswith('blobevm_'):
                vmname = vmname[len('blobevm_'):]
            key = _resource_key('vm', 'local', vmname)
            stats[key] = {'resourceKey': key, 'name': vmname, 'hostId': 'local',
                          'cpuPercent': round(cpu,2), 'memoryPercent': round(mem,2),
                          'cpu_percent': round(cpu,2), 'mem_percent': round(mem,2),
                          'container_name': cname}
        return jsonify({'ok': True, 'scope': {'hostId': 'local', 'provider': 'docker'},
                        'units': {'cpuPercent': 'percent', 'memoryPercent': 'percent'},
                        'vms': stats, 'unsupportedProviders': [
                            {'hostId': host_id, 'reason': 'Per-VM metrics are unavailable from this provider'}
                            for host_id in (getattr(VM_HOST_REGISTRY, 'providers', {}) or {}) if host_id != 'local'
                        ]})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/vm/stats')
@v2_auth_required
def dashboard_v2_vm_stats_alias():
    return dashboard_v2_vm_stats()


@app.get('/dashboard/api/v2/info')
@auth_required
def dashboard_v2_info():
    """Return information about the v2 build files and any recorded last-error file.
    This is intended for the legacy dashboard UI to show why the new dashboard
    may not be available (e.g., not built or build errors).
    """
    try:
        base = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', 'dashboard_v2'))
        dist = os.path.join(base, 'dist')
        info = {'dist_exists': False, 'index_mtime': None, 'files_count': 0, 'last_error': None}
        indexcand = os.path.join(dist, 'index.html')
        if os.path.isfile(indexcand):
            info['dist_exists'] = True
            info['index_mtime'] = int(os.path.getmtime(indexcand))
            # count files under dist
            cnt = 0
            for root, dirs, files in os.walk(dist):
                for f in files:
                    cnt += 1
            info['files_count'] = cnt
        # include any last error file if present (created by build step or admin)
        lasterr = os.path.join(base, 'last_error.txt')
        if os.path.isfile(lasterr):
            try:
                with open(lasterr, 'r') as fh:
                    data = fh.read(4096)
                    info['last_error'] = data
            except Exception:
                info['last_error'] = 'failed to read last_error.txt'
        return jsonify({'ok': True, 'info': info})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/Dashboard/api/v2/info')
@auth_required
def dashboard_v2_info_alias():
    return dashboard_v2_info()


@app.post('/Dashboard/api/vm/exec/<name>')
@v2_auth_required
def dashboard_v2_vm_exec(name):
    return jsonify({
        'ok': False,
        'error': 'Interactive VM command execution is disabled. Use read-only diagnostics or the VM console instead.',
        'code': 'capability_unsafe',
    }), 410


@app.post('/dashboard/api/vm/exec/<name>')
@v2_auth_required
def dashboard_v2_vm_exec_alias(name):
    return dashboard_v2_vm_exec(name)


@app.post('/dashboard/api/reset/<name>')
@auth_required
def api_reset(name):
    """Reset a VM by deleting it and creating a fresh instance.
    This runs in the background and returns immediately. Caller must ensure
    they really want to purge instance data.
    """
    try:
        host = _vm_host()
        def worker(vm_name):
            try:
                # Use manager delete which should remove container and instance data
                host.run_manager('delete', vm_name, capture_output=True, text=True)
            except Exception:
                pass
            try:
                # Create a fresh instance and start it
                host.run_manager('create', vm_name, capture_output=True, text=True)
            except Exception:
                pass
            try:
                host.run_manager('start', vm_name, capture_output=True, text=True)
            except Exception:
                pass
        threading.Thread(target=worker, args=(name,), daemon=True).start()
        return jsonify({'ok': True, 'started': True})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/restart/<name>')
@auth_required
def api_restart(name):
    try:
        host = _vm_host()
        _ensure_remote_vm_exists(host, name)
        r = host.run_manager('restart', name, capture_output=True, text=True)
        ok = (r.returncode == 0)
        return jsonify({'ok': ok, 'output': r.stdout.strip(), 'error': r.stderr.strip()})
    except VmHostUnavailable as exc:
        return _vm_host_error_response(exc)
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

# Bulk/targeted VM actions
@app.post('/dashboard/api/recreate')
@auth_required
def api_recreate():
    names = request.json.get('names', [])
    if not names:
        return jsonify({'error': 'No VM names provided'}), 400
    try:
        result = _vm_host().run_manager('recreate', *names, capture_output=True, text=True)
        ok = (result.returncode == 0)
        return jsonify({'ok': ok, 'output': result.stdout.strip(), 'error': result.stderr.strip()})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/rebuild-vms')
@auth_required
def api_rebuild_vms():
    names = request.json.get('names', [])
    if not names:
        return jsonify({'error': 'No VM names provided'}), 400
    for n in names:
        _set_flag(n, 'rebuilding', True)
    host = _vm_host()
    def worker(targets):
        try:
            result = host.run_manager('rebuild-vms', *targets, capture_output=True, text=True)
            return result.returncode == 0, (result.stdout or '') + (result.stderr or '')
        finally:
            for n in targets:
                _set_flag(n, 'rebuilding', False)
    job_id = _start_job('rebuild-vms', names, lambda: worker(names))
    return jsonify({'ok': True, 'jobId': job_id}), 202

@app.post('/dashboard/api/update-and-rebuild')
@auth_required
def api_update_and_rebuild():
    names = request.json.get('names', [])
    # Mark as rebuilding and run in background
    targets = names[:]
    if not targets:
        # If none specified, mark all known instances
        try:
            targets = [i['name'] for i in manager_json_list()]
        except Exception:
            targets = []
    for n in targets:
        _set_flag(n, 'rebuilding', True)
    host = _vm_host()
    def worker(tgts):
        try:
            result = host.run_manager('update-and-rebuild', *names, capture_output=True, text=True)
            return result.returncode == 0, (result.stdout or '') + (result.stderr or '')
        finally:
            for n in tgts:
                _set_flag(n, 'rebuilding', False)
    job_id = _start_job('update-and-rebuild', targets, lambda: worker(targets))
    return jsonify({'ok': True, 'jobId': job_id}), 202

@app.post('/dashboard/api/delete-all-instances')
@auth_required
def api_delete_all_instances():
    data = request.get_json(silent=True) or request.form or {}
    if data.get('confirm') != 'DELETE':
        return jsonify({'ok': False, 'error': 'Type DELETE to confirm deleting every VM'}), 400
    try:
        host = _vm_host()
        def worker():
            result = host.run_manager('delete-all-instances', '--yes', capture_output=True, text=True)
            return result.returncode == 0, (result.stdout or '') + (result.stderr or '')
        job_id = _start_job('delete-all-instances', [], worker)
        return jsonify({'ok': True, 'jobId': job_id}), 202
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/reset-all-instances')
@auth_required
def api_reset_all_instances():
    """Reset all known instances by deleting and recreating them in background."""
    try:
        data = request.get_json(silent=True) or request.form or {}
        if data.get('confirm') != 'DELETE':
            return jsonify({'ok': False, 'error': 'Type DELETE to confirm resetting every VM'}), 400
        # Determine instance names
        try:
            names = [i['name'] for i in manager_json_list()]
        except Exception:
            # fallback: scan instances directory
            inst_root = os.path.join(_state_dir(), 'instances')
            try:
                names = [n for n in os.listdir(inst_root) if os.path.isdir(os.path.join(inst_root, n))]
            except Exception:
                names = []

        host = _vm_host()
        def worker(all_names):
            output = []
            ok = True
            for n in all_names:
                for action in ('delete', 'create', 'start'):
                    result = host.run_manager(action, n, capture_output=True, text=True)
                    output.append((result.stdout or '') + (result.stderr or ''))
                    ok = ok and result.returncode == 0
            return ok, '\n'.join(output)

        job_id = _start_job('reset-all-instances', names, lambda: worker(names))
        return jsonify({'ok': True, 'jobId': job_id, 'count': len(names)}), 202
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/prune-docker')
@auth_required
def api_prune_docker():
    """Prune only Docker resources explicitly owned by EpicVM."""
    def worker():
        results = [
            _docker('container', 'prune', '-f', '--filter', 'label=com.blobevm.managed=1'),
            _docker('volume', 'prune', '-f', '--filter', 'label=com.blobevm.managed=1'),
            _docker('network', 'prune', '-f', '--filter', 'label=com.blobevm.managed=1'),
        ]
        output = '\n'.join((r.stdout or '') + (r.stderr or '') for r in results)
        return all(r.returncode == 0 for r in results), output
    try:
        job_id = _start_job('prune-blobevm-resources', [], worker)
        return jsonify({'ok': True, 'jobId': job_id}), 202
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.get('/dashboard/api/jobs')
@admin_auth_required
def dashboard_jobs_list():
    _init_users_db()
    conn = _users_conn()
    try:
        rows = conn.execute('SELECT * FROM jobs ORDER BY created_at DESC LIMIT 100').fetchall()
        return jsonify({'ok': True, 'jobs': [_job_row_to_dict(row) for row in rows]})
    finally:
        conn.close()

@app.get('/dashboard/api/jobs/<job_id>')
@admin_auth_required
def dashboard_job_get(job_id):
    _init_users_db()
    conn = _users_conn()
    try:
        row = conn.execute('SELECT * FROM jobs WHERE id = ?', (job_id,)).fetchone()
        if not row:
            return jsonify({'ok': False, 'error': 'Job not found'}), 404
        return jsonify({'ok': True, 'job': _job_row_to_dict(row)})
    finally:
        conn.close()

@app.post('/dashboard/api/update-vm/<name>')
@auth_required
def api_update_vm(name):
    # Set transient updating flag and run in background to avoid blocking and to show status
    try:
        _set_flag(name, 'updating', True)
        def worker(vm_name):
            try:
                ok, out, err, _ = _run_manager('update-vm', vm_name)
                return ok, out or err
            finally:
                _set_flag(vm_name, 'updating', False)
        job_id = _start_job('update-vm', [name], lambda: worker(name))
        return jsonify({'ok': True, 'jobId': job_id}), 202
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/app-install/<name>/<app>')
@auth_required
def api_app_install(name, app):
    try:
        ok, out, err, _ = _run_manager('app-install', name, app)
        return jsonify({'ok': ok, 'output': out, 'error': err})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.get('/dashboard/api/app-status/<name>/<app>')
@auth_required
def api_app_status(name, app):
    try:
        ok, out, err, _ = _run_manager('app-status', name, app)
        # Try to parse a simple status from stdout, else return as-is
        return jsonify({'ok': ok, 'output': out, 'error': err})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/app-uninstall/<name>/<app>')
@auth_required
def api_app_uninstall(name, app):
    try:
        ok, out, err, _ = _run_manager('app-uninstall', name, app)
        return jsonify({'ok': ok, 'output': out, 'error': err})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/app-reinstall/<name>/<app>')
@auth_required
def api_app_reinstall(name, app):
    try:
        ok, out, err, _ = _run_manager('app-reinstall', name, app)
        return jsonify({'ok': ok, 'output': out, 'error': err})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.post('/dashboard/api/clean-vm/<name>')
@auth_required
def api_clean_vm(name):
    """Clean apt caches and common temp directories inside the VM container."""
    cname = f'blobevm_{name}'
    # Best-effort: ignore errors
    try:
        cmds = [
            'apt-get update || true',
            'apt-get -y autoremove || true',
            'apt-get -y autoclean || true',
            'apt-get -y clean || true',
            'rm -rf /var/cache/apt/archives/* || true',
            'rm -rf /var/lib/apt/lists/* || true',
            'rm -rf /tmp/* /var/tmp/* || true',
            'mkdir -p /var/lib/apt/lists || true'
        ]
        for c in cmds:
            _docker('exec', '-u', 'root', cname, 'bash', '-lc', c)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500

@app.get('/dashboard/api/apps')
@auth_required
def api_apps():
    # Enumerate app scripts under /opt/blobe-vm/root/installable-apps
    apps_dir = os.path.join(_state_dir(), 'root', 'installable-apps')
    apps = []
    try:
        for f in os.listdir(apps_dir):
            if f.endswith('.sh'):
                apps.append(f[:-3])
    except Exception:
        pass
    apps.sort()
    return jsonify({'apps': apps})

def _http_check(url: str, timeout: float = 8.0) -> int:
    if not url:
        return 0
    # Ensure trailing slash to satisfy path prefix routers
    if not url.endswith('/'):
        url = url + '/'
    req = urlrequest.Request(url, method='HEAD')
    try:
        with urlrequest.urlopen(req, timeout=timeout) as resp:
            return int(getattr(resp, 'status', 200))
    except urlerror.HTTPError as e:
        try:
            return int(e.code)
        except Exception:
            return 0
    except Exception:
        return 0

@app.post('/dashboard/api/check/<name>')
@auth_required
def api_check(name):
    nofix = request.values.get('nofix') in ('1','true','yes','on')
    url = _build_vm_url(name)
    code = _http_check(url)
    if code and 200 <= code < 400:
        return jsonify({'ok': True, 'code': code, 'url': url, 'fixed': False})
    if nofix:
        return jsonify({'ok': False, 'code': code, 'url': url, 'output': 'no-fix mode'}), 400
    # Attempt auto-resolve: recreate container and retry briefly
    fixed = False
    try:
        cname = f'blobevm_{name}'
        subprocess.run(['docker', 'rm', '-f', cname], capture_output=True)
        _vm_host().run_manager('start', name, capture_output=True)
        for _ in range(8):
            time.sleep(1)
            url = _build_vm_url(name)
            code = _http_check(url)
            if code and 200 <= code < 400:
                fixed = True
                break
    except Exception:
        pass
    return jsonify({'ok': (code and 200 <= code < 400), 'code': code or 0, 'url': url, 'fixed': fixed})

@app.post('/dashboard/api/enable-single-port')
@auth_required
def api_enable_single_port():
    try:
        port = int(request.values.get('port', '20002'))
    except Exception:
        abort(400)
    # Check if port is free on the host by trying to bind inside the container
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(('0.0.0.0', port))
        s.close()
    except OSError:
        return jsonify({'ok': False, 'error': f'Port {port} appears to be in use. Choose a different port.'}), 409
    # Run in a background thread to avoid killing the serving container mid-request
    def worker():
        try:
            _enable_single_port(port)
        except Exception:
            pass
    threading.Thread(target=worker, daemon=True).start()
    return jsonify({'ok': True, 'message': f'Enabling single-port mode on :{port}. Dashboard may reload at http://<host>:{port}/dashboard shortly.'})

@app.post('/dashboard/api/disable-single-port')
@auth_required
def api_disable_single_port():
    dash_port = request.values.get('port')
    try:
        dash_port = int(dash_port) if dash_port else None
    except Exception:
        return jsonify({'ok': False, 'error': 'Invalid port'}), 400
    def worker():
        try:
            _disable_single_port(dash_port)
        except Exception:
            pass
    threading.Thread(target=worker, daemon=True).start()
    env = _read_env()
    effective_port = str(dash_port) if dash_port else env.get('DASHBOARD_PORT','') or env.get('DIRECT_PORT_START','20000')
    msg = f'Disabling single-port mode; dashboard will run on http://<host>:{effective_port}/dashboard.'
    return jsonify({'ok': True, 'message': msg, 'port': effective_port})


@app.get('/dashboard/api/optimizer/status')
@auth_required
def api_optimizer_status():
    """Return optimizer status and stats via embedded optimizer module."""
    try:
        s = dash_optimizer.status()
        return jsonify({'ok': True, 'cfg': s.get('cfg'), 'stats': s.get('stats'), 'lastRestart': s.get('lastRestart'), 'lastRun': s.get('lastRun')})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/optimizer/v2/summary')
@auth_required
def api_optimizer_v2_summary():
    try:
        s = dash_optimizer.status()
        stats = s.get('stats') or {}
        return jsonify({
            'ok': True,
            'hostPressure': stats.get('hostPressure') or {},
            'capacity': stats.get('capacity') or {},
            'reliefCandidates': stats.get('reliefCandidates') or [],
            'vmStates': stats.get('vmStates') or [],
            'recommendations': stats.get('recommendations') or [],
            'profiles': stats.get('profiles') or {},
            'densityProfiles': stats.get('densityProfiles') or {},
            'history': stats.get('history') or {},
            'trends': stats.get('trends') or {},
            'cfg': s.get('cfg') or {},
            'lastRun': s.get('lastRun') or {},
        })
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/optimizer/profile/<name>')
@auth_required
def api_optimizer_profile(name):
    try:
        data = request.get_json(silent=True) or {}
        profile = data.get('profile') if isinstance(data, dict) else None
        if not profile:
            return jsonify({'ok': False, 'error': 'missing profile'}), 400
        chosen = dash_optimizer.set_vm_profile(name, profile)
        return jsonify({'ok': True, 'name': name, 'profile': chosen})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/optimizer/density-profile')
@auth_required
def api_optimizer_density_profile():
    try:
        data = request.get_json(silent=True) or {}
        profile = data.get('profile') if isinstance(data, dict) else None
        if not profile:
            return jsonify({'ok': False, 'error': 'missing profile'}), 400
        result = dash_optimizer.apply_density_profile(profile)
        return jsonify({'ok': True, 'profile': result.get('profile'), 'cfg': result.get('cfg'), 'profiles': dash_optimizer.available_density_profiles()})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/vm/<name>/notifications')
def api_vm_notifications(name):
    gate = _enforce_vm_user_access(name)
    if gate is not None:
        return gate
    clear = request.args.get('clear') in ('1', 'true', 'yes', 'on')
    try:
        items = dash_optimizer.get_vm_notifications(name, clear=clear)
        return jsonify({'ok': True, 'items': items})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/notifications')
@auth_required
def api_notifications():
    clear = request.args.get('clear') in ('1', 'true', 'yes', 'on')
    items = []
    try:
        for instance in manager_json_list():
            name = str(instance.get('name') or '').strip()
            if not name:
                continue
            for item in dash_optimizer.get_vm_notifications(name, clear=clear):
                enriched = dict(item)
                enriched.setdefault('vmName', name)
                items.append(enriched)
        items.sort(key=lambda item: int(item.get('createdAt') or 0), reverse=True)
        return jsonify({'ok': True, 'count': len(items), 'items': items})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/optimizer/activity/<name>')
@auth_required
def api_optimizer_activity(name):
    try:
        data = request.get_json(silent=True) or {}
        source = (data.get('source') if isinstance(data, dict) else None) or 'dashboard-api'
        dash_optimizer.note_vm_activity(name, source)
        return jsonify({'ok': True, 'name': name, 'source': source})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/portal/api/optimizer/activity/<name>')
@portal_auth_required
def portal_optimizer_activity(name):
    if not _user_can_access_vm(request.portal_user, name):
        return jsonify({'ok': False, 'error': 'VM access denied'}), 403
    try:
        data = request.get_json(silent=True) or {}
        source = (data.get('source') if isinstance(data, dict) else None) or 'portal-vm-wrapper'
        dash_optimizer.note_vm_activity(name, source)
        return jsonify({'ok': True, 'name': name, 'source': source})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/optimizer/admission/<name>')
@auth_required
def api_optimizer_admission(name):
    try:
        force = request.args.get('force') in ('1', 'true', 'yes', 'on')
        s = dash_optimizer.status()
        stats = s.get('stats') or {}
        profiles = stats.get('profiles') or {}
        profile = profiles.get(name, 'desktop')
        result = dash_optimizer._can_start_vm(s.get('cfg') or {}, stats.get('vmStates') or [], stats.get('hostPressure') or {}, profile=profile, force=force)
        return jsonify({'ok': True, 'name': name, 'profile': profile, 'admission': result})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/optimizer/run-once')
@auth_required
def api_optimizer_run_once():
    # Start a background run of the embedded optimizer
    def worker():
        try:
            dash_optimizer.run_once()
        except Exception as e:
            dash_optimizer.log(f'run-once worker error {e}')
    threading.Thread(target=worker, daemon=True).start()
    return jsonify({'ok': True, 'started': True})


@app.post('/dashboard/api/optimizer/set')
@auth_required
def api_optimizer_set():
    data = request.get_json() or {}
    key = data.get('key')
    val = data.get('val')
    if not key:
        return jsonify({'ok': False, 'error': 'missing key'}), 400
    try:
        dash_optimizer.set_config(key, val)
        return jsonify({'ok': True})
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.get('/dashboard/api/optimizer/logs')
@auth_required
def api_optimizer_logs():
    try:
        t = dash_optimizer.tail_logs()
        return Response(t or '', mimetype='text/plain')
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


@app.post('/dashboard/api/optimizer/clean-system')
@auth_required
def api_optimizer_clean_system():
    """Clean only explicitly labelled EpicVM Docker resources."""
    def worker():
        results = [
            _docker('container', 'prune', '-f', '--filter', 'label=com.blobevm.managed=1'),
            _docker('volume', 'prune', '-f', '--filter', 'label=com.blobevm.managed=1'),
            _docker('network', 'prune', '-f', '--filter', 'label=com.blobevm.managed=1'),
        ]
        output = '\n'.join((r.stdout or '') + (r.stderr or '') for r in results)
        return all(r.returncode == 0 for r in results), output
    try:
        job_id = _start_job('optimizer-clean-blobevm-resources', [], worker)
        return jsonify({'ok': True, 'jobId': job_id}), 202
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 500


try:
    from .account_workspace import register_account_workspace
except ImportError:
    from account_workspace import register_account_workspace
_account_dashboard_identity = register_account_workspace(app, globals())

try:
    from .direct_stream import register_direct_stream
except ImportError:
    from direct_stream import register_direct_stream
register_direct_stream(app, globals())


if __name__ == '__main__':
    try:
        _init_users_db()
    except Exception:
        pass
    try:
        dash_optimizer.start_background_loop()
    except Exception:
        pass
    app.run(host='0.0.0.0', port=5000)
