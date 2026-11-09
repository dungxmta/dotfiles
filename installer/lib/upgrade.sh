# `install.sh --outdated` / `--upgrade [names]` (and `dot outdated` / `dot upgrade`).
# One name space over every provider: Homebrew, mise, apt, and the repo pins in
# installer/tools/pins.txt. Bash 3.2 compatible.

# Rows: "name kind provider current latest key" per line.
#   kind      tool | runtime | plugin | pin
#   provider  brew | mise | apt | repo
#   key       what the upgrade step needs (package, tool, or the pins.txt line id)
ROWS=""
row() { ROWS="$ROWS$1 $2 $3 $4 $5 $6
"; }

collect_brew() {
  has brew || return 0
  local id pkgs="" name cur latest
  for id in $TOOLS; do
    [ "$(provider_for "$id")" = brew ] && pkgs="$pkgs $(catalog_field "$id" 3)"
  done
  pkgs="$pkgs $APPS"
  [ -n "$(echo $pkgs)" ] || return 0
  # "fzf (0.74.5) < 0.75.0"
  brew outdated --verbose $pkgs 2>/dev/null | while read -r name cur _ latest; do
    cur="${cur#(}" cur="${cur%)}"
    echo "$name tool brew $cur $latest $name"
  done
}

collect_mise() {
  has mise || return 0
  local name req cur latest
  # name requested current latest source; exact pins never show up here
  (cd / && mise outdated --global 2>/dev/null) | awk 'NR > 1 { print $1, $3, $4 }' |
    while read -r name cur latest; do
      case "$cur" in "" | *MISSING*) continue ;; esac
      echo "$name $(in_list "$name" "go java maven python node" && echo runtime || echo tool) mise $cur $latest $name"
    done
}

collect_apt() {
  [ "$PROFILE_PROVIDERS" = linux ] && has apt || return 0
  local id pkgs="" line name latest cur
  for id in $TOOLS; do
    [ "$(provider_for "$id")" = apt ] && pkgs="$pkgs $(catalog_field "$id" 4)"
  done
  [ -n "$pkgs" ] || return 0
  # "ripgrep/noble-updates 14.1.0-1 arm64 [upgradable from: 14.0.0-1]"
  apt list --upgradable 2>/dev/null | while read -r line; do
    name="${line%%/*}"
    in_list "$name" "$pkgs" || continue
    latest="$(echo "$line" | awk '{print $2}')"
    cur="$(echo "$line" | sed -n 's/.*upgradable from: \([^]]*\)].*/\1/p')"
    echo "$name tool apt $cur $latest $name"
  done
}

# Repo pins apply to the repo, so they are listed on every zsh profile.
collect_pins() {
  [ "$PROFILE_SHELL" = zsh ] || return 0
  local group a b c d head name
  while read -r group a b c d; do
    case "$group" in
      zsh | tmux) # a=dir b=repo c=commit
        head="$(pgit ls-remote "https://github.com/$b.git" HEAD 2>/dev/null | cut -f1)"
        [ -n "$head" ] || { warn "could not reach $b"; continue; }
        [ "$head" = "$c" ] || echo "${b##*/} plugin repo $(echo "$c" | cut -c1-7) $(echo "$head" | cut -c1-7) $c:$head"
        ;;
      mise) # a=name b=mise tool c=version d=os
        has mise || continue
        head="$(cd / && mise latest "$b" 2>/dev/null)"
        # a pin for the other OS shows as name@os (omp@linux on a Mac)
        name="$a"
        [ "$d" = all ] || [ "$d" = "$(uname -s | tr 'A-Z' 'a-z')" ] || name="$a@$d"
        [ -n "$head" ] && version_gt "$head" "$c" && echo "$name pin repo $c $head $a"
        ;;
    esac
  done <"$PINS"
}

# version_gt <a> <b>: a is a newer dotted version than b (never offer a downgrade).
version_gt() {
  local a="${1#v}" b="${2#v}"
  [ "$a" != "$b" ] &&
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)" = "$a" ]
}

collect_outdated() {
  say "checking brew, mise, apt and repo pins..."
  ROWS="$( { collect_brew; collect_mise; collect_apt; collect_pins; } | awk 'NF == 6')
"
  [ "$ROWS" = "
" ] && ROWS=""
}

print_rows() {
  printf '\n  %-22s %-8s %-6s %-14s %s\n' NAME KIND FROM CURRENT LATEST
  printf '%s' "$ROWS" | while read -r name kind prov cur latest key; do
    [ -n "$name" ] || continue
    printf '  %-22s %-8s %-6s %-14s %s%s\n' "$name" "$kind" "$prov" "$cur" "$latest" \
      "$([ "$prov" = repo ] && echo "   (repo pin)")"
  done
  echo
}

# upgrade_one <name kind provider current latest key>
upgrade_one() {
  local name="$1" kind="$2" prov="$3" cur="$4" latest="$5" key="$6" group dir repo sha
  printf '==> %-20s ' "$name"
  case "$prov" in
    brew) HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade "$key" >/dev/null && echo "brew upgrade $key" || fail "brew upgrade $key" ;;
    mise) (cd / && mise upgrade "$key" >/dev/null 2>&1) && echo "mise upgrade $key" || fail "mise upgrade $key" ;;
    apt)
      if apt_usable; then
        $APT_SUDO apt-get install -y -qq --only-upgrade "$key" >/dev/null && echo "apt upgrade $key" || fail "apt upgrade $key"
      else fail "apt upgrade $key (no root/sudo)"; fi
      ;;
    repo)
      if [ "$kind" = plugin ]; then
        sha="${key%%:*}" latest="${key#*:}"
        sed -i.bak "s/$sha/$latest/" "$PINS" && rm -f "$PINS.bak"
        echo "pin $(echo "$sha" | cut -c1-7) -> $(echo "$latest" | cut -c1-7)"
        # move the local checkout too, when this machine has it
        while read -r group dir repo _; do
          [ "${repo##*/}" = "$name" ] && [ -d "$HOME/$dir/.git" ] && pinned_checkout "$HOME/$dir" "$repo" "$latest" >/dev/null
        done <"$PINS"
      else
        # mise pin: rewrite the version, re-render the mise config, install it
        awk -v n="$key" -v v="$latest" '$1 == "mise" && $2 == n { sub($4, v) } { print }' "$PINS" >"$PINS.new" &&
          mv "$PINS.new" "$PINS" && echo "pin $cur -> $latest" || fail "pin $name"
        if has chezmoi && [ -f "$HOME/.config/mise/config.toml" ]; then
          chezmoi apply --force "$HOME/.config/mise/config.toml" && (cd / && mise install --yes >/dev/null 2>&1) ||
            fail "install $name $latest"
        fi
      fi
      ;;
  esac
}

# run_upgrade <names...>: names given -> those; --all -> everything; else pick.
run_upgrade() {
  local names="$*" pick="" name kind prov cur latest key missing=""
  collect_outdated
  if [ -z "$ROWS" ]; then say "everything is up to date"; return 0; fi
  print_rows
  [ "$OUTDATED_ONLY" = true ] && return 0
  if [ -n "$names" ]; then
    for name in $names; do
      printf '%s' "$ROWS" | awk -v n="$name" '$1 == n { f = 1 } END { exit !f }' && pick="$pick $name" || missing="$missing $name"
    done
    [ -n "$missing" ] && say "already up to date or unknown:$missing"
  elif [ "$UPGRADE_ALL" = true ]; then
    pick="$(printf '%s' "$ROWS" | awk '{ print $1 }')"
    confirm "Upgrade all $(echo $pick | wc -w | tr -d ' ') items?" y || return 0
  elif interactive; then
    pick="$(printf '%s' "$ROWS" | awk '{ print $1 }')"
    pick="$(choose_many "Select what to upgrade" "$pick" "$pick")"
  else
    say "pass names or --all to upgrade (dot upgrade <name>... | dot upgrade --all)"
    return 0
  fi
  [ -n "$(echo $pick)" ] || { say "nothing selected"; return 0; }
  [ "$DRY_RUN" = true ] && { say "(dry run) would upgrade:" $pick; return 0; }

  # here-doc, not a pipe: fail() must update FAILED in this shell
  while read -r name kind prov cur latest key; do
    [ -n "$name" ] && in_list "$name" "$pick" && upgrade_one "$name" "$kind" "$prov" "$cur" "$latest" "$key"
  done <<EOF
$ROWS
EOF

  if [ -n "$(git -C "$REPO" status --porcelain -- installer/tools/pins.txt 2>/dev/null)" ]; then
    say ""
    say "Repo pins changed; commit to share them with your other machines:"
    say "  installer/tools/pins.txt"
  fi
}
