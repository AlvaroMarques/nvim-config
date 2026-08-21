-- No OTel collector runs locally, so the service's exporter times out and
-- spams SEVERE into the REPL buffer. Standard OTel kill switch.
vim.env.OTEL_SDK_DISABLED = 'true'
vim.env.OTEL_LOGS_EXPORTER = 'none'
vim.env.OTEL_TRACES_EXPORTER = 'none'
vim.env.OTEL_METRICS_EXPORTER = 'none'

-- Start clojure-lsp when opening a .clj/.cljs/.cljc/.edn file
local capabilities = vim.lsp.protocol.make_client_capabilities()
local ok, cmp_lsp = pcall(require, 'cmp_nvim_lsp')
if ok then
  capabilities = vim.tbl_deep_extend('force', capabilities, cmp_lsp.default_capabilities())
end

-- project.clj first: Nubank services are Leiningen, and matching .git first
-- makes clojure-lsp index the whole checkout instead of the service
local root_dir = vim.fs.root(0, { 'project.clj', 'deps.edn', 'bb.edn', '.git' })

if vim.fn.executable('clojure-lsp') == 1 then
  vim.lsp.start({
    name = 'clojure-lsp',
    cmd = { 'clojure-lsp' },
    root_dir = root_dir,
    capabilities = capabilities,
  })
else
  vim.notify('clojure-lsp not found in PATH (brew install clojure-lsp/brew/clojure-lsp-native)', vim.log.levels.WARN)
end

-- LSP keybinds (buffer-local, only for clojure files)
local opts = { buffer = true, silent = true }
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, opts)
-- clean-ns, move-to-let, extract-function, add-missing-require
vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
-- Sort/prune the ns form -- the :clojure-lsp-clean-ns CI check. Kept off the
-- save path on purpose: it drops requires you have added but not yet used.
vim.keymap.set('n', '<leader>cn', function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = 'clojure-lsp' })[1]
  if not client then
    return vim.notify('clojure-lsp not attached', vim.log.levels.WARN)
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  client:request('workspace/executeCommand', {
    command = 'clean-ns',
    arguments = { vim.uri_from_bufnr(0), pos[1] - 1, pos[2] },
  })
end, opts)

-- Format on save. BufWritePre so it lands before the write; the global
-- FormatWriteLock on BufWritePost then only strips trailing whitespace.
vim.api.nvim_create_autocmd('BufWritePre', {
  buffer = 0,
  callback = function()
    vim.lsp.buf.format({ timeout_ms = 3000 })
  end,
})
