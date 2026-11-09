# Tool catalog: one line per tool, read by installer/lib/providers.sh.
#   id        binary    brew       apt        mise
# "-" = not offered by that provider. Package ownership per profile is decided in
# provider_for (lib/providers.sh); this table only says what each provider calls it.
CLI_TOOLS="git curl jq fzf ripgrep fd zoxide mise tree yq eza delta bat lazygit starship direnv"
EXTRA_TOOLS="git-lfs tmux neovim"
RUNTIMES_ALL="go java maven python nodejs"

CATALOG='
git       git       git        git        -
curl      curl      curl       curl       -
jq        jq        jq         jq         jq
fzf       fzf       fzf        -          fzf
ripgrep   rg        ripgrep    ripgrep    ripgrep
fd        fd        fd         -          fd
zoxide    zoxide    zoxide     -          zoxide
mise      mise      mise       -          -
tree      tree      tree       tree       -
yq        yq        yq         -          yq
eza       eza       eza        -          eza
delta     delta     git-delta  -          delta
bat       bat       bat        -          bat
lazygit   lazygit   lazygit    -          lazygit
starship  starship  starship   -          starship
direnv    direnv    direnv     direnv     direnv
git-lfs   git-lfs   git-lfs    git-lfs    git-lfs
tmux      tmux      tmux       tmux       -
neovim    nvim      -          -          neovim
'
# apt "-": Ubuntu's package is missing, too old (fzf: no `fzf --zsh`) or renamed
# (fd -> fdfind, bat -> batcat), so Linux uses mise for it.

# Sparse-checkout directories (under config/dot_config) holding each tool's config.
tool_modules() {
  case "$1" in
    git) echo "config/dot_config/git config/private_dot_ssh" ;;
    lazygit | starship | mise | tmux) echo "config/dot_config/$1" ;;
    neovim) echo "config/dot_config/nvim" ;;
  esac
}

# Mac apps (Homebrew casks), offered on the Mac profiles only; none preselected.
MAC_APPS="kitty ghostty karabiner-elements leader-key mouseless keepassxc"
