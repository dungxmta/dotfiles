# dotfiles

My development environment, managed with chezmoi.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/dungxmta/dotfiles/main/bootstrap.sh | bash
```

Or clone it yourself:

```sh
# partial + sparse (what bootstrap.sh does; install.sh fetches only what your profile needs)
git clone --filter=blob:none --sparse https://github.com/dungxmta/dotfiles.git ~/dotfiles && ~/dotfiles/install.sh

# full checkout
git clone https://github.com/dungxmta/dotfiles.git ~/dotfiles && ~/dotfiles/install.sh
```

## Profiles

| Profile   | For                      | Checkout |
|-----------|--------------------------|----------|
| mac       | personal Mac             | full     |
| mac-work  | managed work Mac         | full     |
| linux-dev | main Ubuntu VM           | sparse   |
| devpod    | dev container            | sparse   |
| tmux-only | remote host, tmux config | sparse   |

## Usage

```sh
dot update            # pull and apply configuration
dot diff              # preview changes
dot edit ~/.zshrc     # edit a managed file
dot outdated          # what has a newer version
dot upgrade           # pick what to upgrade (or: dot upgrade fzf go, --all)
dot sync              # reconcile tools and modules
./install.sh          # change profile, tools or options
```

AI agent config and skills live in a separate repo,
[dungxmta/agents](https://github.com/dungxmta/agents); the installer asks
(default no) or takes `--with-agents`.

Plugin and pinned tool versions live in `installer/tools/pins.txt`;
commit it after `dot upgrade` changes it.

More: `dot help`, `./install.sh --help` (works without `dot`).
