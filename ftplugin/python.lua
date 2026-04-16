-- Start pyright LSP when opening a .py file
local capabilities = vim.lsp.protocol.make_client_capabilities()
local ok, cmp_lsp = pcall(require, 'cmp_nvim_lsp')
if ok then
  capabilities = vim.tbl_deep_extend('force', capabilities, cmp_lsp.default_capabilities())
end

local root_dir = vim.fs.root(0, { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', '.git' })

-- Detect UV venv so pyright resolves installed packages
local function get_python_path(workspace)
  -- 1. Respect VIRTUAL_ENV if already set (e.g. `uv shell` or manual activation)
  local venv = vim.env.VIRTUAL_ENV
  if venv then
    return venv .. '/bin/python'
  end
  -- 2. Check for a .venv in the project root (uv default)
  if workspace then
    local venv_python = workspace .. '/.venv/bin/python'
    if vim.uv.fs_stat(venv_python) then
      return venv_python
    end
  end
  -- 3. Fallback to system python
  return 'python3'
end

vim.lsp.start({
  name = 'pyright',
  cmd = { 'pyright-langserver', '--stdio' },
  root_dir = root_dir,
  capabilities = capabilities,
  settings = {
    python = {
      pythonPath = get_python_path(root_dir),
      analysis = {
        autoSearchPaths = true,
        useLibraryCodeForTypes = true,
      },
    },
  },
})

-- LSP keybinds (buffer-local, only for python files)
local opts = { buffer = true, silent = true }
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
