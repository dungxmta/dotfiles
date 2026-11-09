#!/usr/bin/env bash
# Back up / restore SSH private keys in a KeePassXC database (kept outside this repo).
# ~/.ssh/config and *.pub are managed by chezmoi; private keys never enter git.
#
# Usage: ssh-keys.sh <command>
#   backup   create the database if missing, store every ~/.ssh key pair (overwrites)
#   restore  write keys from the database into ~/.ssh (skips files that already exist)
#   list     list stored keys
#
# Layout: entry SSH/<key-name> with attachments <key-name> and <key-name>.pub
# Env: KEYS_DB (default ~/SYNC/keys.kdbx), SSH_DIR (default ~/.ssh)
# Must stay bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

KEYS_DB="${KEYS_DB:-$HOME/SYNC/keys.kdbx}"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
GROUP="SSH"

if ! command -v keepassxc-cli >/dev/null 2>&1; then
  echo "error: keepassxc-cli not found (brew install --cask keepassxc)" >&2
  exit 1
fi

# Read the database password once; every keepassxc-cli call gets it on stdin.
password=""
read_password() {
  read -r -s -p "Password for $KEYS_DB: " password </dev/tty
  echo >&2
  if ! kp ls >/dev/null 2>&1; then
    echo "error: cannot open $KEYS_DB (wrong password?)" >&2
    exit 1
  fi
}

kp() { printf '%s\n' "$password" | keepassxc-cli "$1" -q "$KEYS_DB" "${@:2}"; }

# Private keys = files in SSH_DIR with a matching .pub that start with a PEM/OpenSSH header.
private_keys() {
  local pub key
  for pub in "$SSH_DIR"/*.pub; do
    [[ -e "$pub" ]] || continue
    key="${pub%.pub}"
    [[ -f "$key" ]] && head -1 "$key" | grep -q -- '-----BEGIN .*PRIVATE KEY-----' && basename "$key"
  done
  return 0
}

create_db() {
  local again
  echo "Creating $KEYS_DB"
  read -r -s -p "New database password: " password </dev/tty
  echo >&2
  read -r -s -p "Repeat password: " again </dev/tty
  echo >&2
  if [[ -z "$password" || "$password" != "$again" ]]; then
    echo "error: passwords empty or do not match" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$KEYS_DB")"
  printf '%s\n%s\n' "$password" "$password" | keepassxc-cli db-create -q -p "$KEYS_DB"
  kp mkdir "$GROUP"
}

cmd_backup() {
  local keys name
  keys="$(private_keys)"
  if [[ -z "$keys" ]]; then
    echo "no key pairs found in $SSH_DIR"
    return
  fi
  if [[ -f "$KEYS_DB" ]]; then
    read_password
    kp ls "$GROUP" >/dev/null 2>&1 || kp mkdir "$GROUP"
  else
    create_db
  fi
  for name in $keys; do
    if ! kp show "$GROUP/$name" >/dev/null 2>&1; then
      kp add "$GROUP/$name" --notes "$(cut -d' ' -f3- "$SSH_DIR/$name.pub")"
    fi
    kp attachment-import -f "$GROUP/$name" "$name" "$SSH_DIR/$name"
    kp attachment-import -f "$GROUP/$name" "$name.pub" "$SSH_DIR/$name.pub"
    echo "backed up $name"
  done
}

stored_keys() { kp ls "$GROUP" | { grep -v '/$' || true; }; }

cmd_restore() {
  local name
  read_password
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  for name in $(stored_keys); do
    if [[ -e "$SSH_DIR/$name" ]]; then
      echo "skip $name: $SSH_DIR/$name exists"
      continue
    fi
    (umask 077 && kp attachment-export "$GROUP/$name" "$name" "$SSH_DIR/$name")
    chmod 600 "$SSH_DIR/$name"
    if [[ ! -e "$SSH_DIR/$name.pub" ]]; then
      kp attachment-export "$GROUP/$name" "$name.pub" "$SSH_DIR/$name.pub"
      chmod 644 "$SSH_DIR/$name.pub"
    fi
    echo "restored $name"
  done
}

cmd_list() {
  read_password
  stored_keys
}

case "${1:-}" in
  backup) cmd_backup ;;
  restore) cmd_restore ;;
  list) cmd_list ;;
  *)
    sed -n '5,8p' "$0" >&2
    exit 2
    ;;
esac
