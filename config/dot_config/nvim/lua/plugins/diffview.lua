-- Also used as git mergetool: ~/.config/zsh/script/git-mergetool-diffview.sh
-- (it calls require("diffview").open(), which lazy.nvim loads on demand)
return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
  keys = {
    { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Diffview Open" },
    { "<leader>gV", "<cmd>DiffviewClose<cr>", desc = "Diffview Close" },
    { "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", desc = "Diffview File History" },
  },
}
