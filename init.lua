require("controller")
vim.o.tabstop = 2
vim.o.shiftwidth = 2
vim.o.timeoutlen = 500

vim.o.statusline = "%f %m %r %= %{v:lua.ClaudeDocStatus()}%{v:lua.ClaudeSessionCount()} %l:%c"
