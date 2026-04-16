local last_count = 0

local function get_claude_count()
	local handle = io.popen("ps aux | grep '[c]laude' | wc -l | tr -d ' \\n'")
	if not handle then
		return 0
	end
	local result = handle:read("*a")
	handle:close()
	return tonumber(result) or 0
end

local function check_claude()
	local count = get_claude_count()
	if count > last_count then
		vim.fn.jobstart({ "afplay", "/tmp/fah.mp3" }, { detach = true })
	end
	last_count = count
	vim.cmd("redrawstatus")
end

vim.fn.timer_start(200, function()
	check_claude()
end, { ["repeat"] = -1 })

function ClaudeSessionCount()
	return "Claude:" .. last_count
end

-- initialize
last_count = get_claude_count()
