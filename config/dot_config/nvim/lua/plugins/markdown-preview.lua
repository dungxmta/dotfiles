return {
  {
    "folke/which-key.nvim",
    optional = true,
    opts = {
      spec = {
        { "<leader>m", group = "markdown-preview" },
      },
    },
  },
  {
    "iamcco/markdown-preview.nvim",
    ft = { "markdown" },
    keys = {
      {
        "<leader>mp",
        "<cmd>MarkdownPreviewToggle<cr>",
        desc = "Markdown Preview",
        ft = "markdown",
      },
      {
        "<leader>ms",
        "<cmd>MarkdownPreview<cr>",
        desc = "Start Markdown Preview",
        ft = "markdown",
      },
      {
        "<leader>mx",
        "<cmd>MarkdownPreviewStop<cr>",
        desc = "Stop Markdown Preview",
        ft = "markdown",
      },
    },
  },
}
