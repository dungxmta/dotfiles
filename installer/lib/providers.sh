# Package providers: who owns each tool on this profile, what is already there,
# and missing-only installs. Bash 3.2 compatible.
# Nothing here upgrades or uninstalls; upgrades only run from `install.sh --upgrade`.

# catalog_field <id> <column: 2=binary 3=brew 4=apt 5=mise>
catalog_field() {
  printf '%s\n' "$CATALOG" | awk -v id="$1" -v c="$2" '$1 == id { print $c; exit }'
}

is_root() { [ "$(id -u)" = 0 ]; }

# apt is usable as root, with passwordless sudo, or (interactively) with sudo.
APT_SUDO="" APT_STATE=""
apt_usable() {
  if [ -z "$APT_STATE" ]; then
    APT_STATE=no
    if has apt-get; then
      if is_root; then APT_STATE=yes
      elif has sudo && { sudo -n true 2>/dev/null || interactive; }; then APT_STATE=yes APT_SUDO=sudo
      fi
    fi
  fi
  [ "$APT_STATE" = yes ]
}

# provider_for <id>: brew | apt | mise | mise-installer | unsupported
provider_for() {
  local id="$1" brew apt mise
  brew="$(catalog_field "$id" 3)" apt="$(catalog_field "$id" 4)" mise="$(catalog_field "$id" 5)"
  case "$PROFILE_PROVIDERS" in
    mac)
      # Portable CLI tools from mise; eza has no macOS release binaries for mise.
      if [ "$mise" != - ] && [ "$id" != eza ] && [ "$id" != git-lfs ]; then echo mise
      elif [ "$brew" != - ]; then echo brew
      else echo unsupported; fi
      ;;
    mac-work)
      # Homebrew for every CLI tool; mise only for Neovim (and runtimes).
      if [ "$id" = neovim ]; then echo mise
      elif [ "$brew" != - ]; then echo brew
      else echo unsupported; fi
      ;;
    linux)
      if [ "$id" = mise ]; then echo mise-installer
      elif [ "$apt" != - ] && apt_usable; then echo apt
      elif [ "$mise" != - ]; then echo mise
      else echo unsupported; fi
      ;;
    *) echo unsupported ;;
  esac
}

# Existing binary (any provider) counts as installed: never install a second copy.
tool_path() {
  local bin
  bin="$(catalog_field "$1" 2)"
  command -v "$bin" 2>/dev/null
}

# Ubuntu's fdfind/batcat do not count: the shell config calls fd and bat.
tool_present() { tool_path "$1" >/dev/null; }

brew_has() { brew list --formula "$1" >/dev/null 2>&1 || brew list --cask "$1" >/dev/null 2>&1; }
apt_has() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

# plan_tools: fills the PLAN_* lists from $TOOLS / $RUNTIMES / $APPS.
#   PLAN_PRESENT     tools already installed (reused)
#   PLAN_BREW        formulae to install     PLAN_CASKS  casks to install
#   PLAN_APT         apt packages to install
#   PLAN_MISE        mise tools for the global config (installed only if missing)
#   PLAN_MISE_SELF   "yes" when mise itself comes from https://mise.run
#   PLAN_UNSUPPORTED tools with no allowed provider here
plan_tools() {
  local id p pkg path
  PLAN_PRESENT="" PLAN_BREW="" PLAN_CASKS="" PLAN_APT="" PLAN_MISE="" PLAN_MISE_SELF="" PLAN_UNSUPPORTED=""
  for id in $TOOLS; do
    p="$(provider_for "$id")"
    if tool_present "$id"; then
      path="$(tool_path "$id")"
      PLAN_PRESENT="$PLAN_PRESENT $id"
      # Anything mise already owns stays in its config (dropping it would break it).
      case "$path" in */mise/*) PLAN_MISE="$PLAN_MISE $id" ;; esac
      continue
    fi
    case "$p" in
      brew) PLAN_BREW="$PLAN_BREW $(catalog_field "$id" 3)" ;;
      apt) PLAN_APT="$PLAN_APT $(catalog_field "$id" 4)" ;;
      mise) PLAN_MISE="$PLAN_MISE $id" ;;
      mise-installer) PLAN_MISE_SELF=yes ;;
      *) PLAN_UNSUPPORTED="$PLAN_UNSUPPORTED $id" ;;
    esac
  done
  # mise is needed for mise-provided tools and runtimes even when deselected.
  if [ -n "$PLAN_MISE$RUNTIMES" ] && ! has mise; then
    case "$PROFILE_PROVIDERS" in
      linux) PLAN_MISE_SELF=yes ;;
      mac | mac-work) in_list mise "$PLAN_BREW" || PLAN_BREW="$PLAN_BREW mise" ;;
    esac
  fi
  if [ "$PROFILE_PROVIDERS" = linux ] && [ -n "${PROFILE_APT_EXTRA:-}" ] && apt_usable; then
    for pkg in $PROFILE_APT_EXTRA; do apt_has "$pkg" || PLAN_APT="$PLAN_APT $pkg"; done
  fi
  for pkg in $APPS; do brew_has "$pkg" || PLAN_CASKS="$PLAN_CASKS $pkg"; done
  PLAN_BREW="$(echo $PLAN_BREW)" PLAN_APT="$(echo $PLAN_APT)" PLAN_MISE="$(echo $PLAN_MISE)"
}

# --- installs (missing only) ---------------------------------------------------

FAILED=""
fail() { FAILED="$FAILED $1"; warn "failed: $1"; }

ensure_brew() {
  has brew && return 0
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && { eval "$("$b" shellenv)"; return 0; }
  done
  if [ "$PROFILE_PROVIDERS" = mac-work ]; then
    warn "Homebrew is missing; install it through your company's process (no sudo here)"
    return 1
  fi
  confirm "Homebrew is missing. Install its notarized .pkg (asks for your password)?" n || return 1
  local tag tmp
  tag="$(github_latest Homebrew/brew)" || { warn "could not find the latest Homebrew release"; return 1; }
  tmp="$(mktemp -d)"
  if curl -fsSL --proto '=https' -o "$tmp/Homebrew.pkg" "https://github.com/Homebrew/brew/releases/download/$tag/Homebrew.pkg" &&
    spctl --assess --type install "$tmp/Homebrew.pkg" 2>/dev/null &&
    pkgutil --check-signature "$tmp/Homebrew.pkg" | grep -q '(927JGANW46)$'; then  # Homebrew's Developer ID team
    sudo installer -pkg "$tmp/Homebrew.pkg" -target / || { rm -rf "$tmp"; return 1; }
  else
    warn "Homebrew $tag: download failed or the package is not signed and notarized"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
}

install_brew() {
  local pkg todo=""
  [ -n "$PLAN_BREW$PLAN_CASKS" ] || return 0
  ensure_brew || { fail "brew:$PLAN_BREW $PLAN_CASKS"; return; }
  # `brew install` on an installed but outdated formula upgrades it: filter first.
  for pkg in $PLAN_BREW; do brew_has "$pkg" || todo="$todo $pkg"; done
  if [ -n "$todo" ]; then
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 \
      brew install $todo || fail "brew:$todo"
  fi
  for pkg in $PLAN_CASKS; do
    # Casks with installer packages ask for an admin password; report instead of retrying.
    HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "$pkg" || fail "cask:$pkg (may need admin rights)"
  done
}

install_apt() {
  [ -n "$PLAN_APT" ] || return 0
  apt_usable || { fail "apt:$PLAN_APT (no root/sudo)"; return; }
  $APT_SUDO apt-get update -qq || { fail "apt-get update"; return; }
  DEBIAN_FRONTEND=noninteractive $APT_SUDO apt-get install -y --no-install-recommends $PLAN_APT || fail "apt:$PLAN_APT"
}

# --- verified downloads (Linux) ------------------------------------------------------
# Release archives are checked against the SHA-256 list published with the release.

# github_latest <owner/repo>: latest release tag, from the redirect (no API rate limit).
github_latest() {
  local url
  url="$(curl -fsSLI --proto '=https' -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")" || return 1
  url="${url##*/tag/}"
  case "$url" in "" | *[!0-9A-Za-z.+_-]*) return 1 ;; esac
  echo "$url"
}

sha256_of() {
  if has sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch_verified <url> <sums url> <file name> <dir>: download into dir and check the hash.
fetch_verified() {
  local url="$1" sums="$2" name="$3" dir="$4" want
  curl -fsSL --proto '=https' -o "$dir/$name" "$url" || return 1
  case "$sums" in
    *.asc) # clearsigned list: keep only the signed text, verified with the pinned key
      curl -fsSL --proto '=https' -o "$dir/sums.asc" "$sums" &&
        gpgv --keyring "$REPO/installer/keys/mise.gpg" --output "$dir/sums" "$dir/sums.asc" 2>/dev/null ||
        { warn "bad or missing signature: $sums"; return 1; } ;;
    *) curl -fsSL --proto '=https' -o "$dir/sums" "$sums" || return 1 ;;
  esac
  want="$(awk -v f="$name" '{ n = $2; sub(/^[*.\/]+/, "", n) } n == f { print $1; exit }' "$dir/sums")"
  [ -n "$want" ] && [ "$(sha256_of "$dir/$name")" = "$want" ] || { warn "checksum mismatch: $name"; return 1; }
}

# chezmoi without Homebrew or mise: release tarball -> ~/.local/bin/chezmoi
install_chezmoi_verified() {
  local tag v arch name tmp rc
  case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) return 1 ;; esac
  tag="$(github_latest twpayne/chezmoi)" || return 1
  v="${tag#v}" name="chezmoi_${v#v}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  fetch_verified "https://github.com/twpayne/chezmoi/releases/download/$tag/$name" \
    "https://github.com/twpayne/chezmoi/releases/download/$tag/chezmoi_${v#v}_checksums.txt" "$name" "$tmp" &&
    tar -xzf "$tmp/$name" -C "$tmp" chezmoi && mkdir -p "$HOME/.local/bin" &&
    cp "$tmp/chezmoi" "$HOME/.local/bin/chezmoi" && chmod 755 "$HOME/.local/bin/chezmoi"
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# mise on Linux: mise's signed apt repository (key pinned in installer/keys) when apt
# is usable, otherwise the release tarball checked against SHASUMS256.txt.
install_mise_self() {
  [ "$PLAN_MISE_SELF" = yes ] || return 0
  has mise && return 0
  if apt_usable; then
    say "mise: apt repository https://mise.jdx.dev/deb (signed)"
    $APT_SUDO install -d -m 755 /etc/apt/keyrings &&
      $APT_SUDO install -m 644 "$REPO/installer/keys/mise-archive-keyring.asc" /etc/apt/keyrings/mise-archive-keyring.asc &&
      echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.asc] https://mise.jdx.dev/deb stable main" |
      $APT_SUDO tee /etc/apt/sources.list.d/mise.list >/dev/null &&
      $APT_SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $APT_SUDO apt-get install -y mise &&
      return 0
    fail "mise (apt)"
    return
  fi
  local tag arch name tmp
  case "$(uname -m)" in x86_64 | amd64) arch=x64 ;; aarch64 | arm64) arch=arm64 ;; *) fail "mise: unsupported CPU"; return ;; esac
  say "mise: verified release -> ~/.local/bin/mise"
  tag="$(github_latest jdx/mise)" || { fail "mise: latest release not found"; return; }
  name="mise-${tag}-linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  if fetch_verified "https://github.com/jdx/mise/releases/download/$tag/$name" \
    "https://github.com/jdx/mise/releases/download/$tag/SHASUMS256.asc" "$name" "$tmp" &&
    tar -xzf "$tmp/$name" -C "$tmp" mise/bin/mise && mkdir -p "$HOME/.local/bin" &&
    cp "$tmp/mise/bin/mise" "$HOME/.local/bin/mise" && chmod 755 "$HOME/.local/bin/mise"; then
    :
  else
    fail "mise ($name)"
  fi
  rm -rf "$tmp"
}

# After chezmoi wrote ~/.config/mise/config.toml: install what it requests and is
# missing (mise install never upgrades an installed version).
install_mise_tools() {
  [ -n "$PLAN_MISE$RUNTIMES" ] || [ "$PROFILE" = linux-dev ] || return 0
  has mise || { fail "mise tools: mise is not installed"; return; }
  if [ -z "${GITHUB_TOKEN:-}${MISE_GITHUB_TOKEN:-}" ]; then
    say "note: no GITHUB_TOKEN; mise may hit GitHub's anonymous rate limit"
  fi
  (cd / && mise install --yes) || fail "mise install (see output above)"
}

