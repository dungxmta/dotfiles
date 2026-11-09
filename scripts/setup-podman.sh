#!/usr/bin/env bash
# Podman on macOS, per https://podman.io/docs/installation:
# official pkg installer (recommended over Homebrew), then a Podman machine (Linux VM).
#
# Usage: setup-podman.sh <command>
#   status   show podman version and machine state (read-only)
#   install  install podman if missing (sudo), init + start the default machine, podman info
# Must stay bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

# The pkg installs to /opt/podman/bin and adds it to /etc/paths.d (new shells only).
PODMAN_BIN_DIR="/opt/podman/bin"
export PATH="$PODMAN_BIN_DIR:$PATH"

pkg_url() {
  local arch
  case "$(uname -m)" in
    arm64) arch="arm64" ;;
    x86_64) arch="amd64" ;;
    *) arch="$(uname -m)" ;;
  esac
  echo "https://github.com/podman-container-tools/podman/releases/latest/download/podman-installer-macos-${arch}.pkg"
}

# Machine state of the default machine: running | stopped | ... | "none" if no machine exists.
machine_state() {
  if [[ -z "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ]]; then
    echo "none"
  else
    podman machine inspect --format '{{.State}}' 2>/dev/null || echo "unknown"
  fi
}

cmd_status() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "podman:  not installed"
    return 1
  fi
  echo "podman:  $(podman --version | awk '{print $3}') ($(command -v podman))"
  echo "machine: $(machine_state)"
}

install_podman() {
  if command -v podman >/dev/null 2>&1; then
    echo "podman already installed: $(podman --version)"
    return
  fi
  local tmp url
  tmp="$(mktemp -d)"
  url="$(pkg_url)"
  echo "downloading $url"
  if ! curl -fL -o "$tmp/podman.pkg" "$url"; then
    rm -rf "$tmp"
    echo "error: no installer for $(uname -m) in the latest release; try: brew install podman" >&2
    return 1
  fi
  if ! spctl --assess --type install "$tmp/podman.pkg" 2>/dev/null; then
    echo "error: $url is not signed and notarized; not installing" >&2
    rm -rf "$tmp"
    return 1
  fi
  sudo installer -pkg "$tmp/podman.pkg" -target /
  rm -rf "$tmp"
}

cmd_install() {
  install_podman
  case "$(machine_state)" in
    none)
      podman machine init
      podman machine start
      ;;
    running) echo "podman machine already running" ;;
    *) podman machine start ;;
  esac
  podman info >/dev/null
  echo
  cmd_status
}

case "${1:-}" in
  status) cmd_status ;;
  install) cmd_install ;;
  *)
    sed -n '5,7p' "$0" >&2
    exit 2
    ;;
esac
