# Managed work Mac: full checkout, every CLI tool from Homebrew (core formulae only),
# mise only for Neovim and language runtimes, no sudo.
PROFILE_CHECKOUT=full
PROFILE_SHELL=zsh
PROFILE_PROVIDERS=mac-work
PROFILE_TOOLS="$CLI_TOOLS $EXTRA_TOOLS"
PROFILE_RUNTIMES="go java maven nodejs"
PROFILE_NVIM=default
PROFILE_TMUX=default
PROFILE_TMUX_PREFIX=C-a
PROFILE_DOT=true
# Casks approved for the work Mac; edit to match your company's policy.
PROFILE_APPS_ALLOWED="kitty ghostty keepassxc"
PROFILE_MODULES=""
