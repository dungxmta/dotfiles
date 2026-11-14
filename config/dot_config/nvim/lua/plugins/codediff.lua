-- Also used as git mergetool: ~/.config/zsh/script/git-mergetool-codediff.sh
-- Defaults already give side-by-side diffs, explorer auto-refresh and the bottom merge result pane.
-- Keymaps below are CodeDiff's full table (buffer-local in CodeDiff tabs, g? for help); "*" marks a change.

-- Pick a branch, remote branch or tag (most recent first); <CR> with no match uses the typed text (sha, HEAD~3)
local function pick_rev(title, on_pick)
  Snacks.picker.pick({
    title = title,
    finder = "proc",
    cmd = "git",
    args = {
      "for-each-ref",
      "--sort=-committerdate",
      "--format=%(refname:short)",
      "refs/heads",
      "refs/remotes",
      "refs/tags",
    },
    cwd = Snacks.git.get_root(),
    transform = function(item)
      item.rev = item.text
    end,
    format = "text",
    preview = function(ctx)
      Snacks.picker.preview.cmd({ "git", "log", "--oneline", "--decorate", "--color", "-50", ctx.item.rev }, ctx)
    end,
    confirm = function(picker, item)
      local rev = item and item.rev or vim.trim(picker.input.filter.pattern)
      picker:close()
      if rev ~= "" then
        on_pick(rev)
      end
    end,
  })
end

-- Two picks, A (left) then B (right): sep nil runs "CodeDiff A B", "..." runs "CodeDiff A...B"
local function pick_two(sep)
  pick_rev("Base (left)", function(a)
    pick_rev("Compare " .. a .. " with (right)", function(b)
      vim.cmd.CodeDiff({ args = sep and { a .. sep .. b } or { a, b } })
    end)
  end)
end

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
      {
        "<leader>gdb",
        function()
          pick_rev("Diff working tree vs", function(rev)
            vim.cmd.CodeDiff({ args = { rev } })
          end)
        end,
        desc = "Diff vs Rev",
      },
      {
        "<leader>gdB",
        function()
          pick_rev("Diff working tree vs merge-base of", function(rev)
            vim.cmd.CodeDiff({ args = { rev .. "..." } })
          end)
        end,
        desc = "Diff vs Rev (merge-base)",
      },
      {
        "<leader>gdc",
        function()
          pick_two()
        end,
        desc = "Diff Two Revs",
      },
      {
        "<leader>gdC",
        function()
          pick_two("...")
        end,
        desc = "Diff Two Revs (merge-base)",
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
      -- Name the which-key "t" group (tl/tc) in every buffer CodeDiff shows; its User events fire before buffers swap in
      vim.api.nvim_create_autocmd("BufWinEnter", {
        callback = function(ev)
          local lifecycle = package.loaded["codediff.ui.lifecycle"]
          local ok, wk = pcall(require, "which-key")
          if ok and lifecycle and lifecycle.get_session(vim.api.nvim_get_current_tabpage()) then
            wk.add({ "t", group = "toggle", buffer = ev.buf })
          end
        end,
      })
    end,
    opts = {
      diff = {
        compact = true, -- fold unchanged regions by default; tc toggles
      },
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
          toggle_compact = "tc", -- * gc (frees comment)
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
