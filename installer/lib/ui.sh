# Prompts and output. Bash 3.2 compatible. Uses fzf when available, otherwise
# plain numbered prompts. Every prompt reads from /dev/tty so `curl | bash` works.

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# in_list <word> <space-separated list>
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# Interactive only when a terminal is attached and --yes was not given.
interactive() { [ "$ASSUME_YES" != true ] && [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; }

# confirm <question> [default y|n]: --yes answers the default "y" questions only.
confirm() {
  local q="$1" def="${2:-y}" a hint="[Y/n]"
  [ "$def" = n ] && hint="[y/N]"
  if ! interactive; then
    # no terminal: only --yes answers yes for the user
    [ "$def" = y ] && [ "$ASSUME_YES" = true ] && return 0
    [ "$ASSUME_YES" = true ] || warn "no terminal for: $q (rerun with --yes)"
    return 1
  fi
  printf '? %s %s ' "$q" "$hint" >/dev/tty
  read -r a </dev/tty || a=""
  [ -z "$a" ] && a="$def"
  case "$a" in [yY]*) return 0 ;; esac
  return 1
}

# choose_one <question> <default> <option...>: prints the chosen option.
# An option ending in " (planned)" is shown but cannot be chosen.
choose_one() {
  local q="$1" def="$2" opt i n a
  shift 2
  if ! interactive; then printf '%s\n' "$def"; return; fi
  if use_fzf; then
    a="$(for opt in "$@"; do printf '%s\n' "$opt"; done |
      fzf --height=~12 --reverse --no-multi --prompt="$q > " \
        --bind "load:pos($(_pos "$def" "$@"))" 2>/dev/tty)" || a="$def"
  else
    printf '? %s\n' "$q" >/dev/tty
    i=0
    for opt in "$@"; do
      i=$((i + 1))
      if [ "$opt" = "$def" ]; then printf '  > %d) %s\n' "$i" "$opt"; else printf '    %d) %s\n' "$i" "$opt"; fi
    done >/dev/tty
    printf '  number [Enter = %s]: ' "$def" >/dev/tty
    read -r n </dev/tty || n=""
    a="$def"
    if [ -n "$n" ]; then
      i=0
      for opt in "$@"; do i=$((i + 1)); [ "$i" = "$n" ] && a="$opt"; done
    fi
  fi
  case "$a" in *" (planned)") warn "$a is not available yet; keeping $def"; a="$def" ;; esac
  printf '%s\n' "$a"
}

_pos() {
  local def="$1" i=0 opt
  shift
  for opt in "$@"; do i=$((i + 1)); [ "$opt" = "$def" ] && { echo "$i"; return; }; done
  echo 1
}

# choose_many <question> <preselected list> <option list>: prints the chosen words.
choose_many() {
  local q="$1" sel="$2" opts="$3" opt i input n out
  if ! interactive; then echo $sel; return; fi
  if use_fzf; then
    # Tab toggles; the load action walks the list and toggles the preselected items.
    local act=""
    for opt in $opts; do
      if in_list "$opt" "$sel"; then act="${act}toggle+down+"; else act="${act}down+"; fi
    done
    # "(none)" comes last; choosing it (alone or with others) means no items.
    out="$(for opt in $opts "(none)"; do printf '%s\n' "$opt"; done |
      fzf --multi --height=~25 --reverse --prompt="$q > " --header='Tab: toggle  Enter: accept' \
        --bind "load:${act}first" 2>/dev/tty)" || { echo $sel; return; }
    case "$out" in *"(none)"*) out="" ;; esac
    echo $out
    return
  fi
  while :; do
    printf '? %s\n' "$q" >/dev/tty
    i=0
    for opt in $opts; do
      i=$((i + 1))
      if in_list "$opt" "$sel"; then printf '  %2d) [x] %s\n' "$i" "$opt"; else printf '  %2d) [ ] %s\n' "$i" "$opt"; fi
    done >/dev/tty
    printf '  toggle numbers (e.g. 1 3), a=all, n=none, Enter=accept: ' >/dev/tty
    read -r input </dev/tty || input=""
    case "$input" in
      "") break ;;
      a | A) sel="$opts" ;;
      n | N) sel="" ;;
      *)
        for n in $input; do
          i=0
          for opt in $opts; do
            i=$((i + 1))
            [ "$i" = "$n" ] || continue
            if in_list "$opt" "$sel"; then sel="$(list_without "$sel" "$opt")"; else sel="$sel $opt"; fi
          done
        done
        ;;
    esac
  done
  # keep catalog order
  out=""
  for opt in $opts; do in_list "$opt" "$sel" && out="$out $opt"; done
  echo $out
}

# fzf 0.36+ (load event) is used when present; otherwise numbered prompts.
use_fzf() {
  [ "${DOT_NO_FZF:-}" = 1 ] && return 1
  has fzf || return 1
  local v
  v="$(fzf --version 2>/dev/null | sed 's/[^0-9.].*//')"
  [ "${v%%.*}" -gt 0 ] 2>/dev/null && return 0
  v="${v#*.}"
  [ "${v%%.*}" -ge 36 ] 2>/dev/null
}

# list_without <list> <word...>
list_without() {
  local list="$1" w out=""
  shift
  for w in $list; do in_list "$w" "$*" || out="$out $w"; done
  echo $out
}

# Comma-separated list for chezmoi data ("-" = empty).
csv() { local s; s="$(echo $1 | tr ' ' ',')"; echo "${s:--}"; }
