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
dot git               # SSH key + optional commit signing per git account
./install.sh          # change profile, tools or options
```

## Git keys and signing

Keys are made per machine and per account, never copied or committed; you
upload each public key in the browser. Signing is optional per account.

```
new machine
 │
 ├─1─ git clone https://github.com/dungxmta/dotfiles ~/dotfiles   # https: no key needed
 │    ~/dotfiles/install.sh                 # profile, work host/email (kept local)
 │
 ├─2─ dot git github                        # auth key → browser → ssh -T; sign? (optional)
 │
 ├─3─ git clone github:dungxmta/<private>   # ssh, key from step 2
 │
 └─4─ dot git work                          # auth key; sign? secretive | yubikey | key | none
      dot git --test                        # read-only check
```

Step 3 stays ssh: https for a private repo needs a token, and the gitconfig
deliberately doesn't rewrite `https://github.com/`, so step 1 works keyless.

`dot git sign <account> [method]` switches or renews signing later; it writes
only local files (`~/.config/git/signing-<account>`, `~/.ssh/git-signing-*`,
`~/.ssh/allowed_signers`), so no `chezmoi apply` is needed. In a Lima VM
started with `vm up --agent`, `secretive` and `yubikey` use the Mac's keys.
Details: `dot git --help`.

Leak guard: `.githooks/pre-commit` blocks commits that contain work data.
Setup and patterns: my private notes (`docs/dotfiles-leak-guard.md`).

AI agent config and skills live in a separate repo,
[dungxmta/agents](https://github.com/dungxmta/agents); the installer asks
(default no) or takes `--with-agents`.

Plugin and pinned tool versions live in `installer/tools/pins.txt`;
commit it after `dot upgrade` changes it.

More: `dot help`, `./install.sh --help` (works without `dot`).
