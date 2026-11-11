#!/usr/bin/env bash
# Optional (not run by install.sh): SSH keys for multiple git accounts.
#
# Usage: setup-git.sh [--test] [account...]
#   account  github | gitlab | work   (default: all; Linux: github work)
#   --test   only check config + test the SSH connection; change nothing
#
# Per account:
#   1. Linux: a forwarded agent holding the Mac key (~/.ssh/mac/<key>.pub) is enough
#   2. key missing -> restore hint (ssh-keys.sh, Mac) or generate one (asks)
#   3. Mac: ssh-add --apple-use-keychain <key>
#   4. ssh -T git@<alias>; on failure copy the public key (Mac: pbcopy + open the
#      key page; Linux: OSC 52 + print it), wait for you to add it, retest
#
# Inputs come from the chezmoi-managed config, nothing is duplicated here:
#   ~/.ssh/config                      Host <alias>: HostName, IdentityFile
#   ~/.config/git/gitconfig-<alias>    user.email (key comment)
# Must stay bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

mac=false
[ "$(uname -s)" = Darwin ] && mac=true
ALL_ACCOUNTS="github work"
[ "$mac" = true ] && ALL_ACCOUNTS="github gitlab work"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

test_only=false
accounts=""
for arg in "$@"; do
  case "$arg" in
    --test) test_only=true ;;
    -h | --help)
      sed -n '4,6p' "$0"
      exit 0
      ;;
    *) accounts="$accounts $arg" ;;
  esac
done
accounts="${accounts:-$ALL_ACCOUNTS}"

# Capture output before filtering: with pipefail, an early-exiting reader (awk exit,
# grep -q) can SIGPIPE the writer and turn a match into a failure.
ssh_opt() {
  local out
  out="$(ssh -G "$1" 2>/dev/null)"
  awk -v k="$2" '$1 == k {print $2; exit}' <<<"$out"
}

key_page() {
  if [[ "$1" == "github.com" ]]; then
    echo "https://github.com/settings/ssh/new"
  else
    echo "https://$1/-/user_settings/ssh_keys"
  fi
}

# Exit status of ssh -T differs per provider (GitHub: 1); match the greeting instead.
ssh_ok() {
  local out
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "git@$1" 2>&1 </dev/null || true)"
  grep -qE 'successfully authenticated|Welcome to GitLab' <<<"$out"
}

# True if the forwarded agent holds the key whose public half is $1.
agent_has() {
  local keys
  [[ -n "${SSH_AUTH_SOCK:-}" && -f "$1" ]] || return 1
  keys="$(ssh-add -L 2>/dev/null)" || return 1
  grep -qF "$(cut -d' ' -f2 "$1")" <<<"$keys"
}

copy_pub() {
  if [[ "$mac" == true ]]; then
    pbcopy <"$1"
  else
    printf '\e]52;c;%s\a' "$(base64 -w0 <"$1")" >/dev/tty
  fi
}

confirm() {
  local answer
  read -r -p "$1 [Y/n] " answer </dev/tty
  [[ -z "$answer" || "$answer" == [yY]* ]]
}

failed=""
for name in $accounts; do
  host="$(ssh_opt "$name" hostname)"
  key="$(ssh_opt "$name" identityfile)"
  email="$(git config --file "$HOME/.config/git/gitconfig-$name" user.email 2>/dev/null || true)"
  key="${key/#\~/$HOME}" # ssh -G prints IdentityFile unexpanded
  printf '\n==> %s (%s, %s, %s)\n' "$name" "$host" "$key" "${email:-no email}"

  if [[ "$host" == "$name" ]]; then
    echo "error: no 'Host $name' in ~/.ssh/config (run chezmoi apply)" >&2
    failed="$failed $name"
    continue
  fi

  if [[ "$mac" != true ]] && agent_has "$HOME/.ssh/mac/$(basename "$key").pub"; then
    echo "using the Mac key from the forwarded agent"
  elif [[ ! -f "$key" ]]; then
    echo "missing key $key"
    [[ "$mac" != true && -n "${SSH_AUTH_SOCK:-}" ]] &&
      echo "  agent forwarded: on the Mac run 'vm agent <this vm> on' to send the Mac's public key"
    [[ "$mac" == true ]] && echo "  restore from KeePassXC: $SCRIPTS_DIR/ssh-keys.sh restore"
    if [[ "$test_only" == true ]] || ! confirm "Generate a new key instead?"; then
      failed="$failed $name"
      continue
    fi
    mkdir -p -m 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "${email:-$name} ($(hostname))" -f "$key" || { failed="$failed $name"; continue; }
  fi

  if [[ "$test_only" != true && "$mac" == true && -f "$key" ]]; then
    [[ -n "${SSH_AUTH_SOCK:-}" ]] || eval "$(ssh-agent -s)" >/dev/null
    ssh-add --apple-use-keychain "$key" || { failed="$failed $name"; continue; }
  fi

  if ssh_ok "$name"; then
    echo "ok: ssh git@$name"
    continue
  fi
  echo "failed: ssh git@$name (key not on the server?)"
  if [[ "$test_only" == true || ! -f "$key.pub" ]]; then
    failed="$failed $name"
    continue
  fi

  copy_pub "$key.pub"
  echo "Copied $key.pub to the clipboard; add it at $(key_page "$host"):"
  cat "$key.pub"
  [[ "$mac" == true ]] && open "$(key_page "$host")"
  read -r -p "Press Enter after adding the key to retest... " _ </dev/tty
  if ssh_ok "$name"; then
    echo "ok: ssh git@$name"
  else
    echo "still failing: ssh -T git@$name"
    failed="$failed $name"
  fi
done

echo
if [[ -n "$failed" ]]; then
  echo "failed:$failed" >&2
  exit 1
fi
echo "all accounts ok"
