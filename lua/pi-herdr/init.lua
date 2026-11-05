local M = {}

--- Default configuration. Users can override these values by passing opts to setup().
M.config = {
  keymap = "<leader>pa",     -- keybinding to trigger the prompt in normal and visual mode
  focus_after_send = true,   -- whether to focus the Pi agent pane after sending a prompt
  herdr_binary = nil,        -- optional path to the herdr executable; defaults to "herdr"
}

--- Return the configured herdr binary, or fall back to "herdr" if unset.
local function herdr_binary()
  local bin = M.config.herdr_binary
  return (bin and bin ~= "") and bin or "herdr"
end

--- Convert a path to an absolute, resolved, trailing-slash-normalized form.
-- This ensures that paths from Neovim and paths from herdr can be compared reliably.
function M.canonical_path(path)
  if not path or path == "" then return nil end
  local expanded = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local resolved = vim.fn.resolve(expanded)
  if resolved ~= "/" then resolved = resolved:gsub("/+$", "") end
  return resolved
end

--- Run herdr with the given arguments and parse its JSON output.
-- @param args table of command-line arguments passed to herdr
-- @param callback function(result, err) called with decoded JSON or an error string
local function herdr_spawn(args, callback)
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)
  local output = {}
  local err_output = {}

  local handle
  -- Spawn the herdr process. Stdin is closed, stdout/stderr are captured.
  handle = vim.uv.spawn(herdr_binary(), {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    handle:close()
    if code ~= 0 then
      local err = table.concat(err_output, ""):gsub("%s+$", "")
      callback(nil, err ~= "" and err or ("herdr exited with code " .. code))
      return
    end
    local text = table.concat(output, "")
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok then
      callback(nil, "failed to parse herdr JSON: " .. tostring(decoded))
      return
    end
    callback(decoded, nil)
  end)

  -- Collect stdout chunks into the output table as they arrive.
  vim.uv.read_start(stdout, function(_, data)
    if data then output[#output + 1] = data end
  end)
  -- Collect stderr chunks so we can report a useful error if herdr fails.
  vim.uv.read_start(stderr, function(_, data)
    if data then err_output[#err_output + 1] = data end
  end)
end

--- Find the single Pi agent whose working directory matches Neovim's cwd.
-- Errors out if no agent matches or if more than one matches (exact-CWD policy).
-- @param callback function(agent, err) called with the matched agent or an error string
local function find_pi_agent(callback)
  local cwd = M.canonical_path(vim.fn.getcwd())
  herdr_spawn({ "agent", "list" }, function(result, err)
    -- vim.schedule wraps the callback so we can safely call Vimscript functions and notify.
    vim.schedule(function()
      if err then
        callback(nil, err)
        return
      end
      local agents = result and result.result and result.result.agents or {}
      local matches = {}
      for _, agent in ipairs(agents) do
        if agent.agent == "pi" then
          -- Prefer foreground_cwd (where the pane currently is) over cwd.
          local agent_cwd = M.canonical_path(agent.foreground_cwd or agent.cwd)
          if agent_cwd and agent_cwd == cwd then
            matches[#matches + 1] = agent
          end
        end
      end
      if #matches == 0 then
        callback(nil, "No Pi agent found for " .. cwd)
      elseif #matches > 1 then
        callback(nil, "Multiple Pi agents match " .. cwd)
      else
        callback(matches[1], nil)
      end
    end)
  end)
end

--- Build the compact context string used in normal mode: file path + current line.
function M.build_context_normal()
  local file = vim.fn.expand("%:p")
  local line = vim.fn.line(".")
  return string.format("File: %s\nLines: %d\n", file, line)
end

--- Build the context string used in visual mode: file path, line range, and selected code.
function M.build_context_visual()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local mode = vim.fn.visualmode()
  if mode == "" then mode = "V" end
  local lines = vim.fn.getregion(start_pos, end_pos, { type = mode })
  local selection = table.concat(lines, "\n")
  local file = vim.fn.expand("%:p")
  local ft = vim.bo.filetype
  return string.format("File: %s\nLines: %d-%d\nSelection:\n```%s\n%s\n```\n", file, start_line, end_line, ft, selection)
end

--- Open a single-line floating input window for typing the prompt.
-- @param title string shown in the window title
-- @param callback function(text|nil) called with the submitted text, or nil if cancelled
local function open_prompt(title, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "pi-herdr-prompt"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local width = math.min(80, math.floor(vim.o.columns * 0.8))
  local height = 1
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  vim.cmd("startinsert!")

  -- Close the floating window and clean up the scratch buffer.
  local function close()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
    if vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end

  -- Submit the prompt: concatenate lines, trim whitespace, close the float, and call callback.
  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    close()
    callback(text ~= "" and text or nil)
  end

  -- Cancel the prompt and invoke callback with nil.
  local function cancel()
    close()
    callback(nil)
  end

  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("i", "<CR>", submit, opts)
  vim.keymap.set("i", "<Esc>", cancel, opts)
  vim.keymap.set("n", "<Esc>", cancel, opts)
  vim.keymap.set("n", "q", cancel, opts)

  -- If the user leaves the buffer without submitting, treat it as a cancel.
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = cancel,
  })
end

--- Send the final message to the matched Pi agent via herdr.
-- Optionally focuses the agent pane after a successful send.
local function send_prompt(agent, prompt, context)
  local message = context .. prompt
  vim.uv.spawn(herdr_binary(), {
    args = { "agent", "prompt", agent.pane_id, message },
  }, function(code)
    vim.schedule(function()
      if code ~= 0 then
        vim.notify("Pi: failed to send prompt", vim.log.levels.ERROR)
        return
      end
      vim.notify("Pi: prompt sent", vim.log.levels.INFO)
      if M.config.focus_after_send then
        vim.uv.spawn(herdr_binary(), { args = { "agent", "focus", agent.pane_id } })
      end
    end)
  end)
end

--- Generic ask flow: build context, open prompt, find agent, send message.
-- @param context_builder function returning the context string to prepend to the prompt
local function ask(context_builder)
  local context = context_builder()
  open_prompt("Ask Pi", function(prompt)
    if not prompt then return end
    find_pi_agent(function(agent, err)
      if err then
        vim.notify("Pi: " .. err, vim.log.levels.ERROR)
        return
      end
      send_prompt(agent, prompt, context)
    end)
  end)
end

--- Public entry point for normal mode: prompt with current file/line context.
function M.ask_normal()
  ask(M.build_context_normal)
end

--- Public entry point for visual mode: prompt with selection context.
function M.ask_visual()
  ask(M.build_context_visual)
end

--- Initialize the plugin. Merge user opts, create commands, and register keymaps.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("PiAsk", M.ask_normal, {})
  vim.api.nvim_create_user_command("PiAskVisual", M.ask_visual, { range = true })

  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, M.ask_normal, { silent = true, desc = "Ask Pi" })
    vim.keymap.set("v", M.config.keymap, M.ask_visual, { silent = true, desc = "Ask Pi selection" })
  end
end

return M
