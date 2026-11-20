# git-push: push the git repos under $GIT_PUSH_ROOTS that have commits no remote has yet.
#   git-push <Tab>    fzf picker of those repos (preview: branch, commits to push, working
#                     tree); Enter inserts the paths, then Enter runs the push
#   git-push          the same picker, then pushes what you select
#   git-push DIR...   push these repos
#   gp                git push origin HEAD (this repo); gp <Tab> / gp DIR... act like git-push
# Everything shown is local (no fetch). Sourced from zshrc after fzf.zsh, whose Tab
# binding it wraps: Tab only opens the picker on a `git-push ` or `gp ` line.

typeset -g GIT_PUSH_ROOTS=${GIT_PUSH_ROOTS:-"$HOME/WORK $HOME/SYNC"}

# Repo folders under the roots (depth ≤ 6, node_modules skipped).
_git_push_repos() {
  local r
  for r in ${=GIT_PUSH_ROOTS}; do
    [[ -d $r ]] || continue
    if (( $+commands[fd] )); then
      fd --hidden --type d --max-depth 6 --prune --exclude node_modules '^\.git$' "$r" 2>/dev/null
    else
      find "$r" -maxdepth 6 -name node_modules -prune -o -type d -name .git -print -prune 2>/dev/null
    fi
  done | sed 's#/\.git/*$##' | sort -u
}

# One row "<path>\t<ahead> <~path> <branch> [✎dirty]" when repo $1 is on a branch with
# commits to push: ahead of its upstream, or commits no remote has when there is no upstream
# yet ("new") or its remote branch was deleted ("gone"). One `git status` call gives branch,
# upstream, ahead and dirty files.
_git_push_row() {
  local d=$1 line b="" up="" ahead="" dirty=0 n mark
  while IFS= read -r line; do
    case $line in
      '# branch.head '*) b=${line#\# branch.head } ;;
      '# branch.upstream '*) up=${line#\# branch.upstream } ;;
      '# branch.ab '*) ahead=${${line#\# branch.ab +}%% *} ;;
      '#'*) ;;
      *) dirty=$((dirty + 1)) ;;
    esac
  done < <(git -C "$d" status --porcelain=v2 --branch 2>/dev/null)
  [[ -n $b && $b != '(detached)' ]] || return 0
  if [[ -n $up && -n $ahead ]]; then
    n=$ahead mark="↑$ahead"
  else
    # no upstream yet ("new"), or its remote branch was deleted ("gone")
    [[ -n $(git -C "$d" remote 2>/dev/null) ]] || return 0
    n=$(git -C "$d" rev-list --count HEAD --not --remotes 2>/dev/null) || return 0
    if [[ -n $up ]]; then mark="gone↑$n"; else mark="new↑$n"; fi
  fi
  (( n > 0 )) || return 0
  printf '%s\t%-7s %-44s %s%s\n' "$d" "$mark" "${d/#$HOME/~}" "$b" "${${dirty:#0}:+  ✎$dirty}"
}

# All rows, one background job per repo (in a subshell: no job notices), sorted by path.
_git_push_rows() {
  (
    local d
    _git_push_repos | while IFS= read -r d; do _git_push_row "$d" & done
    wait
  ) | sort -t$'\t' -k1,1
}

# Preview of one repo (fzf passes its path as {1}).
typeset -g _git_push_preview='p={1}
git -C "$p" -c color.ui=always status -sb | head -1
echo
echo "to push:"
git -C "$p" log --oneline --color=always HEAD --not --remotes | head -30
echo
echo "working tree (not pushed):"
git -C "$p" -c color.ui=always status --short | head -20'

# Prints the picked repo paths (absolute), one per line.
_git_push_pick() {
  local rows
  rows=$(_git_push_rows)
  if [[ -z $rows ]]; then
    print -u2 "git-push: nothing to push under ${GIT_PUSH_ROOTS//$HOME/~}"
    return 1
  fi
  print -r -- "$rows" | fzf --multi --delimiter=$'\t' --with-nth=2 --height=60% --reverse \
    --prompt='push> ' --header='Tab: select several · Enter: done' \
    --preview="$_git_push_preview" --preview-window=right,55% | cut -f1
}

git-push() {
  local r b n out
  local -a repos
  if (( $# )); then
    repos=("$@")
  else
    repos=(${(f)"$(_git_push_pick)"}) || return
  fi
  for r in $repos; do
    if ! git -C "$r" rev-parse --git-dir >/dev/null 2>&1; then
      print -u2 "!!  $r: not a git repo"
      continue
    fi
    b=$(git -C "$r" symbolic-ref --quiet --short HEAD)
    n=$(git -C "$r" rev-list --count HEAD --not --remotes)
    if git -C "$r" rev-parse --verify -q '@{upstream}' >/dev/null 2>&1; then
      out=$(git -C "$r" push 2>&1)
    else
      # first push of this branch: create it on origin (or the only remote) and track it
      out=$(git -C "$r" push -u "$(git -C "$r" remote | grep -x origin || git -C "$r" remote | head -1)" HEAD 2>&1)
    fi
    if (( $? == 0 )); then
      print -r -- "ok  ${r/#$HOME/~}  $b ($n commit${${n:#1}:+s})"
    else
      print -r -- "!!  ${r/#$HOME/~}  $b: push failed"
      print -r -- "$out" | sed 's/^/    /'
    fi
  done
}

# gp: replaces the `gp` alias from aliases.sh (sourced earlier); with args it is git-push.
unalias gp 2>/dev/null
function gp {
  if (( $# )); then
    git-push "$@"
  else
    git push origin HEAD
  fi
}

# Tab on a `git-push ` or `gp ` line opens the picker and inserts ~/paths; any other line
# keeps the widget Tab had before (fzf's completion). On reload-zsh Tab is already ours:
# keep the saved widget instead of calling ourselves.
() {
  local w=${$(bindkey '^I')[2]:-expand-or-complete}
  [[ $w == _git_push_tab ]] || typeset -g _git_push_tab_prev=$w
}
_git_push_tab() {
  if [[ $LBUFFER == (git-push|gp)\ * ]]; then
    local p sel=""
    for p in ${(f)"$(_git_push_pick </dev/tty)"}; do
      sel+="${${(q)p}/#${(q)HOME}/~} "
    done
    LBUFFER+=$sel
    zle reset-prompt
  else
    zle $_git_push_tab_prev
  fi
}
zle -N _git_push_tab
bindkey '^I' _git_push_tab
# zsh-vi-mode initializes lazily and may reset Tab: bind it again after that
(( $+functions[zvm_init] )) && zvm_after_init_commands+=("bindkey '^I' _git_push_tab")
