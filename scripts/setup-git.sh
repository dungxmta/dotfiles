#!/usr/bin/env bash
# Optional (not run by install.sh): SSH keys and commit signing for multiple git accounts.
#
# Usage: dot git                      status of every account, then a menu
#        dot git status               full read-only check (keys, signing, this repo)
#        dot git setup [account...]   auth key: method, make, upload, test; then signing
#        dot git renew [account]      new key: 1) auth  2) signing  3) both
#        dot git sign [account] [1-4|secretive|yubikey|key|none]
#        dot git ssh [clean]          keys in use, old keys (~/.ssh/old/), loose files; clean up
#   account  github | gitlab | work (Linux: github work); omitted = asked
#   Every choice is a numbered menu. Asked once per account and remembered: hardware-only
#   (Secretive / YubiKey keys only, never exportable files) and key expiry days.
#
# Methods, for the auth key and the signing key alike:
#   secretive  Secure Enclave key in the Secretive app; only the .pub is on disk
#   yubikey    ed25519-sk: a handle file here + the YubiKey
#   key        ed25519 file with a passphrase (exportable; not on hardware-only accounts)
# A hardware auth key goes into ~/.ssh/dotgit/<account>.conf (IdentityFile, IdentityAgent,
# and ControlMaster/ControlPersist when each use prompts), included by the account's Host
# block in ~/.ssh/config. No file = the key file from ~/.ssh/config.
#
# Setup prints the plan first: 1 auth key, 2 server (ssh -T; refused -> copy the public key,
# open the key page, wait, retest), 3 signing (Enter keeps the current method).
#
# Local to this machine (never in the dotfiles):
#   ~/.ssh/git-auth-<account>-<method>[.pub]      hardware auth key (.pub / handle)
#   ~/.ssh/git-signing-<account>-<method>[.pub]   signing key, one per method
#   ~/.ssh/allowed_signers            every signing key used here (git log, verify)
#   ~/.config/git/signing-<account>   included by gitconfig-<account>; missing = unsigned
#   ~/.config/git/dotgit              per account: hardware, auth, touch, reuse, days
#   ~/.ssh/old/<stamp>-<reason>/      keys moved aside (renew, replaced), one folder per run
# A VM only uses the Mac's hardware keys (vm up --agent): it never makes or renews them.
# Old forms still work: --test (= status), <account> --new (= renew), sign ... --days N --pin.
#
# Inputs come from the chezmoi-managed config, nothing is duplicated here:
#   ~/.ssh/config                      Host <alias>: HostName, IdentityFile
#   ~/.config/git/gitconfig-<alias>    user.email (key comment, allowed_signers)
# Must stay bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

mac=false
[ "$(uname -s)" = Darwin ] && mac=true
ALL_ACCOUNTS="github work"
[ "$mac" = true ] && ALL_ACCOUNTS="github gitlab work"
METHODS="secretive yubikey key none"
AUTH_METHODS="secretive yubikey key"
ALLOWED="$HOME/.ssh/allowed_signers"
STATE="$HOME/.config/git/dotgit"
CONF_DIR="$HOME/.ssh/dotgit"
CM_DIR="$HOME/.ssh/cm"
OLD_DIR="$HOME/.ssh/old"
old_event="" # this run's folder in OLD_DIR
WRAPPER="$HOME/.ssh/ssh-keygen-sign" # chezmoi-managed: ssh-keygen against Secretive's agent
if [[ "$mac" == true ]]; then
  SECRETIVE_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
else
  SECRETIVE_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/secretive.sock" # vm up --agent
fi

usage() { sed -n '4,12p' "$0"; }

# cmd: menu | status | setup | renew | sign. Flags are the old shortcuts.
cmd=menu new=false pin=false days="" args="" method=""
case "${1:-}" in
  "") ;;
  status | setup | renew | sign | ssh) cmd="$1"; shift ;;
  -h | --help | help) usage; exit 0 ;;
  *) cmd=setup ;; # old form: dot git <account>... [--new] [--test]
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test) cmd=status ;;
    --new) new=true ;;
    --pin) pin=true ;;
    --days) days="${2:-}"; shift ;;
    --days=*) days="${1#--days=}" ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) args="$args $1" ;;
  esac
  shift
done
if [[ -n "$days" && ! "$days" =~ ^[0-9]+$ ]]; then
  echo "--days needs a number of days" >&2
  exit 2
fi
renew_what=""
if [[ "$new" == true && "$cmd" == setup ]]; then
  cmd=renew renew_what=auth
fi
sign_new=false test_only=false planned=false login="" login_key=""
[[ "$cmd" == status ]] && test_only=true

ok() { printf 'ok  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*"; }

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

date_plus() {
  if [[ "$mac" == true ]]; then date -v+"$1"d +%F; else date -d "+$1 days" +%F; fi
}

# What to pick on the key page: $1 host, $2 auth|signing, $3 expiry days (0/empty = none).
page_hint() {
  local hint
  if [[ "$1" == "github.com" ]]; then
    [[ "$2" == auth ]] && hint="Key type: Authentication Key" || hint="Key type: Signing Key"
  else
    [[ "$2" == auth ]] && hint="Usage type: Authentication" || hint="Usage type: Signing"
    [[ -n "${3:-}" && "${3:-}" != 0 ]] && hint="$hint, expiration no later than $(date_plus "$3")"
  fi
  echo "$hint"
}

age_days() {
  local m
  if [[ "$mac" == true ]]; then m="$(stat -f %m "$1")"; else m="$(stat -c %Y "$1")"; fi
  echo $((($(date +%s) - m) / 86400))
}

# Fresh login as git@$1: -S none never goes through a reused connection (ControlPersist),
# which would say nothing about the key. Sets login=ok|refused and login_key= to the
# identity the server accepted (path without .pub; empty when ssh didn't say).
# Exit status of ssh -T differs per provider (GitHub: 1); match the greeting instead.
login_check() {
  local out
  login=refused login_key=""
  out="$(ssh -S none -v -T -o BatchMode=yes -o ConnectTimeout=10 "git@$1" 2>&1 </dev/null || true)"
  grep -qE 'successfully authenticated|Welcome to GitLab' <<<"$out" || return 0
  login=ok
  login_key="$(sed -n 's/^debug1: Server accepts key: \([^ ]*\).*/\1/p' <<<"$out" | tail -1)"
  login_key="${login_key%.pub}"
}

# ssh_ok <account> [pub]: logs in, and (given pub) with that key, not an older fallback
# key still on the server. Sets login=other when another key got in.
ssh_ok() {
  login_check "$1"
  [[ "$login" == ok ]] || return 1
  if [[ -n "${2:-}" && -n "$login_key" && "$login_key" != "${2%.pub}" ]]; then
    login=other
    return 1
  fi
}

# True if the agent at $2 (default: SSH_AUTH_SOCK) holds the key whose public half is $1.
agent_has() {
  local keys sock="${2:-${SSH_AUTH_SOCK:-}}"
  [[ -n "$sock" && -f "$1" ]] || return 1
  keys="$(SSH_AUTH_SOCK="$sock" ssh-add -L 2>/dev/null)" || return 1
  grep -qF "$(cut -d' ' -f2 "$1")" <<<"$keys"
}

copy_pub() {
  if [[ "$mac" == true ]]; then
    pbcopy <"$1"
  else
    printf '\e]52;c;%s\a' "$(base64 -w0 <"$1")" >/dev/tty
  fi
}

# Copy the public key $1, print it with the page for host $2 and what to pick there ($3).
offer_pub() {
  copy_pub "$1"
  echo "Copied $1 to the clipboard; add it at $(key_page "$2") ($3):"
  cat "$1"
  if [[ "$mac" == true ]]; then open "$(key_page "$2")"; fi
}

# confirm <question> [no]: Enter = yes, or no when $2 is "no". End of input is always no.
confirm() {
  local answer
  if [[ "${2:-}" == no ]]; then
    read -r -p "$1 [y/N] " answer </dev/tty || return 1
    [[ "$answer" == [yY]* ]]
  else
    read -r -p "$1 [Y/n] " answer </dev/tty || return 1
    [[ -z "$answer" || "$answer" == [yY]* ]]
  fi
}

# retire <key> <reason>: move <key>[.pub] into this run's ~/.ssh/old/<stamp>-<reason>/
# (one folder per run, with a "reason" note), never left loose in ~/.ssh.
retire() {
  local f moved=false why="${2:-replaced}"
  for f in "$1" "$1.pub"; do
    [[ -f "$f" ]] || continue
    if [[ -z "$old_event" ]]; then
      old_event="$OLD_DIR/$(date +%Y%m%d-%H%M%S)-$(tr -c 'A-Za-z0-9@.+\n' - <<<"$why")"
      mkdir -p "$old_event"
      chmod 700 "$OLD_DIR" "$old_event"
    fi
    mv "$f" "$old_event/"
    moved=true
  done
  [[ "$moved" == true ]] || return 0
  echo "$why: ${1##*/}" >>"$old_event/reason"
  if [[ "$mac" == true && -f "$old_event/${1##*/}.pub" ]]; then
    ssh-add -d "$old_event/${1##*/}.pub" >/dev/null 2>&1 || true
  fi
  echo "old key moved to ${old_event/#$HOME/~}/"
}

account_host() {
  local h
  h="$(ssh_opt "$1" hostname)"
  [[ "$h" != "$1" ]] && echo "$h"
}

account_email() {
  git config --file "$HOME/.config/git/gitconfig-$1" user.email 2>/dev/null || true
}

# Accounts with a Host block on this machine.
accounts_here() {
  local a
  for a in $ALL_ACCOUNTS; do
    if account_host "$a" >/dev/null; then echo "$a"; fi
  done
}

# Per-account settings in ~/.config/git/dotgit: account.<account>.<key>.
state_get() { git config --file "$STATE" "account.$1.$2" 2>/dev/null || true; }
state_set() {
  mkdir -p "$(dirname "$STATE")"
  git config --file "$STATE" "account.$1.$2" "$3"
}

# Sets kd= to the server-side expiry of account $1's key ($2: authDays | signDays):
# --days, else the remembered value, else asked once ($3 names the key) and remembered.
# 0 = no expiry.
expiry_days() {
  kd="$days"
  [[ -n "$kd" ]] || kd="$(state_get "$1" "$2")"
  if [[ -z "$kd" && "$2" == signDays ]]; then kd="$(signing_get "$1" dotgit.keyDays)"; fi
  if [[ -z "$kd" ]]; then
    read -r -p "? $3 key expiry on the server for $1, days (Enter = none): " kd </dev/tty || return 1
    [[ -z "$kd" || "$kd" =~ ^[0-9]+$ ]] || { echo "error: not a number: $kd" >&2; return 1; }
    kd="${kd:-0}"
  fi
  state_set "$1" "$2" "$kd"
}

hardware_only() { [[ "$(state_get "$1" hardware)" == true ]]; }

# Asks the hardware-only question for account $1 unless it is answered already.
ask_hardware() {
  [[ -z "$(state_get "$1" hardware)" ]] || return 0
  if confirm "Keys for $1: hardware only (Secretive / YubiKey, never exportable files)?" no; then
    state_set "$1" hardware true
  else
    state_set "$1" hardware false
  fi
}

# Numbered menu step header: step <n> <total> <title>.
step() { printf '\n[%s/%s] %s\n' "$1" "$2" "$3"; }

# Sets acct= from a numbered list of this machine's accounts (q or end of input = back).
pick_account() {
  local list ans n=0 a
  list="$(accounts_here | tr '\n' ' ')"
  echo "Account?"
  for a in $list; do
    n=$((n + 1))
    printf '  %d) %s%s\n' "$n" "$a" "$(hardware_only "$a" && echo " [hw]")"
  done
  while :; do
    read -r -p "? Choose 1-$n (q = back): " ans </dev/tty || return 1
    [[ "$ans" == q ]] && return 1
    if [[ "$ans" =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= n)); then
      acct="$(awk -v i="$ans" '{print $i}' <<<"$list")"
      return 0
    fi
    if [[ -n "$ans" && " $list " == *" $ans "* ]]; then
      acct="$ans"
      return 0
    fi
  done
}

# Secretive: the user makes the key in the app; its public key is read from the
# clipboard into $1 (secret name $2). The clipboard is never printed.
new_secretive() {
  local tmp fp loaded used
  echo "In Secretive: + new secret \"$2\", Notify (or Require Authentication),"
  echo "  then select it and Copy Public Key."
  read -r -p "Press Enter when the public key is on the clipboard... " _ </dev/tty || return 1
  tmp="$(mktemp)"
  printf '%s\n' "$(pbpaste)" >"$tmp"
  if [[ "$(grep -c '' "$tmp")" != 1 || "$(cut -d' ' -f1 "$tmp")" != ecdsa-sha2-nistp256 ]] ||
    ! fp="$(ssh-keygen -lf "$tmp" 2>/dev/null)"; then
    rm -f "$tmp"
    echo "error: the clipboard doesn't hold one Secretive public key (ecdsa-sha2-nistp256)" >&2
    return 1
  fi
  # One key per account per purpose: a key already used here (e.g. the auth key still on
  # the clipboard) is refused.
  for used in "$HOME"/.ssh/git-auth-*.pub "$HOME"/.ssh/git-signing-*.pub; do
    if [[ -f "$used" && "$used" != "$1" ]] && grep -qF "$(cut -d' ' -f2 "$tmp")" "$used"; then
      rm -f "$tmp"
      echo "error: that key is already $(basename "$used"); copy the new secret's public key" >&2
      return 1
    fi
  done
  fp="$(cut -d' ' -f2 <<<"$fp")"
  loaded="$(SSH_AUTH_SOCK="$SECRETIVE_SOCK" ssh-add -l 2>/dev/null || true)"
  if ! grep -qF "$fp" <<<"$loaded"; then
    rm -f "$tmp"
    echo "error: that key is not in Secretive's agent" >&2
    return 1
  fi
  chmod 644 "$tmp"
  mv "$tmp" "$1"
}

# Secret name for the Secretive app: git-<auth|signing>-<account>@<this Mac>[-<date> on renew].
secret_name() {
  local n="git-$1-$2@$(hostname -s)"
  [[ "$3" == true ]] && n="$n-$(date +%Y%m%d)"
  echo "$n"
}

# YubiKey ed25519-sk key: $1 path, $2 application, $3 comment.
new_yubikey() {
  echo "Touch the YubiKey when it blinks."
  if [[ "$pin" == true ]]; then
    ssh-keygen -t ed25519-sk -O application="$2" -O verify-required -C "$3" -f "$1" -N ''
  else
    ssh-keygen -t ed25519-sk -O application="$2" -C "$3" -f "$1" -N ''
  fi
}

# A new key is made at <key>.new first; only when that worked is the old pair moved aside
# and the new one moved in, so a failed or cancelled attempt leaves the old key working.
# new_path <key>: where to make it (<key> itself when nothing is there yet).
new_path() { if [[ -e "$1" || -e "$1.pub" ]]; then echo "$1.new"; else echo "$1"; fi; }

# install_new <made> <key> <reason>: retire <key> and move <made>[.pub] in (no-op when
# the same).
install_new() {
  [[ "$1" != "$2" ]] || return 0
  retire "$2" "$3"
  if [[ -f "$1" ]]; then mv "$1" "$2"; fi
  if [[ -f "$1.pub" ]]; then mv "$1.pub" "$2.pub"; fi
}

# discard_new <made> <key>: remove a half-made <key>.new pair after a failure.
discard_new() {
  [[ "$1" != "$2" ]] || return 0
  rm -f "$1" "$1.pub"
}

# After a key is in place: agent / Keychain for method $1 at $2. Touch-only YubiKey keys go
# into the agent so a VM can use them through forwarding.
post_add() {
  case "$1" in
    yubikey)
      if [[ "$pin" != true ]]; then ssh-add "$2" || echo "note: not in the agent; VMs can't use it (ssh-add $2)"; fi
      ;;
    key) if [[ "$mac" == true ]]; then ssh-add --apple-use-keychain "$2" || return 1; fi ;;
  esac
  return 0
}

# Asks the PIN question for a new YubiKey key (sets pin=).
ask_pin() {
  if [[ "$pin" != true ]] && confirm "Also require the YubiKey PIN? (then terminal only, no VM use)" no; then
    pin=true
  fi
  return 0
}

# --- auth key ------------------------------------------------------------------

auth_method() {
  local m
  m="$(state_get "$1" auth)"
  echo "${m:-key}"
}

# The key file from ~/.ssh/config (Host block), not a dotgit include or a Mac copy.
file_key_path() {
  local out k
  out="$(ssh -G "$1" 2>/dev/null)"
  k="$(awk '$1 == "identityfile" && $2 !~ /git-auth-/ && $2 !~ /\/mac\// {print $2; exit}' <<<"$out")"
  echo "${k/#\~/$HOME}"
}

auth_own() { echo "$HOME/.ssh/git-auth-$1-$2"; }
auth_mac_pub() { echo "$HOME/.ssh/mac/git-auth-$1-$2.pub"; }

# The public key of account $1's auth key for method $2 (what the server must have).
auth_pub() {
  local f
  case "$2" in
    key)
      f="$(file_key_path "$1")"
      if [[ "$mac" != true && ! -f "$f" ]] && agent_has "$HOME/.ssh/mac/$(basename "$f").pub"; then
        echo "$HOME/.ssh/mac/$(basename "$f").pub"
      else
        echo "$f.pub"
      fi
      ;;
    *) if [[ "$mac" == true ]]; then echo "$(auth_own "$1" "$2").pub"; else auth_mac_pub "$1" "$2"; fi ;;
  esac
}

# Sets why= to what auth method $2 needs for account $1 here; true if nothing.
auth_ok() {
  local types
  why=""
  case "$2" in
    secretive)
      if [[ "$mac" == true ]]; then
        [[ -S "$SECRETIVE_SOCK" ]] || why="the Secretive app, running"
      elif [[ ! -S "$SECRETIVE_SOCK" || ! -f "$(auth_mac_pub "$1" secretive)" ]]; then
        why="a Secretive auth key for $1 on the Mac, then vm agent <this vm> on"
      elif ! agent_has "$(auth_mac_pub "$1" secretive)" "$SECRETIVE_SOCK"; then
        why="the Mac's current key: vm agent <this vm> on, on the Mac"
      fi
      ;;
    yubikey)
      if [[ "$mac" == true ]]; then
        types="$(ssh -Q key 2>/dev/null || true)"
        grep -q '^sk-ssh-ed25519@' <<<"$types" || why="an ssh with security key support"
      elif ! agent_has "$(auth_mac_pub "$1" yubikey)"; then
        why="a YubiKey auth key for $1 on the Mac (no PIN), then vm agent <this vm> on"
      fi
      ;;
    key) hardware_only "$1" && why="no exportable files (hardware-only account)" ;;
  esac
  [[ -z "$why" ]]
}

auth_label() {
  case "$1" in
    secretive) if [[ "$mac" == true ]]; then echo "Secure Enclave on this Mac (hardware)"; else echo "the Mac's Secretive key (hardware)"; fi ;;
    yubikey) if [[ "$mac" == true ]]; then echo "handle on this Mac + the YubiKey (hardware)"; else echo "the Mac's YubiKey key (hardware)"; fi ;;
    key) if [[ "$mac" == true ]]; then echo "file with a passphrase (exportable)"; else echo "the Mac's key file, or one made here (exportable)"; fi ;;
  esac
}

# Sets am= from the auth menu for account $1. Enter keeps the current method; h toggles
# hardware-only.
choose_auth() {
  local cur m answer n avail
  cur="$(auth_method "$1")"
  while :; do
    n=0 avail=""
    echo "Auth key for $1? (now: $cur; hardware-only: $(hardware_only "$1" && echo yes || echo no))"
    for m in $AUTH_METHODS; do
      n=$((n + 1))
      if auth_ok "$1" "$m"; then
        printf '  %d) %-10s %s\n' "$n" "$m" "$(auth_label "$m")"
        avail="$avail $m"
      else
        printf '  %d) %-10s unavailable, needs %s\n' "$n" "$m" "$why"
      fi
    done
    echo "  h) hardware-only: change"
    read -r -p "? Choose 1-$n (Enter = keep $cur): " answer </dev/tty || return 1
    if [[ "$answer" == h ]]; then
      if hardware_only "$1"; then state_set "$1" hardware false; else state_set "$1" hardware true; fi
      continue
    fi
    [[ -n "$answer" ]] || answer="$cur"
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= n)); then
      answer="$(awk -v i="$answer" '{print $i}' <<<"$AUTH_METHODS")"
    fi
    if [[ " $avail " == *" $answer "* ]]; then
      am="$answer"
      return 0
    fi
    echo "  not available here; pick another number"
  done
}

# For a hardware auth key: does each use prompt (Touch ID / touch)? Then reuse connections.
ask_reuse() {
  local t=false mins
  case "$2" in
    secretive) confirm "Does the secret require Touch ID (Require Authentication)?" no && t=true ;;
    yubikey) t=true ;; # a touch per connection
  esac
  state_set "$1" touch "$t"
  if [[ "$t" != true ]]; then
    state_set "$1" reuse 0
    return 0
  fi
  read -r -p "? Reuse a connection so the prompt comes once per … minutes (0 = every connection, Enter = 30): " mins </dev/tty || mins=""
  [[ "$mins" =~ ^[0-9]+$ ]] || mins=30
  state_set "$1" reuse "$mins"
}

# ~/.ssh/dotgit/<account>.conf for a hardware auth key (removed for a key file).
write_auth_conf() {
  local acct=$1 m=$2 f id reuse tmp
  f="$CONF_DIR/$acct.conf"
  if [[ "$m" == key ]]; then
    rm -f "$f"
    return 0
  fi
  case "$m" in
    secretive) if [[ "$mac" == true ]]; then id="$(auth_own "$acct" secretive).pub"; else id="$(auth_mac_pub "$acct" secretive)"; fi ;;
    yubikey) if [[ "$mac" == true ]]; then id="$(auth_own "$acct" yubikey)"; else id="$(auth_mac_pub "$acct" yubikey)"; fi ;;
  esac
  reuse="$(state_get "$acct" reuse)"
  mkdir -p -m 700 "$CONF_DIR"
  tmp="$(mktemp "$f.XXXXXX")"
  {
    echo "# Written by dot git ($acct auth: $m); local to this machine, not managed by chezmoi."
    echo "IdentityFile $id"
    if [[ "$m" == secretive ]]; then echo "IdentityAgent $SECRETIVE_SOCK"; fi
    if [[ -n "$reuse" && "$reuse" != 0 ]]; then
      mkdir -p -m 700 "$CM_DIR"
      echo "ControlMaster auto"
      echo "ControlPath $CM_DIR/%C"
      echo "ControlPersist ${reuse}m"
    fi
  } >"$tmp"
  mv "$tmp" "$f"
}

master_open() { ssh -O check "$1" >/dev/null 2>&1; }

close_master() {
  if master_open "$1"; then
    ssh -O exit "$1" >/dev/null 2>&1 || true
    echo "closed the reused connection to $1"
  fi
  return 0
}

# A VM without a usable Mac key: wait for forwarding (false), or make a VM-only key (true).
vm_key_choice() {
  local a
  if [[ -f "$2" && -n "${SSH_AUTH_SOCK:-}" ]]; then
    warn "the Mac's key changed: the forwarded agent doesn't hold ~/.ssh/mac/$(basename "$2")"
  else
    echo "no key for $1 here, and the Mac's isn't forwarded"
  fi
  echo "  1) use the Mac's key: on the Mac run  vm agent <this vm> on  (then dot git again)"
  if hardware_only "$1"; then
    echo "  (no VM-only key: $1 is hardware-only)"
    echo "skipped $1: on the Mac run  vm agent <this vm> on,  then  dot git setup $1"
    return 1
  fi
  echo "  2) make a VM-only key (uploaded once; vm restore wipes it)"
  while :; do
    read -r -p "? Choose 1-2: " a </dev/tty || return 1
    case "$a" in
      1) echo "skipped $1: on the Mac run  vm agent <this vm> on,  then  dot git setup $1"; return 1 ;;
      2) return 0 ;;
    esac
  done
}

# Make sure account $1 has an auth key for method $2 (new=true: a new one). Sets pub=.
ensure_auth_key() {
  local acct=$1 m=$2 email key own mp stale made
  email="$(account_email "$acct")"
  case "$m" in
    key)
      key="$(file_key_path "$acct")"
      mp="$HOME/.ssh/mac/$(basename "$key").pub"
      if [[ "$new" == true ]]; then
        expiry_days "$acct" authDays "Auth" || return 1
        mkdir -p -m 700 "$HOME/.ssh"
        made="$(new_path "$key")"
        ssh-keygen -t ed25519 -C "${email:-$acct} ($(hostname))" -f "$made" || { discard_new "$made" "$key"; return 1; }
        install_new "$made" "$key" "renew $acct auth"
      elif [[ "$mac" != true ]] && agent_has "$mp"; then
        echo "using the Mac key from the forwarded agent"
      elif [[ ! -f "$key" ]]; then
        if [[ "$test_only" == true ]]; then
          echo "missing key $key"
          return 1
        elif [[ "$mac" == true ]]; then
          echo "missing key $key"
          confirm "Generate a new key?" || return 1
        else
          vm_key_choice "$acct" "$mp" || return 1
        fi
        expiry_days "$acct" authDays "Auth" || return 1
        mkdir -p -m 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -C "${email:-$acct} ($(hostname))" -f "$key" || return 1
      fi
      if [[ "$test_only" != true && "$mac" == true && -f "$key" ]]; then
        [[ -n "${SSH_AUTH_SOCK:-}" ]] || eval "$(ssh-agent -s)" >/dev/null
        ssh-add --apple-use-keychain "$key" || return 1
      fi
      ;;
    secretive | yubikey)
      if [[ "$mac" != true ]]; then
        auth_ok "$acct" "$m" || { warn "$m: needs $why"; return 1; }
        echo "using the Mac's $m key"
      else
        own="$(auth_own "$acct" "$m")"
        stale=false # a Secretive .pub whose secret was deleted in the app
        if [[ "$m" == secretive && -f "$own.pub" ]] && ! agent_has "$own.pub" "$SECRETIVE_SOCK"; then
          stale=true
        fi
        if [[ "$new" == true || ! -f "$own.pub" || "$stale" == true ]]; then
          [[ "$test_only" != true ]] || { echo "missing $m auth key ($own.pub)"; return 1; }
          auth_ok "$acct" "$m" || { warn "$m: needs $why"; return 1; }
          expiry_days "$acct" authDays "Auth" || return 1
          made="$(new_path "$own")"
          if [[ "$m" == secretive ]]; then
            new_secretive "$made.pub" "$(secret_name auth "$acct" "$new")" || { discard_new "$made" "$own"; return 1; }
          else
            ask_pin
            new_yubikey "$made" "ssh:git-auth-$acct" "${email:-$acct} git-auth ($(hostname))" || { discard_new "$made" "$own"; return 1; }
          fi
          install_new "$made" "$own" "$([[ "$new" == true ]] && echo renew || echo replace) $acct auth"
          post_add "$m" "$own"
        fi
      fi
      ;;
  esac
  [[ "$test_only" == true ]] || write_auth_conf "$acct" "$m"
  pub="$(auth_pub "$acct" "$m")"
}

# Auth key for account $1: plan + method (setup), key, ssh -T, upload when refused.
auth_account() {
  local name=$1 host email am old
  host="$(ssh_opt "$name" hostname)"
  email="$(account_email "$name")"
  printf '\n==> %s (%s, %s)\n' "$name" "$host" "${email:-no email}"
  if [[ "$host" == "$name" ]]; then
    echo "error: no 'Host $name' in ~/.ssh/config (run chezmoi apply)" >&2
    return 1
  fi

  am="$(auth_method "$name")"
  if [[ "$test_only" != true && "$planned" != true ]]; then
    echo "Plan:"
    echo "  1. auth key   choose 1-3 (now: $am$(hardware_only "$name" && echo ", hardware-only"))"
    echo "  2. server     ssh -T git@$name; refused → copy key, open $(key_page "$host")"
    echo "                ($(page_hint "$host" auth "$(state_get "$name" authDays)")), wait, retest"
    echo "  3. signing    choose 1-4 (now: $(current_method "$name"))"
    step 1 3 "auth key"
    old="$am"
    choose_auth "$name" || return 1
    if [[ "$am" != key && ("$am" != "$old" || -z "$(state_get "$name" touch)") ]]; then
      ask_reuse "$name" "$am"
    fi
    state_set "$name" auth "$am"
  fi

  ensure_auth_key "$name" "$am" || return 1

  [[ "$test_only" == true || "$planned" == true ]] || step 2 3 "server: ssh -T git@$name"
  if [[ "$test_only" == true && "$(state_get "$name" touch)" == true ]]; then
    echo "not checked: ssh git@$name prompts (Touch ID / touch); test: ssh -S none -v -T git@$name"
    return 0
  fi
  if ssh_ok "$name" "$pub"; then
    ok "ssh git@$name with $(basename "$pub")$([[ -f "$pub" ]] && echo ", $(age_days "$pub") days old")"
    retire_file_key "$name" "$am"
    return 0
  fi
  login_failed "$name" "$pub"
  [[ "$test_only" != true && -f "$pub" ]] || return 1

  offer_pub "$pub" "$host" "$(page_hint "$host" auth "$(state_get "$name" authDays)")"
  read -r -p "Press Enter after adding the key to retest... " _ </dev/tty || return 1
  if ssh_ok "$name" "$pub"; then
    ok "ssh git@$name with $(basename "$pub")"
    retire_file_key "$name" "$am"
  else
    login_failed "$name" "$pub"
    echo "    check: ssh -S none -v -T git@$name 2>&1 | grep -E 'Offering|Server accepts'"
    return 1
  fi
}

# Why ssh_ok failed for account $1 (expected key $2).
login_failed() {
  if [[ "$login" == other ]]; then
    warn "ssh git@$1 logged in with $(basename "$login_key"), not $(basename "$2"): the new key isn't on the server yet"
  else
    echo "failed: ssh git@$1 with $(basename "$2") (not on the server as an authentication key?)"
  fi
}

# After a hardware auth key works on a hardware-only account, offer to move the old,
# exportable key file aside.
retire_file_key() {
  local f
  [[ "$test_only" != true && "$1" != "" && "$2" != key && "$mac" == true ]] || return 0
  f="$(file_key_path "$1")"
  [[ -f "$f" ]] || return 0
  if confirm "Move the old key file $(basename "$f") aside? (exportable; $2 works now)" no; then
    retire "$f" "$1 file key, now $2"
  fi
  return 0
}

# --- signing ---------------------------------------------------------------

signing_file() { echo "$HOME/.config/git/signing-$1"; }

signing_get() { git config --file "$(signing_file "$1")" "$2" 2>/dev/null || true; }

current_method() {
  local m
  m="$(signing_get "$1" dotgit.method)"
  echo "${m:-none}"
}

own_key() { echo "$HOME/.ssh/git-signing-$1-$2"; }
mac_pub() { echo "$HOME/.ssh/mac/git-signing-$1-$2.pub"; }

pub_of() { [[ "$1" == *.pub ]] && echo "$1" || echo "$1.pub"; }

# The path for user.signingkey. A private key (or security-key handle) works with and
# without an agent: ssh-keygen asks the agent first, then loads the file.
sign_key() {
  local own mp
  own="$(own_key "$1" "$2")"
  mp="$(mac_pub "$1" "$2")"
  case "$2" in
    secretive) if [[ "$mac" == true ]]; then echo "$own.pub"; else echo "$mp"; fi ;;
    yubikey) if [[ "$mac" == true ]]; then echo "$own"; else echo "$mp"; fi ;;
    key) if [[ "$mac" != true && ! -f "$own" ]] && agent_has "$mp"; then echo "$mp"; else echo "$own"; fi ;;
  esac
}

# Sets why= to what signing method $2 needs for account $1 here; true if nothing.
method_ok() {
  local types
  why=""
  case "$2" in
    secretive)
      if [[ ! -x "$WRAPPER" ]]; then
        why="chezmoi apply (installs $WRAPPER)"
      elif [[ "$mac" == true ]]; then
        [[ -S "$SECRETIVE_SOCK" ]] || why="the Secretive app, running"
      elif [[ ! -S "$SECRETIVE_SOCK" || ! -f "$(mac_pub "$1" secretive)" ]]; then
        why="vm agent <this vm> on, on the Mac (after a Secretive key for $1 there)"
      elif ! agent_has "$(mac_pub "$1" secretive)" "$SECRETIVE_SOCK"; then
        why="the Mac's current key: vm agent <this vm> on, on the Mac"
      fi
      ;;
    yubikey)
      if [[ "$mac" == true ]]; then
        types="$(ssh -Q key 2>/dev/null || true)"
        grep -q '^sk-ssh-ed25519@' <<<"$types" || why="an ssh with security key support"
      elif ! agent_has "$(mac_pub "$1" yubikey)"; then
        why="a YubiKey key for $1 on the Mac (no PIN), then vm agent <this vm> on"
      fi
      ;;
    key) hardware_only "$1" && why="no exportable files (hardware-only account)" ;;
  esac
  [[ -z "$why" ]]
}

# Menu line for signing method $2 of account $1 (host $3).
method_label() {
  case "$2" in
    secretive)
      if [[ "$mac" == true ]]; then echo "Secure Enclave key in Secretive (notification per commit)"; else echo "the Mac's Secretive key (notification on the Mac)"; fi
      ;;
    yubikey)
      if [[ "$mac" == true ]]; then echo "YubiKey, touch per commit"; else echo "the Mac's YubiKey key (touch)"; fi
      ;;
    key)
      if [[ "$mac" != true ]]; then
        echo "VM-only key file (made here, uploaded once)"
      elif [[ -n "$3" && "$3" == "$(account_host work)" ]]; then
        echo "plain key file (note: some hosts' policies accept only hardware keys)"
      else
        echo "plain key file with a passphrase (exportable)"
      fi
      ;;
    none) echo "don't sign" ;;
  esac
}

# What making a <method> ($1) key involves, for plans.
made_text() {
  case "$1" in
    secretive) echo "Secretive app: + new secret, Copy Public Key (read from the clipboard)" ;;
    yubikey) echo "ssh-keygen ed25519-sk on the YubiKey (touch$([[ "$pin" == true ]] && echo " + PIN"))" ;;
    key) echo "ssh-keygen ed25519 (passphrase)" ;;
  esac
}

# Sets method= from a numbered menu for account $1 (host $2). Enter keeps the current one;
# unavailable methods keep their number but can't be picked.
choose_method() {
  local cur m answer n=0 avail=""
  cur="$(current_method "$1")"
  echo "Sign commits for $1? (now: $cur$(hardware_only "$1" && echo "; hardware-only"))"
  for m in $METHODS; do
    n=$((n + 1))
    if method_ok "$1" "$m"; then
      printf '  %d) %-10s %s\n' "$n" "$m" "$(method_label "$1" "$m" "$2")"
      avail="$avail $m"
    else
      printf '  %d) %-10s unavailable, needs %s\n' "$n" "$m" "$why"
    fi
  done
  while :; do
    read -r -p "? Choose 1-$n (Enter = keep $cur): " answer </dev/tty || return 1
    if [[ -z "$answer" ]]; then
      method="$cur"
      return 0
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= n)); then
      answer="$(awk -v i="$answer" '{print $i}' <<<"$METHODS")"
    fi
    if [[ " $avail " == *" $answer "* ]]; then
      method="$answer"
      return 0
    fi
    echo "  not available here; pick another number"
  done
}

# Append the public key $2 for email $1 to allowed_signers unless it is there.
allow_signer() {
  local blob
  blob="$(cut -d' ' -f2 "$2")"
  touch "$ALLOWED"
  if ! grep -qF "$blob" "$ALLOWED"; then
    printf '%s namespaces="git" %s\n' "${1:-*}" "$(cut -d' ' -f1,2 "$2")" >>"$ALLOWED"
  fi
}

# signing-<account>: $1 account, $2 method, $3 signingkey, $4 keyDays, $5 pin.
# Written atomically; git skips a missing include, so no file = unsigned.
write_signing() {
  local f tmp
  f="$(signing_file "$1")"
  mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "$f.XXXXXX")"
  {
    printf '# Written by dot git sign %s; local to this machine, not managed by chezmoi.\n' "$1"
    printf '[user]\n\tsigningkey = %s\n' "$3"
    printf '[gpg]\n\tformat = ssh\n'
    printf '[gpg "ssh"]\n\tallowedSignersFile = %s\n' "$ALLOWED"
    if [[ "$2" == secretive ]]; then printf '\tprogram = %s\n' "$WRAPPER"; fi
    printf '[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n'
    printf '[dotgit]\n\tmethod = %s\n' "$2"
    if [[ -n "$4" && "$4" != 0 ]]; then printf '\tkeyDays = %s\n' "$4"; fi
    if [[ "$5" == true ]]; then printf '\tpin = true\n'; fi
  } >"$tmp"
  mv "$tmp" "$f"
}

# Sign and verify a test message: $1 email, $2 signing key, $3 method.
test_sign() {
  local d prog=ssh-keygen rc=1
  [[ "$3" == secretive ]] && prog="$WRAPPER"
  d="$(mktemp -d)"
  echo "dot git sign test" >"$d/msg"
  echo "test signature (approve the notification / touch the key)..."
  if "$prog" -Y sign -n git -f "$2" "$d/msg" >/dev/null &&
    ssh-keygen -Y verify -f "$ALLOWED" -I "${1:-*}" -n git -s "$d/msg.sig" <"$d/msg" >/dev/null; then
    rc=0
  fi
  rm -rf "$d"
  return $rc
}

# Make the signing key for method $2 of account $1 at $3 (email $4).
new_key() {
  local comment="${4:-$1} git-sign ($(hostname))"
  mkdir -p -m 700 "$HOME/.ssh"
  case "$2" in
    secretive) new_secretive "$3.pub" "$(secret_name signing "$1" "$sign_new")" ;;
    yubikey) new_yubikey "$3" "ssh:git-sign-$1" "$comment" ;;
    key) ssh-keygen -t ed25519 -C "$comment" -f "$3" ;;
  esac
}

# Switch account $1 to method= (asked when empty) using an existing key, or create +
# upload one (also when sign_new); then write signing-<account>.
sign_account() {
  local acct=$1 host email cur own key pub p stale made mk create=false
  host="$(account_host "$acct")" || { echo "error: no 'Host $acct' in ~/.ssh/config (run chezmoi apply)" >&2; return 1; }
  email="$(account_email "$acct")"
  cur="$(current_method "$acct")"
  if [[ -z "$method" && "$sign_new" == true && "$cur" != none ]]; then
    method="$cur" # renew the active method
  fi
  [[ -n "$method" ]] || choose_method "$acct" "$host" || return 1
  if [[ "$method" == none ]]; then
    rm -f "$(signing_file "$acct")"
    ok "$acct: not signing (keys and allowed_signers kept)"
    return 0
  fi
  if ! method_ok "$acct" "$method"; then
    echo "error: $method can't sign here; needs $why" >&2
    return 1
  fi

  own="$(own_key "$acct" "$method")"
  key="$(sign_key "$acct" "$method")"
  pub="$(pub_of "$key")"
  # On the Mac a Secretive .pub whose secret was deleted in the app counts as missing.
  stale=false
  if [[ "$mac" == true && "$method" == secretive && -f "$pub" ]] && ! agent_has "$pub" "$SECRETIVE_SOCK"; then
    stale=true
  fi
  if [[ "$sign_new" == true || ! -f "$pub" || "$stale" == true ]]; then
    if [[ "$mac" != true && "$method" != key ]]; then
      echo "error: $method keys are made on the Mac (dot git sign $acct), then vm agent <this vm> on" >&2
      return 1
    fi
    create=true
    key="$own"
    [[ "$method" == secretive ]] && key="$own.pub"
    pub="$own.pub"
  fi

  p="$pin"
  if [[ "$create" == true ]]; then
    [[ "$method" != yubikey ]] || ask_pin
    p="$pin"
    expiry_days "$acct" signDays "Signing" || return 1
    echo "New signing key for $acct ($method):"
    echo "  a. key      $(made_text "$method")$([[ "$sign_new" == true ]] && echo "; old key → ~/.ssh/old/")"
    echo "  b. test     sign + verify a test message (notification / touch / passphrase)"
    echo "  c. upload   $(key_page "$host") ($(page_hint "$host" signing "$kd"))"
    echo "-- a. key"
    made="$(new_path "$own")"
    new_key "$acct" "$method" "$made" "$email" || { discard_new "$made" "$own"; return 1; }
    allow_signer "$email" "$made.pub"
    echo "-- b. test"
    if [[ "$method" == secretive ]]; then mk="$made.pub"; else mk="$made"; fi
    if ! test_sign "$email" "$mk" "$method"; then
      discard_new "$made" "$own"
      echo "error: test signature failed; signing-$acct and the old key unchanged" >&2
      return 1
    fi
    ok "test signature verified"
    install_new "$made" "$own" "$([[ "$sign_new" == true ]] && echo renew || echo replace) $acct signing"
    post_add "$method" "$own" || return 1
    echo "-- c. upload"
    offer_pub "$pub" "$host" "$(page_hint "$host" signing "$kd")"
    read -r -p "Press Enter after adding it... " _ </dev/tty || true
  else
    kd="$(state_get "$acct" signDays)"
    [[ -n "$kd" ]] || kd="$(signing_get "$acct" dotgit.keyDays)"
    if [[ "$method" == "$cur" && "$(signing_get "$acct" dotgit.pin)" == true ]]; then p=true; fi
    allow_signer "$email" "$pub"
    ok "using existing $(basename "$pub") ($(age_days "$pub") days old)"
  fi
  write_signing "$acct" "$method" "$key" "$kd" "$p"
  ok "$acct signs with $method"
}

# setup: hardware-only (asked once), auth key (steps 1-2), then signing (step 3).
setup_account() {
  planned=false new=false
  account_host "$1" >/dev/null || { echo "error: no 'Host $1' in ~/.ssh/config (run chezmoi apply)" >&2; return 1; }
  ask_hardware "$1"
  auth_account "$1" || return 1
  step 3 3 "signing"
  method=""
  sign_account "$1"
}

# --- renew -----------------------------------------------------------------

renew_account() {
  local acct=$1 host am cur what ans ad sd n=0 mac_auth=false mac_sign=false auth_ok=true sign_ok=true
  host="$(account_host "$acct")" || { echo "error: no 'Host $acct' in ~/.ssh/config (run chezmoi apply)" >&2; return 1; }
  am="$(auth_method "$acct")"
  cur="$(current_method "$acct")"

  # A VM only uses the Mac's keys; those are renewed on the Mac.
  if [[ "$mac" != true ]]; then
    if [[ "$am" != key || ! -f "$(file_key_path "$acct")" ]]; then mac_auth=true; fi
    case "$cur" in
      secretive | yubikey) mac_sign=true ;;
      key) [[ "$(signing_get "$acct" user.signingkey)" == "$HOME/.ssh/mac/"* ]] && mac_sign=true ;;
    esac
    if [[ "$mac_auth" == true && ("$mac_sign" == true || "$cur" == none) ]]; then
      echo "$acct uses the Mac's keys: renew them on the Mac:"
      echo "  Mac:  dot git renew $acct      then  vm agent <this vm> on"
      return 0
    fi
  fi
  [[ "$mac_auth" == true ]] && auth_ok=false
  [[ "$cur" == none || "$mac_sign" == true ]] && sign_ok=false

  what="$renew_what"
  if [[ -z "$what" ]]; then
    echo "Renew $acct: what?"
    if [[ "$auth_ok" == true ]]; then
      echo "  1) auth key      $am"
    else
      echo "  1) auth key      unavailable: the Mac's key, renew it on the Mac"
    fi
    if [[ "$sign_ok" == true ]]; then
      echo "  2) signing key   $cur"
    elif [[ "$cur" == none ]]; then
      echo "  2) signing key   unavailable: not signing (dot git sign $acct)"
    else
      echo "  2) signing key   unavailable: the Mac's key, renew it on the Mac"
    fi
    echo "  3) both"
    while :; do
      read -r -p "? Choose 1-3 (Enter = auth key): " ans </dev/tty || return 1
      case "$ans" in
        "" | 1) what=auth ;;
        2) what=sign ;;
        3) what=both ;;
        *) continue ;;
      esac
      if [[ ("$what" != sign && "$auth_ok" != true) || ("$what" != auth && "$sign_ok" != true) ]]; then
        echo "  not available here; pick another number"
        continue
      fi
      break
    done
  fi
  if [[ "$what" != auth && "$cur" == none ]]; then
    echo "error: $acct doesn't sign; choose a method with: dot git sign $acct" >&2
    return 1
  fi

  ad="" sd=""
  if [[ "$what" != sign ]]; then expiry_days "$acct" authDays "Auth" || return 1; ad="$kd"; fi
  if [[ "$what" != auth ]]; then expiry_days "$acct" signDays "Signing" || return 1; sd="$kd"; fi
  echo "Plan:"
  if [[ "$what" != sign ]]; then
    n=$((n + 1))
    case "$am" in
      key) echo "  $n. auth key     new $(basename "$(file_key_path "$acct")") (old → ~/.ssh/old/) → page: $(page_hint "$host" auth "$ad")" ;;
      *) echo "  $n. auth key     $(made_text "$am") → page: $(page_hint "$host" auth "$ad")" ;;
    esac
  fi
  if [[ "$what" != auth ]]; then
    n=$((n + 1))
    echo "  $n. signing key  $(made_text "$cur") → test → page: $(page_hint "$host" signing "$sd")"
  fi
  if [[ "$mac" == true ]]; then
    n=$((n + 1))
    echo "  $n. VMs          reminder: vm agent <vm> on for each running VM"
  fi
  n=$((n + 1))
  echo "  $n. cleanup      reminder: delete the old keys at $(key_page "$host")$([[ "$am" == secretive || "$cur" == secretive ]] && echo " and in Secretive")"
  confirm "Continue? (moves the current key aside)" no || return 1

  planned=true
  if [[ "$what" != sign ]]; then
    new=true days="$ad"
    close_master "$acct"
    auth_account "$acct" || return 1
    new=false
  fi
  if [[ "$what" != auth ]]; then
    printf '\n==> %s signing key\n' "$acct"
    sign_new=true method="$cur" days="$sd"
    sign_account "$acct" || return 1
  fi
  echo
  echo "Next:"
  if [[ "$mac" == true ]]; then echo "  vm agent <vm> on      for each running VM (sends the new .pub)"; fi
  echo "  delete the old keys at $(key_page "$host")$([[ "$am" == secretive || "$cur" == secretive ]] && echo " and the old secrets in Secretive")"
}

# --- status ------------------------------------------------------------------

# days_cell <age> <days>: cell="<age>/<days> days" (or "<age> days"); hot=true near expiry.
days_cell() {
  if [[ -n "$2" && "$2" != 0 ]]; then
    cell="$1/$2 days"
    if (($1 >= $2 - 3)); then hot=true; fi
  else
    cell="$1 days"
  fi
}

# Sets cell= and hot= for account $1's auth key.
auth_status() {
  local am key mp p
  am="$(auth_method "$1")"
  hot=false
  if [[ "$am" != key ]]; then
    p="$(auth_pub "$1" "$am")"
    if ! auth_ok "$1" "$am"; then
      hot=true cell="$am: can't use here"
    elif [[ ! -f "$p" ]]; then
      hot=true cell="$am: no key"
    else
      days_cell "$(age_days "$p")" "$(state_get "$1" authDays)"
      cell="$am $cell"
    fi
    return 0
  fi
  key="$(file_key_path "$1")"
  mp="$HOME/.ssh/mac/$(basename "$key").pub"
  if [[ "$mac" != true ]] && agent_has "$mp"; then
    cell="Mac's key"
  elif [[ -f "$key.pub" ]]; then
    days_cell "$(age_days "$key.pub")" "$(state_get "$1" authDays)"
    cell="key $cell"
  elif [[ "$mac" != true && -f "$mp" ]]; then
    hot=true
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then cell="Mac key changed"; else cell="Mac key not forwarded"; fi
  else
    hot=true cell="no key"
  fi
  if [[ "$cell" != *"Mac key"* && "$cell" != "no key" ]] && hardware_only "$1"; then
    hot=true cell="exportable key file"
  fi
}

# Sets cell= and hot= for account $1's signing; why= when it can't sign here.
sign_status() {
  local m pub kd
  m="$(current_method "$1")"
  hot=false why=""
  if [[ "$m" == none ]]; then
    cell=none
    return 0
  fi
  pub="$(pub_of "$(signing_get "$1" user.signingkey)")"
  kd="$(state_get "$1" signDays)"
  [[ -n "$kd" ]] || kd="$(signing_get "$1" dotgit.keyDays)"
  if [[ ! -f "$pub" ]]; then
    hot=true cell="$m: key missing"
  elif ! method_ok "$1" "$m"; then
    hot=true cell="$m: can't sign here"
  elif [[ "$mac" == true && "$m" == secretive ]] && ! agent_has "$pub" "$SECRETIVE_SOCK"; then
    hot=true cell="$m: not in Secretive" why="renew it (secret deleted in the app?)"
  else
    days_cell "$(age_days "$pub")" "$kd"
    cell="$m $cell"
  fi
}

# Sets r_* for the repo in the current directory (r_top empty outside a repo).
repo_facts() {
  local origin b
  r_top="" r_acct="" r_email="" r_want="" r_sig="" r_base="" r_n=0
  r_top="$(git rev-parse --show-toplevel 2>/dev/null)" || { r_top=""; return 0; }
  origin="$(git config --show-origin --get dotgit.method 2>/dev/null ||
    git config --show-origin --get user.email 2>/dev/null || true)"
  r_acct="$(sed -E -n 's#^file:.*/(signing|gitconfig)-([^/[:space:]]+)[[:space:]].*#\2#p' <<<"$origin")"
  r_email="$(git config --get user.email || true)"
  [[ -z "$r_acct" ]] || r_want="$(account_email "$r_acct")"
  git rev-parse -q --verify HEAD >/dev/null || return 0
  r_sig="$(git log -1 --no-show-signature --format=%G? HEAD)"
  for b in origin/HEAD origin/main origin/master; do
    if git rev-parse -q --verify "$b" >/dev/null; then
      r_base="$(git rev-parse --abbrev-ref "$b")"
      break
    fi
  done
  if [[ -n "$r_base" ]]; then
    r_n="$(git log --no-show-signature --format=%G? "$r_base..HEAD" | grep -c '^N$' || true)"
  fi
}

# Accounts with connection reuse on.
reuse_accounts() {
  local a r
  for a in $(accounts_here); do
    r="$(state_get "$a" reuse)"
    if [[ -n "$r" && "$r" != 0 ]]; then echo "$a"; fi
  done
}

# `dot git`: one row per account, this repo, and suggestions (no action is preselected).
status_table() {
  local a n=0 ac sc sv rc=0 fw sock line name suggest="" notes=""
  if [[ "$mac" == true ]]; then
    echo "git accounts (Mac)"
  else
    ssh-add -l >/dev/null 2>&1 || rc=$?
    if [[ -n "${SSH_AUTH_SOCK:-}" && "$rc" != 2 ]]; then fw="Mac keys forwarded"; else fw="Mac keys not forwarded"; fi
    if [[ -S "$SECRETIVE_SOCK" ]]; then sock="Secretive socket ok"; else sock="no Secretive socket"; fi
    echo "git accounts ($(hostname) · $fw · $sock)"
  fi
  printf '  %-2s %-11s %-26s %-28s %s\n' "#" account "auth key" signing server
  for a in $(accounts_here); do
    n=$((n + 1))
    name="$a"
    hardware_only "$a" && name="$a [hw]"
    auth_status "$a"
    ac="$cell"
    if [[ "$hot" == true ]]; then
      ac="!! $ac"
      case "$cell" in
        "Mac key"*) suggest="$suggest"$'\n'"  on the Mac: vm agent <this vm> on   ($a: $cell)" ;;
        "no key" | *": no key") suggest="$suggest"$'\n'"  set up $a" ;;
        *"can't use here") suggest="$suggest"$'\n'"  set up $a ($cell)" ;;
        "exportable key file") suggest="$suggest"$'\n'"  set up $a → auth 1 secretive or 2 yubikey (hardware-only)" ;;
        *) suggest="$suggest"$'\n'"  renew $a: auth key ($cell)" ;;
      esac
    fi
    sign_status "$a"
    sc="$cell"
    if [[ "$hot" == true ]]; then
      sc="!! $sc"
      if [[ -n "$why" ]]; then
        notes="$notes"$'\n'"  $a signing needs $why"
      else
        suggest="$suggest"$'\n'"  renew $a: signing key ($cell)"
      fi
    fi
    if [[ "$(state_get "$a" touch)" == true ]]; then
      # a fresh login would prompt; the reused connection may still be an older key's
      if master_open "$a"; then sv="reused (not rechecked)"; else sv="not checked (prompts)"; fi
    elif ssh_ok "$a" "$(auth_pub "$a" "$(auth_method "$a")")"; then
      sv=ok
    elif [[ "$login" == other ]]; then
      sv="!! old key $(basename "$login_key")"
      suggest="$suggest"$'\n'"  set up $a: its $(auth_method "$a") key isn't on the server yet"
    else
      sv="!! refused"
      [[ "$ac" == "!! "* ]] || suggest="$suggest"$'\n'"  set up $a (key not on the server?)"
    fi
    printf '  %-2s %-11s %-26s %-28s %s\n' "$n" "$name" "$ac" "$sc" "$sv"
  done

  repo_facts
  if [[ -n "$r_top" ]]; then
    line="this repo: ${r_acct:-?}"
    if [[ -n "$r_want" && "$r_email" != "$r_want" ]]; then line="$line · !! email $r_email"; else line="$line · email ok"; fi
    case "$r_sig" in
      G | U) line="$line · HEAD signed" ;;
      "") ;;
      *) line="$line · !! HEAD not signed" ;;
    esac
    [[ -z "$r_base" ]] || line="$line · $r_n unsigned since $r_base"
    echo "$line"
    if ((r_n > 0)); then
      suggest="$suggest"$'\n'"  re-sign: git rebase --exec 'git commit --amend --no-edit -S' $r_base"
    fi
  fi
  loose_files
  stale_mac_pubs
  n="$(printf '%s' "$loose$stale" | grep -c . || true)"
  ((n == 0)) || suggest="$suggest"$'\n'"  ssh: $n loose old key files → dot git ssh clean"
  [[ -z "$notes" ]] || printf 'Notes:%s\n' "$notes"
  [[ -z "$suggest" ]] || printf 'Suggested:%s\n' "$suggest"
  return 0
}

test_signing() {
  local acct=$1 m key pub kd age
  m="$(current_method "$acct")"
  if [[ "$m" == none ]]; then
    ok "$acct: not signing"
    return 0
  fi
  key="$(signing_get "$acct" user.signingkey)"
  pub="$(pub_of "$key")"
  kd="$(state_get "$acct" signDays)"
  [[ -n "$kd" ]] || kd="$(signing_get "$acct" dotgit.keyDays)"
  [[ "$kd" != 0 ]] || kd=""
  if [[ ! -f "$pub" ]]; then
    warn "$acct: $m key missing: $pub (dot git renew $acct)"
    return 1
  fi
  if ! method_ok "$acct" "$m"; then
    warn "$acct: $m can't sign here; needs $why"
    return 1
  fi
  age="$(age_days "$pub")"
  if [[ -n "$kd" ]] && ((age >= kd - 3)); then
    warn "$acct signing key $age days old (expires after $kd): dot git renew $acct"
  else
    ok "$acct: $m, $age days old${kd:+ (expires after $kd)}"
  fi
  if [[ "$mac" == true && "$m" == yubikey && "$(signing_get "$acct" dotgit.pin)" != true ]] && ! agent_has "$pub"; then
    echo "    VMs can't sign with it until: ssh-add $key"
  fi
  if [[ "$m" == key ]] && ! agent_has "$pub"; then
    echo "    not in the agent: each commit asks the passphrase$([[ "$mac" == true ]] && echo " (ssh-add --apple-load-keychain)")"
  fi
  return 0
}

# In a repo: the account that applies, its email, and whether HEAD and the branch are signed.
test_repo() {
  repo_facts
  [[ -n "$r_top" ]] || return 0
  printf '\n==> repo %s\n' "$r_top"
  echo "    account ${r_acct:-?}, email ${r_email:-none}, gpg.format $(git config --get gpg.format || echo -)," \
    "commit.gpgsign $(git config --get commit.gpgsign || echo false)"
  if [[ -n "$r_acct" ]]; then
    if [[ -n "$r_want" && "$r_email" != "$r_want" ]]; then
      warn "user.email $r_email is not $r_acct's $r_want (repo override? git config --local --unset user.email)"
    else
      ok "user.email matches $r_acct"
    fi
  fi
  case "$r_sig" in
    "") return 0 ;;
    G) ok "HEAD signed" ;;
    U) ok "HEAD signed (key not in allowed_signers)" ;;
    N) warn "HEAD not signed" ;;
    *) warn "HEAD signature: $r_sig (git log -1 --show-signature)" ;;
  esac
  [[ -n "$r_base" ]] || return 0
  if ((r_n > 0)); then
    warn "$r_n unsigned commits since $r_base"
    echo "    → git rebase --exec 'git commit --amend --no-edit -S' $r_base"
    echo "      git push --force-with-lease"
  else
    ok "no unsigned commits since $r_base"
  fi
}

# `dot git status`: full read-only check.
details() {
  local name failed=""
  test_only=true
  for name in ${1:-$(accounts_here)}; do
    if ! auth_account "$name"; then
      failed="$failed $name"
      test_signing "$name" || true
      continue
    fi
    test_signing "$name" || failed="$failed $name"
  done
  test_repo
  echo
  if [[ -n "$failed" ]]; then
    echo "failed:$failed" >&2
    return 1
  fi
  echo "all accounts ok"
}

# --- ~/.ssh files -------------------------------------------------------------

# Sets loose= to old key files lying in ~/.ssh (from before ~/.ssh/old/, or half-made),
# one path per pair (the private half when both exist).
loose_files() {
  local f b
  loose=""
  for f in "$HOME"/.ssh/*; do
    [[ -f "$f" ]] || continue
    b="${f##*/}"
    case "$b" in
      *.bak-* | *.stray* | *.new | *.new.pub) ;;
      *) continue ;;
    esac
    if [[ "$b" == *.pub && -f "${f%.pub}" ]]; then continue; fi
    loose="$loose$f"$'\n'
  done
}

# Sets stale= to Mac public keys in a VM's ~/.ssh/mac/ that neither the forwarded agent
# nor Secretive holds any more (only with forwarding on: otherwise nothing can be told).
stale_mac_pubs() {
  local f rc=0
  stale=""
  [[ "$mac" != true && -n "${SSH_AUTH_SOCK:-}" ]] || return 0
  ssh-add -l >/dev/null 2>&1 || rc=$?
  [[ "$rc" != 2 ]] || return 0
  for f in "$HOME"/.ssh/mac/*.pub; do
    [[ -f "$f" ]] || continue
    if agent_has "$f"; then continue; fi
    if [[ -S "$SECRETIVE_SOCK" ]] && agent_has "$f" "$SECRETIVE_SOCK"; then continue; fi
    stale="$stale$f"$'\n'
  done
}

# Sets hwfiles= to "account path" lines: key files of hardware-only accounts that now use a
# hardware auth key (offered for cleanup only after a fresh login proves the new key).
hw_file_keys() {
  local a f
  hwfiles=""
  for a in $(accounts_here); do
    hardware_only "$a" || continue
    [[ "$(auth_method "$a")" != key ]] || continue
    f="$(file_key_path "$a")"
    if [[ -f "$f" || -f "$f.pub" ]]; then hwfiles="$hwfiles$a $f"$'\n'; fi
  done
}

old_folders() {
  local d
  for d in "$OLD_DIR"/*/; do
    if [[ -d "$d" ]]; then echo "${d%/}"; fi
  done
}

# What an old file is, from its name.
old_what() {
  case "${1##*/}" in
    *.new | *.new.pub) echo "half-made key (cancelled renew)" ;;
    *.stray*) echo "not made by dot git" ;;
    git-auth-*) echo "replaced auth key" ;;
    git-signing-*) echo "replaced signing key" ;;
    id_*) echo "old auth key file" ;;
    *) echo "old key" ;;
  esac
}

pair_label() {
  local b="${1##*/}"
  if [[ "$b" != *.pub && -f "$1.pub" ]]; then b="$b (+.pub)"; fi
  echo "$b"
}

# Fingerprint lines of the public keys among the given files / folders (before deleting).
fingerprints() {
  local x f
  for x in "$@"; do
    for f in "$x" "$x.pub" "$x"/*.pub; do
      [[ "$f" == *.pub && -f "$f" ]] || continue
      ssh-keygen -lf "$f" 2>/dev/null | awk '{print "  " $2 "  " $3}'
    done
  done | sort -u
}

ssh_list() {
  local a am pub m sk d n
  loose_files
  stale_mac_pubs
  hw_file_keys
  echo "In use"
  for a in $(accounts_here); do
    am="$(auth_method "$a")"
    pub="$(auth_pub "$a" "$am")"
    printf '  %-11s auth     %-34s %s\n' "$a$(hardware_only "$a" && echo " [hw]")" "${pub##*/}" "$am$([[ -f "$pub" ]] && echo ", $(age_days "$pub") days")"
    m="$(current_method "$a")"
    if [[ "$m" != none ]]; then
      sk="$(pub_of "$(signing_get "$a" user.signingkey)")"
      printf '  %-11s signing  %-34s %s\n' "" "${sk##*/}" "$m$([[ -f "$sk" ]] && echo ", $(age_days "$sk") days")"
    fi
  done
  if [[ -n "$(old_folders)" ]]; then
    echo "Old (in ${OLD_DIR/#$HOME/~}/)"
    for d in $(old_folders); do
      n="$(find "$d" -type f ! -name reason | wc -l | tr -d ' ')"
      printf '  %-44s %2s files  %3s days\n' "${d##*/}" "$n" "$(age_days "$d")"
    done
  fi
  if [[ -n "$loose$hwfiles$stale" ]]; then
    echo "Loose"
    while IFS= read -r a; do
      [[ -n "$a" ]] && printf '  %-44s %s\n' "$(pair_label "$a")" "$(old_what "$a")"
    done <<<"$loose"
    while read -r a d; do
      [[ -n "$a" ]] && printf '  %-44s %s\n' "$(pair_label "$d")" "$a's old file key ($a now uses $(auth_method "$a"))"
    done <<<"$hwfiles"
    while IFS= read -r a; do
      [[ -n "$a" ]] && printf '  %-44s %s\n' "mac/${a##*/}" "the Mac no longer has this key"
    done <<<"$stale"
  fi
  return 0
}

# Moves loose files, proven old file keys and stale Mac copies into ~/.ssh/old/.
ssh_tidy() {
  local f a
  while IFS= read -r f; do [[ -z "$f" ]] || retire "$f" tidy; done <<<"$loose"
  while IFS= read -r f; do [[ -z "$f" ]] || retire "$f" tidy; done <<<"$stale"
  while read -r a f; do
    [[ -n "$a" ]] || continue
    if ssh_ok "$a" "$(auth_pub "$a" "$(auth_method "$a")")"; then
      retire "$f" "tidy $a file key"
    else
      warn "kept ${f##*/}: $a's $(auth_method "$a") key didn't log in (dot git setup $a)"
    fi
  done <<<"$hwfiles"
  [[ -n "$old_event" ]] && ok "moved to ${old_event/#$HOME/~}/" || ok "nothing loose"
}

# Deletes the given paths (old folders under ~/.ssh/old/, or loose key pairs) after a
# [y/N]; prints their fingerprints first, to remove them on the servers too.
ssh_delete() {
  local x prints a
  [[ $# -gt 0 ]] || { echo "nothing to delete"; return 0; }
  echo "Delete:"
  for x in "$@"; do echo "  ${x/#$HOME/~}"; done
  confirm "Delete these for good?" no || return 1
  prints="$(fingerprints "$@")"
  for x in "$@"; do
    if [[ -d "$x" && "$x" == "$OLD_DIR"/?* ]]; then
      rm -rf -- "$x"
    elif [[ -f "$x" || -f "$x.pub" ]]; then
      rm -f -- "$x" "$x.pub"
    fi
  done
  ok "deleted"
  if [[ -n "$prints" ]]; then
    echo "Also remove these keys where they were added (dot git can't):"
    echo "$prints"
    for a in $(accounts_here); do echo "  $(key_page "$(account_host "$a")")"; done | sort -u
    [[ "$mac" != true ]] || echo "  Secretive: secrets with these fingerprints"
  fi
}

ssh_clean() {
  local ans days d i list="" sel=""
  ssh_list
  echo
  echo "  1) tidy      move the loose files into ${OLD_DIR/#$HOME/~}/<now>-tidy/ (nothing deleted)"
  echo "  2) delete    old folders older than … days"
  echo "  3) pick      choose folders / files by number"
  echo "  q) quit"
  while :; do
    read -r -p "? Choose 1-3: " ans </dev/tty || return 0
    case "$ans" in
      1) ssh_tidy; return ;;
      2)
        read -r -p "? Older than how many days (Enter = 30): " days </dev/tty || return 0
        [[ "$days" =~ ^[0-9]+$ ]] || days=30
        set --
        for d in $(old_folders); do
          if (($(age_days "$d") >= days)); then set -- "$@" "$d"; fi
        done
        ssh_delete "$@"
        return
        ;;
      3)
        i=0
        for d in $(old_folders); do i=$((i + 1)); list="$list$d"$'\n'; printf '  %2d  %s/\n' "$i" "${d##*/}"; done
        while IFS= read -r d; do
          [[ -n "$d" ]] || continue
          i=$((i + 1)); list="$list$d"$'\n'; printf '  %2d  %s\n' "$i" "$(pair_label "$d")"
        done <<<"$loose$stale"
        [[ "$i" -gt 0 ]] || { echo "nothing old"; return 0; }
        read -r -p "? Numbers (e.g. 1 3): " ans </dev/tty || return 0
        set --
        for d in $ans; do
          [[ "$d" =~ ^[0-9]+$ ]] && ((d >= 1 && d <= i)) && set -- "$@" "$(sed -n "${d}p" <<<"$list")"
        done
        [[ $# -gt 0 ]] || return 0
        read -r -p "? 1) move to ${OLD_DIR/#$HOME/~}/  2) delete: " ans </dev/tty || return 0
        if [[ "$ans" == 2 ]]; then
          ssh_delete "$@"
        else
          for d in "$@"; do [[ "$d" == "$OLD_DIR"/* ]] || retire "$d" picked; done
          ok "done"
        fi
        return
        ;;
      q) return 0 ;;
    esac
  done
}

close_connections() {
  local a
  for a in $(reuse_accounts); do close_master "$a"; done
  ok "no reused connections left (the next push asks again)"
}

menu() {
  local a reuse files max=4
  reuse="$(reuse_accounts)"
  loose_files
  files="$loose$(old_folders)"
  status_table
  echo
  echo "  1) set up an account   auth key, upload, test; then signing"
  echo "  2) change signing      method for an account"
  echo "  3) renew               new auth and/or signing key"
  echo "  4) details             full read-only check"
  if [[ -n "$reuse" ]]; then
    echo "  5) close connections   end reused ssh connections (next push asks again)"
    max=5
  fi
  if [[ -n "$files" ]]; then
    echo "  6) ssh files           old and loose keys in ~/.ssh: list, tidy, delete"
    max=6
  fi
  echo "  q) quit"
  while :; do
    read -r -p "? Choose 1-$max: " a </dev/tty || return 0
    case "$a" in
      1) pick_account || return 0; setup_account "$acct"; return ;;
      2) pick_account || return 0; method=""; sign_account "$acct"; return ;;
      3) pick_account || return 0; renew_account "$acct"; return ;;
      4) details; return ;;
      5) [[ -n "$reuse" ]] || continue; close_connections; return ;;
      6) [[ -n "$files" ]] || continue; ssh_clean; return ;;
      q) return 0 ;;
    esac
  done
}

# --- main ------------------------------------------------------------------

set -- $args
case "$cmd" in
  menu) menu ;;
  ssh)
    case "${1:-}" in
      "") ssh_list ;;
      clean) ssh_clean ;;
      *) echo "usage: dot git ssh [clean]" >&2; exit 2 ;;
    esac
    ;;
  status) details "${*:-}" ;;
  setup)
    if [[ $# -eq 0 ]]; then pick_account || exit 0; set -- "$acct"; fi
    failed=""
    for a in "$@"; do setup_account "$a" || failed="$failed $a"; done
    echo
    if [[ -n "$failed" ]]; then echo "failed:$failed" >&2; exit 1; fi
    echo "all accounts ok"
    ;;
  renew)
    if [[ $# -eq 0 ]]; then pick_account || exit 0; set -- "$acct"; fi
    for a in "$@"; do renew_account "$a"; done
    ;;
  sign)
    if [[ $# -eq 0 ]]; then pick_account || exit 0; set -- "$acct"; fi
    method="${2:-}"
    if [[ "$method" =~ ^[1-4]$ ]]; then method="$(awk -v i="$method" '{print $i}' <<<"$METHODS")"; fi
    if [[ -n "$method" && " $METHODS " != *" $method "* ]]; then
      echo "unknown method: $method (1-4 or: $METHODS)" >&2
      exit 2
    fi
    if [[ "$new" == true && -z "$method" ]]; then
      renew_what=sign
      renew_account "$1"
    else
      sign_new="$new"
      sign_account "$1"
    fi
    ;;
esac
