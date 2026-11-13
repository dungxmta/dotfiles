return {
  "nvim-mini/mini.files",
  opts = {
    windows = {
      preview = true,
      width_focus = 30,
      width_preview = 60,
    },
    options = {
      -- Whether to use for editing directories
      -- Disabled by default in LazyVim because neo-tree is used for that
      use_as_default_explorer = true,
    },
  },
  keys = {
    {
      "<leader>fm",
      function()
        require("mini.files").open(vim.api.nvim_buf_get_name(0), true)
      end,
      desc = "Open mini.files (Directory of Current File)",
    },
    {
      "\\",
      function()
        -- in a CodeDiff tab: focus its Explorer, or hide it when already there (see codediff.lua)
        local action = vim.bo.filetype == "codediff-explorer" and "toggle" or "focus"
        local plug = "<Plug>(codediff-" .. action .. "-explorer)"
        if vim.fn.maparg(plug, "n") ~= "" then
          return vim.api.nvim_feedkeys(vim.keycode(plug), "m", false)
        end
        require("mini.files").open(vim.api.nvim_buf_get_name(0), true)
      end,
      desc = "Open mini.files / CodeDiff Explorer",
    },

    {
      "<leader>fM",
      function()
        require("mini.files").open(vim.uv.cwd(), true)
      end,
      desc = "Open mini.files (cwd)",
    },
  },
}
