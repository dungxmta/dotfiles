#! /bin/zsh
# script for "git mergetool" or in lazygit press "Shift+M"
# - use "cmd=<command>" directly in .gitconfig doesn't work, even set alias in shell
# - fix diffview.nvim lazy loaded
nvim -n -c "lua require(\"diffview\").open()" "$MERGE"

