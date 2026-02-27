-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out, "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

-- Make sure to setup `mapleader` and `maplocalleader` before
-- loading lazy.nvim so that mappings are correct.
-- This is also a good place to setup other settings (vim.opt)
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Setup lazy.nvim
require("lazy").setup({
	spec = {
		-- import your plugins
		{ "rose-pine/neovim", name = "rose-pine" },
		{ "nvim-lua/plenary.nvim", name = "plenary" },
		{ "mhartington/formatter.nvim", name = "formatter" },
		{ "nvim-telescope/telescope.nvim", name = "telescope", tag = "0.1.8" },
		{
			"hrsh7th/nvim-cmp",
			event = "InsertEnter",
			dependencies = {
				{ "hrsh7th/cmp-nvim-lsp" },
				{ "hrsh7th/cmp-vsnip" },
				{ "hrsh7th/vim-vsnip" },
			},
		},
		{
			"folke/persistence.nvim",
			name = "persistence",
			event = "BufReadPre",
			opts = {
				{
					dir = vim.fn.stdpath("state") .. "/sessions/", -- directory where session files are saved
					need = 0,
					branch = false, -- use git branch to save session
				},
			},
		},
		require("controller.metals"),
	},
	install = { colorscheme = { "habamax" } },
	checker = {},
})
