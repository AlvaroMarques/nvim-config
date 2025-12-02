return {
	"scalameta/nvim-metals",
	name = "metals",
	dependencies = {
		{
			"j-hui/fidget.nvim",
			opts = {},
		},
		{
			"mfussenegger/nvim-dap",
			config = function(self, opts) end,
		},
	},
	ft = { "scala", "sbt", "java" },
	opts = function()
		local metals_config = require("metals").bare_config()

		-- Example of settings
		metals_config.settings = {
			showImplicitArguments = true,
			excludedPackages = { "akka.actor.typed.javadsl", "com.github.swagger.akka.javadsl" },
		}

		-- *READ THIS*
		-- I *highly* recommend setting statusBarProvider to either "off" or "on"
		--
		-- "off" will enable LSP progress notifications by Metals and you'll need
		-- to ensure you have a plugin like fidget.nvim installed to handle them.
		--
		-- "on" will enable the custom Metals status extension and you *have* to have
		-- a have settings to capture this in your statusline or else you'll not see
		-- any messages from metals. There is more info in the help docs about this

		-- Example if you are using cmp how to make sure the correct capabilities for snippets are set
		metals_config.capabilities = require("cmp_nvim_lsp").default_capabilities()

		metals_config.on_attach = function(client, bufnr)
			require("metals").setup_dap()
			local opts = { noremap = true, silent = true, buffer = bufnr }
			vim.diagnostic.setqflist()
			vim.diagnostic.setqflist({ severity = "E" })
			vim.diagnostic.setqflist({ severity = "W" })

			vim.keymap.set("n", "gd", vim.lsp.buf.definition)
			vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
			vim.keymap.set("n", "gD", vim.lsp.buf.declaration)
			vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename)
		end

		metals_config.init_options = {
			projectRootPatterns = {
				"build.sbt",
			},
			statusBarProvider = "off",
		}

		return metals_config
	end,
	config = function(self, metals_config)
		local nvim_metals_group = vim.api.nvim_create_augroup("nvim-metals", { clear = true })
		vim.api.nvim_create_autocmd("FileType", {
			pattern = self.ft,
			callback = function()
				require("metals").initialize_or_attach(metals_config)
			end,
			group = nvim_metals_group,
		})
	end,
}
