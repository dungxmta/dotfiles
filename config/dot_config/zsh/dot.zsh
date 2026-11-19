# dot: small wrapper around chezmoi + git for the dotfiles repo.
# Sourced from zshrc only when enabled in ./install.sh (--with-dot / --without-dot).
# No git operations run on shell startup; `dot push` never stages or commits.

# completion: completions/_dot reads the index `dot index` writes (never runs commands on Tab)
autoload -Uz _dot
(( $+functions[compdef] )) && compdef _dot dot

typeset -g _DOT_INDEX="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/dot-index"

# Repo root (the chezmoi source dir is <repo>/config via .chezmoiroot).
_dot_repo() {
  local src
  src="$(chezmoi source-path 2>/dev/null)" || { print -u2 "dot: chezmoi source not found"; return 1; }
  git -C "$src" rev-parse --show-toplevel 2>/dev/null || print -r -- "$src"
}

# _dot_index [-q] — write the completion index: git accounts with a Host block, the files
# chezmoi manages, and the names `dot upgrade` takes from installer/tools/pins.txt.
_dot_index() {
  emulate -L zsh
  local a repo os tmp
  local -a accts files names
  for a in $HOME/.config/git/gitconfig-*(N:t); do
    a=${a#gitconfig-}
    [[ $(ssh -G "$a" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}') != $a ]] && accts+=($a)
  done
  files=(${(f)"$(chezmoi managed --include=files 2>/dev/null)"})
  repo="$(_dot_repo 2>/dev/null)"
  os=${(L)$(uname -s)}
  if [[ -r $repo/installer/tools/pins.txt ]]; then
    # plugins: the repo name; mise pins: the name (name@os for the other OS, as `dot outdated`)
    names=(${(f)"$(awk -v os=$os '
      $1 == "zsh" || $1 == "tmux" { n = split($3, p, "/"); print p[n] }
      $1 == "mise" { print ($5 == "all" || $5 == os) ? $2 : $2 "@" $5 }' $repo/installer/tools/pins.txt)"})
  fi
  mkdir -p ${_DOT_INDEX:h}
  tmp=$_DOT_INDEX.$$
  {
    print -r -- "# written by dot index; read by completions/_dot"
    print -r -- "_dot_accounts=(${(@q)accts})"
    print -r -- "_dot_managed=(${(@q)files})"
    print -r -- "_dot_upgrade=(${(@q)names})"
  } >$tmp && mv -f $tmp $_DOT_INDEX
  [[ $1 == -q ]] || print -r -- "ok  ${_DOT_INDEX/#$HOME/~}: $#accts accounts, $#files managed files, $#names upgrade names"
}

# Run a command, then refresh the index quietly; keeps the command's exit status.
_dot_then_index() {
  "$@"
  local rc=$?
  _dot_index -q
  return $rc
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
    apply)  _dot_then_index chezmoi apply "$@" ;;
    update)
      # pull, show the changes, then apply only after a yes
      chezmoi git -- pull --ff-only || return
      chezmoi diff
      [[ -z "$(chezmoi status)" ]] && { print "dot: up to date"; _dot_index -q; return 0; }
      read -q "?Apply these changes? [y/N] " || { print; return 1; }
      print
      _dot_then_index chezmoi apply "$@"
      ;;
    status)
      repo="$(_dot_repo)" || return
      git -C "$repo" status -sb
      chezmoi status "$@"
      ;;
    sync)
      repo="$(_dot_repo)" || return
      # dot sync TOOL: only that tool's questions and files
      [[ -n $1 && $1 != -* ]] && set -- --only "$@"
      _dot_then_index "$repo/install.sh" --sync "$@"
      ;;
    tools)  repo="$(_dot_repo)" && _dot_then_index "$repo/install.sh" --select-tools "$@" ;;
    upgrade)  repo="$(_dot_repo)" && _dot_then_index "$repo/install.sh" --upgrade "$@" ;;
    outdated) repo="$(_dot_repo)" && "$repo/install.sh" --outdated "$@" ;;
    push)   repo="$(_dot_repo)" && git -C "$repo" push "$@" ;;
    repo)   repo="$(_dot_repo)" && cd "$repo" ;;
    git)    repo="$(_dot_repo)" && _dot_then_index "$repo/scripts/setup-git.sh" "$@" ;;
    index)  _dot_index "$@" ;;
    help|-h|--help)
      cat <<'EOF'
usage: dot <command>
  edit <file>  edit the chezmoi source of a managed file
  diff         preview changes (chezmoi diff)
  apply        apply changes (chezmoi apply)
  update       pull the repo, show the diff, apply after a yes
  status       git status of the repo + chezmoi status
  sync         reconcile profile, tools and sparse checkout (install.sh --sync)
  sync TOOL    ask TOOL's questions again, preview and apply only its files
               (nvim, tmux, git, herdr; others just re-render)
  tools        choose tools interactively (install.sh --select-tools)
  outdated     list newer versions: tools, runtimes, plugins, repo pins
  upgrade      pick what to upgrade from that list
  upgrade NAME...  upgrade these (fzf, go, omp, ohmyzsh, ...)
  upgrade --all    upgrade everything outdated
  push         push already-committed changes (never stages or commits)
  repo         cd into the dotfiles repo
  git          git accounts: status, then a menu (set up, signing, renew)
  git status   read-only check: ssh, signing keys, this repo's commits
  git ssh      keys in use and old keys; git ssh clean to tidy / delete
  index        rebuild the Tab-completion index (accounts, managed files, upgrade
               names); apply, update, sync, tools, upgrade, git and reload-zsh do it too
EOF
      ;;
    *) print -u2 "dot: unknown command: $cmd (dot help)"; return 2 ;;
  esac
}
