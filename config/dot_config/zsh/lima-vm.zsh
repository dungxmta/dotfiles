# vm: Vagrant-like wrapper around Lima (limactl) with fzf pickers.
# Sourced from zshrc; only defines functions and completion, never touches VMs.
# Usage: vm help
#
# Config (set before sourcing or any time later):
#   LIMA_VM_TEMPLATE_DIRS  colon-separated dirs searched by `vm create` (*.yaml)
#   LIMA_VM_FZF_OPTS       extra fzf options for pickers and the dashboard
#   LIMA_VM_FORCE=1        load even if `vm` is already defined elsewhere

if [[ -z $_LIMA_VM_SOURCED && -z $LIMA_VM_FORCE ]] && (( $+aliases[vm] || $+functions[vm] || $+commands[vm] )); then
  print -u2 -r -- "lima-vm: 'vm' is already defined ($(whence -w vm)); not loading. Set LIMA_VM_FORCE=1 to override."
  return 1
fi
(( $+aliases[vm] )) && unalias vm
typeset -g _LIMA_VM_SOURCED=1

: ${LIMA_VM_TEMPLATE_DIRS:="$HOME/.config/lima/templates:${HOMEBREW_PREFIX:-/opt/homebrew}/share/lima/templates"}

# completion: completions/_vm next to this file
typeset -gU fpath
fpath=("${${(%):-%x}:A:h}/completions" $fpath)
autoload -Uz _vm
(( $+functions[compdef] )) && compdef _vm vm

typeset -g _LIMAVM_LEGEND='enter ssh · C-s start · C-d stop · C-r restart · C-e edit · C-o logs · A-c clone · A-x delete · esc quit · ↑↓/C-n C-p move'

# Detail view of one instance; runs in fzf's preview shell, so plain sh + limactl only.
typeset -g _LIMAVM_PREVIEW='limactl list --format '\''{{.Name}}  [{{.Status}}]
backend   {{.VMType}} / {{.Arch}}
cpus      {{.CPUs}}   memory {{.Config.Memory}}   disk {{.Config.Disk}}
ssh       127.0.0.1:{{.SSHLocalPort}}   protected {{.Protected}}
mounts{{range .Config.Mounts}}
  {{.Location}} -> {{.MountPoint}}  writable={{.Writable}}{{end}}
ports{{range .Config.PortForwards}}{{if not .Ignore}}
  127.0.0.1:{{.HostPort}} -> {{.GuestPort}}{{end}}{{end}}'\'' {1} 2>/dev/null
awk -v n=lima-{1} '\''$1 == "name=" n {f=1} f && /ip_address=/ {sub(/.*=/, ""); print "ip        " $0 " (dhcp lease)"; exit}'\'' /var/db/dhcpd_leases 2>/dev/null
echo; echo "── ha.stderr.log ──"
tail -n 15 "${LIMA_HOME:-$HOME/.lima}"/{1}/ha.stderr.log 2>/dev/null'

_limavm_err() { print -u2 -r -- "vm: $*" }

_limavm_deps() {
  local c
  for c in limactl "$@"; do
    (( $+commands[$c] )) || { _limavm_err "'$c' not found (brew install ${c/limactl/lima})"; return 127; }
  done
}

_limavm_home() { REPLY=${LIMA_HOME:-$HOME/.lima} }

_limavm_exists() {
  local REPLY; _limavm_home
  [[ -n $1 && -e $REPLY/$1/lima.yaml ]]
}

_limavm_state() { limactl list --format '{{.Status}}' "$1" 2>/dev/null }

_limavm_protected() { [[ $(limactl list --format '{{.Protected}}' "$1" 2>/dev/null) == true ]] }

_limavm_valid_name() {
  [[ $1 =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || { _limavm_err "invalid instance name '$1' (letters, digits, . _ -)"; return 1; }
}

_limavm_require() {
  _limavm_exists "$1" || { _limavm_err "no such instance '$1' (see: vm ls)"; return 1; }
}

# _limavm_confirm MSG — y/N from the terminal; no terminal means no.
_limavm_confirm() {
  local a
  print -n -u2 -r -- "$1 [y/N] "
  { read -r a </dev/tty } 2>/dev/null || { print -u2; return 1; }
  [[ $a == [yY]* ]]
}

# _limavm_confirm_name NAME MSG — the user must type NAME.
_limavm_confirm_name() {
  local a
  print -u2 -r -- "$2"
  print -n -u2 -r -- "Type '$1' to confirm: "
  { read -r a </dev/tty } 2>/dev/null || { print -u2; return 1; }
  [[ $a == "$1" ]] || { _limavm_err "confirmation did not match; aborted"; return 1; }
}

# _limavm_prompt MSG [DEFAULT] — sets REPLY.
_limavm_prompt() {
  local a
  print -n -u2 -r -- "$1${2:+ [$2]}: "
  { read -r a </dev/tty } 2>/dev/null || { print -u2; return 1; }
  REPLY=${a:-$2}
}

# Guest IPs from the vmnet DHCP leases (vzNAT); one file read, no guest access.
_limavm_ips() {
  typeset -gA _limavm_ip=()
  local f=/var/db/dhcpd_leases line name=
  [[ -r $f ]] || return 0
  for line in "${(@f)$(<$f)}"; do
    line=${line//[[:space:]]/}
    case $line in
      name=lima-*) name=${line#name=lima-} ;;
      ip_address=*) [[ -n $name && -z ${_limavm_ip[$name]} ]] && _limavm_ip[$name]=${line#ip_address=} ;;
      '}') name= ;;
    esac
  done
}

# _limavm_rows [running|stopped] — header + one aligned row per instance (name first),
# preferred state listed first. Returns 1 when there are no instances.
_limavm_rows() {
  emulate -L zsh
  local prefer=$1 raw line n st cpu mem disk arch vt ip w=4
  local -a names first rest
  local -A row_st row_cpu row_mem row_disk row_arch row_vt
  raw=$(limactl list --format $'{{.Name}}\t{{.Status}}\t{{.CPUs}}\t{{.Memory}}\t{{.Disk}}\t{{.Arch}}\t{{.VMType}}' 2>/dev/null)
  [[ -n $raw ]] || return 1
  _limavm_ips
  for line in "${(@f)raw}"; do
    IFS=$'\t' read -r n st cpu mem disk arch vt <<<"$line"
    names+=($n); (( ${#n} > w )) && w=${#n}
    row_st[$n]=$st row_cpu[$n]=$cpu row_arch[$n]=$arch row_vt[$n]=$vt
    row_mem[$n]=$(printf '%gG' $(( mem / 1073741824.0 )))
    row_disk[$n]=$(printf '%gG' $(( disk / 1073741824.0 )))
  done
  for n in $names; do
    if [[ -n $prefer && ${(L)row_st[$n]} == $prefer ]]; then first+=($n); else rest+=($n); fi
  done
  printf "%-${w}s  %-8s %3s %6s %6s  %-8s %-4s %s\n" NAME STATE CPU RAM DISK ARCH VM IP
  for n in $first $rest; do
    ip=-; [[ ${row_st[$n]} == Running ]] && ip=${_limavm_ip[$n]:--}
    printf "%-${w}s  %-8s %3s %6s %6s  %-8s %-4s %s\n" \
      $n ${row_st[$n]} ${row_cpu[$n]} ${row_mem[$n]} ${row_disk[$n]} ${row_arch[$n]} ${row_vt[$n]} $ip
  done
}

# _limavm_pick PROMPT [running|stopped] — fzf picker; sets REPLY to the instance name.
# Returns fzf's code on cancel (1 no match, 130 Esc/Ctrl-C) so callers do nothing.
_limavm_pick() {
  emulate -L zsh
  _limavm_deps fzf || return
  local rows sel
  rows=$(_limavm_rows "$2") || { _limavm_err "no Lima instances (create one: vm create)"; return 1; }
  sel=$(print -r -- "$rows" | fzf --prompt="$1> " --header-lines=1 --layout=reverse --height=~60% \
    --no-multi --preview="$_LIMAVM_PREVIEW" --preview-window=right,55%,wrap ${=LIMA_VM_FZF_OPTS}) || return
  REPLY=${sel%% *}
  [[ -n $REPLY ]]
}

# _limavm_target VAR PROMPT [prefer] NAME — use NAME if given, else pick.
_limavm_target() {
  local REPLY
  if [[ -n $4 ]]; then
    _limavm_require "$4" || return
    REPLY=$4
  else
    _limavm_pick "$2" "$3" || return
  fi
  : ${(P)1::=$REPLY}
}

# Starting a protected baseline writes to its disk; ask first.
_limavm_guard_baseline() {
  _limavm_protected "$1" || return 0
  _limavm_confirm "'$1' is a protected baseline; starting it changes its disk. Continue?"
}

_limavm_up() {
  local name; _limavm_target name start stopped "$1" || return
  [[ $(_limavm_state "$name") == Running ]] && { print -r -- "$name is already running"; return 0; }
  _limavm_guard_baseline "$name" || return 1
  limactl start "$name"
}

_limavm_down() {
  local name; _limavm_target name stop running "$1" || return
  [[ $(_limavm_state "$name") == Running ]] || { print -r -- "$name is not running"; return 0; }
  limactl stop "$name"
}

_limavm_restart() {
  local name; _limavm_target name restart running "$1" || return
  if [[ $(_limavm_state "$name") == Running ]]; then
    limactl restart "$name"
  else
    _limavm_guard_baseline "$name" || return 1
    limactl start "$name"
  fi
}

# vm ssh [NAME] [-- CMD...]
_limavm_ssh() {
  local name= arg
  local -a cmd
  while (( $# )); do
    arg=$1; shift
    if [[ $arg == -- ]]; then cmd=("$@"); break; fi
    [[ -z $name ]] && name=$arg || cmd+=("$arg")
  done
  _limavm_target name ssh '' "$name" || return
  local -a opts
  if [[ $(_limavm_state "$name") != Running ]]; then
    _limavm_confirm "$name is not running. Start it?" || return 1
    _limavm_guard_baseline "$name" || return 1
    opts=(--start)
  fi
  if (( $#cmd )); then
    limactl shell $opts "$name" "${cmd[@]}"
  else
    # plain `limactl shell` runs bash; open the user's login shell instead
    limactl shell $opts "$name" -- sh -c 's=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7); exec "${s:-/bin/sh}" -l'
  fi
}

_limavm_edit() {
  local name; _limavm_target name edit '' "$1" || return
  limactl edit "$name"
}

# vm logs [NAME] [ha|out|serial] [-f]
_limavm_logs() {
  local name= kind=ha follow= arg REPLY
  for arg; do
    case $arg in
      -f|--follow) follow=1 ;;
      ha|out|serial) kind=$arg ;;
      *) name=$arg ;;
    esac
  done
  _limavm_target name logs '' "$name" || return
  _limavm_home
  local dir=$REPLY/$name f
  case $kind in
    ha) f=$dir/ha.stderr.log ;;
    out) f=$dir/ha.stdout.log ;;
    serial) f=$dir/serialv.log; [[ -e $f ]] || f=$dir/serial.log ;;
  esac
  [[ -r $f ]] || { _limavm_err "no $kind log for $name ($f)"; return 1; }
  if [[ -n $follow ]]; then
    command tail -n 200 -f "$f"
  else
    command tail -n 200 "$f"
  fi
}

# vm create [NAME] [FILE.yaml|template:NAME]
_limavm_create() {
  local name=$1 src=$2 REPLY
  if [[ -z $src && ( $name == *.y(a|)ml || $name == template:* ) ]]; then
    src=$name; name=
  fi
  if [[ -z $src ]]; then
    _limavm_deps fzf || return
    local -a files
    local d
    for d in ${(s.:.)LIMA_VM_TEMPLATE_DIRS}; do
      files+=($d/*.y(a|)ml(N-.))
    done
    (( $#files )) || { _limavm_err "no templates in LIMA_VM_TEMPLATE_DIRS=$LIMA_VM_TEMPLATE_DIRS"; return 1; }
    src=$(print -rl -- $files | fzf --prompt='template> ' --layout=reverse --height=~60% \
      --preview='cat {}' --preview-window=right,60% ${=LIMA_VM_FZF_OPTS}) || return
  elif [[ $src != template:* && ! -r $src ]]; then
    _limavm_err "cannot read '$src'"; return 1
  fi
  if [[ -z $name ]]; then
    local def=${${src:t:r}#template:}
    _limavm_exists "$def" && def=
    _limavm_prompt "Instance name" "$def" || return
    name=$REPLY
  fi
  _limavm_valid_name "$name" || return
  _limavm_exists "$name" && { _limavm_err "instance '$name' already exists"; return 1; }
  limactl validate "$src" || return
  limactl create --name "$name" "$src" || return
  _limavm_confirm "Start $name now?" && limactl start "$name"
  return 0
}

# Host ports of non-ignored forwards as "host:guest" words.
_limavm_forwards() {
  limactl list --format '{{range .Config.PortForwards}}{{if not .Ignore}}{{if .HostPort}}{{.HostPort}}:{{.GuestPort}} {{end}}{{end}}{{end}}' "$@" 2>/dev/null
}

_limavm_port_busy() {
  command lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# _limavm_port_sets SRC — sets reply=(--set=... ...) moving SRC's fixed host ports to a free
# slot (host = 10000 + guest + slot*100, the lima-desktop Makefile convention; otherwise
# host + slot*100), avoiding every instance's configured ports and listening sockets.
_limavm_port_sets() {
  emulate -L zsh
  reply=()
  local -a fw used cand
  local p h g off s conv=1 ok
  fw=(${=$(_limavm_forwards "$1")})
  (( $#fw )) || return 0
  used=(${=$(_limavm_forwards)})
  used=(${used%%:*})
  off=
  for p in $fw; do
    h=${p%%:*} g=${p#*:}
    (( (h - g - 10000) % 100 == 0 && h - g >= 10000 && h - g <= 10900 )) || conv=0
  done
  for s in {0..20}; do
    (( conv && s > 8 )) && break
    (( !conv && s == 0 )) && continue
    cand=() ok=1
    for p in $fw; do
      h=${p%%:*} g=${p#*:}
      if (( conv )); then p=$(( 10000 + g + s * 100 )); else p=$(( h + s * 100 )); fi
      if (( ${used[(Ie)$p]} )) || _limavm_port_busy $p; then ok=0; break; fi
      cand+=($p)
    done
    (( ok )) || continue
    local i=1
    for p in $fw; do
      reply+=("--set=(.portForwards[] | select(.hostPort == ${p%%:*}) | .hostPort) = $cand[i]")
      print -u2 -r -- "  host port ${p%%:*} -> $cand[i] (guest ${p#*:})"
      (( i++ ))
    done
    return 0
  done
  _limavm_err "no free host-port slot found for $1's forwards"
  return 1
}

# vm clone [SRC] [DST]
_limavm_clone() {
  local src dst=$2 REPLY
  _limavm_target src 'clone from' stopped "$1" || return
  if [[ -z $dst ]]; then
    local def=${src%-base}-dev
    _limavm_exists "$def" && def=
    _limavm_prompt "New instance name" "$def" || return
    dst=$REPLY
  fi
  _limavm_valid_name "$dst" || return
  _limavm_exists "$dst" && { _limavm_err "instance '$dst' already exists"; return 1; }
  if [[ $(_limavm_state "$src") != Stopped ]]; then
    _limavm_confirm "$src must be stopped to clone. Stop it now?" || return 1
    limactl stop "$src" || return
  fi
  _limavm_home
  print -u2 -r -- "Source $src uses $(command du -sh "$REPLY/$src" 2>/dev/null | cut -f1) on disk (APFS clones share blocks until changed); $(command df -h "$REPLY" | awk 'NR==2 {print $4}') free."
  local -a reply sets
  _limavm_port_sets "$src" || return
  sets=("${reply[@]}")
  _limavm_confirm "Clone $src -> $dst?" || return 1
  limactl clone "$src" "$dst" "${sets[@]}" || return
  _limavm_confirm "Start $dst now?" && limactl start "$dst"
  return 0
}

# vm restore NAME --from BASE — swap NAME for a fresh clone of BASE, keeping NAME's host
# ports. The old NAME is renamed to NAME-bak-<timestamp>, never deleted.
_limavm_restore() {
  local name= base= arg
  while (( $# )); do
    arg=$1; shift
    case $arg in
      --from) base=$1; shift ;;
      --from=*) base=${arg#--from=} ;;
      *) name=$arg ;;
    esac
  done
  [[ -n $name && -n $base ]] || { _limavm_err "usage: vm restore NAME --from BASE"; return 2; }
  _limavm_require "$name" && _limavm_require "$base" || return
  [[ $name != "$base" ]] || { _limavm_err "refusing to restore '$name' onto itself"; return 1; }
  [[ $(_limavm_state "$base") == Stopped ]] || { _limavm_err "baseline '$base' must be stopped"; return 1; }
  local tmp=$name-restore-tmp bak=$name-bak-$(date +%Y%m%d-%H%M%S) p h g
  _limavm_exists "$tmp" && { _limavm_err "'$tmp' exists from an earlier attempt; remove it first (vm rm $tmp)"; return 1; }

  # map BASE's host port to NAME's host port for the same guest port
  local -A keep
  local -a sets
  for p in ${=$(_limavm_forwards "$name")}; do keep[${p#*:}]=${p%%:*}; done
  for p in ${=$(_limavm_forwards "$base")}; do
    h=${p%%:*} g=${p#*:}
    [[ -n ${keep[$g]} ]] && sets+=("--set=(.portForwards[] | select(.hostPort == $h) | .hostPort) = ${keep[$g]}")
  done

  _limavm_confirm_name "$name" "Restore '$name' from '$base'. Current '$name' is kept (stopped) as '$bak'." || return 1
  limactl clone "$base" "$tmp" "${sets[@]}" || return
  if [[ $(_limavm_state "$name") != Stopped ]]; then
    limactl stop "$name" || { _limavm_err "could not stop $name; new copy left as $tmp"; return 1; }
  fi
  limactl rename "$name" "$bak" || { _limavm_err "rename failed; $name untouched, new copy left as $tmp"; return 1; }
  if ! limactl rename "$tmp" "$name"; then
    limactl rename "$bak" "$name"
    _limavm_err "rename failed; $name restored, new copy left as $tmp"
    return 1
  fi
  print -r -- "Restored $name from $base. Previous state kept as $bak (delete when satisfied: vm rm $bak)."
  _limavm_confirm "Start $name now?" && limactl start "$name"
  return 0
}

_limavm_rm() {
  local name; _limavm_target name delete '' "$1" || return
  if _limavm_protected "$name"; then
    _limavm_err "'$name' is protected; run 'limactl unprotect $name' first if you really mean it"
    return 1
  fi
  limactl list "$name"
  if [[ $(_limavm_state "$name") == Running ]]; then
    _limavm_confirm "$name is running. Stop it before deleting?" || return 1
    limactl stop "$name" || return
  fi
  _limavm_confirm_name "$name" "This permanently deletes instance '$name' and its disk." || return 1
  limactl delete "$name"
}

_limavm_ps() {
  local rows
  rows=$(_limavm_rows) || { print -r -- "no Lima instances"; return 0; }
  print -r -- "$rows"
}

_limavm_dashboard() {
  emulate -L zsh
  _limavm_deps fzf || return
  local rows out query= key name rc
  local -a lines
  while true; do
    rows=$(_limavm_rows) || { _limavm_err "no Lima instances (create one: vm create)"; return 1; }
    out=$(print -r -- "$rows" | fzf --header-lines=1 --layout=reverse --no-multi --print-query \
      --query="$query" --prompt='vm> ' --header="$_LIMAVM_LEGEND" \
      --expect=ctrl-s,ctrl-d,ctrl-r,ctrl-e,ctrl-o,alt-c,alt-x \
      --preview="$_LIMAVM_PREVIEW" --preview-window=right,50%,wrap ${=LIMA_VM_FZF_OPTS})
    (( $? == 0 )) || return 0
    lines=("${(@f)out}")
    query=$lines[1] key=$lines[2] name=${lines[3]%% *}
    [[ -n $name ]] || continue
    case $key in
      '') _limavm_ssh "$name"; return ;;
      ctrl-s) _limavm_up "$name" ;;
      ctrl-d) _limavm_down "$name" ;;
      ctrl-r) _limavm_restart "$name" ;;
      ctrl-e) _limavm_edit "$name" ;;
      ctrl-o) _limavm_home; command less -R +G "$REPLY/$name/ha.stderr.log" ;;
      alt-c) _limavm_clone "$name" ;;
      alt-x) _limavm_rm "$name" ;;
    esac
    rc=$?
    if (( rc != 0 )) && [[ $key != ctrl-o ]]; then
      print -n -u2 "(exit $rc) press enter to return to the list "
      { read -r </dev/tty } 2>/dev/null
    fi
  done
}

_limavm_help() {
  cat <<'EOF'
vm — Lima VM manager (zsh functions around limactl)

  vm                         interactive dashboard
  vm ls [limactl list args]  list instances (limactl list)
  vm ps                      status table: name, state, cpu, ram, disk, arch, backend, ip
  vm up [NAME]               start (picker lists stopped first)
  vm down [NAME]             stop (picker lists running first)
  vm restart [NAME]          restart (starts if stopped)
  vm ssh [NAME] [-- CMD...]  login shell, or run CMD in the guest
  vm edit [NAME]             limactl edit
  vm create [NAME] [FILE.yaml|template:NAME]
                             create from YAML (validated first; never overwrites)
  vm clone [SRC] [DST]       clone a stopped instance, moving host ports to a free slot
  vm restore NAME --from BASE
                             replace NAME with a fresh clone of BASE; old NAME kept as NAME-bak-*
  vm logs [NAME] [ha|out|serial] [-f]
                             tail host-agent / serial logs
  vm rm [NAME]               delete (type the name to confirm; protected instances refused)
  vm help                    this help

Omitting NAME opens an fzf picker; Esc/Ctrl-C cancels without doing anything.

Dashboard keys:
  Enter ssh   Ctrl-S start   Ctrl-D stop   Ctrl-R restart   Ctrl-E edit
  Ctrl-O logs   Alt-C clone   Alt-X delete   Esc/Ctrl-C quit   ↑↓ or Ctrl-N/P move

Config: LIMA_VM_TEMPLATE_DIRS (colon-separated), LIMA_VM_FZF_OPTS
EOF
}

vm() {
  _limavm_deps || return
  local cmd=${1:-dash}
  (( $# )) && shift
  case $cmd in
    dash) _limavm_dashboard ;;
    ls|list) limactl list "$@" ;;
    ps|status) _limavm_ps ;;
    up|start) _limavm_up "$@" ;;
    down|stop|halt) _limavm_down "$@" ;;
    restart|reload) _limavm_restart "$@" ;;
    ssh|shell) _limavm_ssh "$@" ;;
    edit) _limavm_edit "$@" ;;
    create|new) _limavm_create "$@" ;;
    clone) _limavm_clone "$@" ;;
    restore) _limavm_restore "$@" ;;
    logs|log) _limavm_logs "$@" ;;
    rm|delete|destroy) _limavm_rm "$@" ;;
    help|-h|--help) _limavm_help ;;
    *) _limavm_err "unknown command '$cmd' (see: vm help)"; return 2 ;;
  esac
}
