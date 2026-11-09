# dot: small wrapper around chezmoi + git for the dotfiles repo.
# Sourced from zshrc only when enabled in ./install.sh (--with-dot / --without-dot).
# No git operations run on shell startup; `dot push` never stages or commits.

# Repo root (the chezmoi source dir is <repo>/config via .chezmoiroot).
_dot_repo() {
  local src
  src="$(chezmoi source-path 2>/dev/null)" || { print -u2 "dot: chezmoi source not found"; return 1; }
  git -C "$src" rev-parse --show-toplevel 2>/dev/null || print -r -- "$src"
}

dot() {
  local cmd=${1:-help} repo
  (( $# )) && shift
  case $cmd in
    edit)
      # ~/.zshrc is a one-line stub; the managed zshrc is ~/.config/zsh/zshrc.
      [[ ${1:A} == ${HOME:A}/.zshrc ]] && set -- "$HOME/.config/zsh/zshrc" "${@:2}"
      chezmoi edit "$@"
      ;;
    diff)   chezmoi diff "$@" ;;
    apply)  chezmoi apply "$@" ;;
    update)
      # pull, show the changes, then apply only after a yes
      chezmoi git -- pull --ff-only || return
      chezmoi diff
      [[ -z "$(chezmoi status)" ]] && { print "dot: up to date"; return 0; }
      read -q "?Apply these changes? [y/N] " || { print; return 1; }
      print
      chezmoi apply "$@"
      ;;
    status)
      repo="$(_dot_repo)" || return
      git -C "$repo" status -sb
      chezmoi status "$@"
      ;;
    sync)   repo="$(_dot_repo)" && "$repo/install.sh" --sync "$@" ;;
    tools)  repo="$(_dot_repo)" && "$repo/install.sh" --select-tools "$@" ;;
    upgrade)  repo="$(_dot_repo)" && "$repo/install.sh" --upgrade "$@" ;;
    outdated) repo="$(_dot_repo)" && "$repo/install.sh" --outdated "$@" ;;
    push)   repo="$(_dot_repo)" && git -C "$repo" push "$@" ;;
    repo)   repo="$(_dot_repo)" && cd "$repo" ;;
    help|-h|--help)
      cat <<'EOF'
usage: dot <command>
  edit <file>  edit the chezmoi source of a managed file
  diff         preview changes (chezmoi diff)
  apply        apply changes (chezmoi apply)
  update       pull the repo, show the diff, apply after a yes
  status       git status of the repo + chezmoi status
  sync         reconcile profile, tools and sparse checkout (install.sh --sync)
  tools        choose tools interactively (install.sh --select-tools)
  outdated     list newer versions: tools, runtimes, plugins, repo pins
  upgrade      pick what to upgrade from that list
  upgrade NAME...  upgrade these (fzf, go, omp, ohmyzsh, ...)
  upgrade --all    upgrade everything outdated
  push         push already-committed changes (never stages or commits)
  repo         cd into the dotfiles repo
EOF
      ;;
    *) print -u2 "dot: unknown command: $cmd (dot help)"; return 2 ;;
  esac
}
