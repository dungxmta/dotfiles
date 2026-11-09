#!/usr/bin/env bash
# kanata on macOS: Karabiner VirtualHIDDevice driver + LaunchDaemons + permissions.
# Docs: https://github.com/jtroo/kanata/blob/main/docs/setup-macos.md
#
# Usage: setup-kanata.sh <command>
#   status   show versions, driver compatibility and daemon state (read-only, no sudo)
#   install  install/repair everything that can be automated (uses sudo)
#   restart  restart kanata, e.g. after `brew upgrade kanata` (see note it prints)
#   logs     follow kanata's error log
#
# Env: KANATA_CONFIG  config passed to kanata (default ~/.config/kanata/homerow-mods-mac.kbd)
# Must stay bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

KANATA_CONFIG="${KANATA_CONFIG:-$HOME/.config/kanata/homerow-mods-mac.kbd}"
PLIST_SRC_DIR="$HOME/.config/kanata/autostartup"
DAEMONS_DIR="/Library/LaunchDaemons"
LOG_DIR="/Library/Logs/Kanata"

KANATA_LABEL="com.example.kanata"
VHID_DAEMON_LABEL="com.example.karabiner-vhiddaemon"
VHID_MANAGER_LABEL="com.example.karabiner-vhidmanager"

VHID_MANAGER="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
KE_APP="/Applications/Karabiner-Elements.app"

PANE_DRIVER_EXT="x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
PANE_INPUT_MONITORING="x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
PANE_ACCESSIBILITY="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

# --- versions -----------------------------------------------------------------

# Stable path (Homebrew symlink), so the LaunchDaemon survives `brew upgrade kanata`.
kanata_bin() {
  if command -v brew >/dev/null 2>&1 && [[ -x "$(brew --prefix)/bin/kanata" ]]; then
    echo "$(brew --prefix)/bin/kanata"
  else
    command -v kanata
  fi
}

kanata_version() { "$(kanata_bin)" --version | awk '{print $2}'; }

# Driver version each kanata release supports (kanata release notes / setup-macos.md):
#   kanata >= 1.13 -> driver 8.0.0;  kanata < 1.13 -> driver 6.2.0
required_driver_version() {
  local major minor
  IFS=. read -r major minor _ <<<"$1"
  if ((major > 1 || (major == 1 && minor >= 13))); then
    echo "8.0.0"
  else
    echo "6.2.0"
  fi
}

installed_driver_version() {
  local plist="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist"
  if [[ -f "$plist" ]]; then
    defaults read "$plist" CFBundleShortVersionString
  fi
}

service_state() {
  local state
  state="$(launchctl print "system/$1" 2>/dev/null | awk '/^\tstate = / {sub(/^\tstate = /, ""); print; exit}')"
  echo "${state:-not loaded}"
}

# --- status -------------------------------------------------------------------

cmd_status() {
  local kv req cur
  if ! kanata_bin >/dev/null; then
    echo "kanata: not installed (brew install kanata)"
    return 1
  fi
  kv="$(kanata_version)"
  req="$(required_driver_version "$kv")"
  cur="$(installed_driver_version)"
  echo "kanata:              $kv ($(kanata_bin))"
  echo "config:              $KANATA_CONFIG"
  echo "driver required:     $req"
  echo "driver installed:    ${cur:-none}"
  if [[ "$cur" != "$req" ]]; then
    echo "  !! driver mismatch: run '$0 install' to install $req"
  fi
  if [[ -d "$KE_APP" ]]; then
    echo "Karabiner-Elements:  installed (it runs its own VirtualHIDDevice daemon;"
    echo "                     its grabber can hold the keyboard and conflict with kanata)"
  fi
  local label
  for label in "$VHID_MANAGER_LABEL" "$VHID_DAEMON_LABEL" "$KANATA_LABEL"; do
    printf '%-36s %s\n' "$label:" "$(service_state "$label")"
  done
}

# --- install ------------------------------------------------------------------

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ "$answer" == [yY]* ]]
}

install_driver() {
  local req="$1" cur="$2" tmp
  if [[ "$cur" == "$req" ]]; then
    echo "driver $req already installed"
    return
  fi
  echo "kanata needs Karabiner-DriverKit-VirtualHIDDevice $req (installed: ${cur:-none})."
  if [[ -d "$KE_APP" ]]; then
    echo "note: Karabiner-Elements is installed and manages its own copy of the driver."
  fi
  if ! confirm "Download and install driver $req?"; then
    echo "skipped driver install"
    return
  fi
  tmp="$(mktemp -d)"
  curl -fL -o "$tmp/driver.pkg" \
    "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v${req}/Karabiner-DriverKit-VirtualHIDDevice-${req}.pkg"
  if ! spctl --assess --type install "$tmp/driver.pkg" 2>/dev/null; then
    echo "error: $tmp/driver.pkg is not signed and notarized; not installing" >&2
    rm -rf "$tmp"
    return 1
  fi
  sudo installer -pkg "$tmp/driver.pkg" -target /
  rm -rf "$tmp"
  sudo "$VHID_MANAGER" forceActivate
  echo "Approve the driver: System Settings > General > Login Items & Extensions >"
  echo "  Driver Extensions > enable org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
  open "$PANE_DRIVER_EXT"
}

# install_daemon <plist-file> <label>: copy to /Library/LaunchDaemons and (re)load it.
install_daemon() {
  local src="$1" label="$2" dst="$DAEMONS_DIR/$2.plist" i
  plutil -lint "$src" >/dev/null
  sudo install -m 644 -o root -g wheel "$src" "$dst"
  sudo launchctl bootout "system/$label" 2>/dev/null || true
  sudo launchctl enable "system/$label"
  # bootout is asynchronous; bootstrap fails with "5: Input/output error" until it finishes.
  for i in 1 2 3 4 5; do
    if sudo launchctl bootstrap system "$dst" 2>/dev/null; then
      echo "loaded $label"
      return
    fi
    sleep 1
  done
  echo "error: could not load $label (try: sudo launchctl bootstrap system $dst)" >&2
  return 1
}

cmd_install() {
  local bin kv req tmp
  if ! bin="$(kanata_bin)"; then
    brew install kanata
    bin="$(kanata_bin)"
  fi
  kv="$(kanata_version)"
  req="$(required_driver_version "$kv")"

  if [[ ! -f "$KANATA_CONFIG" ]]; then
    echo "error: $KANATA_CONFIG not found (run chezmoi apply, or set KANATA_CONFIG)" >&2
    return 1
  fi
  "$bin" --check -c "$KANATA_CONFIG" >/dev/null

  sudo -v
  install_driver "$req" "$(installed_driver_version)"

  sudo mkdir -p "$LOG_DIR"

  install_daemon "$PLIST_SRC_DIR/$VHID_MANAGER_LABEL.plist" "$VHID_MANAGER_LABEL"
  if [[ -d "$KE_APP" ]]; then
    echo "skip $VHID_DAEMON_LABEL: Karabiner-Elements already runs the VirtualHIDDevice daemon"
  else
    install_daemon "$PLIST_SRC_DIR/$VHID_DAEMON_LABEL.plist" "$VHID_DAEMON_LABEL"
  fi

  # The repo plist hardcodes paths; point it at this machine's binary and config.
  tmp="$(mktemp -d)"
  cp "$PLIST_SRC_DIR/$KANATA_LABEL.plist" "$tmp/"
  set_arg "$tmp/$KANATA_LABEL.plist" 0 "$bin"
  set_arg "$tmp/$KANATA_LABEL.plist" 2 "$KANATA_CONFIG"
  install_daemon "$tmp/$KANATA_LABEL.plist" "$KANATA_LABEL"
  rm -rf "$tmp"

  request_permissions "$bin"
  echo
  cmd_status
}

# set_arg <plist> <index> <value>: replace ProgramArguments[index].
# (plutil -replace on an array index inserts instead of replacing.)
set_arg() {
  plutil -remove "ProgramArguments.$2" "$1"
  plutil -insert "ProgramArguments.$2" -string "$3" "$1"
}

request_permissions() {
  local bin="$1"
  if "$bin" --help | grep -q -- '--macos-request-permissions'; then
    "$bin" --macos-request-permissions || true
  fi
  cat <<EOF

Manual steps (macOS does not allow scripting these):
  1. Privacy & Security > Input Monitoring: add/enable $bin and your terminal
     (Cmd+Shift+G in the file picker to type the path)
  2. Privacy & Security > Accessibility: add/enable $bin and your terminal
  3. Keyboard > Keyboard Shortcuts > Modifier Keys: select
     "Karabiner DriverKit VirtualHIDKeyboard" and set its modifiers
EOF
  open "$PANE_INPUT_MONITORING"
  open "$PANE_ACCESSIBILITY"
}

# --- restart / logs -----------------------------------------------------------

cmd_restart() {
  sudo launchctl kickstart -k "system/$KANATA_LABEL"
  echo "restarted $KANATA_LABEL"
  cat <<EOF
If keys are still not remapped after an upgrade, macOS dropped the Input Monitoring
grant for the new binary: in Privacy & Security > Input Monitoring remove kanata,
add $(kanata_bin) again, enable it, then rerun: $0 restart
EOF
  open "$PANE_INPUT_MONITORING"
}

cmd_logs() { sudo tail -f "$LOG_DIR/kanata.err.log"; }

case "${1:-}" in
  status) cmd_status ;;
  install) cmd_install ;;
  restart) cmd_restart ;;
  logs) cmd_logs ;;
  *)
    sed -n '5,9p' "$0" >&2
    exit 2
    ;;
esac
