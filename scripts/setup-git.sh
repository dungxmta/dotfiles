#!/usr/bin/env bash
# Optional (not run by install.sh): SSH keys and commit signing for multiple git accounts.
#
# Usage: setup-git.sh [account...] [--new] [--test]
#        setup-git.sh sign <account> [secretive|yubikey|key|none] [--new] [--pin] [--days N]
#   account   github | gitlab | work   (default: all; Linux: github work)
#   --new     auth: a new key (old pair -> <key>.bak-<date>); sign: a new key for the method
#   --test    read-only: ssh, signing method + key age, and in a repo: email + signed commits
#   sign      how <account> signs commits; no method = menu, none = stop signing
#   --pin     yubikey: also require the PIN (terminal only, not usable from a VM)
#   --days N  key expiry set on the server; --test warns 3 days before
#
# Auth, per account:
#   1. Linux: a forwarded agent holding the Mac key (~/.ssh/mac/<key>.pub) is enough
#   2. key missing (or --new) -> generate one (asks unless --new)
#   3. Mac: ssh-add --apple-use-keychain <key>
#   4. ssh -T git@<alias>; on failure copy the public key (Mac: pbcopy + open the
#      key page; Linux: OSC 52 + print it), wait for you to add it, retest
#   5. signing: numbered menu, Enter keeps the current method
# Before doing anything it prints the plan (steps 1-3); --new asks to continue.
#
# Signing, local to this machine (never in the dotfiles):
#   ~/.config/git/signing-<account>   included by gitconfig-<account>; missing = unsigned
#   ~/.ssh/git-signing-<account>-<method>[.pub]   one key per account per method
#   ~/.ssh/allowed_signers            every signing key used here (git log, verify)
#   secretive  Secure Enclave key in the Secretive app (Mac; VM: forwarded socket)
#   yubikey    ed25519-sk key (Mac; VM: forwarded agent)
#   key        ed25519 file with a passphrase
# Switching to a method whose key exists only rewrites signing-<account>.
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
WRAPPER="$HOME/.ssh/ssh-keygen-sign" # chezmoi-managed: ssh-keygen against Secretive's agent
if [[ "$mac" == true ]]; then
  SECRETIVE_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
else
  SECRETIVE_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/secretive.sock" # vm up --agent
fi

usage() { sed -n '4,11p' "$0"; }

cmd=auth test_only=false new=false pin=false days="" accounts="" sign_acct="" method=""
[[ "${1:-}" == sign ]] && { cmd=sign; shift; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test) test_only=true ;;
    --new) new=true ;;
    --pin) pin=true ;;
    --days) days="${2:-}"; shift ;;
    --days=*) days="${1#--days=}" ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ "$cmd" == auth ]]; then
        accounts="$accounts $1"
      elif [[ -z "$sign_acct" ]]; then
        sign_acct="$1"
      elif [[ -z "$method" ]]; then
        method="$1"
      else
        echo "too many arguments" >&2; usage >&2; exit 2
      fi
      ;;
  esac
  shift
done
accounts="${accounts:-$ALL_ACCOUNTS}"
if [[ -n "$days" && ! "$days" =~ ^[0-9]+$ ]]; then
  echo "--days needs a number of days" >&2
  exit 2
fi
if [[ "$cmd" == sign ]]; then
  [[ -n "$sign_acct" ]] || { echo "usage: setup-git.sh sign <account> [method]" >&2; exit 2; }
  if [[ -n "$method" && " $METHODS " != *" $method "* ]]; then
    echo "unknown method: $method ($METHODS)" >&2
    exit 2
  fi
fi
if [[ "$test_only" == true && ("$new" == true || "$cmd" == sign) ]]; then
  echo "--test changes nothing; use it alone" >&2
  exit 2
fi
# --new renews the auth key in `dot git <account> --new`, the signing key in `dot git sign`.
sign_new=false
[[ "$cmd" == sign ]] && sign_new="$new"

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

# What to pick on the key page: $1 host, $2 auth|signing, $3 expiry days (optional).
page_hint() {
  local hint
  if [[ "$1" == "github.com" ]]; then
    [[ "$2" == auth ]] && hint="Key type: Authentication Key" || hint="Key type: Signing Key"
  else
    [[ "$2" == auth ]] && hint="Usage type: Authentication" || hint="Usage type: Signing"
    [[ -n "${3:-}" ]] && hint="$hint, expiration no later than $(date_plus "$3")"
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
        why="a Secretive key for $1 on the Mac, then vm agent <this vm> on"
      fi
      ;;
    yubikey)
      if [[ "$mac" == true ]]; then
        types="$(ssh -Q key 2>/dev/null || true)"
        grep -q '^sk-ssh-ed25519@' <<<"$types" || why="an ssh with security key support"
      elif ! agent_has "$(mac_pub "$1" yubikey)"; then
        why="a YubiKey key for $1 on the Mac (no --pin), then vm agent <this vm> on"
      fi
      ;;
  esac
  [[ -z "$why" ]]
}

# Menu line for method $2 of account $1 (host $3).
method_label() {
  case "$2" in
    secretive) echo "Secure Enclave key in Secretive (notification per commit)" ;;
    yubikey) echo "YubiKey, touch per commit" ;;
    key)
      if [[ -n "$3" && "$3" == "$(account_host work)" ]]; then
        echo "plain key file (note: some hosts' policies accept only hardware keys)"
      else
        echo "plain key file with a passphrase"
      fi
      ;;
    none) echo "don't sign" ;;
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
    read -r -p "? Choose 1-$n (Enter = keep $cur): " answer </dev/tty
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
    if [[ -n "$4" ]]; then printf '\tkeyDays = %s\n' "$4"; fi
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
  read -r -p "Press Enter when the public key is on the clipboard... " _ </dev/tty
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

# dot git sign <account> [method]: switch to an existing key, or create + upload one;
# then write signing-<account>.
sign_account() {
  local acct=$1 host email cur own key pub kd p made create=false
  host="$(account_host "$acct")" || { echo "error: no 'Host $acct' in ~/.ssh/config (run chezmoi apply)" >&2; return 1; }
  email="$(account_email "$acct")"
  cur="$(current_method "$acct")"
  if [[ -z "$method" && "$sign_new" == true && "$cur" != none ]]; then
    method="$cur" # renew the active method
  fi
  [[ -n "$method" ]] || choose_method "$acct" "$host"
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
  if [[ "$sign_new" == true || ! -f "$pub" ]]; then
    if [[ "$mac" != true && "$method" != key ]]; then
      echo "error: make $method keys on the Mac (dot git sign $acct $method), then vm agent <this vm> on" >&2
      return 1
    fi
    create=true
    key="$own"
    [[ "$method" == secretive ]] && key="$own.pub"
    pub="$own.pub"
  fi

  kd="$days" p="$pin"
  if [[ "$create" == true ]]; then
    if [[ -z "$kd" ]]; then
      read -r -p "? Key expiry on the server, days (Enter = none): " kd </dev/tty || return 1
      [[ -z "$kd" || "$kd" =~ ^[0-9]+$ ]] || { echo "error: not a number: $kd" >&2; return 1; }
    fi
    case "$method" in
      secretive) made="in the Secretive app: + new secret, Copy Public Key (read from the clipboard)" ;;
      yubikey) made="ssh-keygen ed25519-sk on the YubiKey (touch$([[ "$pin" == true ]] && echo " + PIN"))" ;;
      key) made="ssh-keygen ed25519 (passphrase)" ;;
    esac
    [[ "$sign_new" == true ]] && made="$made; old key kept as .bak-<date>"
    echo "New $method signing key for $acct:"
    echo "  a. key      $made"
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
    read -r -p "Press Enter after adding it... " _ </dev/tty
  else
    if [[ "$method" == "$cur" ]]; then
      [[ -n "$kd" ]] || kd="$(signing_get "$acct" dotgit.keyDays)"
      [[ "$(signing_get "$acct" dotgit.pin)" == true ]] && p=true
    fi
    allow_signer "$email" "$pub"
    ok "using existing $(basename "$pub") ($(age_days "$pub") days old)"
  fi
  write_signing "$acct" "$method" "$key" "$kd" "$p"
  ok "$acct signs with $method"
}

# --- --test ----------------------------------------------------------------

test_signing() {
  local acct=$1 m key pub kd age
  m="$(current_method "$acct")"
  if [[ "$m" == none ]]; then
    ok "$acct: not signing"
    return 0
  fi
  key="$(signing_get "$acct" user.signingkey)"
  pub="$(pub_of "$key")"
  kd="$(signing_get "$acct" dotgit.keyDays)"
  if [[ ! -f "$pub" ]]; then
    warn "$acct: $m key missing: $pub (dot git sign $acct $m --new)"
    return 1
  fi
  if ! method_ok "$acct" "$m"; then
    warn "$acct: $m can't sign here; needs $why"
    return 1
  fi
  age="$(age_days "$pub")"
  if [[ -n "$kd" ]] && ((age >= kd - 3)); then
    warn "$acct signing key $age days old (keyDays $kd): dot git sign $acct --new"
  else
    ok "$acct: $m, $age days old${kd:+ (keyDays $kd)}"
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
  local top origin acct email want sig base b n
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  printf '\n==> repo %s\n' "$top"
  origin="$(git config --show-origin --get dotgit.method 2>/dev/null ||
    git config --show-origin --get user.email 2>/dev/null || true)"
  acct="$(sed -E -n 's#^file:.*/(signing|gitconfig)-([^/[:space:]]+)[[:space:]].*#\2#p' <<<"$origin")"
  email="$(git config --get user.email || true)"
  echo "    account ${acct:-?}, email ${email:-none}, gpg.format $(git config --get gpg.format || echo -)," \
    "commit.gpgsign $(git config --get commit.gpgsign || echo false)"
  if [[ -n "$acct" ]]; then
    want="$(account_email "$acct")"
    if [[ -n "$want" && "$email" != "$want" ]]; then
      warn "user.email $email is not $acct's $want (repo override? git config --local --unset user.email)"
    else
      ok "user.email matches $acct"
    fi
  fi
  git rev-parse -q --verify HEAD >/dev/null || return 0
  sig="$(git log -1 --no-show-signature --format=%G? HEAD)"
  case "$sig" in
    G) ok "HEAD signed" ;;
    U) ok "HEAD signed (key not in allowed_signers)" ;;
    N) warn "HEAD not signed" ;;
    *) warn "HEAD signature: $sig (git log -1 --show-signature)" ;;
  esac
  base=""
  for b in origin/HEAD origin/main origin/master; do
    if git rev-parse -q --verify "$b" >/dev/null; then
      base="$(git rev-parse --abbrev-ref "$b")"
      break
    fi
  done
  [[ -n "$base" ]] || return 0
  n="$(git log --no-show-signature --format=%G? "$base..HEAD" | grep -c '^N$' || true)"
  if ((n > 0)); then
    warn "$n unsigned commits since $base"
    echo "    → git rebase --exec 'git commit --amend --no-edit -S' $base"
    echo "      git push --force-with-lease"
  else
    ok "no unsigned commits since $base"
  fi
}

# --- auth ------------------------------------------------------------------

step() { printf '\n[%s/3] %s\n' "$1" "$2"; }

auth_account() {
  local name=$1 host key email action
  host="$(ssh_opt "$name" hostname)"
  key="$(ssh_opt "$name" identityfile)"
  email="$(account_email "$name")"
  key="${key/#\~/$HOME}" # ssh -G prints IdentityFile unexpanded
  printf '\n==> %s (%s, %s, %s)\n' "$name" "$host" "$key" "${email:-no email}"

  if [[ "$host" == "$name" ]]; then
    echo "error: no 'Host $name' in ~/.ssh/config (run chezmoi apply)" >&2
    return 1
  fi

  if [[ "$test_only" != true ]]; then
    if [[ "$new" == true ]]; then
      action="new key ($(basename "$key").bak-<date> keeps the old pair)"
    elif [[ "$mac" != true ]] && agent_has "$HOME/.ssh/mac/$(basename "$key").pub"; then
      action="the Mac's key through the forwarded agent"
    elif [[ -f "$key" ]]; then
      action="existing $(basename "$key")$([[ "$mac" == true ]] && echo ", added to the agent")"
    else
      action="missing: generate one (asks)"
    fi
    echo "Plan:"
    echo "  1. auth key   $action"
    echo "  2. server     ssh -T git@$name; refused → copy key, open $(key_page "$host")"
    echo "                ($(page_hint "$host" auth)), wait, retest"
    echo "  3. signing    choose 1-4 (now: $(current_method "$name"))"
    if [[ "$new" == true ]] && ! confirm "Continue? (moves the current key aside)" no; then
      return 1
    fi
    step 1 "auth key"
  fi

  [[ "$new" == true ]] && retire "$key"
  if [[ "$mac" != true && "$new" != true ]] && agent_has "$HOME/.ssh/mac/$(basename "$key").pub"; then
    echo "using the Mac key from the forwarded agent"
  elif [[ ! -f "$key" ]]; then
    if [[ "$new" != true ]]; then
      echo "missing key $key"
      [[ "$mac" != true && -n "${SSH_AUTH_SOCK:-}" ]] &&
        echo "  agent forwarded: on the Mac run 'vm agent <this vm> on' to send the Mac's public key"
      if [[ "$test_only" == true ]] || ! confirm "Generate a new key?"; then
        return 1
      fi
    fi
    mkdir -p -m 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "${email:-$name} ($(hostname))" -f "$key" || return 1
  fi

  if [[ "$test_only" != true && "$mac" == true && -f "$key" ]]; then
    [[ -n "${SSH_AUTH_SOCK:-}" ]] || eval "$(ssh-agent -s)" >/dev/null
    ssh-add --apple-use-keychain "$key" || return 1
  fi

  [[ "$test_only" == true ]] || step 2 "server: ssh -T git@$name"
  if ssh_ok "$name"; then
    ok "ssh git@$name$([[ -f "$key.pub" ]] && echo " (key $(age_days "$key.pub") days old)")"
    return 0
  fi
  echo "failed: ssh git@$name (key not on the server?)"
  [[ "$test_only" != true && -f "$key.pub" ]] || return 1

  offer_pub "$key.pub" "$host" "$(page_hint "$host" auth)"
  read -r -p "Press Enter after adding the key to retest... " _ </dev/tty
  if ssh_ok "$name"; then
    ok "ssh git@$name"
  else
    echo "still failing: ssh -T git@$name"
    return 1
  fi
}

if [[ "$cmd" == sign ]]; then
  sign_account "$sign_acct"
  exit
fi

failed=""
for name in $accounts; do
  if ! auth_account "$name"; then
    failed="$failed $name"
    [[ "$test_only" == true ]] && test_signing "$name" || true
    continue
  fi
  if [[ "$test_only" == true ]]; then
    test_signing "$name" || failed="$failed $name"
  else
    method=""
    step 3 "signing"
    sign_account "$name" || failed="$failed $name"
  fi
done
[[ "$test_only" == true ]] && test_repo

echo
if [[ -n "$failed" ]]; then
  echo "failed:$failed" >&2
  exit 1
fi
echo "all accounts ok"
