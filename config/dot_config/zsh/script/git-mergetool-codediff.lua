-- Sourced by git-mergetool-codediff.sh (nvim -S): opens CodeDiff's 3-way merge view for $MERGED.
-- CodeDiff saves unresolved blocks as BASE text without markers and always exits 0, so on close
-- write "ok" to $CODEDIFF_OK only when every block is resolved and the result is saved.
-- A block kept as BASE (<leader>cx) also counts as unresolved: `git add` it by hand instead.
-- Uses CodeDiff internals (v4.0.6); if they change, the check fails closed.
vim.api.nvim_create_autocmd("User", {
  pattern = "CodeDiffClose",
  once = true,
  callback = function(ev)
    local ok, resolved = pcall(function()
      local s = require("codediff.ui.lifecycle").get_session(ev.data.tabpage)
      local tracking = require("codediff.ui.conflict.tracking")
      if vim.bo[s.result_bufnr].modified then
        return false
      end
      for _, block in ipairs(s.conflict_blocks) do
        if tracking.is_block_active(s, block) then
          return false
        end
      end
      return true
    end)
    if ok and resolved then
      vim.fn.writefile({ "ok" }, vim.env.CODEDIFF_OK)
    end
  end,
})

vim.cmd.CodeDiff({ args = { "--exit-on-close", "merge", vim.env.MERGED } })
