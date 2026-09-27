#!/usr/bin/env bash

set -euo pipefail
set -o errtrace

# EpicVM Host/VPS Installer
# - Installs Docker and Traefik (default) OR runs in direct mode without a proxy
# - Sets up a shared docker network "proxy" (Traefik mode only)
# - Deploys Traefik (HTTP only by default, optional HTTPS via ACME) unless disabled
# - Builds the EpicVM image from this repository
# - Installs the EpicVM CLI and the legacy compatibility launcher
# - Optionally creates a first VM instance and prints its URL
#
# Environment overrides (optional, useful for automation):
#   BLOBEVM_DOMAIN, BLOBEVM_EMAIL, BLOBEVM_HTTP_PORT, BLOBEVM_HTTPS_PORT
#   BLOBEVM_FORCE_HTTPS, BLOBEVM_ENABLE_DASHBOARD, BLOBEVM_ENABLE_KVM
#   BLOBEVM_HSTS, BLOBEVM_TRAEFIK_NETWORK, BLOBEVM_REUSE_SETTINGS
#   BLOBEVM_AUTO_CREATE_VM, BLOBEVM_INITIAL_VM_NAME, BLOBEVM_ENABLE_TLS
#   BLOBEVM_ASSUME_DEFAULTS (accept safe defaults during prompts)
#   BLOBEVM_ALLOW_INSECURE_DASHBOARD=1 (explicitly opt out of dashboard auth)
#   DISABLE_DASHBOARD (legacy flag to skip dashboard deployment)
#   BLOBEVM_NO_TRAEFIK (1 to run without Traefik; VMs get unique high ports)
#   BLOBEVM_DIRECT_PORT_START (first port to try in direct/no-Traefik mode; default 20000)
#   EPICVM_* equivalents are the canonical public names; BLOBEVM_* names remain compatible.

trap 'echo "[ERROR] ${BASH_SOURCE[0]}: line ${LINENO} failed: ${BASH_COMMAND}" >&2' ERR


require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This installer must run as root. Re-running with sudo..." >&2
    exec sudo -E bash "$0" "$@"
  fi
}

detect_repo_root() {
  # Default to the directory two levels up from this script (repo root)
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  REPO_DIR="$(cd "$script_dir/.." && pwd)"
  # If that path does not contain a Dockerfile (as expected by build_image), try to locate it
  if [[ ! -f "$REPO_DIR/Dockerfile" ]]; then
    # Common install layouts:
    # 1) /opt/blobe-vm/repo contains the working copy and the Dockerfile
    if [[ -f /opt/blobe-vm/repo/Dockerfile ]]; then
      REPO_DIR="/opt/blobe-vm/repo"
    # 2) /opt/blobe-vm (parent) holds the Dockerfile
    elif [[ -f /opt/blobe-vm/Dockerfile ]]; then
      REPO_DIR="/opt/blobe-vm"
    elif [[ -f "$script_dir/../Dockerfile" ]]; then
      REPO_DIR="$(cd "$script_dir/.." && pwd)"
    elif [[ -f "$script_dir/../../Dockerfile" ]]; then
      REPO_DIR="$(cd "$script_dir/../.." && pwd)"
    fi
  fi
}

# Load existing settings if present (update-safe)
load_existing_env() {
  local env_file=/opt/blobe-vm/.env
  [[ -f "$env_file" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" =~ ^# ]] && continue
    v="${v%\'}"; v="${v#\'}"; v="${v%\"}"; v="${v#\"}"
    export "$k"="$v"
  done < "$env_file"
}

# Normalize the public EPICVM_* interface once, after persisted settings are loaded.
# Keep all downstream logic on its historical BLOBEVM_* and legacy variable names.
normalize_epicvm_environment() {
  [[ -n "${EPICVM_DOMAIN:-}" ]] && BLOBEVM_DOMAIN="${EPICVM_DOMAIN}"
  [[ -n "${EPICVM_EMAIL:-}" ]] && BLOBEVM_EMAIL="${EPICVM_EMAIL}"
  [[ -n "${EPICVM_HTTP_PORT:-}" ]] && BLOBEVM_HTTP_PORT="${EPICVM_HTTP_PORT}"
  [[ -n "${EPICVM_HTTPS_PORT:-}" ]] && BLOBEVM_HTTPS_PORT="${EPICVM_HTTPS_PORT}"
  [[ -n "${EPICVM_DIRECT_PORT_START:-}" ]] && BLOBEVM_DIRECT_PORT_START="${EPICVM_DIRECT_PORT_START}"

  if [[ -n "${EPICVM_ENABLE_DASHBOARD:-}" ]]; then
    BLOBEVM_ENABLE_DASHBOARD="${EPICVM_ENABLE_DASHBOARD}"
    ENABLE_DASHBOARD="$(normalize_bool "${EPICVM_ENABLE_DASHBOARD}")"
    DISABLE_DASHBOARD=0
  elif [[ -n "${BLOBEVM_ENABLE_DASHBOARD:-}" ]]; then
    ENABLE_DASHBOARD="$(normalize_bool "${BLOBEVM_ENABLE_DASHBOARD}")"
    DISABLE_DASHBOARD=0
  fi

  [[ -n "${EPICVM_INITIAL_VM_NAME:-}" ]] && BLOBEVM_INITIAL_VM_NAME="${EPICVM_INITIAL_VM_NAME}"
  if [[ -n "${EPICVM_NO_TRAEFIK:-}" ]]; then
    BLOBEVM_NO_TRAEFIK="${EPICVM_NO_TRAEFIK}"
  elif [[ -n "${EPICVM_DIRECT_MODE:-}" ]]; then
    BLOBEVM_NO_TRAEFIK="${EPICVM_DIRECT_MODE}"
  fi
  [[ -n "${EPICVM_FORCE_REBUILD:-}" ]] && BLOBEVM_FORCE_REBUILD="${EPICVM_FORCE_REBUILD}"
}

normalize_bool() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|y|on|enable|enabled) echo 1 ;;
    0|false|no|n|off|disable|disabled) echo 0 ;;
    *) echo "${value}" ;;
  esac
}

apply_env_overrides() {
  # Read environment overrides and normalize values. Do NOT write compose here.
  if [[ -n "${BLOBEVM_HTTPS_PORT:-}" ]]; then
    HTTPS_PORT="${BLOBEVM_HTTPS_PORT}"
  fi
  if [[ -n "${BLOBEVM_HTTP_PORT:-}" ]]; then
    HTTP_PORT="${BLOBEVM_HTTP_PORT}"
  fi
  if [[ -n "${BLOBEVM_TRAEFIK_NETWORK:-}" ]]; then
    TRAEFIK_NETWORK="${BLOBEVM_TRAEFIK_NETWORK}"
  fi
  if [[ -n "${BLOBEVM_BASE_PATH:-}" ]]; then
    BASE_PATH="${BLOBEVM_BASE_PATH}"
  fi

  # Opt-in: No Traefik mode (direct port publishing)
  if [[ -n "${BLOBEVM_NO_TRAEFIK:-}" ]]; then
    local nt
    nt="$(normalize_bool "${BLOBEVM_NO_TRAEFIK}")"
    [[ "${nt}" == "1" ]] && NO_TRAEFIK=1 || NO_TRAEFIK=0
  fi
  if [[ -n "${BLOBEVM_SKIP_TRAEFIK:-}" ]]; then
    local skip
    skip="$(normalize_bool "${BLOBEVM_SKIP_TRAEFIK}")"
    [[ "${skip}" == "1" ]] && SKIP_TRAEFIK=1
  fi

  # Force installer-managed Traefik takeover (ignore external; bind 80/443)
  if [[ -n "${BLOBEVM_MANAGE_TRAEFIK:-${BLOBEVM_TAKEOVER_TRAEFIK:-}}" ]]; then
    local t
    t="$(normalize_bool "${BLOBEVM_MANAGE_TRAEFIK:-${BLOBEVM_TAKEOVER_TRAEFIK:-}}")"
    if [[ "$t" == "1" ]]; then
      NO_TRAEFIK=0
      SKIP_TRAEFIK=0
      MANAGE_TRAEFIK=1
      AUTO_FREE_PORTS=1
    fi
  fi

  # Optionally auto-free ports 80/443 without prompting
  if [[ -n "${BLOBEVM_AUTO_FREE_PORTS:-}" ]]; then
    local af
    af="$(normalize_bool "${BLOBEVM_AUTO_FREE_PORTS}")"
    [[ "$af" == "1" ]] && AUTO_FREE_PORTS=1
  fi

  if [[ -n "${BLOBEVM_REUSE_SETTINGS:-}" ]]; then
    BLOBEVM_REUSE_SETTINGS="$(normalize_bool "${BLOBEVM_REUSE_SETTINGS}")"
  fi
  if [[ -n "${BLOBEDASH_USER:-}" ]]; then
    DASH_AUTH_USER="${BLOBEDASH_USER}"
  fi
  if [[ -n "${BLOBEVM_ASSUME_DEFAULTS:-}" ]]; then
    ASSUME_DEFAULTS="$(normalize_bool "${BLOBEVM_ASSUME_DEFAULTS}")"
  fi
}

prompt_dashboard_auth() {
  [[ "${ENABLE_DASHBOARD:-0}" -eq 1 ]] || return 0

  if [[ "${BLOBEVM_ALLOW_INSECURE_DASHBOARD:-0}" == "1" ]]; then
    BLOBEDASH_USER=""
    BLOBEDASH_PASS=""
    echo "WARNING: dashboard authentication is disabled by BLOBEVM_ALLOW_INSECURE_DASHBOARD=1." >&2
    return 0
  fi

  if [[ -n "${BLOBEDASH_PASS:-}" ]]; then
    [[ -z "${BLOBEDASH_USER:-}" ]] && BLOBEDASH_USER="admin"
    return 0
  fi

  if [[ "${ASSUME_DEFAULTS:-0}" == "1" ]]; then
    BLOBEDASH_USER="${BLOBEDASH_USER:-admin}"
    BLOBEDASH_PASS="$(openssl rand -base64 24 | tr -d '\n')"
    echo "Generated dashboard credentials (shown once): ${BLOBEDASH_USER} / ${BLOBEDASH_PASS}" >&2
    return 0
  fi

  local dash_user dash_pass dash_pass_confirm dash_user_input
  dash_user="${BLOBEDASH_USER:-admin}"
  read -rp "EpicVM dashboard username [${dash_user}]: " dash_user_input || true
  [[ -n "${dash_user_input:-}" ]] && dash_user="${dash_user_input}"
  while true; do
    read -rsp "Preferred dashboard password: " dash_pass; echo
    if [[ ${#dash_pass} -lt 12 ]]; then
      echo "Password must be at least 12 characters." >&2
      continue
    fi
    read -rsp "Confirm dashboard password: " dash_pass_confirm; echo
    if [[ "$dash_pass" != "$dash_pass_confirm" ]]; then
      echo "Passwords did not match. Try again." >&2
      continue
    fi
    break
  done
  BLOBEDASH_USER="$dash_user"
  BLOBEDASH_PASS="$dash_pass"
}

ensure_dashboard_secrets() {
  [[ "${ENABLE_DASHBOARD:-0}" -eq 1 ]] || return 0
  [[ -n "${DASH_V2_SECRET:-}" ]] || DASH_V2_SECRET="$(openssl rand -hex 32)"
  [[ -n "${BLOBEVM_USER_SECRET:-}" ]] || BLOBEVM_USER_SECRET="$(openssl rand -hex 32)"
}

prompt_config() {
  echo "--- EpicVM Host Configuration ---"

  if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
    echo "Mode: Direct (no Traefik). Each VM will be published on a unique high port."
  fi

  if [[ -n "${BLOBEVM_DOMAIN:-}" ]]; then
    echo "Domain supplied via environment: ${BLOBEVM_DOMAIN}"
  else
    read -rp "Primary domain for VMs (e.g., example.com) [leave empty to use URL paths]: " BLOBEVM_DOMAIN || true
    BLOBEVM_DOMAIN="${BLOBEVM_DOMAIN//[[:space:]]/}"
  fi

  if [[ -n "${BLOBEVM_EMAIL:-}" && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    echo "Using Let's Encrypt email from environment."
  else
    if [[ "${NO_TRAEFIK:-0}" -ne 1 ]]; then
      read -rp "Email for Let's Encrypt (optional; required for HTTPS): " BLOBEVM_EMAIL || true
    fi
    BLOBEVM_EMAIL="${BLOBEVM_EMAIL//[[:space:]]/}"
  fi

  local enable_kvm_response=""
  if [[ -n "${ENABLE_KVM:-}" ]]; then
    ENABLE_KVM=$([[ "${ENABLE_KVM}" == "1" ]] && echo 1 || echo 0)
  elif [[ "${ASSUME_DEFAULTS:-0}" == "1" ]]; then
    ENABLE_KVM=0
  else
    read -rp "Enable KVM passthrough to containers if available? [y/N]: " enable_kvm_response || true
    ENABLE_KVM=0
    [[ "${enable_kvm_response,,}" == y* ]] && ENABLE_KVM=1
  fi

  if [[ -n "${BLOBEVM_EMAIL:-}" && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    if [[ -n "${FORCE_HTTPS:-}" ]]; then
      FORCE_HTTPS=$([[ "${FORCE_HTTPS}" == "1" ]] && echo 1 || echo 0)
    elif [[ "${ASSUME_DEFAULTS:-0}" == "1" ]]; then
      FORCE_HTTPS=1
    else
      local force_https_response=""
      read -rp "Force HTTP->HTTPS redirect on all routers? [Y/n]: " force_https_response || true
      FORCE_HTTPS=1
      [[ "${force_https_response,,}" == n* ]] && FORCE_HTTPS=0
    fi
  else
    FORCE_HTTPS=0
  fi

  local dash_auth_response=""
  if [[ -n "${TRAEFIK_DASHBOARD_AUTH:-}" && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    [[ -z "${DASH_AUTH_USER:-}" ]] && DASH_AUTH_USER="${TRAEFIK_DASHBOARD_AUTH%%:*}"
    echo "Dashboard basic auth supplied via environment."
  elif [[ "${ASSUME_DEFAULTS:-0}" == "1" ]]; then
    TRAEFIK_DASHBOARD_AUTH=""
  else
    if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
      TRAEFIK_DASHBOARD_AUTH=""
    else
      read -rp "Protect Traefik dashboard with basic auth? [y/N]: " dash_auth_response || true
      if [[ "${dash_auth_response,,}" =~ ^y(es)?$ ]]; then
        local dash_user dash_pass dash_hash
        dash_user="${DASH_AUTH_USER:-admin}"
        read -rp "Dashboard username [${dash_user}]: " dash_user_input || true
        [[ -n "${dash_user_input}" ]] && dash_user="${dash_user_input}"
        read -rsp "Dashboard password: " dash_pass; echo
        if ! command -v htpasswd >/dev/null 2>&1; then
          apt-get update -y >/dev/null 2>&1 || true
          apt-get install -y apache2-utils >/dev/null 2>&1 || true
        fi
        dash_hash=$(htpasswd -nbB "${dash_user}" "${dash_pass}" 2>/dev/null | sed 's/^.*://')
        [[ -z "${dash_hash}" ]] && dash_hash=$(htpasswd -nb "${dash_user}" "${dash_pass}" 2>/dev/null | sed 's/^.*://')
        TRAEFIK_DASHBOARD_AUTH="${dash_user}:${dash_hash}"
        DASH_AUTH_USER="${dash_user}"
      else
        TRAEFIK_DASHBOARD_AUTH=""
      fi
    fi
  fi

  if [[ -n "${BLOBEVM_HSTS:-}" && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    HSTS_ENABLED=$([[ "${HSTS_ENABLED:-0}" == "1" ]] && echo 1 || echo 0)
  elif [[ "${ASSUME_DEFAULTS:-0}" == "1" ]]; then
    HSTS_ENABLED=0
  else
    if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
      HSTS_ENABLED=0
    else
      local hsts_ans
      read -rp "Enable HSTS headers on HTTPS routers? (adds preload, subdomains) [y/N]: " hsts_ans || true
      HSTS_ENABLED=0
      [[ "${hsts_ans,,}" =~ ^y(es)?$ ]] && HSTS_ENABLED=1
    fi
  fi

  if [[ "${DISABLE_DASHBOARD:-0}" -eq 1 ]]; then
    ENABLE_DASHBOARD=0
  elif [[ -n "${ENABLE_DASHBOARD:-}" ]]; then
    ENABLE_DASHBOARD=$([[ "${ENABLE_DASHBOARD}" == "1" ]] && echo 1 || echo 0)
  else
    # In direct mode, default to disabled (enable with BLOBEVM_ENABLE_DASHBOARD=1)
    if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
      ENABLE_DASHBOARD=0
    else
      ENABLE_DASHBOARD=1
    fi
  fi

  TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-proxy}"

  echo
  echo "Summary:"
  echo "  Domain:    ${BLOBEVM_DOMAIN:-<none - path-based URLs>}"
  echo "  ACME email:${BLOBEVM_EMAIL:-<none - HTTP only>}"
  echo "  KVM:       $([[ "${ENABLE_KVM}" -eq 1 ]] && echo enabled || echo disabled)"
  if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
    echo "  Proxy:      disabled (direct mode)"
  else
    echo "  Force HTTPS: $([[ "${FORCE_HTTPS}" -eq 1 ]] && echo yes || echo no)"
    echo "  HSTS:        $([[ "${HSTS_ENABLED}" -eq 1 ]] && echo yes || echo no)"
  fi
  echo "  Web Dashboard: $([[ "${ENABLE_DASHBOARD}" -eq 1 ]] && echo yes || echo no) (set DISABLE_DASHBOARD=1 to skip)"
  if [[ -n "${BLOBEDASH_PASS:-}" ]]; then
    echo "  EpicVM Dashboard Auth: enabled (user: ${BLOBEDASH_USER:-admin})"
  else
    echo "  EpicVM Dashboard Auth: disabled"
  fi
  if [[ -n "${TRAEFIK_DASHBOARD_AUTH}" ]]; then
    local summary_user="${DASH_AUTH_USER:-${TRAEFIK_DASHBOARD_AUTH%%:*}}"
    echo "  Traefik Dashboard Auth: enabled (user: ${summary_user:-admin})"
  else
    echo "  Traefik Dashboard Auth: disabled"
  fi
  echo
}

install_prereqs() {
  echo "Ensuring prerequisite packages are installed..."
  export DEBIAN_FRONTEND=noninteractive
  # Clean up duplicate apt source lines that cause warnings on some hosts
  if [[ -f /etc/apt/sources.list.d/ubuntu-mirrors.list ]]; then
    tmpf="$(mktemp)"
    awk '!seen[$0]++' /etc/apt/sources.list.d/ubuntu-mirrors.list > "$tmpf" || true
    mv "$tmpf" /etc/apt/sources.list.d/ubuntu-mirrors.list || true
  fi
  apt-get update -y
  apt-get install -y ca-certificates curl wget gnupg lsb-release jq >/dev/null
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    cat <<EOF >/etc/apt/sources.list.d/docker.list
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF
  fi

  # Quick sanity checks
  command -v docker >/dev/null 2>&1 || { echo "Docker did not install correctly." >&2; exit 1; }
  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin is unavailable. Please ensure docker-compose-plugin is installed." >&2
    exit 1
  fi
  local detected_docker
  detected_docker="$(command -v docker)"
  if [[ -z "${detected_docker}" ]]; then
    echo "Unable to determine docker CLI path." >&2
    exit 1
  fi
  if [[ -z "${HOST_DOCKER_BIN:-}" || ! -e "${HOST_DOCKER_BIN}" ]]; then
    HOST_DOCKER_BIN="${detected_docker}"
  fi
  if [[ ! -e "${HOST_DOCKER_BIN}" ]]; then
    echo "Docker CLI not found at ${HOST_DOCKER_BIN}." >&2
    exit 1
  fi
  export HOST_DOCKER_BIN
  command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
  command -v wget >/dev/null 2>&1 || { echo "wget is required." >&2; exit 1; }
}

ensure_network() {
  # Create a shared docker network for Traefik routing
  if [[ "${SKIP_TRAEFIK:-0}" -eq 1 || "${NO_TRAEFIK:-0}" -eq 1 ]]; then
    # We are reusing an external Traefik; assume its network exists
    return 0
  fi
  local net_name
  net_name="${TRAEFIK_NETWORK:-proxy}"
  if ! docker network inspect "${net_name}" >/dev/null 2>&1; then
    docker network create "${net_name}"
  fi
}

# If configured to skip Traefik because of a previous external instance, but it's gone now,
# clear SKIP_TRAEFIK so we deploy ours.
validate_skip_traefik() {
  [[ "${NO_TRAEFIK:-0}" -eq 1 ]] && return 0
  if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 ]]; then
    SKIP_TRAEFIK=0
    return 0
  fi
  if [[ "${SKIP_TRAEFIK:-0}" -eq 1 ]]; then
    local net_name="${TRAEFIK_NETWORK:-proxy}"
    local has_tr=0 has_net=0
    if docker ps -a --format '{{.Names}}' | grep -Eq '^(traefik|traefik-traefik-1)$'; then has_tr=1; fi
    if docker network inspect "${net_name}" >/dev/null 2>&1; then has_net=1; fi
    if [[ "$has_tr" -ne 1 || "$has_net" -ne 1 ]]; then
      echo "Configured to reuse external Traefik, but it's not present (container/network missing)."
      echo "Re-enabling Traefik deployment."
      SKIP_TRAEFIK=0
    fi
  fi
}

# --- Port helpers and interactive resolution ---
# Return 0 if port is in use
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -E "(^|:)${p}$" >/dev/null 2>&1
  else
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -E "(^|:)${p}$" >/dev/null 2>&1
  fi
}

# Print processes listening on a port (best-effort)
print_port_owners() {
  local p="$1"
  echo "Processes on port ${p}:"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | awk -v P=":${p}$" '$4 ~ P {print $0}' | sed 's/^/  /'
  else
    netstat -ltnp 2>/dev/null | awk -v P=":${p} " '$4 ~ P {print $0}' | sed 's/^/  /'
  fi
}

# Extract PIDs bound to a port (best-effort)
port_pids() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp | awk -v P=":${p}$" '$4 ~ P {print $0}' |
      sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u
  else
    netstat -ltnp 2>/dev/null | awk -v P=":${p} " '$4 ~ P {print $7}' |
      sed -n 's|/.*||p' | sort -u
  fi
}

# Find Docker containers publishing a given host port (e.g., 0.0.0.0:80->...)
docker_containers_on_port() {
  local p="$1"
  command -v docker >/dev/null 2>&1 || return 0
  docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' 2>/dev/null | \
    awk -v P=":${p}->" 'index($0, P)>0 {print $1}'
}

# Stop/remove Docker containers that are publishing the specified port
free_port_docker() {
  local p="$1"; local ids
  ids="$(docker_containers_on_port "$p" | tr '\n' ' ')"
  [[ -n "$ids" ]] || return 0
  echo "Stopping Docker containers publishing port ${p}..."
  local id
  for id in $ids; do
    # Best-effort remove; container might be important, but in takeover we prefer freeing the port
    docker rm -f "$id" >/dev/null 2>&1 || docker stop "$id" >/dev/null 2>&1 || true
  done
  # give docker a moment to release docker-proxy
  sleep 1
}

# Attempt to gracefully stop known services, else kill PIDs
free_port_by_killing() {
  local p="$1"
  # First handle docker containers exposing this port
  free_port_docker "$p" || true
  local pids; pids=$(port_pids "$p")
  [[ -n "$pids" ]] || return 0
  echo "Attempting to free port ${p}..."
  local pid
  for pid in $pids; do
    local comm cmd svc
    comm=$(tr -d '\0' < "/proc/${pid}/comm" 2>/dev/null || true)
    cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)
    svc=""
    case "${comm:-$cmd}" in
      *nginx*) svc=nginx ;;
      *apache2*|*httpd*) svc=apache2 ;;
      *caddy*) svc=caddy ;;
      *traefik*) svc=traefik ;;
      *haproxy*) svc=haproxy ;;
      *dockerd*|*docker-proxy*) svc="" ;;
    esac
    if command -v systemctl >/dev/null 2>&1 && [[ -n "$svc" ]]; then
      if systemctl list-unit-files | grep -q "^${svc}\.service"; then
        echo "Stopping service ${svc} (pid ${pid})..."
        systemctl stop "$svc" || true
      fi
    fi
    if kill -0 "$pid" 2>/dev/null; then
      echo "Sending SIGTERM to pid ${pid}..."
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
    if kill -0 "$pid" 2>/dev/null; then
      echo "Sending SIGKILL to pid ${pid}..."
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  # wait until freed (up to 10 tries)
  local i=0
  while (( i < 10 )); do
    if ! port_in_use "$p"; then return 0; fi
    sleep 0.5; i=$((i+1))
  done
  return 1
}

# Aggressively attempt to free a port using docker stop, service stop, and SIGKILL.
ensure_port_free() {
  local p="$1"; local tries=3; local i=0
  while (( i < tries )); do
    if ! port_in_use "$p"; then return 0; fi
    free_port_docker "$p" || true
    free_port_by_killing "$p" || true
    # If common web servers are installed under systemd, try stopping them explicitly
    if command -v systemctl >/dev/null 2>&1; then
      for svc in nginx apache2 httpd caddy traefik haproxy lighttpd envoy; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
      done
    fi
    sleep 1
    if ! port_in_use "$p"; then return 0; fi
    i=$((i+1))
  done
  return 1
}

# Find first free TCP port from a starting point, up to N attempts
find_free_port() {
  local start="$1"; local attempts="${2:-200}"; local p="$start"; local i=0
  while (( i < attempts )); do
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
    p=$((p+1)); i=$((i+1))
  done
  return 1
}

# When a desired port is busy, ask user to kill or switch
resolve_busy_port_interactive() {
  local label="$1" desired="$2" fallback_start="$3"
  echo "=== ${label} port ${desired} is currently in use ==="
  print_port_owners "$desired"
  echo
  echo "Options:"
  echo "  1) Kill the process(es) using port ${desired} and use ${desired}"
  echo "  2) Switch to another port automatically (start from ${fallback_start})"
  echo "  3) Enter a custom port"
  local choice
  while true; do
    read -rp "Choose [1/2/3]: " choice || true
    case "$choice" in
      1)
        if free_port_by_killing "$desired"; then
          echo "$desired"
          return 0
        else
          echo "Failed to free port ${desired}." >&2
        fi
        ;;
      2)
        local alt
        alt=$(find_free_port "$fallback_start" 200 || true)
        if [[ -n "$alt" ]]; then
          echo "$alt"
          return 0
        else
          echo "No free alternative port found starting at ${fallback_start}." >&2
        fi
        ;;
      3)
        local custom
        read -rp "Enter port number: " custom || true
        if [[ "$custom" =~ ^[0-9]+$ && "$custom" -ge 1 && "$custom" -le 65535 ]]; then
          if port_in_use "$custom"; then
            echo "Port ${custom} is also in use. Try again." >&2
          else
            echo "$custom"
            return 0
          fi
        else
          echo "Invalid port. Try again." >&2
        fi
        ;;
      *) echo "Please enter 1, 2, or 3." ;;
    esac
  done
}

detect_ports() {
  # Choose host ports for Traefik, prompting to kill or switch when needed
  [[ "${NO_TRAEFIK:-0}" -eq 1 ]] && return 0
  local desired_http="${HTTP_PORT:-${BLOBEVM_HTTP_PORT:-80}}"
  local desired_https="${HTTPS_PORT:-${BLOBEVM_HTTPS_PORT:-443}}"
  HTTP_PORT="${desired_http}"
  HTTPS_PORT="${desired_https}"

  # In takeover mode, aggressively free ports 80/443 and use them
  if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 || "${AUTO_FREE_PORTS:-0}" -eq 1 ]]; then
    if [[ "$HTTP_PORT" -ne 80 ]]; then HTTP_PORT=80; fi
    if port_in_use 80; then
      ensure_port_free 80 || true
    fi
    if [[ -n "${BLOBEVM_EMAIL:-}" ]]; then
      if [[ "$HTTPS_PORT" -ne 443 ]]; then HTTPS_PORT=443; fi
      if port_in_use 443; then
        ensure_port_free 443 || true
      fi
    fi
  fi

  if port_in_use "$HTTP_PORT"; then
    if [[ "${ASSUME_DEFAULTS}" == "1" || "${AUTO_FREE_PORTS:-0}" -eq 1 || "${MANAGE_TRAEFIK:-0}" -eq 1 ]]; then
      if ensure_port_free "$HTTP_PORT"; then
        echo "Freed port ${HTTP_PORT} for Traefik." >&2
      fi
      if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 && "$desired_http" -eq 80 ]]; then
        # Try freeing again and insist on 80 in takeover mode
        if port_in_use 80; then
          ensure_port_free 80 || true
        fi
        if port_in_use 80; then
          echo "Port 80 remains busy; continuing with alternative port (manage mode)" >&2
        else
          HTTP_PORT=80
          echo "Using HTTP port 80 (manage mode)." >&2
          goto_http_set=1
        fi
      fi
      if [[ -z "${goto_http_set:-}" ]]; then
        local fallback_http
        if [[ "$HTTP_PORT" -eq 80 ]]; then
          fallback_http=8080
        else
          fallback_http=$((HTTP_PORT + 1))
        fi
        HTTP_PORT=$(find_free_port "$fallback_http" 200 || true)
        if [[ -z "$HTTP_PORT" ]]; then
          echo "Unable to find a free HTTP port automatically. Exiting." >&2
          exit 1
        fi
        echo "Port ${desired_http} is busy; automatically using HTTP port ${HTTP_PORT}." >&2
      fi
    else
      local fallback_http
      if [[ "$desired_http" -eq 80 ]]; then
        fallback_http=8080
      else
        fallback_http=$((desired_http + 1))
      fi
      HTTP_PORT=$(resolve_busy_port_interactive "HTTP" "$desired_http" "$fallback_http")
    fi
  fi

  if port_in_use "$HTTPS_PORT"; then
    if [[ "${ASSUME_DEFAULTS}" == "1" || "${AUTO_FREE_PORTS:-0}" -eq 1 || "${MANAGE_TRAEFIK:-0}" -eq 1 ]]; then
      if ensure_port_free "$HTTPS_PORT"; then
        echo "Freed port ${HTTPS_PORT} for Traefik." >&2
      fi
      if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 && -n "${BLOBEVM_EMAIL:-}" && "$desired_https" -eq 443 ]]; then
        if port_in_use 443; then
          ensure_port_free 443 || true
        fi
        if port_in_use 443; then
          echo "Port 443 remains busy; continuing with alternative port (manage mode)" >&2
        else
          HTTPS_PORT=443
          echo "Using HTTPS port 443 (manage mode)." >&2
          goto_https_set=1
        fi
      fi
      if [[ -z "${goto_https_set:-}" ]]; then
        local fallback_https
        if [[ "$HTTPS_PORT" -eq 443 ]]; then
          fallback_https=8443
        else
          fallback_https=$((HTTPS_PORT + 1))
        fi
        HTTPS_PORT=$(find_free_port "$fallback_https" 200 || true)
        if [[ -z "$HTTPS_PORT" ]]; then
          echo "Unable to find a free HTTPS port automatically. Exiting." >&2
          exit 1
        fi
        echo "Port ${desired_https} is busy; automatically using HTTPS port ${HTTPS_PORT}." >&2
      fi
    else
      local fallback_https
      if [[ "$desired_https" -eq 443 ]]; then
        fallback_https=8443
      else
        fallback_https=$((desired_https + 1))
      fi
      HTTPS_PORT=$(resolve_busy_port_interactive "HTTPS" "$desired_https" "$fallback_https")
    fi
  fi
}

# When ACME email is set but port 80 is busy, prompt the user to either free it or continue without TLS for now.
handle_tls_port_conflict() {
  [[ "${NO_TRAEFIK:-0}" -eq 1 ]] && { TLS_ENABLED=0; return 0; }
  TLS_ENABLED=0
  if [[ -n "${BLOBEVM_EMAIL:-}" ]]; then
    # Default to TLS if port 80 is available
    if [[ "${HTTP_PORT:-80}" == "80" ]]; then
      TLS_ENABLED=1
      return 0
    fi
    if [[ "${ASSUME_DEFAULTS}" == "1" ]]; then
      TLS_ENABLED=0
      echo "HTTPS requires port 80; continuing without TLS (non-interactive mode)." >&2
      return 0
    fi
    echo
    echo "=== HTTPS/ACME requires inbound port 80 ==="
    echo "You provided an email for Let's Encrypt, but port 80 is currently in use."
    echo "Options:"
    echo "  1) Free port 80 now and retry detection (recommended for HTTPS)."
    echo "  2) Continue WITHOUT TLS for now (you can enable it later after freeing port 80)."
    echo
    while true; do
      read -rp "Choose [1/2]: " choice || true
      case "${choice}" in
        1)
          echo "Press Enter after you have freed port 80 (e.g., stop nginx/apache/caddy)..."
          read -r _ || true
          detect_ports
          if [[ "${HTTP_PORT}" == "80" ]]; then
            TLS_ENABLED=1
            echo "Port 80 is free. Proceeding with HTTPS enabled."
            return 0
          else
            echo "Port 80 still busy. You can choose 1 again to retry or 2 to continue without TLS."
          fi
          ;;
        2)
          TLS_ENABLED=0
          echo "Proceeding without TLS. You can re-run the installer later to enable HTTPS."
          return 0
          ;;
        *)
          echo "Please enter 1 or 2."
          ;;
      esac
    done
  fi
}

detect_external_traefik() {
  if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 ]]; then
    return 0
  fi
  # Look for a running Traefik container and offer to reuse it
  local tid
  tid=$(docker ps --filter=ancestor=traefik --format '{{.ID}}' | head -n1 || true)
  if [[ -z "$tid" ]]; then
    # Try by name contains 'traefik'
    tid=$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | awk '/traefik/{print $1; exit}')
  fi
  [[ -z "$tid" ]] && return 0

  echo
  echo "Detected an existing Traefik container on this host."
  local reuse
  read -rp "Reuse the existing Traefik instead of deploying a new one? [Y/n]: " reuse || true
  if [[ -z "$reuse" || "${reuse,,}" == y* ]]; then
    # Pick its first attached user-defined network
    local net
    net=$(docker inspect "$tid" -f '{{ range $k, $v := .NetworkSettings.Networks }}{{$k}} {{ end }}' | awk '{for(i=1;i<=NF;i++) if($i!~/(bridge|host|none)/){print $i; exit}}')
    if [[ -z "$net" ]]; then
      echo "Could not determine a suitable user-defined network from the existing Traefik."
      echo "Falling back to deploying our own Traefik."
      return 0
    fi
    TRAEFIK_NETWORK="$net"
    SKIP_TRAEFIK=1
    echo "Reusing Traefik on network '$TRAEFIK_NETWORK'."
  fi
}

# Warn if reusing external Traefik and it forces HTTP->HTTPS while TLS is disabled
warn_if_external_redirect() {
  [[ "${SKIP_TRAEFIK:-0}" -ne 1 ]] && return 0
  [[ "${TLS_ENABLED:-0}" -ne 0 ]] && return 0
  local tid
  tid=$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | awk '/traefik/{print $1; exit}')
  [[ -z "$tid" ]] && return 0
  local args
  args=$(docker inspect "$tid" -f '{{range .Args}}{{.}}\n{{end}}' 2>/dev/null || true)
  if echo "$args" | grep -q -- '--entrypoints.web.http.redirections.entryPoint.to=websecure'; then
    echo
    echo "NOTE: External Traefik appears to have HTTP->HTTPS redirection enabled, but TLS is disabled in this setup."
    echo "That will cause browsers/curl to be redirected to HTTPS and likely see 404s if no websecure routers exist."
    echo "To fix: remove the redirection flag from the external Traefik and restart it, or allow this installer to manage Traefik."
    echo "Flag to remove: --entrypoints.web.http.redirections.entryPoint.to=websecure (and related scheme settings)."
  fi
}

# --- Traefik self-test: create a temporary VM and verify routing ---
auto_test_traefik() {
  [[ "${NO_TRAEFIK:-0}" -eq 1 ]] && return 0
  local name="_testvm"
  echo
  echo "Running Traefik routing self-test..."
  # Clean up any old test
  if docker ps -a --format '{{.Names}}' | grep -qx "blobevm_${name}"; then
    docker rm -f "blobevm_${name}" >/dev/null 2>&1 || true
  fi
  rm -rf "/opt/blobe-vm/instances/${name}" 2>/dev/null || true
  # Create test VM
  epicvm create "$name" >/dev/null 2>&1 || epicvm start "$name" >/dev/null 2>&1 || true
  # Wait for backend HTTP service to be ready inside the proxy network
  local cname="blobevm_${name}"
  local net_name="${TRAEFIK_NETWORK:-proxy}"
  local ready=0 tries=0 max_tries=30
  echo "[self-test] Waiting for backend service (http://${cname}:3000/) to be ready..."
  docker pull -q curlimages/curl:8.8.0 >/dev/null 2>&1 || true
  while [[ $tries -lt $max_tries ]]; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
      code=$(docker run --rm --network "$net_name" curlimages/curl:8.8.0 -sS -o /dev/null -m 5 -L -w '%{http_code}' "http://${cname}:3000/" 2>/dev/null || echo 000)
      if [[ "$code" =~ ^[23]..$ ]]; then
        ready=1; break
      fi
    fi
    tries=$((tries+1))
    sleep 1
  done
  if [[ $ready -ne 1 ]]; then
    echo "[self-test] Backend not ready after $max_tries seconds; continuing with Traefik probe anyway..."
  else
    echo "[self-test] Backend ready."
  fi

  # Determine URLs to test
  local base_path="${BASE_PATH:-/vm}"; [[ "$base_path" != /* ]] && base_path="/$base_path"; base_path="${base_path%/}"
  local http_port="${HTTP_PORT:-80}" https_port="${HTTPS_PORT:-443}"
  local http_suffix="" https_suffix=""
  [[ "$http_port" != "80" ]] && http_suffix=":"$http_port
  [[ "$https_port" != "443" ]] && https_suffix=":"$https_port
  local ip host_url path_url
  ip="$(hostname -I | awk '{print $1}')"
  # Use localhost for path-based routing test to avoid DNS/host routing issues
  local loop_host="127.0.0.1"
  path_url="http://${loop_host}${http_suffix}${base_path}/${name}/"
  if [[ -n "${BLOBEVM_DOMAIN:-}" ]]; then
    host_url="http://${name}.${BLOBEVM_DOMAIN}${http_suffix}/"
  else
    host_url=""
  fi
  # Export for final summary
  export SELF_TEST_PATH_URL="$path_url"
  export SELF_TEST_HOST_URL="$host_url"
  # Probe function
  _probe() {
    local url="$1"; [[ -z "$url" ]] && return 1
    curl -sS -o /dev/null -m 12 -L -w '%{http_code}' "$url" 2>/dev/null || echo 000
  }
  # Try path and host
  local ok=0 code
  code=$(_probe "$path_url"); export SELF_TEST_PATH_CODE="$code"; [[ "$code" =~ ^[23]..$ ]] && ok=1
  if [[ "$ok" -ne 1 && -n "$host_url" ]]; then
    code=$(_probe "$host_url"); export SELF_TEST_HOST_CODE="$code"; [[ "$code" =~ ^[23]..$ ]] && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    echo "[self-test] Traefik routing OK."; export SELF_TEST_STATUS="OK"
  else
    echo "[self-test] Routing check failed. Attempting remediation..."
    # Ensure Traefik network exists
    local net_name="${TRAEFIK_NETWORK:-proxy}"
    if ! docker network inspect "$net_name" >/dev/null 2>&1; then
      docker network create "$net_name" >/dev/null 2>&1 || true
    fi
    # Restart Traefik compose service
    if [[ -f /opt/blobe-vm/traefik/docker-compose.yml ]]; then
      (cd /opt/blobe-vm/traefik && docker compose up -d) >/dev/null 2>&1 || true
    fi
    # Recreate VM to refresh labels and network
    epicvm recreate "$name" >/dev/null 2>&1 || true
    sleep 2
    ok=0
    code=$(_probe "$path_url"); export SELF_TEST_PATH_CODE="$code"; [[ "$code" =~ ^[23]..$ ]] && ok=1
    if [[ "$ok" -ne 1 && -n "$host_url" ]]; then
      code=$(_probe "$host_url"); export SELF_TEST_HOST_CODE="$code"; [[ "$code" =~ ^[23]..$ ]] && ok=1
    fi
    if [[ "$ok" -eq 1 ]]; then
      echo "[self-test] Fixed by recreate."; export SELF_TEST_STATUS="FIXED"
    else
      echo "[self-test] Still failing. Suggestions:" >&2
      echo " - Ensure Traefik network '${TRAEFIK_NETWORK:-proxy}' exists and the Traefik container is running." >&2
      echo " - If using a custom domain, make sure DNS and port ${HTTP_PORT} reach this host." >&2
      export SELF_TEST_STATUS="FAIL"
      # Dump diagnostics to help with troubleshooting
      dump_traefik_diagnostics "$name" || true
    fi
  fi
  # Clean up test VM (container and instance dir)
  docker rm -f "blobevm_${name}" >/dev/null 2>&1 || true
  rm -rf "/opt/blobe-vm/instances/${name}" >/dev/null 2>&1 || true
}

# --- Diagnostics: print container labels, network status, Traefik routers/services/logs ---
dump_traefik_diagnostics() {
  local test_name="$1"
  local cname="blobevm_${test_name}"
  local net_name="${TRAEFIK_NETWORK:-proxy}"
  local base_path="${BASE_PATH:-/vm}"; [[ "$base_path" != /* ]] && base_path="/$base_path"; base_path="${base_path%/}"
  echo
  echo "[diagnostics] BEGIN"
  echo "[diagnostics] Container: $cname"
  if docker inspect "$cname" >/dev/null 2>&1; then
    echo "[diagnostics] Labels:"
    docker inspect -f '{{json .Config.Labels}}' "$cname" 2>/dev/null | { command -v jq >/dev/null 2>&1 && jq . || cat; }
    echo "[diagnostics] Networks:"
    docker inspect -f '{{json .NetworkSettings.Networks}}' "$cname" 2>/dev/null | { command -v jq >/dev/null 2>&1 && jq . || cat; }
    if docker inspect -f '{{json .NetworkSettings.Networks}}' "$cname" 2>/dev/null | grep -q '"'"$net_name"'"'; then
      echo "[diagnostics] Connected to network '$net_name': YES"
    else
      echo "[diagnostics] Connected to network '$net_name': NO (this will break Traefik routing)"
    fi
  else
    echo "[diagnostics] Container $cname not found"
  fi

  # Try to capture Traefik logs
  local traefik_cid
  traefik_cid="$(docker ps -q --filter 'ancestor=traefik:v2.11' | head -n1)"
  if [[ -n "$traefik_cid" ]]; then
    echo "[diagnostics] Traefik logs (last 120 lines):"
    docker logs --tail 120 "$traefik_cid" 2>&1 || true
  else
    echo "[diagnostics] Traefik container not found (image traefik:v2.11)."
  fi

  # Query Traefik API from within the proxy network
  echo "[diagnostics] Traefik API snapshot (routers, services, entrypoints)"
  docker pull -q curlimages/curl:8.8.0 >/dev/null 2>&1 || true
  for ep in /api/entrypoints /api/http/routers /api/http/services; do
    echo "[diagnostics] GET $ep"
    docker run --rm --network "$net_name" curlimages/curl:8.8.0 -sS \
      --max-time 6 "http://traefik:8080$ep" || echo "[diagnostics] (unreachable)"
    echo
  done

  # Quick string matches for this VM's host/path rules
  if [[ -n "${BLOBEVM_DOMAIN:-}" ]]; then
    echo "[diagnostics] Routers mentioning host '${test_name}.${BLOBEVM_DOMAIN}':"
    docker run --rm --network "$net_name" curlimages/curl:8.8.0 -sS --max-time 6 \
      "http://traefik:8080/api/http/routers" | grep -i "${test_name}\.${BLOBEVM_DOMAIN}" || true
  fi
  echo "[diagnostics] Routers mentioning path '${base_path}/${test_name}':"
  docker run --rm --network "$net_name" curlimages/curl:8.8.0 -sS --max-time 6 \
    "http://traefik:8080/api/http/routers" | grep -i "${base_path}/${test_name}" || true
  echo "[diagnostics] END"
}

# Check DNS for provided domain and print exact A records needed
check_domain_dns() {
  [[ -n "${BLOBEVM_DOMAIN:-}" ]] || return 0
  echo
  echo "Validating DNS for domain: ${BLOBEVM_DOMAIN}"
  local pub4 dns4 base_ok=0 traefik_ok=0
  pub4=$(curl -4 -fsS ifconfig.me || curl -4 -fsS icanhazip.com || true)
  if [[ -z "$pub4" ]]; then
    echo "Could not determine this server's public IPv4 address. Skipping DNS validation." >&2
    return 0
  fi
  # Resolve A records using getent; fallback to host if available
  dns4=$(getent ahostsv4 "$BLOBEVM_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$dns4" && $(command -v host) ]]; then
    dns4=$(host -4 "$BLOBEVM_DOMAIN" 2>/dev/null | awk '/has address/{print $4}' | sort -u | tr '\n' ' ')
  fi
  if [[ "$dns4" == *"$pub4"* ]]; then base_ok=1; fi
  # Check traefik subdomain specifically
  local traefik_host="traefik.${BLOBEVM_DOMAIN}"
  local dns4_t
  dns4_t=$(getent ahostsv4 "$traefik_host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$dns4_t" && $(command -v host) ]]; then
    dns4_t=$(host -4 "$traefik_host" 2>/dev/null | awk '/has address/{print $4}' | sort -u | tr '\n' ' ')
  fi
  if [[ "$dns4_t" == *"$pub4"* ]]; then traefik_ok=1; fi

  if [[ $base_ok -eq 1 && $traefik_ok -eq 1 ]]; then
    echo "DNS looks good: ${BLOBEVM_DOMAIN} and traefik.${BLOBEVM_DOMAIN} resolve to ${pub4}."
    return 0
  fi

  echo "DNS not fully configured for ${BLOBEVM_DOMAIN}."
  [[ -n "$dns4" ]] && echo "  Current A for ${BLOBEVM_DOMAIN}: ${dns4}"
  [[ -n "$dns4_t" ]] && echo "  Current A for traefik.${BLOBEVM_DOMAIN}: ${dns4_t}"
  if [[ $base_ok -eq 1 ]]; then
    echo "  ✓ Base domain resolves to this server."
  else
    echo "  ✗ Base domain does not resolve to this server yet."
  fi
  if [[ $traefik_ok -eq 1 ]]; then
    echo "  ✓ traefik.${BLOBEVM_DOMAIN} resolves to this server."
  else
    echo "  ✗ traefik.${BLOBEVM_DOMAIN} is missing or not pointing here."
  fi
  echo
  echo "Recommended A records (choose one):"
  echo "  - Wildcard for VM subdomains:  A  *.${BLOBEVM_DOMAIN}       -> ${pub4}"
  echo "  - Or add per-VM subdomains:    A  <vm>.${BLOBEVM_DOMAIN}    -> ${pub4}"
  echo "  - Optional Traefik dashboard:  A  traefik.${BLOBEVM_DOMAIN} -> ${pub4}"
  echo
  echo "Note: Host-based VM URLs (<vm>.${BLOBEVM_DOMAIN}) require either a wildcard or per-VM records."
  echo "Path-based URLs (${BASE_PATH:-/vm}/<name>/) will work immediately on the server IP."
  echo
  echo "After updating DNS, allow time for propagation. HTTPS (Let's Encrypt) will only work after ${BLOBEVM_DOMAIN} resolves to ${pub4} and port 80 is reachable."
  return 1
}

# Return 0 when both apex and traefik.<domain> resolve to our public IP
domain_ready() {
  [[ -n "${BLOBEVM_DOMAIN:-}" ]] || return 1
  local pub4 base_ok=0 traefik_ok=0
  pub4=$(curl -4 -fsS ifconfig.me || curl -4 -fsS icanhazip.com || true)
  [[ -z "$pub4" ]] && return 1
  local dns4
  dns4=$(getent ahostsv4 "$BLOBEVM_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$dns4" && $(command -v host) ]]; then
    dns4=$(host -4 "$BLOBEVM_DOMAIN" 2>/dev/null | awk '/has address/{print $4}' | sort -u | tr '\n' ' ')
  fi
  [[ "$dns4" == *"$pub4"* ]] && base_ok=1
  local traefik_host="traefik.${BLOBEVM_DOMAIN}" dns4_t
  dns4_t=$(getent ahostsv4 "$traefik_host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z "$dns4_t" && $(command -v host) ]]; then
    dns4_t=$(host -4 "$traefik_host" 2>/dev/null | awk '/has address/{print $4}' | sort -u | tr '\n' ' ')
  fi
  [[ "$dns4_t" == *"$pub4"* ]] && traefik_ok=1
  [[ $base_ok -eq 1 && $traefik_ok -eq 1 ]]
}

# Optional: wait for DNS to become ready before enabling TLS
wait_for_dns_propagation() {
  # Only relevant when TLS is enabled and HTTP_PORT is 80 (ACME requires 80)
  [[ "${NO_TRAEFIK:-0}" -eq 1 ]] && return 0
  [[ "${BLOBEVM_SKIP_DNS_CHECK:-0}" -eq 1 ]] && return 0
  [[ "${TLS_ENABLED:-0}" -eq 1 ]] || return 0
  [[ "${HTTP_PORT:-80}" == "80" ]] || return 0
  domain_ready && return 0
  echo
  echo "DNS for ${BLOBEVM_DOMAIN} does not point to this server yet."
  local ans
  read -rp "Wait for DNS to propagate before continuing? [y/N]: " ans || true
  [[ "${ans,,}" == y* ]] || return 0

  local attempts=40 delay=15 count=0
  echo "Waiting up to $((attempts*delay/60)) minutes. Checking every ${delay}s..."
  while (( count < attempts )); do
    if domain_ready; then
      echo "DNS is now pointing correctly."
      return 0
    fi
    count=$((count+1))
    sleep "$delay"
    # Every 4 attempts (~1 min), ask if we should keep waiting
    if (( count % 4 == 0 && count < attempts )); then
      local cont
      read -t 10 -rp "Still waiting on DNS... keep waiting? [Y/n]: " cont || cont=""
      if [[ -n "$cont" && "${cont,,}" == n* ]]; then
        echo "Skipping further DNS wait."
        return 0
      fi
    fi
  done
  echo "Timed out waiting for DNS. You can continue; HTTPS will start working once DNS is correct."
}

setup_traefik() {
  if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
    echo "Traefik disabled: skipping proxy deployment."
    return 0
  fi
  if [[ "${SKIP_TRAEFIK:-0}" -eq 1 ]]; then
    echo "Skipping Traefik deployment (reusing existing)."
    return 0
  fi

  # Defaults and paths
  local compose_file="/opt/blobe-vm/traefik/docker-compose.yml"
  local net_name="${TRAEFIK_NETWORK:-proxy}"
  local HTTP_PORT_VAL="${HTTP_PORT:-80}"
  local HTTPS_PORT_VAL="${HTTPS_PORT:-443}"

  # Remove any pre-existing Traefik containers that may hold ports 80/443
  if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 ]]; then
    for c in traefik traefik-traefik-1; do
      if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        docker rm -f "$c" >/dev/null 2>&1 || true
      fi
    done
  fi

  mkdir -p /opt/blobe-vm/traefik/letsencrypt
  chmod 700 /opt/blobe-vm/traefik/letsencrypt

  # Ensure network exists
  if ! docker network inspect "$net_name" >/dev/null 2>&1; then
    docker network create "$net_name" >/dev/null 2>&1 || true
  fi

  echo "Writing Traefik docker-compose.yml to $compose_file"

  # Build base of compose
  if [[ "${TLS_ENABLED:-0}" -eq 1 ]]; then
    cat > "$compose_file" <<EOF
services:
  traefik:
    image: traefik:v2.11
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --accesslog=true
      - --api.dashboard=true
      - --certificatesresolvers.myresolver.acme.email=${BLOBEVM_EMAIL}
      - --certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.myresolver.acme.httpchallenge=true
      - --certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web
EOF
    # Constrain Traefik provider to only discover EpicVM-managed containers
    echo '      - --providers.docker.constraints=Label(`com.blobevm.managed`,`1`)' >> "$compose_file"
    if [[ "${FORCE_HTTPS:-0}" -eq 1 ]]; then
      cat >> "$compose_file" <<EOF
      - --entrypoints.web.http.redirections.entryPoint.to=websecure
      - --entrypoints.web.http.redirections.entryPoint.scheme=https
EOF
    fi
    {
      echo "    ports:";
      echo "      - \"${HTTP_PORT_VAL}:80\"";
      echo "      - \"${HTTPS_PORT_VAL}:443\"";
    } >> "$compose_file"
    cat >> "$compose_file" <<EOF
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
EOF
    {
      echo "    networks:";
      echo "      - ${net_name}";
    } >> "$compose_file"
    cat >> "$compose_file" <<'EOF'
    labels:
      - traefik.enable=true
      - com.blobevm.managed=1
      # Dashboard/API under /traefik with StripPrefix and redirect
      - traefik.http.routers.traefik.rule=PathPrefix(`/traefik`)
      - traefik.http.routers.traefik.entrypoints=web
      - traefik.http.routers.traefik.middlewares=traefik-redirectregex,traefik-stripprefix
      - traefik.http.routers.traefik.service=api@internal
      # Secure router for dashboard/API over HTTPS
      - traefik.http.routers.traefik-secure.rule=PathPrefix(`/traefik`)
      - traefik.http.routers.traefik-secure.entrypoints=websecure
      - traefik.http.routers.traefik-secure.tls=true
      - traefik.http.routers.traefik-secure.middlewares=traefik-redirectregex,traefik-stripprefix
      - traefik.http.routers.traefik-secure.service=api@internal
      - traefik.http.middlewares.traefik-stripprefix.stripprefix.prefixes=/traefik
      - traefik.http.middlewares.traefik-redirectregex.redirectregex.regex=^/traefik/?$
      - traefik.http.middlewares.traefik-redirectregex.redirectregex.replacement=/traefik/dashboard/
      - traefik.http.middlewares.traefik-redirectregex.redirectregex.permanent=true
EOF
  else
    cat > "$compose_file" <<EOF
services:
  traefik:
    image: traefik:v2.11
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --accesslog=true
      - --api.dashboard=true
EOF
    # Constrain Traefik provider to only discover EpicVM-managed containers
    echo '      - --providers.docker.constraints=Label(`com.blobevm.managed`,`1`)' >> "$compose_file"
    {
      echo "    ports:";
      echo "      - \"${HTTP_PORT_VAL}:80\"";
    } >> "$compose_file"
    cat >> "$compose_file" <<EOF
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF
    {
      echo "    networks:";
      echo "      - ${net_name}";
    } >> "$compose_file"
    cat >> "$compose_file" <<'EOF'
    labels:
      - traefik.enable=true
      - com.blobevm.managed=1
      # Dashboard/API under /traefik with StripPrefix and redirect
      - traefik.http.routers.traefik.rule=PathPrefix(`/traefik`)
      - traefik.http.routers.traefik.entrypoints=web
      - traefik.http.routers.traefik.middlewares=traefik-redirectregex,traefik-stripprefix
      - traefik.http.routers.traefik.service=api@internal
      - traefik.http.middlewares.traefik-stripprefix.stripprefix.prefixes=/traefik
      - traefik.http.middlewares.traefik-redirectregex.redirectregex.regex=^/traefik/?$
      - traefik.http.middlewares.traefik-redirectregex.redirectregex.replacement=/traefik/dashboard/
      - traefik.http.middlewares.traefik-redirectregex.redirectregex.permanent=true
EOF
  fi

  cat >> "$compose_file" <<EOF
networks:
  ${net_name}:
    external: true
EOF

  echo "Starting Traefik..."
  (cd /opt/blobe-vm/traefik && docker compose up -d)

  # Attempt automatic self-heal if Traefik isn't exposing its API due to a common misquote
  traefik_self_heal || true
}

# -- Traefik self-heal: fix common misconfigurations automatically --
traefik_self_heal() {
  local dir="/opt/blobe-vm/traefik"
  local file="$dir/docker-compose.yml"
  local container="traefik-traefik-1"

  [[ -f "$file" ]] || return 0

  # Give it a moment to start
  sleep 1

  # If logs show illegal rune literal, it's almost always a single-quoted rule
  if docker logs "$container" --since 30s 2>/dev/null | grep -qi "illegal rune literal"; then
    if grep -q "traefik.http.routers.traefik.rule=PathPrefix('/traefik')" "$file"; then
      echo "[traefik-self-heal] Fixing PathPrefix('/traefik') -> PathPrefix(\`/traefik\`)"
      sed -i 's#traefik.http.routers.traefik.rule=PathPrefix('\''/traefik'\'')#traefik.http.routers.traefik.rule=PathPrefix(`/traefik`)#g' "$file"
      (cd "$dir" && docker compose up -d)
      sleep 1
    fi
  fi

  # If the rule was mangled to PathPrefix(), restore it
  if grep -q "traefik.http.routers.traefik.rule=PathPrefix()" "$file"; then
    echo "[traefik-self-heal] Restoring missing PathPrefix to /traefik"
    sed -i 's#traefik.http.routers.traefik.rule=PathPrefix()#traefik.http.routers.traefik.rule=PathPrefix(`/traefik`)#g' "$file"
    (cd "$dir" && docker compose up -d)
    sleep 1
  fi

  # Quick health probe of the local API through the proxy
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/traefik/api/http/routers || true)
  if [[ "$code" != "200" ]]; then
    echo "[traefik-self-heal] Traefik API not reachable (HTTP $code). Attempting labels canonicalization..." >&2
    traefik_canonicalize_labels "$file" "$dir"
    # Re-check health once more
    code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/traefik/api/http/routers || true)
    if [[ "$code" != "200" ]]; then
      echo "[traefik-self-heal] Still unhealthy (HTTP $code). See 'docker logs traefik-traefik-1'." >&2
    else
      echo "[traefik-self-heal] Traefik API healthy after labels canonicalization."
    fi
  else
    echo "[traefik-self-heal] Traefik API healthy."
  fi

  # If TLS is disabled, prune any stray websecure routers that might be coming from other stacks
  if [[ "${TLS_ENABLED:-0}" -eq 0 ]]; then
    # This relies on provider constraint to avoid unrelated containers, but ensure no HTTPS redirect flags linger
    if grep -q "--entrypoints.web.http.redirections.entryPoint.to=websecure" "$file"; then
      echo "[traefik-self-heal] Removing HTTP->HTTPS redirection flag because TLS is disabled."
      sed -i '/--entrypoints.web.http.redirections.entryPoint.to=websecure/d' "$file"
      sed -i '/--entrypoints.web.http.redirections.entryPoint.scheme=https/d' "$file" || true
      (cd "$dir" && docker compose up -d) || true
    fi
  fi
}

# Replace the Traefik service labels with a minimal, working dashboard/API router.
traefik_canonicalize_labels() {
  local file="$1"
  local dir="$2"
  [[ -f "$file" ]] || return 0
  echo "[traefik-self-heal] Rewriting Traefik labels to a known-good set..."
  awk '
    BEGIN{inlabels=0; done=0}
    /^\s*labels:\s*$/ && inlabels==0 && done==0 {
      print "    labels:";
      print "      - traefik.enable=true";
      print "      - com.blobevm.managed=1";
      print "      - traefik.http.routers.apidash.rule=PathPrefix(`/traefik`)";
      print "      - traefik.http.routers.apidash.entrypoints=web";
      print "      - traefik.http.routers.apidash.middlewares=apidash-redirect,apidash-stripprefix";
      print "      - traefik.http.routers.apidash.service=api@internal";
      print "      - traefik.http.routers.apidash-secure.rule=PathPrefix(`/traefik`)";
      print "      - traefik.http.routers.apidash-secure.entrypoints=websecure";
      print "      - traefik.http.routers.apidash-secure.tls=true";
      print "      - traefik.http.routers.apidash-secure.middlewares=apidash-redirect,apidash-stripprefix";
      print "      - traefik.http.routers.apidash-secure.service=api@internal";
      print "      - traefik.http.middlewares.apidash-stripprefix.stripprefix.prefixes=/traefik";
      print "      - traefik.http.middlewares.apidash-redirect.redirectregex.regex=^/traefik/?$";
      print "      - traefik.http.middlewares.apidash-redirect.redirectregex.replacement=/traefik/dashboard/";
      print "      - traefik.http.middlewares.apidash-redirect.redirectregex.permanent=true";
      inlabels=1; done=1; next
    }
    inlabels==1 {
      # Skip existing labels section content until next non-indented section
      if ($0 !~ /^\s{6,}[-a-zA-Z0-9_.:]/) { inlabels=0 }
      next
    }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  (cd "$dir" && docker compose up -d)
  sleep 1
}

# --- Direct mode dashboard deployment (no Traefik) ---
deploy_dashboard_direct() {
  [[ "${ENABLE_DASHBOARD:-0}" -eq 1 ]] || return 0
  echo "Deploying dashboard in direct mode (no proxy)..."
  local start_port="${BLOBEVM_DIRECT_PORT_START:-20000}"
  local port
  port=$(find_free_port "$start_port" 200 || true)
  if [[ -z "$port" ]]; then
    echo "Could not find a free port for the dashboard. Skipping dashboard deployment." >&2
    return 0
  fi
  DASHBOARD_PORT="$port"
  local docker_bin="${HOST_DOCKER_BIN:-}"
  if [[ -z "$docker_bin" || ! -e "$docker_bin" ]]; then
    docker_bin="$(command -v docker || true)"
  fi
  if [[ -z "$docker_bin" || ! -e "$docker_bin" ]]; then
    echo "Unable to determine docker CLI path for dashboard deployment." >&2
    return 1
  fi
  local compose_bin="${HOST_DOCKER_COMPOSE_BIN:-}"
  if [[ -z "$compose_bin" || ! -x "$compose_bin" ]]; then
    for candidate in /usr/libexec/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose; do
      if [[ -x "$candidate" ]]; then compose_bin="$candidate"; break; fi
    done
  fi
  if [[ -z "$compose_bin" || ! -x "$compose_bin" ]]; then
    echo "Unable to determine Docker Compose plugin path for console orchestration." >&2
    return 1
  fi
  # Always remove and repull dashboard container/image to ensure freshness
  if docker ps -a --format '{{.Names}}' | grep -qx "blobedash"; then
    echo "[dashboard] Removing old dashboard container..."
    docker rm -f blobedash >/dev/null 2>&1 || true
  fi
  echo "[dashboard] Removing old dashboard image (if any)..."
  docker image rm -f ghcr.io/library/python:3.11-slim 2>/dev/null || true
  docker image rm -f python:3.11-slim 2>/dev/null || true
  echo "[dashboard] Pulling latest dashboard base image..."
  docker pull python:3.11-slim
  docker run -d --name blobedash --init --restart unless-stopped \
    --env-file /opt/blobe-vm/.env \
    -p "${DASHBOARD_PORT}:5000" \
    -v /opt/blobe-vm:/opt/blobe-vm \
    -v /opt/epicvm:/opt/epicvm \
    -v /usr/local/bin/epicvm:/usr/local/bin/epicvm:ro \
    -v "${docker_bin}:/usr/bin/docker:ro" \
    -v "${compose_bin}:/usr/libexec/docker/cli-plugins/docker-compose:ro" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /opt/blobe-vm/dashboard:/app:ro \
    -e BLOBEVM_ALLOW_INSECURE_DASHBOARD="${BLOBEVM_ALLOW_INSECURE_DASHBOARD:-0}" \
    -e HOST_DOCKER_BIN="${docker_bin}" \
    -e EPICVM_CONSOLE_ROOT="${EPICVM_CONSOLE_ROOT:-/opt/epicvm/instances}" \
    -e EPICVM_CONSOLE_BACKEND="${EPICVM_CONSOLE_BACKEND:-moonlight}" \
    -e EPICVM_MOONLIGHT_ROOT="${EPICVM_MOONLIGHT_ROOT:-/opt/epicvm/moonlight-instances}" \
    -e EPICVM_TRAEFIK_NETWORK="${EPICVM_TRAEFIK_NETWORK:-}" \
    -e EPICVM_PUBLIC_HOST="${EPICVM_PUBLIC_HOST:-}" \
    -e EPICVM_TRAEFIK_CERTRESOLVER="${EPICVM_TRAEFIK_CERTRESOLVER:-}" \
    -e EPICVM_TRAEFIK_AUTH_MIDDLEWARE="${EPICVM_TRAEFIK_AUTH_MIDDLEWARE:-}" \
    -e EPICVM_TRAEFIK_ROUTER_PRIORITY="${EPICVM_TRAEFIK_ROUTER_PRIORITY:-}" \
    -e EPICVM_GUACAMOLE_IMAGE="${EPICVM_GUACAMOLE_IMAGE:-}" \
    -e EPICVM_GUACD_IMAGE="${EPICVM_GUACD_IMAGE:-}" \
    -e EPICVM_POSTGRES_IMAGE="${EPICVM_POSTGRES_IMAGE:-}" \
    -e EPICVM_MOONLIGHT_IMAGE="${EPICVM_MOONLIGHT_IMAGE:-}" \
    -e EPICVM_MOONLIGHT_NAT_HOST="${EPICVM_MOONLIGHT_NAT_HOST:-}" \
  python:3.11-slim \
  bash -c "apt-get update && apt-get install -y curl jq && pip install --no-cache-dir flask==3.1.1 cryptography==46.0.3 gunicorn==26.2.0 && gunicorn --bind 0.0.0.0:5000 --workers 1 --threads 4 --timeout 60 --access-logfile - --error-logfile - wsgi:app" \
    >/dev/null
}

build_image() {
  # Fallback if REPO_DIR is missing or was loaded stale from .env
  if [[ -z "${REPO_DIR:-}" || ! -d "$REPO_DIR" ]]; then
    detect_repo_root
  fi
  # If the directory exists but doesn't contain a Dockerfile, try to auto-correct
  if [[ ! -f "$REPO_DIR/Dockerfile" ]]; then
    detect_repo_root
  fi
  local image="blobevm:latest"
  local force="${BLOBEVM_FORCE_REBUILD:-0}"
  # Compute a content hash of the Dockerfile and the VM root/ folder
  local cur_hash prev_hash hash_file
  hash_file="/opt/blobe-vm/.image.hash"
  cur_hash=$( \
    cd "$REPO_DIR" && { \
      { sha256sum Dockerfile 2>/dev/null || true; } \
      && { find root -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null || true; } \
    } | sha256sum | awk '{print $1}'
  )
  [[ -f "$hash_file" ]] && prev_hash="$(cat "$hash_file" 2>/dev/null || true)" || prev_hash=""

  # Check if image exists
  local img_id
  img_id=$(docker images -q "$image" 2>/dev/null || true)

  if [[ "$force" == "1" || -z "$img_id" || "$cur_hash" != "$prev_hash" ]]; then
    echo "Building the EpicVM image from $REPO_DIR ..."
    docker build -t "$image" "$REPO_DIR"
    echo "$cur_hash" > "$hash_file" || true
    echo "Build complete."
  else
    echo "Image '$image' is up-to-date. Skipping rebuild."
  fi
}

install_manager() {
  echo "Installing EpicVM CLI and legacy compatibility launcher..."
  # Only replace if changed to preserve running processes and avoid unnecessary writes.
  local src="$REPO_DIR/server/epicvm" dst="/usr/local/bin/epicvm"
  if [[ -f "$dst" ]]; then
    if ! cmp -s "$src" "$dst"; then
      install -Dm755 "$src" "$dst"
    else
      chmod 755 "$dst"
    fi
  else
    install -Dm755 "$src" "$dst"
  fi
  # Keep the historical command as a compatibility launcher.
  install -Dm755 "$REPO_DIR/server/blobe-vm-manager" /usr/local/bin/blobe-vm-manager
  # RemoteVM host enrollment is a separate, VM-focused helper.
  if [[ -f "$REPO_DIR/server/epicvm-remote-host" ]]; then
    install -Dm755 "$REPO_DIR/server/epicvm-remote-host" /usr/local/bin/epicvm-remote-host
    install -d -m 700 /opt/blobe-vm
    if [[ ! -e /opt/blobe-vm/remote-hosts.json ]]; then
      printf '{"version":1,"hosts":[]}\n' > /opt/blobe-vm/remote-hosts.json
      chmod 600 /opt/blobe-vm/remote-hosts.json
    fi
  fi
  mkdir -p /opt/blobe-vm/instances
  install -d -m 700 /opt/epicvm /opt/epicvm/instances
  # Ensure dashboard app is available under /opt for both modes
  mkdir -p /opt/blobe-vm/dashboard
  if [[ -f "$REPO_DIR/dashboard/app.py" ]]; then
    # Before copying, attempt to build dashboard_v2 from likely repo locations
    POSSIBLE_SRC=("$REPO_DIR" "$REPO_DIR/BlobeVM" "/opt/blobe-vm/repo" )
    for src in "${POSSIBLE_SRC[@]}"; do
      if [[ -d "$src/dashboard_v2" ]]; then
        echo "Found dashboard_v2 sources at $src/dashboard_v2 — attempting build"
        DDIR="$src/dashboard_v2"
        LERR="$DDIR/last_error.txt"
        rm -f "$LERR" 2>/dev/null || true
        # Copy or sync the dashboard_v2 folder into /opt/blobe-vm so runtime scripts can pick it up
        mkdir -p /opt/blobe-vm
        rsync -a --delete "$src/dashboard_v2/" /opt/blobe-vm/dashboard_v2/ || true
        break
      fi
    done
    while IFS= read -r -d '' dashboard_module; do
      install -Dm644 "$dashboard_module" "/opt/blobe-vm/dashboard/$(basename "$dashboard_module")"
    done < <(find "$REPO_DIR/dashboard" -maxdepth 1 -type f -name '*.py' -print0 | sort -z)
    if [[ -d "$REPO_DIR/epicvm_web" ]]; then
      mkdir -p /opt/blobe-vm/epicvm_web
      rsync -a --delete \
        --exclude node_modules \
        --exclude .pytest_cache \
        "$REPO_DIR/epicvm_web/" /opt/blobe-vm/epicvm_web/
    fi
  fi
  # Build dashboard_v2 frontend (if present) so /Dashboard is available after install
  # dashboard_v2 build is handled by Docker Compose only
  # Install dashboard service assets
  mkdir -p /opt/blobe-vm/server
  if [[ -f "$REPO_DIR/server/blobedash-ensure.sh" ]]; then
    install -Dm755 "$REPO_DIR/server/blobedash-ensure.sh" /opt/blobe-vm/server/blobedash-ensure.sh
  fi
  if [[ -f "$REPO_DIR/server/blobedash.service" ]]; then
    install -Dm644 "$REPO_DIR/server/blobedash.service" /etc/systemd/system/blobedash.service
  fi
  local base_path="${BASE_PATH:-/vm}"
  # Helper to single-quote values safely for shell
  sh_q() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\''/g")"; }
  {
    echo "BLOBEVM_DOMAIN=$(sh_q "${BLOBEVM_DOMAIN:-}")";
    echo "BLOBEVM_EMAIL=$(sh_q "${BLOBEVM_EMAIL:-}")";
    echo "ENABLE_TLS=$(sh_q "${TLS_ENABLED}")";
    echo "ENABLE_KVM=$(sh_q "${ENABLE_KVM}")";
    echo "REPO_DIR=$(sh_q "${REPO_DIR}")";
    echo "BASE_PATH=$(sh_q "${base_path}")";
    echo "FORCE_HTTPS=$(sh_q "${FORCE_HTTPS}")";
    echo "TRAEFIK_DASHBOARD_AUTH=$(sh_q "${TRAEFIK_DASHBOARD_AUTH}")";
    echo "BLOBEDASH_USER=$(sh_q "${BLOBEDASH_USER:-}")";
    echo "BLOBEDASH_PASS=$(sh_q "${BLOBEDASH_PASS:-}")";
    echo "DASH_V2_SECRET=$(sh_q "${DASH_V2_SECRET:-}")";
    echo "BLOBEVM_USER_SECRET=$(sh_q "${BLOBEVM_USER_SECRET:-}")";
    echo "BLOBEVM_ALLOW_INSECURE_DASHBOARD=$(sh_q "${BLOBEVM_ALLOW_INSECURE_DASHBOARD:-0}")";
    echo "HSTS_ENABLED=$(sh_q "${HSTS_ENABLED}")";
    echo "ENABLE_DASHBOARD=$(sh_q "${ENABLE_DASHBOARD}")";
    echo "HTTP_PORT=$(sh_q "${HTTP_PORT}")";
    echo "HTTPS_PORT=$(sh_q "${HTTPS_PORT}")";
    echo "TRAEFIK_NETWORK=$(sh_q "${TRAEFIK_NETWORK}")";
    echo "SKIP_TRAEFIK=$(sh_q "${SKIP_TRAEFIK:-0}")";
    echo "NO_TRAEFIK=$(sh_q "${NO_TRAEFIK:-0}")";
    echo "DASHBOARD_PORT=$(sh_q "${DASHBOARD_PORT:-}")";
    echo "DIRECT_PORT_START=$(sh_q "${BLOBEVM_DIRECT_PORT_START:-20000}")";
    echo "HOST_DOCKER_BIN=$(sh_q "${HOST_DOCKER_BIN}")";
    echo "HOST_DOCKER_COMPOSE_BIN=$(sh_q "${HOST_DOCKER_COMPOSE_BIN:-}")";
    echo "EPICVM_CONSOLE_ROOT=$(sh_q "${EPICVM_CONSOLE_ROOT:-/opt/epicvm/instances}")";
    echo "EPICVM_CONSOLE_BACKEND=$(sh_q "${EPICVM_CONSOLE_BACKEND:-moonlight}")";
    echo "EPICVM_MOONLIGHT_ROOT=$(sh_q "${EPICVM_MOONLIGHT_ROOT:-/opt/epicvm/moonlight-instances}")";
    echo "EPICVM_TRAEFIK_NETWORK=$(sh_q "${EPICVM_TRAEFIK_NETWORK:-}")";
    echo "EPICVM_PUBLIC_HOST=$(sh_q "${EPICVM_PUBLIC_HOST:-}")";
    echo "EPICVM_TRAEFIK_CERTRESOLVER=$(sh_q "${EPICVM_TRAEFIK_CERTRESOLVER:-}")";
    echo "EPICVM_TRAEFIK_AUTH_MIDDLEWARE=$(sh_q "${EPICVM_TRAEFIK_AUTH_MIDDLEWARE:-}")";
    echo "EPICVM_TRAEFIK_ROUTER_PRIORITY=$(sh_q "${EPICVM_TRAEFIK_ROUTER_PRIORITY:-}")";
    echo "EPICVM_GUACAMOLE_IMAGE=$(sh_q "${EPICVM_GUACAMOLE_IMAGE:-}")";
    echo "EPICVM_GUACD_IMAGE=$(sh_q "${EPICVM_GUACD_IMAGE:-}")";
    echo "EPICVM_POSTGRES_IMAGE=$(sh_q "${EPICVM_POSTGRES_IMAGE:-}")";
    echo "EPICVM_MOONLIGHT_IMAGE=$(sh_q "${EPICVM_MOONLIGHT_IMAGE:-}")";
    echo "EPICVM_MOONLIGHT_NAT_HOST=$(sh_q "${EPICVM_MOONLIGHT_NAT_HOST:-}")";
    echo "EPICVM_MOONLIGHT_TURN_URLS=$(sh_q "${EPICVM_MOONLIGHT_TURN_URLS:-}")";
    echo "EPICVM_MOONLIGHT_TURN_USERNAME=$(sh_q "${EPICVM_MOONLIGHT_TURN_USERNAME:-}")";
    echo "EPICVM_MOONLIGHT_TURN_CREDENTIAL=$(sh_q "${EPICVM_MOONLIGHT_TURN_CREDENTIAL:-}")";
    echo "EPICVM_BLOBEDASH_IMAGE=$(sh_q "${EPICVM_BLOBEDASH_IMAGE:-}")";
  } > /opt/blobe-vm/.env
  chmod 600 /opt/blobe-vm/.env
}

# Verify that the dashboard will be able to show VM status by ensuring
# docker CLI and socket are reachable from a tiny probe container and that
# the manager script is on the host.
preflight_dashboard_runtime() {
  echo "Running dashboard preflight checks..."
  # 1) Host docker binary path
  local docker_bin="${HOST_DOCKER_BIN:-}"
  if [[ -z "$docker_bin" || ! -e "$docker_bin" ]]; then
    docker_bin="$(command -v docker || true)"
  fi
  if [[ -z "$docker_bin" || ! -e "$docker_bin" ]]; then
    echo "[preflight] Could not locate docker CLI on host." >&2
    return 1
  fi
  # 2) Docker socket
  if [[ ! -S /var/run/docker.sock ]]; then
    echo "[preflight] /var/run/docker.sock not found. Is Docker running?" >&2
    return 1
  fi
  # 3) Manager binary
  if [[ ! -x /usr/local/bin/epicvm ]]; then
    echo "[preflight] epicvm missing at /usr/local/bin/epicvm" >&2
    return 1
  fi
  # 4) Instances dir exists
  mkdir -p /opt/blobe-vm/instances
  install -d -m 700 /opt/epicvm /opt/epicvm/instances /opt/epicvm/moonlight-instances

  # 5) In-container probe: ensure docker ps works when mounting CLI and socket
  local probe="blobedash-preflight-$$"
  docker rm -f "$probe" >/dev/null 2>&1 || true
  if ! docker run --rm --name "$probe" \
      -v "/opt/blobe-vm:/opt/blobe-vm" \
      -v "/opt/epicvm:/opt/epicvm" \
      -v "/usr/local/bin/epicvm:/usr/local/bin/epicvm:ro" \
      -v "$docker_bin:/usr/bin/docker:ro" \
      -v "/var/run/docker.sock:/var/run/docker.sock" \
    python:3.11-slim bash -lc "docker ps >/dev/null 2>&1"; then
    echo "[preflight] docker ps failed inside probe container. Check docker socket permissions." >&2
    return 1
  fi
  echo "Dashboard preflight checks passed."
}

maybe_create_first_vm() {
  echo
  local auto_create="$(normalize_bool "${BLOBEVM_AUTO_CREATE_VM:-0}")"
  if [[ "$auto_create" == "1" ]]; then
    local name="${BLOBEVM_INITIAL_VM_NAME:-alpha}"
    echo "Auto-creating initial VM '${name}'."
    epicvm create "$name"
    return 0
  fi

  if [[ "${ASSUME_DEFAULTS}" == "1" ]]; then
    echo "Skipping initial VM creation (non-interactive mode)."
    return 0
  fi

  read -rp "Create an initial VM instance now? [y/N]: " create_now || true
  if [[ "${create_now,,}" =~ ^y(es)?$ ]]; then
    local name
    read -rp "Instance name (subdomain or path name): " name
    if [[ -z "$name" ]]; then
      echo "No name provided, skipping initial VM creation."
      return 0
    fi
    epicvm create "$name"
  fi
}

print_success() {
  echo
  echo "EpicVM host setup complete."
  local base_path="${BASE_PATH:-/vm}"
  local http_suffix=""
  local https_suffix=""
  [[ "${HTTP_PORT}" != "80" ]] && http_suffix=":${HTTP_PORT}"
  [[ "${HTTPS_PORT}" != "443" ]] && https_suffix=":${HTTPS_PORT}"
  local ip
  ip="$(hostname -I | awk '{print $1}')"
  # Derive dashboard port if not available in env
  local dport
  dport="${DASHBOARD_PORT:-}"
  if [[ -z "$dport" ]]; then
    if docker inspect blobedash >/dev/null 2>&1; then
      dport="$(docker inspect -f '{{ (index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort }}' blobedash 2>/dev/null | head -n1)"
    fi
  fi
  if [[ -z "$dport" ]]; then
    dport="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | awk '/^blobedash / {print $2}' | sed -E 's/.*:([0-9]+)->5000.*/\1/' | head -n1)"
  fi

  local base_host old_dashboard_url dashboard_v2_url test_vm_name test_vm_url scheme
  scheme="http"
  [[ "${TLS_ENABLED:-0}" -eq 1 ]] && scheme="https"
  if [[ -n "${BLOBEVM_DOMAIN:-}" && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    base_host="${BLOBEVM_DOMAIN}"
  else
    base_host="${ip}"
  fi
  old_dashboard_url=""
  dashboard_v2_url=""
  if [[ "${ENABLE_DASHBOARD:-0}" -eq 1 && -n "$dport" ]]; then
    old_dashboard_url="http://${ip}:${dport}/dashboard"
    dashboard_v2_url="http://${ip}:${dport}/Dashboard"
  fi
  if [[ -n "${BLOBEVM_DOMAIN:-}" && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    if [[ "${TLS_ENABLED:-0}" -eq 1 ]]; then
      echo "- Traefik:  https://traefik.${BLOBEVM_DOMAIN}${https_suffix}/"
      echo "- VM URLs:  https://<name>.${BLOBEVM_DOMAIN}${https_suffix}/ (path fallback ${base_path}/<name>/)"
    else
      echo "- Traefik:  http://traefik.${BLOBEVM_DOMAIN}${http_suffix}/"
      echo "- VM URLs:  http://<name>.${BLOBEVM_DOMAIN}${http_suffix}/ (path fallback ${base_path}/<name>/)"
    fi
    echo "- Ensure DNS: *.${BLOBEVM_DOMAIN} and traefik.${BLOBEVM_DOMAIN} → this server's IP."
    if [[ "${BLOBEVM_SKIP_DNS_CHECK:-0}" -eq 1 ]]; then
      echo "  (Using path-based routing. Live now: http://${BLOBEVM_DOMAIN}${http_suffix}${base_path}/<name>/ and http://${BLOBEVM_DOMAIN}${http_suffix}/traefik/)"
    fi
  else
    echo "- VM URLs: http://<SERVER_IP>${http_suffix}${base_path}/<name>/"
    [[ "${TLS_ENABLED:-0}" -eq 1 ]] && echo "- VM URLs (HTTPS): https://<SERVER_IP>${https_suffix}${base_path}/<name>/"
  fi
  if [[ -n "$old_dashboard_url" ]]; then
    echo "- Dashboard v2: ${dashboard_v2_url}"
    echo "- Old dashboard: ${old_dashboard_url}"
  else
    echo "- Dashboard: disabled (enable by setting BLOBEVM_ENABLE_DASHBOARD=1 and re-running install)."
  fi
  test_vm_name="${BLOBEVM_INITIAL_VM_NAME:-testvm}"
  if [[ -d "/opt/blobe-vm/instances/${test_vm_name}" ]]; then
    if command -v epicvm >/dev/null 2>&1; then
      test_vm_url="$(epicvm url "${test_vm_name}" 2>/dev/null || true)"
    fi
    if [[ -n "$test_vm_url" ]]; then
      echo "- Test VM (${test_vm_name}): ${test_vm_url}"
    else
      echo "- Test VM (${test_vm_name}): ${scheme}://${base_host}${http_suffix}${base_path}/${test_vm_name}/"
    fi
  fi
  echo "- Manage VMs: epicvm [list|create|start|stop|delete|rename] <name>"
  echo "- Uninstall everything: epicvm nuke"
  # Self-test summary if available
  if [[ -n "${SELF_TEST_STATUS:-}" ]]; then
    local st_path="${SELF_TEST_PATH_URL:-}" st_path_c="${SELF_TEST_PATH_CODE:-}" st_host="${SELF_TEST_HOST_URL:-}" st_host_c="${SELF_TEST_HOST_CODE:-}"
    echo "- Traefik self-test: ${SELF_TEST_STATUS}"
    if [[ -n "$st_path" ]]; then
      echo "  - Path URL: ${st_path} => ${st_path_c}"
    fi
    if [[ -n "$st_host" ]]; then
      echo "  - Host URL: ${st_host} => ${st_host_c}"
    fi
  fi
}

main() {
  require_root "$@"
  detect_repo_root
  # Detect existing install and load settings
  UPDATE_MODE=0
  if [[ -d /opt/blobe-vm || -f /usr/local/bin/blobe-vm-manager ]]; then
    UPDATE_MODE=1
    load_existing_env || true
  fi

  normalize_epicvm_environment
  apply_env_overrides
  ASSUME_DEFAULTS=${ASSUME_DEFAULTS:-0}

  if [[ "$UPDATE_MODE" -eq 1 ]]; then
    echo "Detected existing EpicVM installation."
    local reuse_cfg
    if [[ "${BLOBEVM_REUSE_SETTINGS:-}" == "1" ]]; then
      reuse_cfg="y"
    elif [[ "${ASSUME_DEFAULTS}" == "1" ]]; then
      reuse_cfg="y"
    else
      read -rp "Use existing settings and update components? [Y/n]: " reuse_cfg || true
    fi
    if [[ -z "$reuse_cfg" || "${reuse_cfg,,}" == y* ]]; then
      # Keep existing settings from .env; ensure defaults for missing
      BLOBEVM_DOMAIN="${BLOBEVM_DOMAIN:-}"
      BLOBEVM_EMAIL="${BLOBEVM_EMAIL:-}"
      ENABLE_KVM=${ENABLE_KVM:-0}
      FORCE_HTTPS=${FORCE_HTTPS:-0}
      HSTS_ENABLED=${HSTS_ENABLED:-0}
      ENABLE_DASHBOARD=${ENABLE_DASHBOARD:-1}
      TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-proxy}"
      SKIP_TRAEFIK=${SKIP_TRAEFIK:-0}
      HTTP_PORT=${HTTP_PORT:-80}
      HTTPS_PORT=${HTTPS_PORT:-443}
      TLS_ENABLED=${ENABLE_TLS:-0}
      # If TLS is disabled, ensure FORCE_HTTPS is not set to avoid unintended redirects
      if [[ "${TLS_ENABLED:-0}" -eq 0 ]]; then
        FORCE_HTTPS=0
      fi
      BASE_PATH=${BASE_PATH:-/vm}
      # Ensure REPO_DIR points to a real directory (avoid stale temp paths)
      if [[ -z "${REPO_DIR:-}" || ! -d "$REPO_DIR" || ! -f "$REPO_DIR/Dockerfile" ]]; then
        detect_repo_root
      fi
    else
      prompt_config
      # User chose to reconfigure: clear any previously loaded derived values so we re-detect ports/TLS
      unset HTTP_PORT HTTPS_PORT TLS_ENABLED
    fi
  else
    prompt_config
  fi
  BASE_PATH=${BASE_PATH:-/vm}
  prompt_dashboard_auth
  ensure_dashboard_secrets
  install_prereqs
  # External Traefik only if we're not already configured to skip and not in direct mode
  if [[ "${SKIP_TRAEFIK:-0}" -ne 1 && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    detect_external_traefik || true
  fi
  # If previous config said to reuse external Traefik but it's gone, auto-enable our deployment
  validate_skip_traefik || true
  ensure_network
  if [[ "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    if [[ "${BLOBEVM_SKIP_DNS_CHECK:-0}" -ne 1 ]]; then
      check_domain_dns || true
    fi
  fi
  # If reusing an external Traefik, skip our port detection and TLS prompts entirely
  if [[ "${SKIP_TRAEFIK:-0}" -ne 1 && "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    # In manage/takeover mode, force port detection (reset to 80/443 if possible)
    if [[ "${MANAGE_TRAEFIK:-0}" -eq 1 ]]; then
      unset HTTP_PORT HTTPS_PORT
      detect_ports
    else
      # If updating, prefer existing port settings; otherwise detect
      if [[ -z "${HTTP_PORT:-}" || -z "${HTTPS_PORT:-}" ]]; then
        detect_ports
      fi
    fi
    if [[ -z "${TLS_ENABLED:-}" ]]; then
      handle_tls_port_conflict
    fi
    if [[ "${TLS_ENABLED:-0}" -eq 0 ]]; then
      FORCE_HTTPS=0
    fi
    # If TLS is enabled, optionally wait for DNS to point before launching Traefik
    wait_for_dns_propagation || true
  fi
  setup_traefik
  build_image
  install_manager
  # In proxy mode, refresh VM containers so latest routing labels (routers/services/middlewares) apply
  if [[ "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    if command -v epicvm >/dev/null 2>&1; then
      echo "Refreshing VM routing labels (recreating containers in proxy mode)..."
      epicvm recreate-all || true
    fi
  fi
  # Check dashboard runtime dependencies before deployment
  preflight_dashboard_runtime || true
  # Always ensure the dashboard direct-service is enabled and running
  # dashboard_v2 deployment is now handled by blobedash-ensure.sh (direct mode, like VMs)
  if [[ -f /etc/systemd/system/blobedash.service ]]; then
    systemctl daemon-reload || true
    systemctl enable blobedash.service || true
    systemctl restart blobedash.service || systemctl start blobedash.service || true
  else
    # Fallback to one-shot docker run if systemd missing for any reason
    deploy_dashboard_direct || true
  fi
  # Load DASHBOARD_PORT from .env if assigned by ensure script
  if [[ -f /opt/blobe-vm/.env ]]; then
    # shellcheck disable=SC1091
    set +u
    while IFS='=' read -r k v; do
      [[ -z "$k" || "$k" =~ ^# ]] && continue
      v="${v%\'}"; v="${v#\'}"; v="${v%\"}"; v="${v#\"}"
      if [[ "$k" == "DASHBOARD_PORT" ]]; then export DASHBOARD_PORT="$v"; fi
    done < /opt/blobe-vm/.env
    set -u
  fi
  # Persist current env back to .env (now including DASHBOARD_PORT when present)
  install_manager

  # If running in direct mode, migrate existing instances to ensure port assignment
  if [[ "${NO_TRAEFIK:-0}" -eq 1 ]]; then
    echo "Migrating existing VMs to direct mode (assigning high ports)..."
    shopt -s nullglob
    for d in /opt/blobe-vm/instances/*; do
      [[ -d "$d" ]] || continue
      n="$(basename "$d")"
      cname="blobevm_${n}"
      # Remove old container if present to trigger port-publish recreation
      if docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
        docker rm -f "$cname" >/dev/null 2>&1 || true
      fi
      epicvm start "$n" || true
    done
  fi
  # If reusing external Traefik while TLS is disabled, warn about possible redirect
  warn_if_external_redirect || true

  # Optional: Traefik routing self-test with a disposable VM
  if [[ "${NO_TRAEFIK:-0}" -ne 1 ]]; then
    auto_test_traefik || true
  fi
  if [[ "$UPDATE_MODE" -eq 1 ]]; then
    echo "Update complete. Existing VMs were not modified."
  else
    maybe_create_first_vm
  fi
  print_success
  echo
  echo "Current VMs:"
  if command -v epicvm >/dev/null 2>&1; then
    epicvm list || true
  else
    echo "  (manager not found in PATH)"
  fi
}

main "$@"
