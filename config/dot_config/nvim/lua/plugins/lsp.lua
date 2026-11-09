return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      ["*"] = {
        -- stylua: ignore
        keys = {
        --   { "<leader>cl", function() Snacks.picker.lsp_config() end, desc = "Lsp Info" },
        --   { "<leader>cf", vim.lsp.buf.format, desc = "Code Format" },
        --   { "gd", vim.lsp.buf.definition, desc = "Goto Definition", has = "definition" },
        --   { "gr", vim.lsp.buf.references, desc = "References", nowait = true },
        { "gi", vim.lsp.buf.implementation, desc = "Goto Implementation", has = "implementationProvider" },
        -- { "gi", "<cmd>lua vim.lsp.buf.implementation()<CR>", desc = "Goto Implementation", has = "implementationProvider" },
        --   { "gy", vim.lsp.buf.type_definition, desc = "Goto T[y]pe Definition" },
        --   { "gD", vim.lsp.buf.declaration, desc = "Goto Declaration" },
        --   { "K", function() return vim.lsp.buf.hover() end, desc = "Hover" },
        --   { "gK", function() return vim.lsp.buf.signature_help() end, desc = "Signature Help", has = "signatureHelp" },
        --
        --   { "<c-k>", function() return vim.lsp.buf.signature_help() end, mode = "i", desc = "Signature Help", has = "signatureHelp" },
        --   { "<leader>ca", vim.lsp.buf.code_action, desc = "Code Action", mode = { "n", "x" }, has = "codeAction" },
        --   { "<leader>.", vim.lsp.buf.code_action, desc = "Code Actions" },
        --   { "<leader>cc", vim.lsp.codelens.run, desc = "Run Codelens", mode = { "n", "x" }, has = "codeLens" },
        --   { "<leader>cC", vim.lsp.codelens.refresh, desc = "Refresh & Display Codelens", mode = { "n" }, has = "codeLens" },
        --   { "<leader>cR", function() Snacks.rename.rename_file() end, desc = "Rename File", mode ={"n"}, has = { "workspace/didRenameFiles", "workspace/willRenameFiles" } },
        --   { "<leader>cr", vim.lsp.buf.rename, desc = "Rename", has = "rename" },
        --   { "<leader>cA", LazyVim.lsp.action.source, desc = "Source Action", has = "codeAction" },
        --   { "]]", function() Snacks.words.jump(vim.v.count1) end, has = "documentHighlight",
        --     desc = "Next Reference", enabled = function() return Snacks.words.is_enabled() end },
        --   { "[[", function() Snacks.words.jump(-vim.v.count1) end, has = "documentHighlight",
        --     desc = "Prev Reference", enabled = function() return Snacks.words.is_enabled() end },
        --   { "<a-n>", function() Snacks.words.jump(vim.v.count1, true) end, has = "documentHighlight",
        --     desc = "Next Reference", enabled = function() return Snacks.words.is_enabled() end },
        --   { "<a-p>", function() Snacks.words.jump(-vim.v.count1, true) end, has = "documentHighlight",
        --     desc = "Prev Reference", enabled = function() return Snacks.words.is_enabled() end },
        --   {
        --     "<leader>co",
        --     LazyVim.lsp.action["source.organizeImports"],
        --     desc = "Organize Imports",
        --     has = "codeAction",
        --     enabled = function(buf)
        --       local code_actions = vim.tbl_filter(function(action)
        --         return action:find("^source%.organizeImports%.?$")
        --       end, LazyVim.lsp.code_actions({ bufnr = buf }))
        --       return #code_actions > 0
        --     end
        --   },
        },
      },
    },
  },
}
