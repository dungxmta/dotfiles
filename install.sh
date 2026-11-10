#!/usr/bin/env bash
# dotfiles installer: profile, tools and configuration through chezmoi.
# Bash 3.2 compatible (macOS /bin/bash). Safe to rerun. See --help.
set -u  # no -e: failures are collected and reported (see fail)

usage() {
  cat <<'EOF'
usage: ./install.sh [options]

  (no options)          interactive: profile, tools, variants, review, apply
  --profile NAME        mac | mac-work | linux-dev | devpod | tmux-only
  --tools a,b,c         tool selection (replaces the saved/default one)
  --select-tools        only ask for tools; keep the other saved answers
  --with-dot            source the `dot` helper in zsh
  --without-dot         stop sourcing it (the file is left in place)
  --with-agents         clone the agents repo (agent config + skills) and run
                        its installer; $AGENTS_DIR, default ~/SYNC/agents
  --without-agents      stop syncing it (links and the clone are left in place)
  --configure-only      this run only: apply configuration, install no packages
  --checkout full|sparse
  --sync                no questions: reuse saved answers, offer new profile
                        defaults, expand the sparse checkout, install missing
                        tools, preview and apply configuration
  --outdated            list what has a newer version (tools, runtimes, repo pins)
  --upgrade [NAME...]   upgrade those, or pick from the outdated list; one name
                        space for brew, mise, apt and repo pins (pins.txt)
  --all                 with --upgrade: everything outdated, one confirmation
  --dry-run             show what would happen; change nothing
  -y, --yes             skip routine confirmations (backups still happen)
  -h, --help            this help

State lives in ~/.config/chezmoi/chezmoi.toml ([data]); edit it there or rerun.
The installer regenerates that file: keep custom settings inside [data]
(other tables such as [diff] are not kept; the old file is backed up).
Replaced files are backed up to ~/.local/state/dotfiles/backup/<time>/.
Deselected tools are never uninstalled; deselected configs stay on disk unmanaged.
Daily use: dot update | dot diff | dot apply | dot upgrade | dot help
EOF
}

REPO="$(cd "$(dirname "$0")" && pwd)"
OPT_PROFILE="" OPT_TOOLS="" OPT_DOT="" OPT_AGENTS="" OPT_CHECKOUT="" OPT_MODE=""
SYNC=false UPGRADE=false DRY_RUN=false ASSUME_YES=false SELECT_TOOLS=false
OUTDATED_ONLY=false UPGRADE_ALL=false UPGRADE_NAMES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) OPT_PROFILE="${2:?--profile needs a name}"; shift ;;
    --tools) OPT_TOOLS="$(echo "${2:?--tools needs a list}" | tr ',' ' ')"; shift ;;
    --select-tools) SELECT_TOOLS=true ;;
    --with-dot) OPT_DOT=true ;;
    --without-dot) OPT_DOT=false ;;
    --with-agents) OPT_AGENTS=true ;;
    --without-agents) OPT_AGENTS=false ;;
    --configure-only) OPT_MODE=configure ;;
    --checkout) OPT_CHECKOUT="${2:?--checkout needs full or sparse}"; shift ;;
    --sync) SYNC=true ;;
    --upgrade | --outdated)
      UPGRADE=true
      [ "$1" = --outdated ] && OUTDATED_ONLY=true
      # names that follow, up to the next option
      while [ $# -gt 1 ]; do
        case "$2" in -*) break ;; esac
        UPGRADE_NAMES="$UPGRADE_NAMES $2"
        shift
      done
      ;;
    --all) UPGRADE_ALL=true ;;
    --dry-run) DRY_RUN=true ;;
    -y | --yes) ASSUME_YES=true ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$OPT_CHECKOUT" in "" | full | sparse) ;; *) echo "--checkout: full or sparse" >&2; exit 2 ;; esac

# A fresh sparse clone has only the root files: fetch the installer first.
if [ ! -f "$REPO/installer/lib/ui.sh" ]; then
  git -C "$REPO" sparse-checkout add installer && [ -f "$REPO/installer/lib/ui.sh" ] ||
    { echo "error: could not check out installer/ (network?)" >&2; exit 1; }
fi
. "$REPO/installer/lib/ui.sh"
. "$REPO/installer/lib/providers.sh"
. "$REPO/installer/lib/checkout.sh"
. "$REPO/installer/tools/catalog.sh"

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
PROFILES="mac mac-work linux-dev devpod tmux-only"
STAMP="$(date +%Y%m%d-%H%M%S)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
BACKUP_DIR="$STATE_DIR/backup/$STAMP"
CZ_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/chezmoi/chezmoi.toml"
AGENTS_DIR="${AGENTS_DIR:-$HOME/SYNC/agents}"
AGENTS_URL="https://github.com/dungxmta/agents.git"

# --- saved state ----------------------------------------------------------------

S_PROFILE="" S_TOOLS="" S_RUNTIMES="" S_APPS="" S_NVIM="" S_TMUX="" S_PREFIX="" S_DOT="" S_AGENTS="" S_MODE=""
S_CHECKOUT="" S_SEEN="" S_WORK=""
load_state() {
  [ -f "$CZ_CONFIG" ] && has chezmoi || return 0
  local k v out
  out="$(chezmoi --source "$REPO" execute-template '
S_PROFILE={{ get . "profile" }}
S_TOOLS={{ get . "tools" | default list | join " " }}
S_RUNTIMES={{ get . "runtimes" | default list | join " " }}
S_APPS={{ get . "apps" | default list | join " " }}
S_NVIM={{ get . "nvimVariant" }}
S_TMUX={{ get . "tmuxVariant" }}
S_PREFIX={{ get . "tmuxPrefix" }}
S_DOT={{ get . "dotEnabled" }}
S_AGENTS={{ get . "agentsEnabled" }}
S_MODE={{ get . "installMode" }}
S_CHECKOUT={{ get . "checkout" }}
S_SEEN={{ get . "defaultsSeen" | default list | join " " }}
S_WORK={{ if hasKey . "work" }}yes{{ end }}' 2>/dev/null)" || return 0
  # Saved values are plain words (tool names, C-a, ...); anything else is ignored.
  while IFS='=' read -r k v; do
    case "$k" in S_[A-Z]*) ;; *) continue ;; esac
    case "$k" in *[!A-Z_]*) continue ;; esac
    v="${v//<no value>/}"
    case "$v" in *[!A-Za-z0-9\ ._-]*) warn "ignoring unexpected saved value for $k"; continue ;; esac
    printf -v "$k" '%s' "$v"
  done <<EOF
$out
EOF
}

# write_state <config file>: render config/.chezmoi.toml.tmpl into it.
write_state() {
  DOT_REPO="$REPO" DOT_PROFILE="$PROFILE" DOT_CHECKOUT="$CHECKOUT" \
    DOT_TOOLS="$(csv "$TOOLS")" DOT_RUNTIMES="$(csv "$RUNTIMES")" DOT_APPS="$(csv "$APPS")" \
    DOT_MISE_TOOLS="$(csv "$PLAN_MISE")" DOT_DEFAULTS_SEEN="$(csv "$PROFILE_TOOLS")" \
    DOT_NVIM="$NVIM" DOT_TMUX="$TMUX_VARIANT" DOT_TMUX_PREFIX="$PREFIX" DOT_DOT="$DOT" DOT_AGENTS="$AGENTS" DOT_MODE="$SAVED_MODE" \
    DOT_WORK_HOST="${WORK_HOST:-}" DOT_WORK_EMAIL="${WORK_EMAIL:-}" \
    chezmoi --config "$1" --source "$REPO" init --no-tty >/dev/null
}

# --- profile + answers -------------------------------------------------------------

guess_profile() {
  if [ -n "${DEVPOD:-}${DEVPOD_WORKSPACE_ID:-}" ]; then echo devpod
  elif [ "$(uname -s)" = Darwin ]; then echo mac
  else echo linux-dev; fi
}

load_state

if [ -n "$OPT_PROFILE" ]; then PROFILE="$OPT_PROFILE"
elif [ -n "$S_PROFILE" ] && { [ "$SYNC" = true ] || [ "$UPGRADE" = true ] || [ "$SELECT_TOOLS" = true ] || ! interactive; }; then
  PROFILE="$S_PROFILE"
elif [ "$SYNC" = true ] || [ "$UPGRADE" = true ]; then
  die "no saved profile yet: run ./install.sh first"
else
  say "dotfiles installer"
  PROFILE="$(choose_one "Select profile" "${S_PROFILE:-$(guess_profile)}" $PROFILES)"
fi
in_list "$PROFILE" "$PROFILES" || die "unknown profile: $PROFILE ($PROFILES)"
. "$REPO/installer/profiles/$PROFILE.sh"

same=false
[ "$PROFILE" = "$S_PROFILE" ] && same=true
if [ "$same" = true ]; then
  TOOLS="$S_TOOLS" RUNTIMES="$S_RUNTIMES" APPS="$S_APPS" NVIM="${S_NVIM:-$PROFILE_NVIM}"
  TMUX_VARIANT="${S_TMUX:-$PROFILE_TMUX}" PREFIX="${S_PREFIX:-$PROFILE_TMUX_PREFIX}"
  DOT="${S_DOT:-$PROFILE_DOT}" MODE="${S_MODE:-install}" CHECKOUT="${S_CHECKOUT:-$PROFILE_CHECKOUT}"
  AGENTS="${S_AGENTS:-false}"
else
  TOOLS="$PROFILE_TOOLS" RUNTIMES="$PROFILE_RUNTIMES" APPS="" NVIM="$PROFILE_NVIM"
  TMUX_VARIANT="$PROFILE_TMUX" PREFIX="$PROFILE_TMUX_PREFIX" DOT="$PROFILE_DOT" MODE=install
  CHECKOUT="$PROFILE_CHECKOUT" AGENTS=false  # agents: opt-in on every profile
fi
# First run on an ordinary full clone: keep it full unless --checkout sparse.
[ -z "$S_CHECKOUT" ] && [ -e "$REPO/.git" ] && ! is_sparse && CHECKOUT=full

if [ "$UPGRADE" = true ]; then
  [ "$PROFILE_PROVIDERS" = none ] && { say "tmux-only installs no packages"; exit 0; }
  . "$REPO/installer/lib/shell.sh"
  . "$REPO/installer/lib/upgrade.sh"
  [ "$PROFILE_PROVIDERS" = linux ] && apt_usable  # probe sudo once, before subshells
  run_upgrade $UPGRADE_NAMES
  [ -z "$FAILED" ] || die "partial failure:$FAILED"
  exit 0
fi

# Profile defaults that changed in the repo never override saved choices silently.
if [ "$same" = true ] && [ "$SYNC" = true ]; then
  new=""
  for id in $PROFILE_TOOLS; do in_list "$id" "$S_SEEN $TOOLS" || new="$new $id"; done
  if [ -n "$new" ]; then
    say "new $PROFILE defaults since your last selection:$new"
    for id in $new; do confirm "Add $id?" n && TOOLS="$TOOLS $id"; done
  fi
fi

ask_prefix() {
  local def="$PREFIX"
  case "$def" in C-a | C-b) ;; *) def=Custom ;; esac
  PREFIX="$(choose_one "tmux prefix" "$def" C-a C-b Custom)"
  if [ "$PREFIX" = Custom ]; then
    printf '? Custom prefix (tmux key, e.g. C-s or M-a) [%s]: ' "$S_PREFIX" >/dev/tty
    read -r PREFIX </dev/tty || PREFIX=""
    PREFIX="${PREFIX:-$S_PREFIX}"
  fi
}

ask=false
interactive && [ "$SYNC" != true ] && ask=true
if [ "$PROFILE" = tmux-only ]; then
  TOOLS=tmux RUNTIMES="" APPS="" NVIM=none TMUX_VARIANT=lite DOT=false AGENTS=false MODE=configure
  [ "$ask" = true ] && ask_prefix
elif [ "$ask" = true ]; then
  TOOLS="$(choose_many "Select tools" "$TOOLS" "$CLI_TOOLS $EXTRA_TOOLS")"
  if [ "$SELECT_TOOLS" != true ]; then
    RUNTIMES="$(choose_many "Language runtimes (mise, global defaults)" "$RUNTIMES" "$RUNTIMES_ALL")"
    [ -n "$PROFILE_APPS_ALLOWED" ] && APPS="$(choose_many "Mac apps (Homebrew casks)" "$APPS" "$PROFILE_APPS_ALLOWED")"
    in_list neovim "$TOOLS" && NVIM="$(choose_one "Neovim configuration" "$NVIM" default "lite (planned)")"
    if in_list tmux "$TOOLS"; then
      TMUX_VARIANT="$(choose_one "tmux configuration" "$TMUX_VARIANT" default lite)"
      ask_prefix
    fi
    d="$(choose_one "Install dot CLI helper?" "$([ "$DOT" = true ] && echo Yes || echo No)" Yes No)"
    [ "$d" = Yes ] && DOT=true || DOT=false
    d="$(choose_one "Install AI agent config + skills (agents repo)?" "$([ "$AGENTS" = true ] && echo Yes || echo No)" No Yes)"
    [ "$d" = Yes ] && AGENTS=true || AGENTS=false
    m="$(choose_one "Installation mode" "$([ "$MODE" = configure ] && echo "Configure only" || echo "Install + configure")" \
      "Install + configure" "Configure only")"
    [ "$m" = "Configure only" ] && MODE=configure || MODE=install
    if [ -z "$S_PROFILE" ] && [ -z "$S_WORK" ] && in_list git "$TOOLS"; then
      printf '? Work Git host, e.g. gitlab.example.com (Enter = none): ' >/dev/tty
      read -r WORK_HOST </dev/tty || WORK_HOST=""
      if [ -n "$WORK_HOST" ]; then
        printf '? Work Git email: ' >/dev/tty
        read -r WORK_EMAIL </dev/tty || WORK_EMAIL=""
      fi
    fi
  fi
fi
case "$PREFIX" in C-[a-z] | M-[a-z] | C-Space) ;; *) die "invalid tmux prefix: '$PREFIX' (C-x, M-x or C-Space)" ;; esac

[ -n "$OPT_TOOLS" ] && TOOLS="$OPT_TOOLS"
[ -n "$OPT_DOT" ] && DOT="$OPT_DOT"
[ -n "$OPT_AGENTS" ] && AGENTS="$OPT_AGENTS"
SAVED_MODE="$MODE"  # --configure-only applies to this run only
[ -n "$OPT_MODE" ] && MODE="$OPT_MODE"
[ -n "$OPT_CHECKOUT" ] && CHECKOUT="$OPT_CHECKOUT"
if [ "$PROFILE" = tmux-only ]; then
  [ "$DOT" = true ] && warn "the dot helper is not available on tmux-only"
  [ "$AGENTS" = true ] && warn "the agents repo is not available on tmux-only"
  DOT=false AGENTS=false TOOLS=tmux MODE=configure
fi
for id in $TOOLS; do in_list "$id" "$CLI_TOOLS $EXTRA_TOOLS" || die "unknown tool: $id"; done
for id in $RUNTIMES; do in_list "$id" "$RUNTIMES_ALL" || die "unknown runtime: $id"; done
for id in $APPS; do in_list "$id" "$PROFILE_APPS_ALLOWED" || die "app not allowed on $PROFILE: $id"; done
in_list neovim "$TOOLS" || NVIM=none
[ "$NVIM" = none ] && in_list neovim "$TOOLS" && NVIM=default
WORK_HOST="${WORK_HOST:-}" WORK_EMAIL="${WORK_EMAIL:-}"
[ -n "$WORK_HOST" ] && [ -z "$WORK_EMAIL" ] && { warn "no work email given; skipping the work identity"; WORK_HOST=""; }
case "$WORK_HOST" in *[!A-Za-z0-9.-]*) die "invalid work Git host: $WORK_HOST" ;; esac
case "$WORK_EMAIL" in *[!A-Za-z0-9.@_+-]*) die "invalid work Git email: $WORK_EMAIL" ;; esac

# --- review ----------------------------------------------------------------------

PLAN_MISE="" PLAN_PRESENT="" PLAN_BREW="" PLAN_CASKS="" PLAN_APT="" PLAN_MISE_SELF="" PLAN_UNSUPPORTED=""
[ "$PROFILE_PROVIDERS" = linux ] && apt_usable  # probe sudo once, before subshells
[ "$MODE" = install ] && plan_tools
# mise-owned tools that are already installed stay listed in mise's config.
if [ "$MODE" = configure ] && [ "$PROFILE_PROVIDERS" != none ]; then
  for id in $TOOLS; do
    case "$(tool_path "$id")" in */mise/*) PLAN_MISE="$PLAN_MISE $id" ;; esac
  done
  PLAN_MISE="$(echo $PLAN_MISE)"
fi

# Dependency: tools or runtimes provided by mise need mise itself (and its config).
if [ -n "$PLAN_MISE$RUNTIMES" ] && ! in_list mise "$TOOLS"; then
  TOOLS="$TOOLS mise"
  say "note: mise added to the tools (needed by:$([ -n "$PLAN_MISE" ] && echo " $PLAN_MISE") $RUNTIMES)"
  [ "$MODE" = install ] && plan_tools
fi

n_cli=0
for id in $TOOLS; do in_list "$id" "$CLI_TOOLS" && n_cli=$((n_cli + 1)); done
extras=""
for id in $EXTRA_TOOLS; do in_list "$id" "$TOOLS" && extras="$extras + $id"; done

step "Review installation"
[ -n "$S_PROFILE" ] && [ "$same" != true ] && say "  Profile change: $S_PROFILE -> $PROFILE (selections reset to $PROFILE defaults)"
say "  Profile:    $PROFILE"
say "  Checkout:   $CHECKOUT (currently $(is_sparse && echo sparse || echo full))"
say "  Shell:      $([ "$PROFILE_SHELL" = zsh ] && echo "zsh + Oh My Zsh + Starship" || echo "unmanaged")"
if [ "$PROFILE" = tmux-only ]; then say "  Tools:      none (~/.tmux.conf only)"; else say "  Tools:      $n_cli CLI$extras"; fi
[ -n "$RUNTIMES" ] && say "  Runtimes:   $RUNTIMES (mise)"
[ -n "$APPS" ] && say "  Apps:       $APPS"
say "  Neovim:     $NVIM    tmux: $TMUX_VARIANT ($PREFIX)"
say "  Dot helper: $([ "$DOT" = true ] && echo enabled || echo disabled)"
say "  Agents:     $([ "$AGENTS" = true ] && echo "$AGENTS_DIR (agent config + skills)" || echo disabled)"
say "  Mode:       $([ "$MODE" = install ] && echo "install + configure" || echo "configure only")"
if [ "$MODE" = install ]; then
  say "  Packages (missing only, nothing is upgraded):"
  say "    already installed:${PLAN_PRESENT:- none}"
  [ -n "$PLAN_BREW" ] && say "    brew install: $PLAN_BREW"
  [ -n "$PLAN_CASKS" ] && say "    brew install --cask: $PLAN_CASKS"
  [ -n "$PLAN_APT" ] && say "    apt-get install: $PLAN_APT$([ -n "$APT_SUDO" ] && echo " (sudo)" || true)"
  [ "$PLAN_MISE_SELF" = yes ] && say "    mise: $(apt_usable && echo "signed apt repository (mise.jdx.dev)" || echo "verified release -> ~/.local/bin")"
  [ -n "$PLAN_MISE$RUNTIMES" ] && say "    mise (global config): $PLAN_MISE $RUNTIMES"
  [ -n "$PLAN_UNSUPPORTED" ] && say "    NOT INSTALLABLE here (no allowed provider):$PLAN_UNSUPPORTED"
fi
has chezmoi || say "  Installer requirement: chezmoi ($( [ "$PROFILE_PROVIDERS" = mac ] || [ "$PROFILE_PROVIDERS" = mac-work ] && echo "brew" || echo "verified release -> ~/.local/bin"))"

if [ "$DRY_RUN" != true ] && ! confirm "Continue?" y; then say "aborted"; exit 1; fi

# --- apply -----------------------------------------------------------------------

# Backups may contain ~/.ssh/config or work identity data: owner-only.
if [ "$DRY_RUN" != true ]; then mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"; fi

step "Checkout"
apply_checkout "$CHECKOUT"

if [ "$MODE" = install ] && [ "$DRY_RUN" != true ]; then
  step "Packages"
  install_brew
  install_apt
  install_mise_self
fi

step "chezmoi"
if has chezmoi; then
  say "found $(command -v chezmoi)"
elif [ "$DRY_RUN" = true ]; then
  say "would install chezmoi"
elif [ "$PROFILE_PROVIDERS" = mac ] || [ "$PROFILE_PROVIDERS" = mac-work ]; then
  ensure_brew && HOMEBREW_NO_AUTO_UPDATE=1 brew install chezmoi || die "could not install chezmoi"
elif [ "$PROFILE" = linux-dev ] && has mise; then
  # linux-dev lists chezmoi in its mise config; run it through mise until then.
  mise install chezmoi@latest || die "could not install chezmoi with mise"
  chezmoi() { mise exec chezmoi@latest -- chezmoi "$@"; }
else
  install_chezmoi_verified || die "could not install chezmoi (verified release download)"
fi
[ "$DRY_RUN" = true ] || has chezmoi || die "chezmoi is not available after installing it"

step "Configuration"
if ! has chezmoi; then
  say "(dry run) no chezmoi: configuration preview skipped"
elif [ ! -f "$REPO/config/.chezmoiignore" ]; then
  say "(dry run) config/ is not checked out yet: configuration preview unavailable"
else
  for f in "${CZ_CONFIG%.toml}".yaml "${CZ_CONFIG%.toml}".json "${CZ_CONFIG%.toml}".jsonc; do
    [ -f "$f" ] && die "found $f: chezmoi.toml is the only supported config format here"
  done
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # Start from the existing config so [data.work] and hand-added keys are kept.
  [ -f "$CZ_CONFIG" ] && cp -p "$CZ_CONFIG" "$tmp/chezmoi.toml"
  write_state "$tmp/chezmoi.toml" || die "could not render the chezmoi config"
  state_changed=true
  [ -f "$CZ_CONFIG" ] && cmp -s "$CZ_CONFIG" "$tmp/chezmoi.toml" && state_changed=false
  changes="$(chezmoi --config "$tmp/chezmoi.toml" --source "$REPO" status --exclude=scripts 2>&1)" ||
    die "chezmoi status failed: $changes"
  if [ -z "$changes" ]; then
    say "configuration is up to date"
  else
    say "$changes"
    say "(inspect with: chezmoi diff)"
  fi
  # Existing files that would be replaced (and ~/.zshrc, see below).
  replace=""  # one path per line: paths can contain spaces
  # Managed dirs that are symlinks here: chezmoi would swap the link for an empty
  # dir (e.g. a linked ~/.ssh loses its keys), and backups would write through it.
  linked=""
  managed_dirs="$(chezmoi --config "$tmp/chezmoi.toml" --source "$REPO" managed --include=dirs 2>/dev/null)" || managed_dirs=""
  while read -r st path; do
    [ -n "$path" ] || continue
    [ -d "$HOME/$path" ] && [ ! -L "$HOME/$path" ] && continue  # dirs: only modes change
    if [ -L "$HOME/$path" ] && [ -d "$HOME/$path" ] && printf '%s\n' "$managed_dirs" | grep -qxF -- "$path"; then
      linked="$linked$path
"
      continue
    fi
    if [ -e "$HOME/$path" ] || [ -L "$HOME/$path" ]; then replace="$replace$path
"; fi
  done <<EOF
$changes
EOF
  [ -n "$replace" ] && say "existing files that will be replaced (backed up first):" && printf '%s' "$replace" | sed 's/^/  /'
  if [ -n "$linked" ]; then
    say "managed directories that are symlinks here (chezmoi would replace them with empty directories):"
    printf '%s' "$linked" | sed 's/^/  ~\//'
    say "make each a real directory (e.g. rm the link, mv its target there) and rerun"
  fi
  if [ "$DRY_RUN" = true ]; then
    say "(dry run) nothing changed"
  elif [ -n "$linked" ]; then
    fail "configuration not applied: symlinked managed directories"
  elif [ -n "$changes" ] && ! confirm "Apply these changes?" y; then
    say "configuration not applied"
  else
    backup_ok=true
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      mkdir -p "$BACKUP_DIR/$(dirname "$path")" && cp -pPR "$HOME/$path" "$BACKUP_DIR/$path" ||
        { fail "backup of ~/$path"; backup_ok=false; }
    done <<EOF
$replace
EOF
    [ -n "$replace" ] && say "backup: $BACKUP_DIR"
    if [ "$backup_ok" != true ]; then
      say "configuration not applied: a backup failed"
    else
      if [ "$state_changed" = true ]; then
        mkdir -p "$(dirname "$CZ_CONFIG")"
        if [ -f "$CZ_CONFIG" ]; then mkdir -p "$BACKUP_DIR"; cp -p "$CZ_CONFIG" "$BACKUP_DIR/chezmoi.toml"; fi
        write_state "$CZ_CONFIG" || die "could not write $CZ_CONFIG"
      fi
      [ -z "$changes" ] || chezmoi apply --force || fail "chezmoi apply"
    fi
  fi
fi

if [ "$MODE" = install ] && [ "$DRY_RUN" != true ]; then
  step "mise tools"
  install_mise_tools
fi

if [ "$PROFILE_SHELL" = zsh ] && [ "$DRY_RUN" = true ]; then
  step "Shell"
  say "(dry run) would ensure Oh My Zsh + plugins, the ~/.zshrc line and zsh as login shell"
elif [ "$PROFILE_SHELL" = zsh ]; then
  step "Shell"
  . "$REPO/installer/lib/shell.sh"
  setup_zsh
  in_list tmux "$TOOLS" && [ "$TMUX_VARIANT" = default ] && setup_tpm
fi

if [ "$AGENTS" = true ]; then
  step "Agents"
  if [ "$DRY_RUN" = true ]; then
    say "(dry run) would $([ -d "$AGENTS_DIR/.git" ] || echo "clone $AGENTS_URL to $AGENTS_DIR and ")run its install.sh"
  else
    # public HTTPS clone; ~/.gitconfig would rewrite it to SSH (see pgit in lib/shell.sh)
    [ -d "$AGENTS_DIR/.git" ] ||
      GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 git clone -q "$AGENTS_URL" "$AGENTS_DIR" ||
      fail "clone $AGENTS_URL"
    # links, then pinned skills; it asks before replacing a file (backups kept)
    [ -x "$AGENTS_DIR/install.sh" ] && { "$AGENTS_DIR/install.sh" sync || fail "agents install.sh"; }
  fi
fi

step "Done"
if [ -n "$FAILED" ]; then
  say "partial failure:$FAILED" >&2
  exit 1
fi
[ -n "$PLAN_UNSUPPORTED" ] && say "not installed (no allowed provider):$PLAN_UNSUPPORTED"
[ "$DRY_RUN" = true ] || say "Open a new shell (exec zsh) to load the configuration."
