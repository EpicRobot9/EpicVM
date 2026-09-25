#!/usr/bin/env bash
set -euo pipefail

# One-line installer for EpicVM on a fresh server (BLOBEVM_* remains compatible)
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/EpicRobot9/BlobeVM-Manager/main/server/quick-install.sh)"

if [[ $EUID -ne 0 ]]; then
  echo "Re-running as root..."
  exec sudo -E bash "$0" "$@"
fi

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y git curl ca-certificates >/dev/null 2>&1 || true

TMP_DIR="/tmp/epicvm-install-$(date +%s)"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

REPO_URL="${EPICVM_REPO_URL:-${BLOBEVM_REPO_URL:-https://github.com/EpicRobot9/BlobeVM-Manager.git}}"
BRANCH="${EPICVM_BRANCH:-${BLOBEVM_BRANCH:-main}}"
echo "Cloning EpicVM repo..."
git clone --branch "$BRANCH" --depth 1 "$REPO_URL" repo
cd repo

echo "Running installer in one-shot onboarding mode..."
: "${BLOBEVM_ASSUME_DEFAULTS:=${EPICVM_ASSUME_DEFAULTS:-1}}"
: "${BLOBEVM_ENABLE_DASHBOARD:=${EPICVM_ENABLE_DASHBOARD:-1}}"
: "${BLOBEVM_AUTO_CREATE_VM:=${EPICVM_AUTO_CREATE_VM:-1}}"
: "${BLOBEVM_INITIAL_VM_NAME:=${EPICVM_INITIAL_VM_NAME:-testvm}}"
export BLOBEVM_ASSUME_DEFAULTS BLOBEVM_ENABLE_DASHBOARD BLOBEVM_AUTO_CREATE_VM BLOBEVM_INITIAL_VM_NAME
bash server/install.sh

echo "Cleaning up temp directory..."
cd /
rm -rf "$TMP_DIR"

echo "Done. One-shot onboarding finished."
if command -v epicvm >/dev/null 2>&1; then
  echo
  echo "Running post-install doctor..."
  epicvm doctor || true
  echo
  echo "Current VMs:"
  epicvm list || true
fi
