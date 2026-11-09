# Sparse checkout (Git cone mode). Bash 3.2 compatible.
# Sparse checkout only limits the working tree; with `--filter=blob:none` the clone
# also fetches file contents lazily. Neither is a security boundary.

is_sparse() { [ "$(git -C "$REPO" config --bool core.sparseCheckout 2>/dev/null)" = true ]; }

# Directories the installer and the selected profile/tools need.
sparse_paths() {
  local id paths="installer config/.chezmoitemplates"
  if [ "$PROFILE_SHELL" = zsh ]; then
    paths="$paths scripts config/dot_config/zsh config/dot_config/shell"
    for id in $TOOLS; do paths="$paths $(tool_modules "$id")"; done
    paths="$paths $PROFILE_MODULES"
  fi
  echo $paths
}

# apply_checkout <full|sparse>: never discards local changes; git refuses to
# remove modified files from the working tree.
apply_checkout() {
  [ -e "$REPO/.git" ] || { say "not a git checkout: $REPO (skipping checkout mode)"; return 0; }
  if [ "$1" = full ]; then
    is_sparse || return 0
    say "checkout: sparse -> full"
    [ "$DRY_RUN" = true ] && return 0
    git -C "$REPO" sparse-checkout disable || fail "git sparse-checkout disable"
    return
  fi
  local want
  want="$(sparse_paths)"
  if is_sparse; then
    say "checkout: sparse ($want)"
  else
    say "checkout: full -> sparse ($want)"
    if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
      warn "uncommitted changes in $REPO; keeping the full checkout"
      return 0
    fi
  fi
  [ "$DRY_RUN" = true ] && return 0
  # `set` (not `add`) so deselected modules leave the working tree as well;
  # chezmoi then stops managing them without touching the deployed files.
  git -C "$REPO" sparse-checkout set --cone $want || fail "git sparse-checkout set"
}
