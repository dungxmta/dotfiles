-- Also used as git mergetool: ~/.config/zsh/script/git-mergetool-codediff.sh
-- Defaults already give side-by-side diffs, explorer auto-refresh and the bottom merge result pane.
-- Keymaps below are CodeDiff's full table (buffer-local in CodeDiff tabs, g? for help); "*" marks a change.
return {
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>gd", group = "git diff" },
      },
    },
  },
  {
    "esmuellert/codediff.nvim",
    cmd = "CodeDiff",
    keys = {
      { "<leader>gdd", "<cmd>CodeDiff<cr>", desc = "Diff Working Tree" },
      { "<leader>gds", "<cmd>CodeDiff --staged<cr>", desc = "Diff Staged" },
      { "<leader>gdf", "<cmd>CodeDiff file HEAD<cr>", desc = "Diff File vs HEAD" },
      {
        "<leader>gdm",
        function()
          vim.cmd.CodeDiff({ args = { "merge", vim.fn.expand("%:p") } })
        end,
        desc = "Merge Conflicts (File)",
      },
      { "<leader>gH", "<cmd>CodeDiff history<cr>", desc = "Git History" },
    },
    init = function()
      -- Explorer only (lazygit-style), via CodeDiff's own keys: <space> = "-" stage/unstage file, e = "gf" open file
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "codediff-explorer",
        callback = function(ev)
          local opts = { buffer = ev.buf, remap = true, nowait = true }
          vim.keymap.set("n", "<space>", "-", vim.tbl_extend("force", opts, { desc = "Stage/unstage file" }))
          vim.keymap.set("n", "e", "gf", vim.tbl_extend("force", opts, { desc = "Open file in editor" }))
        end,
      })
    end,
    opts = {
      keymaps = {
        view = {
          quit = "q",
          toggle_explorer = "<Plug>(codediff-toggle-explorer)", -- * <leader>b; "\" in mini-files.lua focuses/hides
          focus_explorer = "<Plug>(codediff-focus-explorer)", -- * <leader>e
          next_hunk = "]c",
          prev_hunk = "[c",
          next_file = "]f",
          prev_file = "[f",
          diff_get = "do",
          diff_put = "dp",
          open_in_prev_tab = "gf",
          close_on_open_in_prev_tab = false,
          toggle_stage = "-",
          toggle_staged_view = "<Tab>", -- * gS (lazygit <tab>)
          stage_hunk = "<leader>ghs", -- * <leader>hs, same keys as gitsigns
          unstage_hunk = "<leader>ghu", -- * <leader>hu
          discard_hunk = "<leader>ghr", -- * <leader>hr
          hunk_textobject = "ih",
          align_move = "gm",
          toggle_layout = "tl", -- * t (frees the t motion)
          toggle_compact = "tf", -- * gc (frees comment)
          show_help = "g?",
        },
        explorer = {
          select = "<CR>",
          hover = "K",
          refresh = "R",
          toggle_view_mode = "`", -- * i (lazygit)
          stage_all = "S",
          unstage_all = "U",
          restore = "d", -- * X (lazygit; asks to confirm)
          toggle_changes = "gu",
          toggle_staged = "gs",
          fold_open = "zo",
          fold_open_recursive = "zO",
          fold_close = "zc",
          fold_close_recursive = "zC",
          fold_toggle = "za",
          fold_toggle_recursive = "zA",
          fold_open_all = "zR",
          fold_close_all = "zM",
        },
        history = {
          select = "<CR>",
          toggle_view_mode = "`", -- * i (lazygit)
          refresh = "R",
          fold_open = "zo",
          fold_open_recursive = "zO",
          fold_close = "zc",
          fold_close_recursive = "zC",
          fold_toggle = "za",
          fold_toggle_recursive = "zA",
          fold_open_all = "zR",
          fold_close_all = "zM",
        },
        conflict = {
          accept_incoming = "<leader>ct", -- theirs (left)
          accept_current = "<leader>co", -- ours (right)
          accept_both = "<leader>cb",
          discard = "<leader>cx", -- keep base
          accept_all_incoming = "<leader>cT",
          accept_all_current = "<leader>cO",
          accept_all_both = "<leader>cB",
          discard_all = "<leader>cX",
          next_conflict = "]x",
          prev_conflict = "[x",
          diffget_incoming = "2do",
          diffget_current = "3do",
        },
      },
    },
  },
}
