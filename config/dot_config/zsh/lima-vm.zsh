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
    # plain `limactl shell` runs bash; open the user's login shell instead, with SHELL
    # matching it (limactl exports SHELL=/bin/bash, and tmux starts panes with $SHELL)
    limactl shell $opts "$name" -- sh -c 's=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7); s=${s:-/bin/sh}; SHELL=$s exec "$s" -l'
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

# vm clone [SRC] [DST] [--agent|--no-agent] — --agent forwards the Mac's SSH agent into the
# clone (git uses the Mac's keys while connected); without either flag it asks, default no.
_limavm_clone() {
  local src dst agent= arg REPLY
  local -a pos
  for arg; do
    case $arg in
      --agent) agent=true ;;
      --no-agent) agent=false ;;
      -*) _limavm_err "unknown option '$arg' (vm clone [SRC] [DST] [--agent|--no-agent])"; return 2 ;;
      *) pos+=("$arg") ;;
    esac
  done
  dst=$pos[2]
  _limavm_target src 'clone from' stopped "$pos[1]" || return
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
  if [[ -z $agent ]]; then
    agent=false
    _limavm_confirm "Use the Mac's SSH keys in $dst (agent forwarding)?" && agent=true
  fi
  sets+=("--set=.ssh.forwardAgent=$agent")
  limactl clone "$src" "$dst" "${sets[@]}" || return
  if _limavm_confirm "Start $dst now?"; then
    limactl start "$dst" && _limavm_set_password "$dst"
  else
    print -u2 -r -- "Before using it: vm up $dst && vm passwd $dst"
  fi
}

# vm agent [NAME] [on|off] — the Mac's SSH keys in the VM through agent forwarding; without
# on/off, show the setting. A running VM is restarted to apply it. Baselines are refused.
_limavm_agent() {
  local name=$1 want=$2 cur state
  [[ $name == (on|off) ]] && { want=$name; name=; }
  [[ -z $want || $want == (on|off) ]] || { _limavm_err "usage: vm agent [NAME] [on|off]"; return 2; }
  _limavm_target name 'agent forwarding of' '' "$name" || return
  cur=$(limactl list --format '{{.Config.SSH.ForwardAgent}}' "$name" 2>/dev/null)
  [[ $cur == true ]] && cur=on || cur=off
  if [[ -z $want || $want == $cur ]]; then
    print -r -- "$name: agent forwarding $cur"
    return 0
  fi
  _limavm_protected "$name" && { _limavm_err "'$name' is a protected baseline; set it on the clone instead"; return 1; }
  state=$(_limavm_state "$name")
  if [[ $state == Running ]]; then
    _limavm_confirm "$name is running; restart it to turn agent forwarding $want?" || return 1
    limactl stop "$name" || return
  fi
  limactl edit --tty=false "$name" --set ".ssh.forwardAgent=$([[ $want == on ]] && print true || print false)" || return
  [[ $state == Running ]] && { limactl start "$name" || return; }
  print -r -- "$name: agent forwarding $want"
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
  if _limavm_confirm "Start $name now?"; then
    limactl start "$name" && _limavm_set_password "$name"
  else
    print -u2 -r -- "Before using it: vm up $name && vm passwd $name"
  fi
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

# Characters never printed from guest names: controls and bidi overrides.
typeset -g _LIMAVM_BAD=$'[[:cntrl:]\u202a-\u202e\u2066-\u2069]'

# Paths that look like credentials (extended regex, matched in lower case against a
# full path). Used by the guest scan and again on the Mac by vm share.
typeset -g _LIMAVM_SECRET_RE='/\.(ssh|gnupg|aws|azure|kube|docker|password-store)/|/keyrings/|/\.config/(gh|glab-cli|gcloud|rclone)/|/\.m2/settings\.xml$|/\.claude/\.credentials\.json$|/\.codex/auth\.json$|/(\.netrc|\.git-credentials|\.pgpass|\.npmrc|\.pypirc|\.vault-token|\.env|\.env\.[^/]*|[^/]*\.(pem|key|p12|pfx|kdbx|tfstate)|id_[^/]*|\.?credentials[^/]*|ssh_host_[^/]*|[^/]*_history)$'

# sh -c SCRIPT _ PATH FOLLOW SCAN HOME_RELATIVE SECRET_RE — plain sh, runs on host and guest.
# Line 1: "dir|file SIZE_KB FILES SYMLINKS" or "missing" (FOLLOW=1 counts through links).
# Then "L rel -> target" for absolute or escaping symlinks (max 101 lines) and, with
# SCAN=1, "S perms size path" for files that look like credentials (max 1001 lines;
# GNU find/readlink/stat, so guest only). The scan always follows symlinks and matches
# the resolved path, so a link like kl -> .kube can't hide what it points to.
# Relative paths start at $HOME when HOME_RELATIVE=1.
typeset -g _LIMAVM_STAT='p=$1 L=
[ "$2" = 1 ] && L=-L
case $p in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac
[ "$4" = 1 ] && cd "$HOME"
case $p in /*) ;; *) p=$PWD/$p ;; esac
if [ -d "$p" ]; then k=dir; elif [ -e "$p" ] || [ -L "$p" ]; then k=file; else echo missing; exit 0; fi
echo "$k $(du $L -sk "$p" 2>/dev/null | cut -f1) $(find $L "$p" -type f 2>/dev/null | wc -l | tr -d " ") $(find "$p" -type l 2>/dev/null | wc -l | tr -d " ")"
find "$p" -type l 2>/dev/null | while IFS= read -r l; do
  t=$(readlink "$l")
  case $t in /*|..|../*|*/..|*/../*) echo "L ${l#"$p"/} -> $t" ;; esac
done | head -n 101
[ -n "$L" ] && find -L "$p" -type l 2>/dev/null | head -n 101 | while IFS= read -r l; do echo "B ${l#"$p"/}"; done
[ "$3" = 1 ] || exit 0
find -L "$p" -type f -exec readlink -f -- {} + 2>/dev/null | grep -iE -- "$5" | head -n 1001 | while IFS= read -r f; do
  echo "S $(stat -c "%A %s" "$f" 2>/dev/null) $f"
done'

# Password check inside the guest: the password comes on stdin, the hash never leaves.
# It guards against copying secrets out by mistake. It is no defence against a
# compromised guest, which can answer "ok" and read the password: use a VM-only one.
typeset -g _LIMAVM_PWCHECK='IFS= read -r pw
e=$(sudo -n getent shadow "$(id -un)" 2>/dev/null) || { echo nocheck; exit 0; }
h=$(printf "%s\n" "$e" | cut -d: -f2)
case $h in ""|"!"*|"*"*) echo nopass; exit 0 ;; esac
printf "%s\n" "$pw" | H=$h perl -e '\''$p = <STDIN>; chomp $p; print crypt($p, $ENV{H}) eq $ENV{H} ? "ok\n" : "bad\n"'\'''

# _limavm_split ARG — "NAME:PATH" sets reply=(NAME PATH); returns 1 for a host path
# (write a host path containing ":" as ./a:b).
_limavm_split() {
  [[ $1 == [A-Za-z0-9]*:* && ${1%%:*} != */* ]] || return 1
  reply=("${1%%:*}" "${1#*:}")
}

# _limavm_stat NAME PATH [FOLLOW] [SCAN] — sets reply=(KIND SIZE_KB FILES SYMLINKS),
# _limavm_links (risky symlinks) and _limavm_secrets (SCAN=1). Empty NAME means the host.
_limavm_stat() {
  local out l
  local -a lines
  if [[ -n $1 ]]; then
    # at most 1 MiB from the guest
    out=$(limactl shell --workdir / "$1" -- sh -c "$_LIMAVM_STAT" _ "$2" "${3:-0}" "${4:-0}" 1 "$_LIMAVM_SECRET_RE" 2>/dev/null |
      command head -c 1048576; exit $pipestatus[1]) || { _limavm_err "cannot read $1:$2"; return 1; }
  else
    out=$(command sh -c "$_LIMAVM_STAT" _ "$2" "${3:-0}" 0 0)
  fi
  lines=("${(@f)out}")
  # The guest's answer ends up in arithmetic, which can run code: accept digits only.
  reply=(${=lines[1]})
  [[ $lines[1] == missing ]] ||
    [[ $reply[1] == (dir|file) && $#reply == 4 && $reply[2] == <-> && $reply[3] == <-> && $reply[4] == <-> ]] ||
    { _limavm_err "unexpected answer about $2: ${(q)lines[1]}"; return 1; }
  # Names come from the guest: only ever printed, with control characters replaced.
  typeset -ga _limavm_links=() _limavm_broken=() _limavm_secrets=()
  for l in $lines[2,-1]; do
    l=${l//${~_LIMAVM_BAD}/?}
    case $l in
      'L '*) _limavm_links+=("${l#L }") ;;
      'B '*) _limavm_broken+=("${l#B }") ;;
      'S '*) _limavm_secrets+=("${l#S }") ;;
    esac
  done
}

# _limavm_set_password NAME — set the guest user's password (sudo, RDP, vm share of
# sensitive files). A fresh clone has none; typed into the guest's passwd, never stored.
_limavm_set_password() {
  local user try
  user=$(limactl shell --workdir / "$1" -- id -un) || return
  print -u2 -r -- "Set the password for '$user' in $1 (required: sudo, RDP, vm share of sensitive files)"
  for try in 1 2 3; do
    limactl shell --workdir / "$1" -- sudo passwd "$user" </dev/tty && return 0
  done
  _limavm_err "password not set; run: vm passwd $1"
  return 1
}

_limavm_passwd() {
  local name; _limavm_target name 'set password of' running "$1" || return
  _limavm_running "$name" || return
  _limavm_set_password "$name"
}

# _limavm_password NAME — ask for the guest user's password and check it in the guest.
_limavm_password() {
  local pw out try tty
  for try in 1 2 3; do
    # read -s only hides input on the shell's own terminal; turn echo off explicitly,
    # before the prompt so nothing typed early is shown
    tty=$(command stty -g </dev/tty 2>/dev/null) || return 1
    {
      command stty -echo </dev/tty
      print -n -u2 -r -- "Password of the user in $1: "
      IFS= read -r pw </dev/tty
    } always { out=$?; command stty "$tty" </dev/tty }
    print -u2
    (( out == 0 )) || return 1
    out=$(print -r -- "$pw" | limactl shell --workdir / "$1" -- sh -c "$_LIMAVM_PWCHECK" 2>/dev/null)
    case $out in
      ok) return 0 ;;
      nopass) _limavm_err "$1 has no user password; set one first (vm passwd $1)"; return 1 ;;
      bad) _limavm_err "wrong password" ;;
      *) _limavm_err "could not check the password in $1 (needs sudo and perl in the VM)"; return 1 ;;
    esac
  done
  return 1
}

_limavm_running() {
  [[ $(_limavm_state "$1") == Running ]] && return 0
  _limavm_confirm "$1 is not running. Start it?" || return 1
  _limavm_guard_baseline "$1" || return 1
  limactl start "$1"
}

_limavm_human() {
  if (( $1 >= 1048576 )); then printf '%.1f GB' $(( $1 / 1048576.0 ))
  elif (( $1 >= 1024 )); then printf '%.1f MB' $(( $1 / 1024.0 ))
  else printf '%d KB' $1; fi
}

# _limavm_list TITLE ITEM... — at most 100 items, then "+N more".
_limavm_list() {
  print -u2 -r -- "      $1"
  print -u2 -rl -- "        "${^@[2,101]}
  (( $# > 101 )) && print -u2 -r -- "        … +$(( $# - 101 )) more"
}

# _limavm_plan GUEST PATH SRC DST [EXISTS] [NOFOLLOW] — the warning shown before every
# copy: size, file and symlink counts, risky symlinks and (from a guest) the guest's own
# list of sensitive files. With symlinks it offers scp, which follows them, unless
# NOFOLLOW. Sets REPLY=rsync|scp and reply to the source's stat; 1 means no.
_limavm_plan() {
  local guest=$1 spath=$2 src=$3 dst=$4 exists=$5 nofollow=$6 follow=0 a
  while true; do
    _limavm_stat "$guest" "$spath" $follow ${guest:+1} || return
    [[ $reply[1] != missing ]] || { _limavm_err "no such file or folder: $src"; return 1; }
    print -u2 -r -- "vm: warning: copying $reply[1] $src$( (( follow )) && print ' (following symlinks)')"
    print -u2 -r -- "      size $(_limavm_human $reply[2]) · $reply[3] file(s) · $reply[4] symlink(s)"
    print -u2 -r -- "      -> $dst${exists:+ (already exists)}"
    if (( $#_limavm_links )); then
      if [[ -n $nofollow ]]; then
        _limavm_list "symlinks leaving the folder (all symlinks are removed on this Mac):" $_limavm_links
      elif (( follow )); then
        _limavm_list "symlinks leaving the folder (their targets are copied):" $_limavm_links
      else
        _limavm_list "symlinks leaving the folder (copied as links; on the other side they point there):" $_limavm_links
      fi
    fi
    (( $#_limavm_broken )) &&
      _limavm_list "broken symlinks (scp stops at the first one; answer N and use y instead):" $_limavm_broken
    if (( $#_limavm_secrets )); then
      print -u2 -r -- "vm: sensitive files reported by $guest ($#_limavm_secrets$( (( $#_limavm_secrets > 1000 )) && print '+')); names only:"
      _limavm_list "perms size path" $_limavm_secrets
    fi
    if [[ -z $nofollow ]] && (( !follow && reply[4] > 0 )); then
      print -n -u2 -r -- "Continue? [y = copy links as links / s = scp, follow links / N] "
      { read -r a </dev/tty } 2>/dev/null || { print -u2; return 1; }
      case $a in
        [yY]*) REPLY=rsync; break ;;
        [sS]*) follow=1; continue ;;
        *) return 1 ;;
      esac
    fi
    _limavm_confirm "Continue$( (( follow )) && print ' with scp')?" || return 1
    (( follow )) && REPLY=scp || REPLY=rsync
    break
  done
  return 0
}

# Guest paths reach a remote shell (rsync without --protect-args), so allow only plain
# characters; anything else is refused rather than quoted.
_limavm_guest_path_ok() {
  [[ $1 == [A-Za-z0-9._/~+@%,=-]## ]] && return 0
  _limavm_err "guest path '${(q)1}' has spaces or shell characters; rename it or use limactl copy"
  return 1
}

# _limavm_copy_flags KIND — sets reply to limactl copy flags for KIND and $REPLY.
# The backend is always explicit: "auto" falls back to scp, which follows symlinks.
_limavm_copy_flags() {
  reply=(--backend=$REPLY)
  [[ $1 == dir ]] && reply+=(-r)
}

# vm cp SRC NAME:DST — copy a file or folder from this Mac into a VM. Always shows size,
# file and symlink counts, then asks. Copies the other way: vm share.
_limavm_cp() {
  emulate -L zsh
  setopt extendedglob
  (( $# == 2 )) || { _limavm_err "usage: vm cp SRC NAME:DST (from a VM: vm share NAME:PATH)"; return 2; }
  local REPLY exists
  local -a reply d
  _limavm_split "$1" && { _limavm_err "copies from a VM go to the share folder: vm share $1"; return 2; }
  _limavm_split "$2" && d=("${reply[@]}") || { _limavm_err "DST must be NAME:PATH"; return 2; }
  _limavm_guest_path_ok "$d[2]" || return 1
  _limavm_require "$d[1]" && _limavm_running "$d[1]" || return
  _limavm_stat "$d[1]" "$d[2]" || return
  exists=${${reply[1]:#missing}:+1}
  _limavm_plan '' "$1" "$1" "$2" "$exists" || return 1
  _limavm_copy_flags $reply[1]
  limactl copy $reply -- "$1" "$2"
}

# The share folder: where vm share puts copies from VMs. No VM may mount it.
_limavm_share_dir() { REPLY=${${LIMA_VM_SHARE:-$HOME/WORKSPACE/vm/volume-share}/#\~/$HOME} }

# _limavm_realpath PATH — PATH with symlinks resolved, even if its end doesn't exist yet.
_limavm_realpath() {
  local p=${1%/} rest=
  while [[ -n $p && ! -e $p ]]; do rest=/${p:t}$rest; p=${p:h}; done
  REPLY=${p:A}$rest
}

# _limavm_share_init — create the share folder (700, not indexed by Spotlight); sets
# REPLY. Refuses when any VM mounts it, a folder above it or one inside it (compared
# with symlinks resolved and case folded, as APFS does), or when that can't be checked.
_limavm_share_init() {
  local share m out
  _limavm_share_dir; _limavm_realpath "$REPLY"; share=$REPLY
  out=$(limactl list --format '{{range .Config.Mounts}}{{.Location}}{{"\n"}}{{end}}' 2>/dev/null) ||
    { _limavm_err "cannot list the VMs' mounts, so the share folder can't be checked; refusing"; return 1; }
  for m in ${(f)out}; do
    _limavm_realpath "${m/#\~/$HOME}"; m=$REPLY
    if [[ ${(L)share} == ${(L)m} || ${(L)share} == ${(L)m}/* || ${(L)m} == ${(L)share}/* ]]; then
      _limavm_err "the share folder $share overlaps $m, which a VM mounts; set LIMA_VM_SHARE elsewhere"
      return 1
    fi
  done
  [[ -L ${share%/} ]] && { _limavm_err "the share folder $share is a symlink; refusing"; return 1; }
  command mkdir -p -m 700 -- "$share" && command chmod 700 "$share" || return
  [[ -e $share/.metadata_never_index ]] || : >"$share/.metadata_never_index"
  REPLY=$share
}

# _limavm_sanitize DIR ORIG — on this Mac, where the guest can't fake it: delete
# symlinks and special files in the staged copy DIR (_limavm_dropped); find sensitive
# files (_limavm_found) by name, matched against ORIG (the path in the guest) plus the
# path inside the copy, or by holding a private key; and disable the config of any
# folder shaped like a git repository (_limavm_gitdirs), since git commands run inside
# one would read it. Every scan fails closed: a folder find can't read is an error.
_limavm_sanitize() {
  local dir=$1 par=${2:h} f rel out
  typeset -ga _limavm_dropped=() _limavm_found=() _limavm_gitdirs=()
  out=$(command find "$dir" -mindepth 1 ! -type f ! -type d -print0) || return
  for f in ${(0)out}; do
    _limavm_dropped+=("${${f#$dir/}//${~_LIMAVM_BAD}/?}")
    command rm -f -- "$f" || return
  done
  out=$(command find "$dir" -type f -print0) || return
  for f in ${(0)out}; do
    rel=${f#$dir/}
    [[ ${(L):-/$par/$rel} =~ $_LIMAVM_SECRET_RE ]] && _limavm_found+=("${rel//${~_LIMAVM_BAD}/?}")
  done
  # -a: a NUL byte must not hide a key; -D skip: never open pipes or devices
  out=$(command grep -rlaE -D skip -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----|^PuTTY-User-Key-File-' "$dir")
  (( $? > 1 )) && return 1
  for f in ${(f)out}; do
    rel=${${f#$dir/}//${~_LIMAVM_BAD}/?}
    (( ${_limavm_found[(Ie)$rel]} )) || _limavm_found+=("$rel (private key)")
  done
  out=$(command find "$dir" -type f -name HEAD -print0) || return
  for f in ${(0)out}; do
    f=${f:h}
    [[ -d $f/objects && -d $f/refs && -f $f/config ]] || continue
    command mv -n -- "$f/config" "$f/config.disabled-by-vm-share" || return
    _limavm_gitdirs+=("${${f#$dir/}//${~_LIMAVM_BAD}/?}")
  done
}

# _limavm_undot DIR — rename every hidden entry below DIR to dot<name> (.envrc ->
# dot.envrc), deepest first, so configs that run code (.envrc, .git/hooks, .vscode…)
# stay inert. Sets REPLY to the count and _limavm_renamed to the new paths, relative
# to DIR, in renaming order.
_limavm_undot() {
  local f new out
  typeset -ga _limavm_renamed=()
  out=$(command find "$1" -mindepth 1 -depth -name '.*' -print0) || return
  for f in ${(0)out}; do
    new=${f:h}/dot${f:t}
    if [[ -e $new || -L $new ]]; then
      _limavm_err "cannot rename ${(q)f:t}: ${(q)new:t} exists next to it; nothing was copied"
      return 1
    fi
    command mv -n -- "$f" "$new" || return
    # parents are renamed later: record every hidden component under its final name
    _limavm_renamed+=("${(j:/:)${(@)${(s:/:)${new#$1/}}/#./dot.}}")
  done
  REPLY=$#_limavm_renamed
}

# vm share NAME:PATH — copy a file or folder from a VM into the share folder on this
# Mac (LIMA_VM_SHARE, default ~/WORKSPACE/vm/volume-share, as NAME/<time>-<name>/).
# The guest sends a plain tar stream, capped near the previewed size; bsdtar unpacks
# it into a private temp folder (it refuses .., absolute paths and writing through
# symlinks) without the guest's owners, ACLs, xattrs, flags or Mac metadata. There, on
# the Mac, the copy is made inert: symlinks and special files are deleted, hidden
# names become dot*, git configs are disabled, folders 700, files 600, and the
# quarantine flag is set. Sensitive files (as the VM reports them or as this Mac finds
# them) need the VM user's password.
# vm share [analyze] | open | restore-dots PATH — manage the share folder.
_limavm_share() {
  emulate -L zsh
  setopt extendedglob
  local -a reply
  if [[ $1 != *:* ]]; then
    _limavm_share_manage "$@"
    return
  fi
  local REPLY share tmp stage entry name gpath item stamp sens magic out
  integer guest_secrets ndots cap
  if ! { (( $# == 1 )) && _limavm_split "$1" }; then
    _limavm_err "usage: vm share NAME:PATH (to send files to a VM: vm cp)"
    return 2
  fi
  name=$reply[1] gpath=${reply[2]%%/##}
  item=${gpath:t}
  [[ -n $item && $item != (.|..|'~'|_from.txt|_dots.list) ]] ||
    { _limavm_err "cannot share '$1' (name a file or folder; _from.txt and _dots.list are reserved)"; return 1; }
  _limavm_guest_path_ok "$gpath" && _limavm_require "$name" || return
  _limavm_share_init || return
  share=$REPLY
  _limavm_running "$name" || return
  stamp=$(command date +%Y%m%d-%H%M%S)
  entry=$share/$name/$stamp-${item#.}
  _limavm_plan "$name" "$gpath" "$1" "$entry/" '' nofollow || return 1
  guest_secrets=$#_limavm_secrets
  # tar adds headers and padding; anything far beyond the preview is refused
  cap=$(( reply[2] * 1024 + reply[3] * 1536 + 10485760 ))
  tmp=$(command mktemp -d "${TMPDIR:-/tmp}/vm-share.XXXXXX") || return
  stage=$tmp/x
  {
    limactl shell --workdir / "$name" -- sh -c 'p=$1
      case $p in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac
      cd "$HOME" && case $p in /*) ;; *) p=$PWD/$p ;; esac
      cd "$(dirname "$p")" && exec tar -cf - -- "$(basename "$p")"' _ "$gpath" 2>/dev/null |
      command head -c $cap >"$tmp/stream.tar"
    if (( pipestatus[1] )) || (( $(command stat -f %z "$tmp/stream.tar") >= cap )); then
      _limavm_err "the copy failed (or $name sent more than it reported); nothing was copied"
      return 1
    fi
    # plain tar only: bsdtar would also unpack compressed or text (mtree) formats,
    # which can expand far beyond the cap
    magic=$(command dd if="$tmp/stream.tar" bs=1 skip=257 count=5 2>/dev/null)
    [[ $magic == ustar ]] || { _limavm_err "$name did not send a plain tar stream; nothing was copied"; return 1; }
    command mkdir -m 700 "$stage" &&
      command bsdtar -xf "$tmp/stream.tar" -C "$stage" --no-same-owner --no-same-permissions \
        --no-xattrs --no-acls --no-fflags --no-mac-metadata 2>/dev/null ||
      { _limavm_err "could not unpack the copy; nothing was copied"; return 1; }
    command rm -f "$tmp/stream.tar"
    # drop any ACL, then make sure a read-only folder can't protect what's inside it
    command chmod -RN "$stage" 2>/dev/null
    command chmod -R u+rwX "$stage" || return 1
    if (( $(command du -A -sk "$stage" | cut -f1) * 1024 > cap )); then
      _limavm_err "the copy unpacks to more than $name reported; nothing was copied"
      return 1
    fi
    _limavm_sanitize "$stage" "$gpath" || { _limavm_err "could not check the copy; nothing was copied"; return 1; }
    if (( $#_limavm_dropped )); then
      print -u2 -r -- "vm: removed from the copy on this Mac ($#_limavm_dropped):"
      _limavm_list "symlinks, pipes, devices" $_limavm_dropped
    fi
    if (( $#_limavm_gitdirs )); then
      print -u2 -r -- "vm: folders shaped like a git repository; their config was renamed to config.disabled-by-vm-share:"
      _limavm_list "folder" $_limavm_gitdirs
    fi
    [[ -e $stage/$item ]] || { _limavm_err "nothing left to copy"; return 1; }
    if (( $#_limavm_found || guest_secrets )); then
      if (( $#_limavm_found )); then
        print -u2 -r -- "vm: sensitive files found on this Mac ($#_limavm_found):"
        _limavm_list "path in the copy" $_limavm_found
      else
        print -u2 -r -- "vm: $name reported sensitive files (above) that this Mac can't see by name"
      fi
      _limavm_password "$name" || { _limavm_err "nothing was copied"; return 1; }
      sens=1
    fi
    _limavm_undot "$stage" || return 1
    ndots=$REPLY
    command find "$stage" -type d -exec chmod 700 {} + && command find "$stage" -type f -exec chmod 600 {} + || return 1
    # last line of defence: only plain files and folders, no hidden names, all readable
    out=$(command find "$stage" -mindepth 1 \( ! -type f ! -type d -o -name '.*' \) -print -quit) && [[ -z $out ]] ||
      { _limavm_err "the copy still holds links, special files or hidden names; nothing was copied"; return 1; }
    command xattr -r -w com.apple.quarantine "0081;$(printf %x $(command date +%s));vm share;" "$stage" ||
      { _limavm_err "could not set the quarantine flag; nothing was copied"; return 1; }
    [[ -L $share/$name ]] && { _limavm_err "$share/$name is a symlink; refusing"; return 1; }
    command mkdir -p -m 700 -- "$share/$name" || return 1
    while [[ -e $entry || -L $entry ]]; do entry=$entry+; done
    command mkdir -m 700 -- "$entry" || return 1
    [[ $item == .* ]] && item=dot$item
    command mv -n -- "$stage/$item" "$entry/" || return 1
    print -rl -- "from: $1" "copied: $(command date '+%F %T')" \
      "removed: $#_limavm_dropped symlink(s) or special file(s)" "renamed hidden: $ndots" \
      "git configs disabled: $#_limavm_gitdirs" \
      "sensitive: ${${sens:+yes, allowed with the VM password}:-no}" >"$entry/_from.txt" &&
    # exactly what was renamed, so restore-dots never unhides a name the VM chose
    print -rn -- ${(pj:\0:)_limavm_renamed} >"$entry/_dots.list" &&
    command chmod 600 "$entry/_from.txt" "$entry/_dots.list" ||
      { _limavm_err "copied, but could not write the record files in $entry"; return 1; }
  } always {
    command chmod -RN "$tmp" 2>/dev/null
    command chmod -R u+rwX "$tmp" 2>/dev/null
    command rm -rf -- "$tmp" || _limavm_err "could not remove the temp folder $tmp"
  }
  print -r -- "share: $entry/$item"
}

# vm share [analyze] | open | restore-dots PATH
_limavm_share_manage() {
  local REPLY
  _limavm_share_dir
  case ${1:-analyze} in
    analyze|ls) _limavm_share_analyze "${REPLY:A}" ;;
    open)
      [[ -d $REPLY ]] || { print -r -- "the share folder $REPLY is empty"; return 0; }
      command open -- "$REPLY" ;;
    restore-dots) _limavm_share_restore "${REPLY:A}" "$2" ;;
    *) _limavm_err "usage: vm share NAME:PATH | vm share [analyze | open | restore-dots PATH]"; return 2 ;;
  esac
}

# Preview every entry in the share folder, then offer to clean: all, older than N
# days, picked, none.
_limavm_share_analyze() {
  local share=$1 e a flags meta
  local -a entries picked
  local -A ages
  integer now days age size files
  entries=($share/*/*(N/))
  (( $#entries )) || { print -r -- "the share folder $share is empty"; return 0; }
  now=$(command date +%s)
  printf '%-45s %5s %9s %6s  %s\n' ENTRY AGE SIZE FILES FLAGS
  for e in $entries; do
    age=$(( (now - $(command stat -f %m -- "$e")) / 86400 ))
    ages[$e]=$age
    size=$(command du -sk -- "$e" | cut -f1)
    files=$(command find "$e" -type f ! -name _from.txt ! -name _dots.list | wc -l)
    flags=
    if [[ -r $e/_from.txt ]]; then
      meta=$(<$e/_from.txt)
      [[ $meta == *'sensitive: yes'* ]] && flags+='sensitive '
      [[ $meta == *'renamed hidden: '[1-9]* ]] && flags+='dot-renamed '
      [[ $meta == *'removed: '[1-9]* ]] && flags+='links-removed '
    fi
    printf '%-45s %4dd %9s %6d  %s\n' "${${e#$share/}//${~_LIMAVM_BAD}/?}" $age "$(_limavm_human $size)" $files "$flags"
  done
  print -r -- "total: $(command du -sh -- "$share" | cut -f1 | tr -d ' ') in $#entries entr$( (( $#entries == 1 )) && print y || print ies) ($share)"
  print -n -u2 -r -- "Clean? [a = all / o = older than N days / p = pick / N = none] "
  { read -r a </dev/tty } 2>/dev/null || { print -u2; return 0; }
  case $a in
    [aA]*) picked=($entries) ;;
    [oO]*)
      _limavm_prompt "Older than how many days" 7 || return 1
      [[ $REPLY == <-> ]] || { _limavm_err "not a number: $REPLY"; return 1; }
      days=$REPLY
      for e in $entries; do (( ages[$e] >= days )) && picked+=($e); done ;;
    [pP]*)
      _limavm_deps fzf || return
      picked=(${(f)"$(print -rl -- ${entries#$share/} | fzf --multi --prompt='clean> ' \
        --layout=reverse --height=~60% --header='Tab to mark, Enter to confirm' ${=LIMA_VM_FZF_OPTS})"})
      picked=($share/${^picked}) ;;
    *) return 0 ;;
  esac
  (( $#picked )) || { print -r -- "nothing to clean"; return 0; }
  print -rl -- "  "${^${picked#$share/}//${~_LIMAVM_BAD}/?}
  _limavm_confirm "Delete these $#picked entr$( (( $#picked == 1 )) && print y || print ies)?" || return 1
  command rm -rf -- $picked && command rmdir -- $share/*(N/^F) 2>/dev/null
  print -r -- "deleted $#picked"
}

# vm share restore-dots PATH — give back the hidden names that vm share renamed below
# PATH (inside the share folder; relative to it or to the current folder). Only names
# listed in the entry's _dots.list are restored.
_limavm_share_restore() {
  local share=$1 p rel entry f new
  local -a parts list todo
  if [[ -n $2 ]]; then
    [[ $2 == /* || -e $2 ]] && p=${2:A} || p=${${:-$share/$2}:A}
  fi
  [[ -n $p && $p == $share/*/* && -e $p ]] ||
    { _limavm_err "usage: vm share restore-dots PATH (an entry, or a path inside one, in $share)"; return 2; }
  parts=(${(s:/:)${p#$share/}})
  entry=$share/$parts[1]/$parts[2]
  [[ -r $entry/_dots.list ]] || { print -r -- "nothing to restore: $entry has no _dots.list"; return 0; }
  list=(${(0)"$(<$entry/_dots.list)"})
  rel=${p#$entry}; rel=${rel#/}
  for f in $list; do
    [[ -z $rel || $f == $rel || $f == $rel/* ]] && [[ -e $entry/$f || -L $entry/$f ]] && todo+=($f)
  done
  (( $#todo )) || { print -r -- "nothing to restore under $p"; return 0; }
  print -u2 -r -- "vm: hidden files can run code when you open the folder (.envrc, .git/hooks, .git/config, .vscode); a git config renamed to config.disabled-by-vm-share stays disabled."
  _limavm_list "to rename back ($#todo):" ${todo//${~_LIMAVM_BAD}/?}
  _limavm_confirm "Restore these names?" || return 1
  # the list is deepest first, so parents still have their dot names here
  for f in $todo; do
    new=${f:t}
    new=$entry/${f:h}/${new#dot}
    if [[ -e $new || -L $new ]]; then _limavm_err "skipped ${f//${~_LIMAVM_BAD}/?}: it exists"; continue; fi
    command mv -n -- "$entry/$f" "$new"
  done
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
  vm clone [SRC] [DST] [--agent|--no-agent]
                             clone a stopped instance, moving host ports to a free slot;
                             asks whether to use the Mac's SSH keys (agent forwarding)
  vm restore NAME --from BASE
                             replace NAME with a fresh clone of BASE; old NAME kept as NAME-bak-*
                             (clone and restore ask for the new VM's user password on start)
  vm passwd [NAME]           set the VM user's password (sudo, RDP, vm share of sensitive files)
  vm agent [NAME] [on|off]   use the Mac's SSH keys in the VM (agent forwarding); no on/off: show
  vm logs [NAME] [ha|out|serial] [-f]
                             tail host-agent / serial logs
  vm rm [NAME]               delete (type the name to confirm; protected instances refused)
  vm cp SRC NAME:DST         copy a file/folder into a VM (shows size, asks first); symlinks
                             stay links (rsync), or answer s to follow them (scp)
  vm share NAME:PATH         copy from a VM into the share folder, made inert on this Mac:
                             no symlinks, hidden names -> dot*, 700/600, quarantined;
                             sensitive files need the VM user's password
  vm share [analyze]         preview the share folder, then clean (all / older / pick)
  vm share open              open the share folder in Finder
  vm share restore-dots PATH give back hidden names vm share renamed (after review)
  vm help                    this help

Omitting NAME opens an fzf picker; Esc/Ctrl-C cancels without doing anything.

Dashboard keys:
  Enter ssh   Ctrl-S start   Ctrl-D stop   Ctrl-R restart   Ctrl-E edit
  Ctrl-O logs   Alt-C clone   Alt-X delete   Esc/Ctrl-C quit   ↑↓ or Ctrl-N/P move

Config: LIMA_VM_TEMPLATE_DIRS (colon-separated), LIMA_VM_FZF_OPTS,
        LIMA_VM_SHARE (default ~/WORKSPACE/vm/volume-share; must not be mounted into a VM)
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
    passwd|password) _limavm_passwd "$@" ;;
    agent) _limavm_agent "$@" ;;
    logs|log) _limavm_logs "$@" ;;
    rm|delete|destroy) _limavm_rm "$@" ;;
    cp|copy) _limavm_cp "$@" ;;
    share) _limavm_share "$@" ;;
    help|-h|--help) _limavm_help ;;
    *) _limavm_err "unknown command '$cmd' (see: vm help)"; return 2 ;;
  esac
}
