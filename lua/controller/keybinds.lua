vim.g.mapleader = " "
vim.keymap.set("n", "<leader>pv", vim.cmd.Ex)

local telescope = require("telescope.builtin")
vim.keymap.set("n", "<leader>pf", telescope.find_files, { desc = "Telescope find files" })
vim.keymap.set("n", "<leader>pq", telescope.git_files, {})
vim.keymap.set("n", "<leader>ps", telescope.grep_string)
vim.keymap.set("n", "<leader>fp", function()
	vim.fn.setreg("+", vim.fn.expand("%:p:."))
end, { desc = "get file path" })
