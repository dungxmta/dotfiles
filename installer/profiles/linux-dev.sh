# Main Ubuntu development VM (Lima): the complete CLI environment, sparse checkout.
PROFILE_CHECKOUT=sparse
PROFILE_SHELL=zsh
PROFILE_PROVIDERS=linux
PROFILE_TOOLS="$CLI_TOOLS $EXTRA_TOOLS"
PROFILE_RUNTIMES="go java nodejs"
PROFILE_NVIM=default
PROFILE_TMUX=default
PROFILE_TMUX_PREFIX=C-b
PROFILE_DOT=true
PROFILE_APPS_ALLOWED=""
# Extra apt packages and config modules this VM always had.
PROFILE_APT_EXTRA="zsh ca-certificates unzip xz-utils build-essential podman podman-compose uidmap slirp4netns"
PROFILE_MODULES="config/dot_config/herdr config/dot_config/private_k9s config/dot_config/private_superfile config/dot_config/posting config/dot_config/private_dlv"
