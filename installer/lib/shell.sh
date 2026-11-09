# Zsh + Oh My Zsh + plugins, the ~/.zshrc stub, login shell, tmux plugins.
# Bash 3.2 compatible. Plugins come from installer/tools/pins.txt at exact commits;
# only `dot upgrade` / `install.sh --upgrade` moves them. Never deletes existing checkouts.

PINS="$REPO/installer/tools/pins.txt"

# Ignore ~/.gitconfig: on macOS it rewrites GitHub URLs to SSH, which a fresh
# machine has no key for yet. These are public HTTPS fetches.
pgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git "$@"; }

# pinned_checkout <dir> <repo> <commit>: fetch exactly that commit and check it out.
pinned_checkout() {
  local dir="$1" repo="$2" sha="$3" new=false
  case "$sha" in *[!0-9a-f]* | "") fail "bad pin for $repo: $sha"; return ;; esac
  [ ${#sha} -eq 40 ] || { fail "bad pin for $repo: $sha"; return; }
  if [ ! -e "$dir" ]; then
    new=true
    mkdir -p "$dir" && pgit -C "$dir" init -q && pgit -C "$dir" remote add origin "https://github.com/$repo.git" ||
      { fail "git init $dir"; return; }
  fi
  if pgit -C "$dir" fetch -q --depth 1 origin "$sha" && pgit -C "$dir" checkout -q --detach FETCH_HEAD; then
    say "$repo @ $(echo "$sha" | cut -c1-7)"
  else
    fail "fetch $repo@$sha"
    [ "$new" = true ] && rm -rf "$dir"  # only what this function created
  fi
}

# install_pinned <group>: missing repos are fetched at their pin; existing ones are left alone.
install_pinned() {
  local group dir repo sha
  while read -r group dir repo sha; do
    [ "$group" = "$1" ] || continue
    dir="$HOME/$dir"
    if [ -d "$dir/.git" ]; then
      [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$sha" ] ||
        say "note: ~/${dir#"$HOME/"} is not at its pinned commit (dot upgrade moves it)"
      continue
    fi
    # installed some other way (tarball, package): leave it alone
    if [ -e "$dir" ]; then
      warn "~/${dir#"$HOME/"} exists but is not a git checkout; leaving it as is"
      continue
    fi
    pinned_checkout "$dir" "$repo" "$sha"
  done <"$PINS"
}

ZSHRC_LINE='source "$HOME/.config/zsh/zshrc"'

setup_zsh() {
  has zsh || { fail "zsh is not installed"; return; }
  install_pinned zsh

  # ~/.zshrc stays a small user-owned file (Lima appends its PATH block to it);
  # the managed config is ~/.config/zsh/zshrc.
  local rc="$HOME/.zshrc"
  if [ -L "$rc" ] && [ "$(readlink "$rc")" = "$HOME/.config/zsh/zshrc" ]; then
    rm "$rc"
  fi
  if ! grep -qxF "$ZSHRC_LINE" "$rc" 2>/dev/null; then
    if [ -s "$rc" ]; then
      confirm "Replace ~/.zshrc with a line that sources ~/.config/zsh/zshrc? (backup kept)" y ||
        { say "kept ~/.zshrc; add: $ZSHRC_LINE"; return 0; }
      mkdir -p "$BACKUP_DIR" && cp -pP "$rc" "$BACKUP_DIR/.zshrc" && say "backup: $BACKUP_DIR/.zshrc"
      rm -f "$rc"
    fi
    printf '%s\n' "$ZSHRC_LINE" >>"$rc" && say "~/.zshrc: $ZSHRC_LINE"
  fi

  local zsh_bin cur
  zsh_bin="$(command -v zsh)"
  if [ "$(uname -s)" = Darwin ]; then
    cur="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
  else
    cur="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"
  fi
  case "$cur" in */zsh) return 0 ;; esac
  if is_root; then
    usermod -s "$zsh_bin" "$(id -un)" || fail "usermod -s $zsh_bin"
  elif [ "$PROFILE_PROVIDERS" = linux ] && sudo -n true 2>/dev/null; then
    sudo usermod -s "$zsh_bin" "$(id -un)" && say "login shell -> $zsh_bin (new sessions)" || fail "usermod -s $zsh_bin"
  elif interactive && confirm "Change your login shell to $zsh_bin (chsh asks for your password)?" y; then
    chsh -s "$zsh_bin" || fail "chsh -s $zsh_bin"
  else
    say "login shell is ${cur:-unknown}; change it with: chsh -s $zsh_bin"
  fi
}

# tpm and the plugins in tmux.conf, all pinned. tpm's own install (prefix + I) is
# not run: it would clone plugins at their latest commit.
setup_tpm() {
  install_pinned tmux
}
