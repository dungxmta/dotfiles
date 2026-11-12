-- Paste over a selection without yanking it, so the same text can be pasted again.
-- Overrides LazyVim's yanky extra for visual p only.
return {
  "gbprod/yanky.nvim",
  keys = {
    { "p", "<Plug>(YankyPutBefore)", mode = "x", desc = "Paste without yanking the selection" },
  },
}
