#!/usr/bin/env bash
# Optional (not run by install.sh): SSH keys and commit signing for multiple git accounts.
#
# Usage: dot git                      status of every account, then a menu
#        dot git status               full read-only check (keys, signing, this repo)
#        dot git setup [account...]   auth key: make, upload, test; then signing
#        dot git renew [account]      new key: 1) auth  2) signing  3) both
#        dot git sign [account] [1-4|secretive|yubikey|key|none]
#   account  github | gitlab | work (Linux: github work); omitted = asked
#   Every choice is a numbered menu. Key expiry days are asked once per account.
#
# Auth (setup), per account; it prints the plan first:
#   1. auth key: Linux uses the Mac key from a forwarded agent (~/.ssh/mac/<key>.pub),
#      else this machine's key (missing: generate; Mac: ssh-add --apple-use-keychain)
#   2. server: ssh -T git@<alias>; refused -> copy the public key (Mac: pbcopy + open the
#      key page; Linux: OSC 52 + print it), wait for you to add it, retest
#   3. signing: numbered menu, Enter keeps the current method
#
# Signing, local to this machine (never in the dotfiles):
#   ~/.config/git/signing-<account>   included by gitconfig-<account>; missing = unsigned
#   ~/.ssh/git-signing-<account>-<method>[.pub]   one key per account per method
#   ~/.ssh/allowed_signers            every signing key used here (git log, verify)
#   ~/.config/git/dotgit              remembered expiry days per account
#   secretive  Secure Enclave key in the Secretive app (Mac; VM: forwarded socket)
#   yubikey    ed25519-sk key (Mac; VM: forwarded agent)
#   key        ed25519 file with a passphrase
# A VM only uses the Mac's keys: making or renewing them happens on the Mac.
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
ALLOWED="$HOME/.ssh/allowed_signers"
STATE="$HOME/.config/git/dotgit"
WRAPPER="$HOME/.ssh/ssh-keygen-sign" # chezmoi-managed: ssh-keygen against Secretive's agent
if [[ "$mac" == true ]]; then
  SECRETIVE_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
else
  SECRETIVE_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/secretive.sock" # vm up --agent
fi

usage() { sed -n '4,10p' "$0"; }

# cmd: menu | status | setup | renew | sign. Flags are the old shortcuts.
cmd=menu new=false pin=false days="" args="" method=""
case "${1:-}" in
  "") ;;
  status | setup | renew | sign) cmd="$1"; shift ;;
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
sign_new=false test_only=false planned=false
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

# Exit status of ssh -T differs per provider (GitHub: 1); match the greeting instead.
ssh_ok() {
  local out
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "git@$1" 2>&1 </dev/null || true)"
  grep -qE 'successfully authenticated|Welcome to GitLab' <<<"$out"
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

# Move a key pair aside: <key> -> <key>.bak-<stamp>, <key>.pub -> <key>.bak-<stamp>.pub.
retire() {
  local s
  s="$(date +%Y%m%d-%H%M%S)"
  if [[ -f "$1" ]]; then mv "$1" "$1.bak-$s"; fi
  if [[ -f "$1.pub" ]]; then
    mv "$1.pub" "$1.bak-$s.pub"
    if [[ "$mac" == true ]]; then ssh-add -d "$1.bak-$s.pub" >/dev/null 2>&1 || true; fi
    echo "old key kept as $1.bak-$s"
  fi
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

auth_key_path() {
  local k
  k="$(ssh_opt "$1" identityfile)"
  echo "${k/#\~/$HOME}" # ssh -G prints IdentityFile unexpanded
}

# Remembered expiry days: account.<account>.authDays / signDays in ~/.config/git/dotgit.
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

# Numbered menu step header: step <n> <total> <title>.
step() { printf '\n[%s/%s] %s\n' "$1" "$2" "$3"; }

# Sets acct= from a numbered list of this machine's accounts (q or end of input = back).
pick_account() {
  local list ans n=0 a
  list="$(accounts_here | tr '\n' ' ')"
  echo "Account?"
  for a in $list; do
    n=$((n + 1))
    printf '  %d) %s\n' "$n" "$a"
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

# Sets why= to what <method> ($2) needs to sign for <account> ($1) here; true if nothing.
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
  esac
  [[ -z "$why" ]]
}

# Menu line for method $2 of account $1 (host $3).
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
        echo "plain key file with a passphrase"
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
  echo "Sign commits for $1? (now: $cur)"
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

# Secretive: the user makes the key in the app; its public key is read from the
# clipboard into $1 (account $2). The clipboard is never printed.
new_secretive() {
  local tmp fp loaded name="git-signing-$2"
  [[ "$sign_new" == true ]] && name="$name-$(date +%Y%m%d)"
  echo "In Secretive: + new secret \"$name\", Notify (or Require Authentication),"
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

# Make the key for method $2 of account $1 at $3 (email $4).
new_key() {
  local comment="${4:-$1} git-sign ($(hostname))"
  mkdir -p -m 700 "$HOME/.ssh"
  case "$2" in
    secretive) new_secretive "$3.pub" "$1" ;;
    yubikey)
      echo "Touch the YubiKey when it blinks."
      if [[ "$pin" == true ]]; then
        ssh-keygen -t ed25519-sk -O application="ssh:git-sign-$1" -O verify-required -C "$comment" -f "$3" -N '' || return 1
      else
        ssh-keygen -t ed25519-sk -O application="ssh:git-sign-$1" -C "$comment" -f "$3" -N '' || return 1
        # a touch-only key in the agent can sign from a VM through forwarding
        ssh-add "$3" || echo "note: not in the agent; VMs can't sign with it (ssh-add $3)"
      fi
      ;;
    key)
      ssh-keygen -t ed25519 -C "$comment" -f "$3" || return 1
      if [[ "$mac" == true ]]; then ssh-add --apple-use-keychain "$3" || return 1; fi
      ;;
  esac
}

# Switch account $1 to method= (asked when empty) using an existing key, or create +
# upload one (also when sign_new); then write signing-<account>.
sign_account() {
  local acct=$1 host email cur own key pub p stale create=false
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
    if [[ "$method" == yubikey && "$pin" != true ]] &&
      confirm "Also require the YubiKey PIN? (then terminal only, no VM use)" no; then
      pin=true p=true
    fi
    expiry_days "$acct" signDays "Signing" || return 1
    echo "New signing key for $acct ($method):"
    echo "  a. key      $(made_text "$method")$([[ "$sign_new" == true ]] && echo "; old key kept as .bak-<date>")"
    echo "  b. test     sign + verify a test message (notification / touch / passphrase)"
    echo "  c. upload   $(key_page "$host") ($(page_hint "$host" signing "$kd"))"
    echo "-- a. key"
    [[ "$sign_new" == true ]] && retire "$own"
    new_key "$acct" "$method" "$own" "$email" || return 1
    allow_signer "$email" "$pub"
    echo "-- b. test"
    test_sign "$email" "$key" "$method" || { echo "error: test signature failed; signing-$acct unchanged" >&2; return 1; }
    ok "test signature verified"
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

# --- auth ------------------------------------------------------------------

# A VM without a usable Mac key: wait for forwarding (false), or make a VM-only key (true).
vm_key_choice() {
  local a
  if [[ -f "$2" && -n "${SSH_AUTH_SOCK:-}" ]]; then
    warn "the Mac's key changed: the forwarded agent doesn't hold ~/.ssh/mac/$(basename "$2")"
  else
    echo "no key for $1 here, and the Mac's isn't forwarded"
  fi
  echo "  1) use the Mac's key: on the Mac run  vm agent <this vm> on  (then dot git again)"
  echo "  2) make a VM-only key (uploaded once; vm restore wipes it)"
  while :; do
    read -r -p "? Choose 1-2: " a </dev/tty || return 1
    case "$a" in
      1) echo "skipped $1: on the Mac run  vm agent <this vm> on,  then  dot git setup $1"; return 1 ;;
      2) return 0 ;;
    esac
  done
}

# Auth key for account $1: plan (unless planned/test), key, ssh -T, upload when refused.
auth_account() {
  local name=$1 host key email action mp ad
  host="$(ssh_opt "$name" hostname)"
  key="$(auth_key_path "$name")"
  email="$(account_email "$name")"
  mp="$HOME/.ssh/mac/$(basename "$key").pub"
  printf '\n==> %s (%s, %s, %s)\n' "$name" "$host" "$key" "${email:-no email}"

  if [[ "$host" == "$name" ]]; then
    echo "error: no 'Host $name' in ~/.ssh/config (run chezmoi apply)" >&2
    return 1
  fi

  if [[ "$test_only" != true && "$planned" != true ]]; then
    if [[ "$mac" != true ]] && agent_has "$mp"; then
      action="the Mac's key through the forwarded agent"
    elif [[ -f "$key" ]]; then
      action="existing $(basename "$key")$([[ "$mac" == true ]] && echo ", added to the agent")"
    elif [[ "$mac" == true ]]; then
      action="missing: generate one (asks)"
    else
      action="missing: use the Mac's (forwarding) or make a VM-only key (asks)"
    fi
    echo "Plan:"
    echo "  1. auth key   $action"
    echo "  2. server     ssh -T git@$name; refused → copy key, open $(key_page "$host")"
    echo "                ($(page_hint "$host" auth "$(state_get "$name" authDays)")), wait, retest"
    echo "  3. signing    choose 1-4 (now: $(current_method "$name"))"
    step 1 3 "auth key"
  fi

  [[ "$new" == true ]] && retire "$key"
  if [[ "$mac" != true && "$new" != true ]] && agent_has "$mp"; then
    echo "using the Mac key from the forwarded agent"
  elif [[ ! -f "$key" ]]; then
    if [[ "$new" != true ]]; then
      if [[ "$test_only" == true ]]; then
        echo "missing key $key"
        return 1
      elif [[ "$mac" == true ]]; then
        echo "missing key $key"
        confirm "Generate a new key?" || return 1
      else
        vm_key_choice "$name" "$mp" || return 1
      fi
    fi
    expiry_days "$name" authDays "Auth" || return 1
    mkdir -p -m 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "${email:-$name} ($(hostname))" -f "$key" || return 1
  fi

  if [[ "$test_only" != true && "$mac" == true && -f "$key" ]]; then
    [[ -n "${SSH_AUTH_SOCK:-}" ]] || eval "$(ssh-agent -s)" >/dev/null
    ssh-add --apple-use-keychain "$key" || return 1
  fi

  [[ "$test_only" == true || "$planned" == true ]] || step 2 3 "server: ssh -T git@$name"
  if ssh_ok "$name"; then
    ok "ssh git@$name$([[ -f "$key.pub" ]] && echo " (key $(age_days "$key.pub") days old)")"
    return 0
  fi
  echo "failed: ssh git@$name (key not on the server?)"
  [[ "$test_only" != true && -f "$key.pub" ]] || return 1

  ad="$(state_get "$name" authDays)"
  offer_pub "$key.pub" "$host" "$(page_hint "$host" auth "$ad")"
  read -r -p "Press Enter after adding the key to retest... " _ </dev/tty || return 1
  if ssh_ok "$name"; then
    ok "ssh git@$name"
  else
    echo "still failing: ssh -T git@$name"
    return 1
  fi
}

# setup: auth key (steps 1-2), then signing (step 3).
setup_account() {
  planned=false new=false
  auth_account "$1" || return 1
  step 3 3 "signing"
  method=""
  sign_account "$1"
}

# --- renew -----------------------------------------------------------------

renew_account() {
  local acct=$1 host key cur what ans ad sd n=0 mac_auth=false mac_sign=false auth_ok=true sign_ok=true
  host="$(account_host "$acct")" || { echo "error: no 'Host $acct' in ~/.ssh/config (run chezmoi apply)" >&2; return 1; }
  key="$(auth_key_path "$acct")"
  cur="$(current_method "$acct")"

  # A VM only uses the Mac's keys; those are renewed on the Mac.
  if [[ "$mac" != true ]]; then
    [[ -f "$key" ]] || mac_auth=true
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
      echo "  1) auth key      $(basename "$key")"
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
    echo "  $n. auth key     new $(basename "$key") (old → .bak-<date>) → page: $(page_hint "$host" auth "$ad")"
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
  echo "  $n. cleanup      reminder: delete the old keys at $(key_page "$host")"
  confirm "Continue? (moves the current key aside)" no || return 1

  planned=true
  if [[ "$what" != sign ]]; then
    new=true days="$ad"
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
  echo "  delete the old keys at $(key_page "$host")"
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
  local key mp
  key="$(auth_key_path "$1")"
  mp="$HOME/.ssh/mac/$(basename "$key").pub"
  hot=false
  if [[ "$mac" != true ]] && agent_has "$mp"; then
    cell="Mac's key"
  elif [[ -f "$key.pub" ]]; then
    days_cell "$(age_days "$key.pub")" "$(state_get "$1" authDays)"
  elif [[ "$mac" != true && -f "$mp" ]]; then
    hot=true
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then cell="Mac key changed"; else cell="Mac key not forwarded"; fi
  else
    hot=true cell="no key"
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

# `dot git`: one row per account, this repo, and suggestions (no action is preselected).
status_table() {
  local a n=0 ac sc sv rc=0 fw sock line suggest="" notes=""
  if [[ "$mac" == true ]]; then
    echo "git accounts (Mac)"
  else
    ssh-add -l >/dev/null 2>&1 || rc=$?
    if [[ -n "${SSH_AUTH_SOCK:-}" && "$rc" != 2 ]]; then fw="Mac keys forwarded"; else fw="Mac keys not forwarded"; fi
    if [[ -S "$SECRETIVE_SOCK" ]]; then sock="Secretive socket ok"; else sock="no Secretive socket"; fi
    echo "git accounts ($(hostname) · $fw · $sock)"
  fi
  printf '  %-2s %-8s %-26s %-30s %s\n' "#" account "auth key" signing server
  for a in $(accounts_here); do
    n=$((n + 1))
    auth_status "$a"
    ac="$cell"
    if [[ "$hot" == true ]]; then
      ac="!! $ac"
      case "$cell" in
        "Mac key"*) suggest="$suggest"$'\n'"  on the Mac: vm agent <this vm> on   ($a: $cell)" ;;
        "no key") suggest="$suggest"$'\n'"  set up $a" ;;
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
    if ssh_ok "$a"; then
      sv=ok
    else
      sv="!! refused"
      [[ "$ac" == "!! "* ]] || suggest="$suggest"$'\n'"  set up $a (key not on the server?)"
    fi
    printf '  %-2s %-8s %-26s %-30s %s\n' "$n" "$a" "$ac" "$sc" "$sv"
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

menu() {
  local a
  status_table
  echo
  echo "  1) set up an account   key, upload, test; then signing"
  echo "  2) change signing      method for an account"
  echo "  3) renew               new auth and/or signing key"
  echo "  4) details             full read-only check"
  echo "  q) quit"
  while :; do
    read -r -p "? Choose 1-4: " a </dev/tty || return 0
    case "$a" in
      1) pick_account || return 0; setup_account "$acct"; return ;;
      2) pick_account || return 0; method=""; sign_account "$acct"; return ;;
      3) pick_account || return 0; renew_account "$acct"; return ;;
      4) details; return ;;
      q) return 0 ;;
    esac
  done
}

# --- main ------------------------------------------------------------------

set -- $args
case "$cmd" in
  menu) menu ;;
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
