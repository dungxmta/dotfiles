# dot sync TOOL (install.sh --sync --only TOOL): preview and apply only TOOL's files,
# with the answers install.sh just asked for it. Bash 3.2 compatible.

sync_only() {
  local tool="$1" t managed targets="" changes st path backup="" state_changed=true
  in_list "$tool" "$CLI_TOOLS $EXTRA_TOOLS herdr" || die "unknown tool: $tool"
  [ "$tool" = herdr ] || in_list "$tool" "$TOOLS" || die "$tool isn't selected (dot tools)"
  has chezmoi || die "no chezmoi yet: run ./install.sh first"
  [ -n "$(tool_targets "$tool")" ] || { say "$tool has no configuration in the dotfiles"; return 0; }

  # Keep what this run doesn't ask about (an unanswered clipboard-over-ssh stays unanswered).
  PLAN_MISE="$S_MISE" SEEN_TOOLS="$S_SEEN"
  [ "$tool" = neovim ] || NVIM_CLIPBOARD="$S_NVIM_CLIPBOARD"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT  # global: the trap runs after this function returns
  [ -f "$CZ_CONFIG" ] && cp -p "$CZ_CONFIG" "$tmp/chezmoi.toml"
  write_state "$tmp/chezmoi.toml" || die "could not render the chezmoi config"
  [ -f "$CZ_CONFIG" ] && cmp -s "$CZ_CONFIG" "$tmp/chezmoi.toml" && state_changed=false

  # Only paths managed on this machine (e.g. no ~/.config/tmux with the lite variant).
  managed="$(chezmoi --config "$tmp/chezmoi.toml" --source "$REPO" managed 2>/dev/null)" ||
    die "chezmoi managed failed"
  for t in $(tool_targets "$tool"); do
    printf '%s\n' "$managed" | grep -qxF -- "$t" && targets="$targets $HOME/$t"
  done
  [ -n "$targets" ] || die "no $tool files are managed here"

  step "Changes to $tool:$(echo "$targets" | sed "s|$HOME|~|g")"
  changes="$(chezmoi --config "$tmp/chezmoi.toml" --source "$REPO" status --recursive --exclude=scripts $targets 2>&1)" ||
    die "chezmoi status failed: $changes"
  if [ -z "$changes" ]; then
    say "configuration is up to date"
    [ "$state_changed" = true ] || return 0
  else
    say "$changes"
    chezmoi --config "$tmp/chezmoi.toml" --source "$REPO" diff --no-pager --recursive --exclude=scripts $targets
  fi
  if [ "$DRY_RUN" = true ]; then say "(dry run) nothing changed"; return 0; fi
  if [ -n "$changes" ] && ! confirm "Apply these changes?" y; then say "not applied"; return 1; fi

  # Back up what gets replaced, then save the answers and apply.
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  while read -r st path; do
    [ -n "$path" ] || continue
    [ -d "$HOME/$path" ] && [ ! -L "$HOME/$path" ] && continue  # dirs: only modes change
    if [ -e "$HOME/$path" ] || [ -L "$HOME/$path" ]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$path")" && cp -pPR "$HOME/$path" "$BACKUP_DIR/$path" ||
        die "backup of ~/$path failed; nothing applied"
      backup=yes
    fi
  done <<EOT
$changes
EOT
  if [ "$state_changed" = true ]; then
    mkdir -p "$(dirname "$CZ_CONFIG")"
    if [ -f "$CZ_CONFIG" ]; then mkdir -p "$BACKUP_DIR" && cp -p "$CZ_CONFIG" "$BACKUP_DIR/chezmoi.toml"; backup=yes; fi
    write_state "$CZ_CONFIG" || die "could not write $CZ_CONFIG"
  fi
  [ -n "$backup" ] && say "backup: $BACKUP_DIR"
  if [ -n "$changes" ]; then chezmoi apply --force $targets || die "chezmoi apply failed"; fi
  say "$tool: done"
}
