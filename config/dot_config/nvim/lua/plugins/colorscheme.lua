return {
  {
    "rebelot/kanagawa.nvim",
    lazy = true,
    opts = {
      dimInactive = true, -- dim inactive window `:h hl-NormalNC`
      -- Remove gutter background
      colors = {
        theme = {
          all = {
            ui = {
              bg_gutter = "none",
            },
          },
        },
      },
      overrides = function(colors)
        local theme = colors.theme
        return {
          -- Transparent background
          NormalFloat = { bg = "none" },
          FloatBorder = { bg = "none" },
          FloatTitle = { bg = "none" },

          NormalDark = { fg = theme.ui.fg_dim, bg = theme.ui.bg_m3 },
          LazyNormal = { bg = theme.ui.bg_m3, fg = theme.ui.fg_dim },
          MasonNormal = { bg = theme.ui.bg_m3, fg = theme.ui.fg_dim },

          -- Dashboard (Snacks)
          SnacksDashboardDesc = { fg = theme.syn.identifier },
          SnacksDashboardFooter = { fg = theme.syn.comment },
          SnacksDashboardHeader = { fg = theme.vcs.removed },
          SnacksDashboardIcon = { fg = theme.ui.special },
          SnacksDashboardKey = { fg = theme.syn.special1 },
          SnacksDashboardSpecial = { fg = theme.syn.special1 },
          SnacksDashboardDir = { link = "Directory" },
        }
      end,
    },
  },
  -- Configure LazyVim to load theme
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "kanagawa-wave",
    },
  },
}
