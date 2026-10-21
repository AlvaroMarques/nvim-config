-- claudedoc: markdown skeleton + Claude-filled sidecar snippets.
-- Skeleton (doc.md) is never written by Claude. Snippets live in doc.snippets/,
-- doc.out.md is rendered from both. See bin/claudedoc.py for the file protocol.
local M = {}

local script = vim.fn.stdpath("config") .. "/bin/claudedoc.py"

-- per-session queue: Q[root] = { items = { {doc=, id=, force=, instr=}... }, job = <jobid|nil>, current = <id|nil> }
-- asks on one document (and on docs nested in its snippets) share a claude session,
-- so they run one at a time, in order. id "@doc" is a whole-document rewrite.
local Q = {}
local spinner, spin_i, spin_timer = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, 1, nil

local function q_of(path)
	Q[path] = Q[path] or { items = {} }
	return Q[path]
end

local function any_running()
	for _, q in pairs(Q) do
		if q.job then return true end
	end
	return false
end

local function spin_update()
	if any_running() then
		if not spin_timer then
			spin_timer = vim.fn.timer_start(100, function()
				spin_i = spin_i % #spinner + 1
				vim.cmd("redrawstatus")
			end, { ["repeat"] = -1 })
		end
	elseif spin_timer then
		vim.fn.timer_stop(spin_timer)
		spin_timer = nil
	end
	vim.cmd("redrawstatus")
end

local function is_out(path)
	return path:match("%.out%.md$") ~= nil
end

local function skeleton_of(path)
	return is_out(path) and (path:gsub("%.out%.md$", ".md")) or path
end

local function out_of(path)
	return is_out(path) and path or (path:gsub("%.md$", ".out.md"))
end

local function snippets_dir(path)
	return (skeleton_of(path):gsub("%.md$", ".snippets"))
end

-- outermost doc owning `path`: a doc inside X.snippets/ belongs to X.md (same
-- session); mirrors root_doc() in claudedoc.py
local function root_of(path)
	path = skeleton_of(path)
	for dir in path:gmatch("()%.snippets/") do -- left to right = outermost first
		local cand = path:sub(1, dir - 1) .. ".md"
		if vim.uv.fs_stat(cand) then return cand end
	end
	return path
end

-- state of a block id for one document: "running" | "queued" | nil
local function q_state(path, id)
	local q = Q[root_of(path)]
	if not q then return nil end
	if q.current and q.current.doc == path and q.current.id == id then return "running" end
	for _, it in ipairs(q.items) do
		if it.doc == path and it.id == id then return "queued" end
	end
	return nil
end

function ClaudeDocStatus()
	local parts = {}
	for _, q in pairs(Q) do
		if q.current then
			local s = q.current.id
			if #q.items > 0 then s = s .. " +" .. #q.items end
			parts[#parts + 1] = s
		end
	end
	if #parts == 0 then return "" end
	table.sort(parts)
	return spinner[spin_i] .. " claudedoc:" .. table.concat(parts, ",") .. " "
end

local function run(args, cb)
	local out, err = {}, {}
	vim.fn.jobstart({ "python3", "-I", script, unpack(args) }, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, d) out = d end,
		on_stderr = function(_, d) err = d end,
		on_exit = function(_, code)
			local o = table.concat(out, "\n"):gsub("%s+$", "")
			local e = table.concat(err, "\n"):gsub("%s+$", "")
			cb(code, o, e)
		end,
	})
end

local function run_sync(args)
	local r = vim.system({ "python3", "-I", script, unpack(args) }, { text = true }):wait()
	if r.code ~= 0 then
		vim.notify("claudedoc: " .. (r.stderr or ""), vim.log.levels.ERROR)
		return nil
	end
	return (r.stdout or ""):gsub("%s+$", "")
end

local function blocks(path)
	local o = run_sync({ "blocks", skeleton_of(path) })
	return o and vim.json.decode(o) or {}
end

local function linemap(path)
	local f = io.open(snippets_dir(path) .. "/.linemap")
	if not f then return {} end
	local s = f:read("*a"); f:close()
	local ok, m = pcall(vim.json.decode, s)
	return ok and m or {}
end

-- block under cursor in the SKELETON (by line range)
-- pick, among blocks on one line, the one whose [col, end_col) span holds `col`
-- (0-based byte column); fall back to the nearest span on that line.
local function pick_by_col(cands, col, lo, hi)
	if #cands == 1 then return cands[1] end
	local best, bestd
	for _, c in ipairs(cands) do
		local a, b = lo(c), hi(c)
		if col >= a and col < b then return c end
		local d = col < a and (a - col) or (col - b + 1)
		if not bestd or d < bestd then best, bestd = c, d end
	end
	return best
end

-- block under cursor; several inline asks may share a line, so use the column too
local function block_at_cursor()
	local path = vim.fn.expand("%:p")
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local by_id = {}
	for _, b in ipairs(blocks(path)) do by_id[b.id] = b end
	if is_out(path) then
		-- entries exactly on this rendered line (inline asks carry a column span)
		local on_line = {}
		for _, m in ipairs(linemap(path)) do
			if m[2] + 1 == row and m[4] then on_line[#on_line + 1] = m end
		end
		if #on_line > 0 then
			local m = pick_by_col(on_line, col, function(x) return x[4] end, function(x) return x[5] end)
			return by_id[m[3]]
		end
		-- otherwise nearest marker at or above row (fenced result spans several lines)
		local best
		for _, m in ipairs(linemap(path)) do
			if m[2] + 1 <= row then best = m end
		end
		return best and by_id[best[3]] or nil
	end
	local cands = {}
	for _, b in ipairs(blocks(path)) do
		if row >= b.line and row <= b["end"] then cands[#cands + 1] = b end
	end
	if #cands == 0 then return nil end
	return pick_by_col(cands, col, function(b) return b.col or 0 end, function(b) return b.end_col or math.huge end)
end

local function reload_out(path)
	local outp = out_of(path)
	local b = vim.fn.bufnr(outp)
	if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
		vim.api.nvim_buf_call(b, function() vim.cmd("silent! edit!") end)
	end
end

------------------------------------------------------------------ actions
function M.render()
	local path = skeleton_of(vim.fn.expand("%:p"))
	run({ "render", path }, function(code, _, e)
		if code ~= 0 then return vim.notify("claudedoc render: " .. e, vim.log.levels.ERROR) end
		reload_out(path)
	end)
end

-- <leader>cl : insert a fenced claude-command block (visual: wrap selection as prompt)
function M.new_block(visual)
	local path = skeleton_of(vim.fn.expand("%:p"))
	vim.cmd("silent! update")
	local id = run_sync({ "new-id", path }) or "c1"
	local open, close = "```claude-command id=" .. id, "```"
	if visual then
		-- '< '> are only set on leaving visual mode, so inside the mapping they
		-- still hold the previous selection; read the live one instead
		local s, e = vim.fn.line("v"), vim.fn.line(".")
		if s > e then s, e = e, s end
		vim.cmd("normal! \27")
		vim.api.nvim_buf_set_lines(0, e, e, false, { close })
		vim.api.nvim_buf_set_lines(0, s - 1, s - 1, false, { open })
		vim.api.nvim_win_set_cursor(0, { s, 0 })
	else
		local row = vim.api.nvim_win_get_cursor(0)[1]
		vim.api.nvim_buf_set_lines(0, row, row, false, { open, "", close })
		vim.api.nvim_win_set_cursor(0, { row + 2, 0 })
		vim.cmd("startinsert")
	end
end

-- <leader>cli : insert an inline [claude id=] marker at cursor
function M.new_inline()
	local path = skeleton_of(vim.fn.expand("%:p"))
	vim.cmd("silent! update")
	local id = run_sync({ "new-id", path }) or "c1"
	local marker = "[claude id=" .. id .. "] "
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { marker })
	vim.api.nvim_win_set_cursor(0, { row, col + #marker })
	vim.cmd("startinsert")
end

-- queue worker -------------------------------------------------------------
local function pump(root)
	local q = q_of(root)
	if q.job or #q.items == 0 then return end
	local it = table.remove(q.items, 1)
	local path = it.doc
	q.current = it
	local args = { "ask", path, it.id }
	if it.instr then args = { "rewrite", path, it.instr } end
	if it.force then table.insert(args, "--force") end
	local out, err = {}, {}
	q.job = vim.fn.jobstart({ "python3", "-I", script, unpack(args) }, {
		stdout_buffered = true, stderr_buffered = true,
		on_stdout = function(_, d) out = d end,
		on_stderr = function(_, d) err = d end,
		on_exit = function(_, code)
			q.job, q.current = nil, nil
			local o = table.concat(out, "\n"):match("^[^\n]*") or ""
			local ok, r = pcall(vim.json.decode, o)
			if code == 0 then
				vim.notify("claudedoc: " .. it.id .. " " .. (ok and r.result or "done"), vim.log.levels.INFO)
			elseif code == 130 or code == 143 then
				vim.notify("claudedoc: " .. it.id .. " cancelled", vim.log.levels.WARN)
			else
				vim.notify("claudedoc: " .. it.id .. " failed: " .. table.concat(err, "\n"):gsub("%s+$", ""), vim.log.levels.ERROR)
			end
			if it.instr then vim.cmd("silent! checktime") end -- rewrite edited skeleton + snippets
			reload_out(path)
			spin_update()
			pump(root)
		end,
	})
	vim.notify("claudedoc: asking " .. it.id .. " ...", vim.log.levels.INFO)
	spin_update()
end

local function enqueue(path, id, force, instr)
	local root = root_of(path)
	local q = q_of(root)
	local st = q_state(path, id)
	if st == "running" then return vim.notify("claudedoc: " .. id .. " already running", vim.log.levels.WARN) end
	if st == "queued" then return vim.notify("claudedoc: " .. id .. " already queued", vim.log.levels.WARN) end
	q.items[#q.items + 1] = { doc = path, id = id, force = force, instr = instr }
	if q.job then
		vim.notify(("claudedoc: queued %s (position %d)"):format(id, #q.items), vim.log.levels.INFO)
	end
	pump(root)
end

-- <leader>cld / clD : fill block under cursor (cache unless prompt changed / force); stacks
function M.do_it(force)
	local path = skeleton_of(vim.fn.expand("%:p"))
	vim.cmd("silent! wall")
	local b = block_at_cursor()
	if not b then return vim.notify("claudedoc: no claude block under cursor", vim.log.levels.WARN) end
	if b.status == "cached" and not force and not q_state(path, b.id) then
		-- nothing to do; still re-render so out.md is fresh
		M.render()
		return vim.notify("claudedoc: " .. b.id .. " cached (use <leader>clD to force)", vim.log.levels.INFO)
	end
	enqueue(path, b.id, force)
end

-- <leader>cla / clA : enqueue every missing/stale block (or all, forced)
function M.do_all(force)
	local path = skeleton_of(vim.fn.expand("%:p"))
	vim.cmd("silent! wall")
	local root, n = root_of(path), 0
	local q = q_of(root)
	for _, b in ipairs(blocks(path)) do
		if (force or b.status ~= "cached") and not q_state(path, b.id) then
			q.items[#q.items + 1] = { doc = path, id = b.id, force = force }
			n = n + 1
		end
	end
	if n == 0 then return vim.notify("claudedoc: nothing to fill (all cached)", vim.log.levels.INFO) end
	vim.notify(("claudedoc: queued %d block(s)"):format(n), vim.log.levels.INFO)
	pump(root)
end

-- <leader>clg : apply one instruction to the whole document (skeleton prose + snippets),
-- snapshotting first; queued like any ask
function M.rewrite()
	local path = skeleton_of(vim.fn.expand("%:p"))
	vim.ui.input({ prompt = "claudedoc, whole document: " }, function(instr)
		if not instr or instr:match("^%s*$") then return end
		vim.cmd("silent! wall")
		enqueue(path, "@doc", false, instr)
	end)
end

-- <leader>clu : restore a snapshot (taken before each rewrite and each restore)
function M.restore()
	local path = skeleton_of(vim.fn.expand("%:p"))
	local o = run_sync({ "snapshots", path })
	local snaps = o and vim.json.decode(o) or {}
	if #snaps == 0 then return vim.notify("claudedoc: no snapshots", vim.log.levels.INFO) end
	vim.ui.select(snaps, {
		prompt = "Restore to the state before",
		format_item = function(s) return os.date("%m-%d %H:%M:%S", s.time) .. "  " .. s.label end,
	}, function(choice)
		if not choice then return end
		vim.cmd("silent! wall")
		if run_sync({ "restore", path, choice.name }) then
			vim.cmd("silent! checktime")
			reload_out(path)
			vim.notify("claudedoc: restored " .. choice.name .. " (<leader>clu again to undo)", vim.log.levels.INFO)
		end
	end)
end

-- <leader>clx : cancel the running ask; <leader>clX : cancel running + drop the queue
function M.cancel(all)
	local path = skeleton_of(vim.fn.expand("%:p"))
	local q = Q[root_of(path)]
	if not q or (not q.job and #q.items == 0) then return vim.notify("claudedoc: nothing running", vim.log.levels.INFO) end
	if all then q.items = {} end
	if q.job then vim.fn.jobstop(q.job) end
end

-- <leader>clw : watch the live log of the block under cursor (or the running one)
function M.watch()
	local path = skeleton_of(vim.fn.expand("%:p"))
	local b = block_at_cursor()
	local cur = Q[root_of(path)] and Q[root_of(path)].current
	local id = b and b.id or (cur and cur.id)
	if not b and cur then path = cur.doc end
	if not id then return vim.notify("claudedoc: no block under cursor and nothing running", vim.log.levels.WARN) end
	local log = snippets_dir(path) .. "/" .. id .. ".log"
	vim.cmd("botright 15split")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "claudedoc-log"
	vim.api.nvim_buf_set_name(buf, "claudedoc://" .. id .. ".log")
	local win = vim.api.nvim_get_current_win()
	local function refresh()
		if not vim.api.nvim_buf_is_valid(buf) then return false end
		local lines = vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or { "(no log yet for " .. id .. ")" }
		local st = q_state(path, id)
		lines[#lines + 1] = st and ("── " .. st .. " ──") or "── idle ──"
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			vim.api.nvim_win_set_cursor(win, { #lines, 0 })
		end
		return true
	end
	refresh()
	local t
	t = vim.fn.timer_start(300, function()
		if not refresh() then vim.fn.timer_stop(t) end
	end, { ["repeat"] = -1 })
	vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() vim.fn.timer_stop(t) end })
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

-- <leader>clq : show the queue
function M.queue()
	local path = skeleton_of(vim.fn.expand("%:p"))
	local q = Q[root_of(path)]
	if not q or (not q.current and #q.items == 0) then return vim.notify("claudedoc: queue empty", vim.log.levels.INFO) end
	local function name(it)
		local where = it.doc ~= path and (" [" .. vim.fn.fnamemodify(it.doc, ":t") .. "]") or ""
		return it.id .. where .. (it.instr and (": " .. it.instr) or "")
	end
	local l = {}
	if q.current then l[#l + 1] = "running: " .. name(q.current) end
	for i, it in ipairs(q.items) do l[#l + 1] = ("%d. %s%s"):format(i, name(it), it.force and " (force)" or "") end
	vim.notify("claudedoc queue\n" .. table.concat(l, "\n"), vim.log.levels.INFO)
end

-- <leader>clt : toggle skeleton <-> rendered, cursor on the same block
function M.toggle()
	local path = vim.fn.expand("%:p")
	local row = vim.api.nvim_win_get_cursor(0)[1]
	vim.cmd("silent! update")
	local target, map
	if is_out(path) then
		target, map = skeleton_of(path), {}
		for _, m in ipairs(linemap(path)) do map[#map + 1] = { m[2] + 1, m[1] + 1 } end
	else
		run_sync({ "render", path })
		target, map = out_of(path), {}
		for _, m in ipairs(linemap(path)) do map[#map + 1] = { m[1] + 1, m[2] + 1 } end
	end
	-- piecewise mapping: offset from the nearest marker at or above the cursor
	local new_row, best = row, nil
	for _, m in ipairs(map) do
		if m[1] <= row and (not best or m[1] > best[1]) then best = m end
	end
	if best then new_row = best[2] + (row - best[1]) end
	vim.cmd("edit " .. vim.fn.fnameescape(target))
	local last = vim.api.nvim_buf_line_count(0)
	vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(new_row, last)), 0 })
end

-- <leader>cls : open the snippet for the block under cursor in a split
function M.open_snippet()
	local b = block_at_cursor()
	if not b then return vim.notify("claudedoc: no claude block under cursor", vim.log.levels.WARN) end
	local f = snippets_dir(vim.fn.expand("%:p")) .. "/" .. b.id .. ".md"
	vim.cmd("vsplit " .. vim.fn.fnameescape(f))
end

-- <leader>clb : list blocks + status in quickfix
function M.list()
	local path = skeleton_of(vim.fn.expand("%:p"))
	local items = {}
	for _, b in ipairs(blocks(path)) do
		items[#items + 1] = {
			filename = path, lnum = b.line, col = 1,
			text = string.format("[%s] %s (%s): %s", q_state(path, b.id) or b.status, b.id, b.kind, b.prompt:gsub("\n", " ")),
		}
	end
	vim.fn.setqflist({}, " ", { title = "claudedoc", items = items })
	vim.cmd("copen")
end

-- <leader>clL : link asks to an existing claude session (picker over recent sessions)
function M.link(shared)
	local path = skeleton_of(vim.fn.expand("%:p"))
	local o = run_sync({ "sessions", vim.fn.fnamemodify(root_of(path), ":h") })
	local sessions = o and vim.json.decode(o) or {}
	if #sessions == 0 then return vim.notify("claudedoc: no claude sessions for this dir", vim.log.levels.WARN) end
	vim.ui.select(sessions, {
		prompt = "Link claudedoc to session" .. (shared and " (shared)" or " (fork)"),
		format_item = function(s)
			return os.date("%m-%d %H:%M", s.mtime) .. "  " .. s.id:sub(1, 8) .. "  " .. s.prompt
		end,
	}, function(choice)
		if not choice then return end
		local args = { "link", path, choice.id }
		if shared then table.insert(args, "--shared") end
		local r = run_sync(args)
		if r then vim.notify("claudedoc: " .. r, vim.log.levels.INFO) end
	end)
end

function M.unlink()
	local r = run_sync({ "unlink", skeleton_of(vim.fn.expand("%:p")) })
	if r then vim.notify("claudedoc: unlinked", vim.log.levels.INFO) end
end

-- <leader>clh : help popup
local HELP = {
	"claudedoc  (skeleton doc.md -> doc.snippets/<id>.md -> doc.out.md)",
	"",
	"  ```claude-command id=foo        multi-line prompt block",
	"  ...prompt...",
	"  ```",
	"  text [claude id=bar] prompt [/claude] text   inline ([/claude] optional: EOL)",
	"",
	"  <leader>cl   (n)  new fenced block with fresh id",
	"  <leader>cl   (x)  wrap selection as the prompt of a new block",
	"  <leader>cli       new inline [claude id=] marker at cursor",
	"  <leader>cld       do it: fill block under cursor (cached unless prompt changed)",
	"  <leader>clD       do it, force regeneration",
	"                    (asks stack: one runs at a time per document, in order)",
	"  <leader>cla       queue all missing/stale blocks",
	"  <leader>clA       queue all blocks, forced",
	"  <leader>clw       watch live log of block under cursor (tools, text)",
	"  <leader>clq       show the queue",
	"  <leader>clx       cancel running ask      <leader>clX  cancel + drop queue",
	"  <leader>clg       instruction for the whole document (prose + snippets, prompts kept)",
	"  <leader>clu       restore a snapshot (one is taken before each clg and each restore)",
	"  <leader>clt       toggle skeleton <-> rendered (cursor on same block)",
	"  <leader>cls       open snippet of block under cursor in vsplit (hand-edit)",
	"  <leader>clb       quickfix list of blocks with status",
	"  <leader>clr       re-render (also on save of skeleton/snippet)",
	"  <leader>clL       link asks to an existing claude session (fork, safe)",
	"  <leader>clS       link asks to an existing claude session (shared)",
	"  <leader>clU       unlink session",
	"  <leader>clh       this help",
	"",
	"  docs inside X.snippets/ (opened via cls) use X.md's session and queue",
	"",
	"  env: CLAUDEDOC_FLAGS, CLAUDEDOC_MODEL        q / <Esc> closes",
}

function M.help()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, HELP)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	local w = 0
	for _, l in ipairs(HELP) do w = math.max(w, #l) end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor", style = "minimal", border = "rounded",
		width = w + 2, height = #HELP,
		row = math.floor((vim.o.lines - #HELP) / 2), col = math.floor((vim.o.columns - w) / 2),
		title = " claudedoc ", title_pos = "center",
	})
	for _, k in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", k, function() vim.api.nvim_win_close(win, true) end, { buffer = buf, nowait = true })
	end
end

------------------------------------------------------------------ setup
function M.setup()
	local grp = vim.api.nvim_create_augroup("claudedoc", { clear = true })
	vim.api.nvim_create_autocmd("FileType", {
		group = grp, pattern = "markdown",
		callback = function(ev)
			local function map(lhs, fn, desc, mode)
				vim.keymap.set(mode or "n", lhs, fn, { buffer = ev.buf, desc = "claudedoc: " .. desc })
			end
			map("<leader>cl", function() M.new_block(false) end, "new block")
			map("<leader>cl", function() M.new_block(true) end, "wrap selection as block", "x")
			map("<leader>cli", M.new_inline, "new inline marker")
			map("<leader>cld", function() M.do_it(false) end, "do it (cached)")
			map("<leader>clD", function() M.do_it(true) end, "do it (force)")
			map("<leader>cla", function() M.do_all(false) end, "do all")
			map("<leader>clA", function() M.do_all(true) end, "do all (force)")
			map("<leader>clt", M.toggle, "toggle skeleton/rendered")
			map("<leader>cls", M.open_snippet, "open snippet")
			map("<leader>clb", M.list, "list blocks")
			map("<leader>clr", M.render, "render")
			map("<leader>clL", function() M.link(false) end, "link to claude session (fork)")
			map("<leader>clS", function() M.link(true) end, "link to claude session (shared)")
			map("<leader>clU", M.unlink, "unlink session")
			map("<leader>clh", M.help, "help")
			map("<leader>clw", M.watch, "watch live log")
			map("<leader>clq", M.queue, "show queue")
			map("<leader>clx", function() M.cancel(false) end, "cancel running")
			map("<leader>clX", function() M.cancel(true) end, "cancel running + drop queue")
			map("<leader>clg", M.rewrite, "instruction for the whole document")
			map("<leader>clu", M.restore, "restore snapshot")
		end,
	})
	-- re-render when a skeleton or a snippet is saved (only if snippets dir exists)
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = grp, pattern = { "*.md" },
		callback = function(ev)
			local p = ev.file
			if is_out(p) then return end
			local d = p:match("^(.*)%.snippets/[^/]+%.md$")
			for _, skel in ipairs({ p, d and d .. ".md" }) do
				if vim.uv.fs_stat(snippets_dir(skel)) then
					run({ "render", skel }, function() reload_out(skel) end)
				end
			end
		end,
	})
	-- make the rendered file visibly read-only-ish
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = grp, pattern = "*.out.md",
		callback = function() vim.bo.modifiable = false; vim.bo.readonly = true end,
	})
end

return M
