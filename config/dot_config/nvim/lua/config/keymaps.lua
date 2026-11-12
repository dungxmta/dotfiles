-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set
local rm = vim.keymap.del
-- Silent keymap option
local opts = { silent = true }

-- delete default keymaps
rm("n", "<leader>l") -- <cmd>Lazy<cr>

-- custom keymaps
map("n", "<leader>zZ", "<cmd>Lazy<cr>", { desc = "Lazy" })

-- Paste over a selection without yanking it, so the same text can be pasted again
map("x", "p", "P", { remap = true, desc = "Paste without yanking the selection" })

-- Copy whole file content to clipboard with C-c
map("n", "<C-c>", ":%y+<CR>", opts)

-- Select all text in buffer with Alt-a
map("n", "<A-a>", "ggVG", { noremap = true, silent = true, desc = "Select all" })
