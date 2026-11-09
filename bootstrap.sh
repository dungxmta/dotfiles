#!/usr/bin/env bash
# First install:  curl -fsSL https://raw.githubusercontent.com/dungxmta/dotfiles/main/bootstrap.sh | bash
# Inspect first:  curl -fsSLO https://raw.githubusercontent.com/dungxmta/dotfiles/main/bootstrap.sh && less bootstrap.sh && bash bootstrap.sh
# Env: DOTFILES_DIR (default ~/dotfiles), DOTFILES_REPO, extra args are passed to install.sh.
set -eu

# Everything runs from main, so a partially downloaded script does nothing.
main() {
  repo="${DOTFILES_REPO:-https://github.com/dungxmta/dotfiles.git}"
  dir="${DOTFILES_DIR:-$HOME/dotfiles}"

  command -v git >/dev/null 2>&1 || { echo "error: git is required (macOS: xcode-select --install; Ubuntu: sudo apt-get install git)" >&2; exit 1; }

  if [ -e "$dir/.git" ]; then
    # never run some other repo's install.sh
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    norm() { echo "$1" | sed -e 's|^git@github.com:|https://github.com/|' -e 's|^git@github:|https://github.com/|' -e 's|\.git$||'; }
    if [ "$(norm "$origin")" != "$(norm "$repo")" ]; then
      echo "error: $dir is a checkout of ${origin:-an unknown repo}, not $repo; set DOTFILES_DIR" >&2
      exit 1
    fi
    echo "using existing checkout: $dir"
  elif [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "error: $dir exists and is not a git checkout; set DOTFILES_DIR" >&2
    exit 1
  else
    # Partial clone (file contents on demand) + sparse checkout (root files only);
    # install.sh adds the modules the chosen profile needs.
    git clone --filter=blob:none --sparse "$repo" "$dir"
  fi

  # Under `curl | bash` stdin is the script: give the installer the terminal.
  if { : </dev/tty; } 2>/dev/null; then exec bash "$dir/install.sh" "$@" </dev/tty; fi
  exec bash "$dir/install.sh" "$@"
}

main "$@"
