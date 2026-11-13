-- Also used as git mergetool: ~/.config/zsh/script/git-mergetool-codediff.sh
-- Defaults already give side-by-side diffs, explorer auto-refresh and the bottom merge result pane.
--
-- Native keymaps (buffer-local in CodeDiff tabs, see g? for the full list):
--   ]c / [c                    next / prev hunk
--   ]f / [f                    next / prev file (explorer, history)
--   ]x / [x                    next / prev conflict
--   <leader>co / <leader>ct    accept ours (current) / theirs (incoming)
--   <leader>cb / <leader>cx    accept both / restore base
--   <leader>cO / <leader>cT    accept all ours / all theirs (<leader>cB / <leader>cX: all both / all base)
--   t                          toggle side-by-side / inline layout
--   g?                         keymap help
--   q                          close (in mergetool: quit nvim)
return {
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>gv", group = "git visual" },
      },
    },
  },
  {
    "esmuellert/codediff.nvim",
    cmd = "CodeDiff",
    keys = {
      { "<leader>gvd", "<cmd>CodeDiff<cr>", desc = "Diff Working Tree" },
      { "<leader>gvs", "<cmd>CodeDiff --staged<cr>", desc = "Diff Staged" },
      { "<leader>gvf", "<cmd>CodeDiff file HEAD<cr>", desc = "Diff File vs HEAD" },
      {
        "<leader>gvm",
        function()
          vim.cmd.CodeDiff({ args = { "merge", vim.fn.expand("%:p") } })
        end,
        desc = "Merge Conflicts (File)",
      },
      { "<leader>gvh", "<cmd>CodeDiff history<cr>", desc = "Git History" },
    },
  },
}
