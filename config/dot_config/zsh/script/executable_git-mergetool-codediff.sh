#! /bin/zsh
# script for "git mergetool" or in lazygit press "Shift+M"
# - use "cmd=<command>" directly in .gitconfig doesn't work, even set alias in shell
# - git doesn't export $MERGED, so gitconfig passes it as $1; nvim reads it from the
#   env, so spaces/quotes in the path need no escaping
# - CodeDiff --exit-on-close always exits 0, so (with trustExitCode = true) this script
#   decides: fail on nvim error (:cq), unresolved/unsaved blocks or leftover conflict
#   markers, so cancelled or partial merges are not staged
export MERGED="$1"
export CODEDIFF_OK=$(mktemp) || exit 1
trap 'rm -f -- "$CODEDIFF_OK"' EXIT

nvim -n -S "${0:A:h}/git-mergetool-codediff.lua" -- "$MERGED" || exit 1

if [[ $(<"$CODEDIFF_OK") != ok ]]; then
  echo "codediff: unresolved or unsaved conflicts in $MERGED" >&2
  exit 1
fi
if grep -qE '^(<<<<<<<|>>>>>>>)( |$)' -- "$MERGED"; then
  echo "codediff: conflict markers remain in $MERGED" >&2
  exit 1
fi
