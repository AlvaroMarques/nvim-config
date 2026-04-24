-- Start rust-analyzer LSP
local capabilities = vim.lsp.protocol.make_client_capabilities()
local ok, cmp_lsp = pcall(require, 'cmp_nvim_lsp')
if ok then
  capabilities = vim.tbl_deep_extend('force', capabilities, cmp_lsp.default_capabilities())
end

local root_dir = vim.fs.root(0, { 'Cargo.toml', '.git' })

vim.lsp.start({
  name = 'rust-analyzer',
  cmd = { 'rust-analyzer' },
  root_dir = root_dir,
  capabilities = capabilities,
})

-- LSP keybinds (buffer-local, only for rust files)
local opts = { buffer = true, silent = true }
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, opts)
vim.keymap.set('n', '<leader>ooo', function()
  vim.lsp.buf.code_action({
    context = { only = { 'quickfix' } },
    apply = true,
  })
end, opts)

-- Format with rustfmt on save and reload the buffer
vim.api.nvim_create_autocmd('BufWritePost', {
  buffer = 0,
  callback = function()
    local filepath = vim.fn.expand('%:p')
    vim.fn.jobstart({ 'rustfmt', '--edition', '2021', filepath }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.schedule(function()
            vim.cmd('checktime')
          end)
        end
      end,
    })
  end,
})
