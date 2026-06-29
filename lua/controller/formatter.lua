-- Utilities for creating configurations
local util = require("formatter.util")

local function black_or_hatch()
	local filepath = vim.api.nvim_buf_get_name(0)

	if vim.fn.executable("uv") == 1 then
		return {
			exe = "uv",
			args = { "run", "black", "-", "--fast", "--stdin-filename", filepath },
			stdin = true,
		}
	elseif vim.fn.executable("hatch") == 1 then
		return {
			exe = "hatch",
			args = { "run", "dev:black", "-", "--fast", "--stdin-filename", filepath },
			stdin = true,
		}
	elseif vim.fn.executable("black") == 1 then
		return {
			exe = "black",
			args = { "-", "--fast", "--stdin-filename", filepath },
			stdin = true,
		}
	else
		return nil
	end
end

local function prettier()
	return {
		exe = "npx",
		args = {
			"prettier",
			"--stdin-filepath",
			util.escape_path(util.get_current_buffer_file_path()),
		},
		stdin = true,
	}
end

local function clang_format()
	local filepath = util.get_current_buffer_file_path()

	if vim.fn.executable("clang-format-21") == 1 then
		return {
			exe = "clang-format-21",
			args = {
				"--assume-filename=" .. util.escape_path(filepath),
			},
			stdin = true,
		}
	elseif vim.fn.executable("clang-format") == 1 then
		return {
			exe = "clang-format",
			args = {
				"--assume-filename=" .. util.escape_path(filepath),
			},
			stdin = true,
		}
	else
		return nil
	end
end

-- Provides the Format, FormatWrite, FormatLock, and FormatWriteLock commands
require("formatter").setup({
	-- Enable or disable logging
	logging = true,

	-- Set the log level
	log_level = vim.log.levels.WARN,

	-- All formatter configurations are opt-in
	filetype = {
		lua = {
			require("formatter.filetypes.lua").stylua,

			function()
				if util.get_current_buffer_file_name() == "special.lua" then
					return nil
				end

				return {
					exe = "stylua",
					args = {
						"--search-parent-directories",
						"--stdin-filepath",
						util.escape_path(util.get_current_buffer_file_path()),
						"--",
						"-",
					},
					stdin = true,
				}
			end,
		},

		python = {
			black_or_hatch,
		},

		json = {
			function()
				return {
					exe = "jq",
					args = { "." },
					stdin = true,
				}
			end,
		},

		javascript = {
			function()
				return {
					exe = "js-beautify",
					args = { "-r" },
					stdin = false,
				}
			end,
		},

		typescript = {
			prettier,
		},

		typescriptreact = {
			prettier,
		},

		html = {
			prettier,
		},

		c = {
			clang_format,
		},

		cpp = {
			clang_format,
		},

		cuda = {
			clang_format,
		},

		sh = {
			require("formatter.filetypes.sh").shfmt,
		},

		-- Use the special "*" filetype for defining formatter configurations on any filetype
		["*"] = {
			require("formatter.filetypes.any").remove_trailing_whitespace,
		},
	},
})

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4

local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

augroup("__formatter__", { clear = true })

autocmd("BufWritePost", {
	group = "__formatter__",
	command = "FormatWriteLock",
})
