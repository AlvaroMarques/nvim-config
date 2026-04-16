-- Portable scala-reader LSP setup
local home = vim.env.HOME
local repo_dir = home .. '/dev/misc/scala-reader'
local repo_url = 'https://github.com/AlvaroMarques/scala-reader.git'

-- Find uv on PATH
local uv_bin = vim.fn.exepath('uv')
if uv_bin == '' then
  vim.notify('scala-reader: uv not found in PATH, skipping LSP', vim.log.levels.WARN)
  return
end

-- Auto-clone if missing
if not vim.uv.fs_stat(repo_dir) then
  vim.fn.mkdir(home .. '/dev/misc', 'p')
  vim.notify('scala-reader: cloning repo to ' .. repo_dir .. '...', vim.log.levels.INFO)
  local result = vim.fn.system({ 'git', 'clone', repo_url, repo_dir })
  if vim.v.shell_error ~= 0 then
    vim.notify('scala-reader: clone failed: ' .. result, vim.log.levels.ERROR)
    return
  end
end

-- Start LSP
vim.lsp.start({
  name = 'scala_reader',
  cmd = { uv_bin, 'run', '--directory', repo_dir, 'python', '-m', 'scala_reader' },
  root_dir = vim.fs.root(0, { '.git', 'build.sbt', 'pom.xml' }),
})

-- LSP keybinds (buffer-local, only for scala files)
local opts = { buffer = true, silent = true }
vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)

-- Debug window: show cached files with option to clear cache
local function get_client()
  local clients = vim.lsp.get_clients({ name = 'scala_reader' })
  if #clients == 0 then
    vim.notify('scala-reader LSP not attached', vim.log.levels.WARN)
    return nil
  end
  return clients[1]
end

local function open_debug_window()
  local client = get_client()
  if not client then return end

  client:request('workspace/executeCommand', {
    command = 'scala-reader/listCache',
    arguments = {},
  }, function(err, result)
    vim.schedule(function()
      if err then
        vim.notify('Error fetching cache: ' .. tostring(err), vim.log.levels.ERROR)
        return
      end

      local lines = {
        ' scala-reader cache',
        ' ─────────────────────────────────────────',
        '',
      }

      if not result or #result == 0 then
        table.insert(lines, '  (empty — no files indexed)')
      else
        for i, entry in ipairs(result) do
          local path = entry.uri:gsub('^file://', '')
          local short = vim.fn.fnamemodify(path, ':~:.')
          table.insert(lines, string.format('  %d. %s  (%d symbols)', i, short, entry.symbols))
        end
      end

      table.insert(lines, '')
      table.insert(lines, ' ─────────────────────────────────────────')
      table.insert(lines, '  [c] Clear cache    [q/Esc] Close')

      -- Create floating window
      local width = 60
      for _, line in ipairs(lines) do
        if #line + 4 > width then width = #line + 4 end
      end
      local height = #lines

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].filetype = 'scala_reader_debug'

      local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        width = width,
        height = height,
        col = math.floor((vim.o.columns - width) / 2),
        row = math.floor((vim.o.lines - height) / 2),
        style = 'minimal',
        border = 'rounded',
        title = ' scala-reader ',
        title_pos = 'center',
      })

      local function close()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end

      vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true })
      vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true })

      vim.keymap.set('n', 'c', function()
        close()
        client:request('workspace/executeCommand', {
          command = 'scala-reader/clearCache',
          arguments = {},
        }, function()
          vim.schedule(function()
            vim.notify('scala-reader: cache cleared', vim.log.levels.INFO)
          end)
        end)
      end, { buffer = buf, nowait = true })
    end)
  end)
end

vim.api.nvim_create_user_command('ScalaReaderDebug', open_debug_window, { desc = 'Show scala-reader cache debug window' })
vim.keymap.set('n', '<leader>rd', open_debug_window, { buffer = true, desc = 'Scala Reader Debug' })
