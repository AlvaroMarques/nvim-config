require("controller")
tabstop=2
shiftwidth=2

vim.o.statusline = "%f %m %r %= %{v:lua.ClaudeSessionCount()} %l:%c"
