local M = {}

--- Default configuration. Users can override these values by passing opts to setup().
M.config = {
  keymap = "<leader>pa",     -- keybinding to trigger the prompt in normal and visual mode
  focus_after_send = true,   -- whether to focus the Pi agent pane after sending a prompt
  herdr_binary = nil,        -- optional path to the herdr executable; defaults to "herdr"
  --- Built-in prompt templates. Keys are shown by `M.select()`; values may contain placeholders.
  prompts = {
    explain = "Explain @this",
    fix = "Fix @this",
    test = "Add tests for @this",
    document = "Document @this",
    optimize = "Optimize @this",
    review = "Review @this",
    implement = "Implement @this",
  },
}

-- State used by the operator motion callback.
M._operator_prefix = ""

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

--- Deliver a fully composed message to a Pi agent.
-- @param agent table Herdr agent descriptor containing pane_id
-- @param message string complete prompt to send
local function deliver(agent, message)
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

--- Build the compact context string used in normal mode: file path + current line.
function M.build_context_normal()
  return string.format("@%s:%d\n", vim.fn.expand("%:p"), vim.fn.line("."))
end

--- Build the context string for an arbitrary line range.
-- @param start_line number
-- @param end_line number
function M.build_context_range(start_line, end_line)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local selection = table.concat(lines, "\n")
  local file = vim.fn.expand("%:p")
  local ft = vim.bo.filetype
  return string.format("@%s:%d-%d\nSelection:\n```%s\n%s\n```\n", file, start_line, end_line, ft, selection)
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
  return string.format("@%s:%d-%d\nSelection:\n```%s\n%s\n```\n", file, start_line, end_line, ft, selection)
end

--- Build a compact reference to the current buffer (path only).
function M.build_context_buffer()
  return string.format("@%s\n", vim.fn.expand("%:p"))
end

--- Build a compact list of diagnostics for the current buffer or range.
-- @param range_start number|nil optional start line
-- @param range_end number|nil optional end line
function M.build_context_diagnostics(range_start, range_end)
  local diags = vim.diagnostic.get(0)
  if range_start and range_end then
    if range_start > range_end then
      range_start, range_end = range_end, range_start
    end
    diags = vim.tbl_filter(function(d)
      return d.lnum + 1 >= range_start and d.lnum + 1 <= range_end
    end, diags)
  end
  if #diags == 0 then return "No diagnostics\n" end
  local parts = { "Diagnostics:\n" }
  for _, d in ipairs(diags) do
    local line = d.lnum + 1
    local col = d.col + 1
    local severity_names = { "ERROR", "WARN", "INFO", "HINT" }
    local severity = severity_names[d.severity] or "?"
    parts[#parts + 1] = string.format("- line %d:%d [%s] %s\n", line, col, severity, d.message:gsub("\n", " "))
  end
  return table.concat(parts, "")
end

--- Return the current visual selection line range, or nil if none is meaningful.
local function visual_range()
  local mode = vim.fn.visualmode()
  if mode == "" then return nil end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  if start_pos[2] == 0 or end_pos[2] == 0 then return nil end
  return start_pos[2], end_pos[2]
end

--- Build the default @this context based on current state or an explicit range.
-- @param opts table|nil { mode = "n"|"v", range = { start_line, end_line } }
function M.build_context_this(opts)
  opts = opts or {}
  if opts.range then
    return M.build_context_range(opts.range[1], opts.range[2])
  end
  if opts.mode == "v" then
    return M.build_context_visual()
  end
  -- Normal mode or auto-detect with no active selection.
  if opts.mode == nil then
    local s, e = visual_range()
    if s then return M.build_context_visual() end
  end
  return M.build_context_normal()
end

--- Capture all context strings from the current editor state before the cursor moves.
-- This is important because opening the prompt float changes the current buffer/window.
-- @param opts table|nil { mode = "n"|"v", range = { start_line, end_line } }
function M.capture_context(opts)
  opts = opts or {}
  local range = opts.range
  local this_ctx
  if range then
    this_ctx = M.build_context_range(range[1], range[2])
  elseif opts.mode == "v" then
    this_ctx = M.build_context_visual()
  elseif opts.mode == "n" then
    this_ctx = M.build_context_normal()
  else
    local s, e = visual_range()
    if s then
      this_ctx = M.build_context_visual()
      range = { s, e }
    else
      this_ctx = M.build_context_normal()
    end
  end
  return {
    this = this_ctx,
    buffer = M.build_context_buffer(),
    diagnostics = M.build_context_diagnostics(range and range[1], range and range[2]),
  }
end

--- Replace context placeholders in a prompt with their compact representations.
-- Supported placeholders: @this, @buffer, @diagnostics.
-- @param text string prompt possibly containing placeholders
-- @param opts table|nil { mode = "n"|"v", range = { start_line, end_line }, context = captured_context }
function M.substitute_placeholders(text, opts)
  opts = opts or {}
  local ctx = opts.context or M.capture_context(opts)
  text = text:gsub("@this", ctx.this)
  text = text:gsub("@buffer", ctx.buffer)
  text = text:gsub("@diagnostics", ctx.diagnostics)
  return text
end

--- Open a single-line floating input window for typing the prompt.
-- @param title string shown in the window title
-- @param default_text string|nil initial text in the input
-- @param callback function(text|nil) called with the submitted text, or nil if cancelled
local function open_prompt(title, default_text, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "pi-herdr-prompt"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default_text or "" })

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

  -- Place cursor at the end of the default text and enter insert mode.
  vim.api.nvim_win_set_cursor(win, { 1, vim.fn.strlen(default_text or "") + 1 })
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

--- Ask Pi with an optional prefilled prompt. Placeholders are resolved after editing.
-- Context is captured before the floating prompt opens so line numbers stay correct.
-- This is the main opencode-style entry point.
-- @param prefix string|nil text to prefill in the prompt window
-- @param opts table|nil { mode = "n"|"v", range = { start_line, end_line } }
function M.ask(prefix, opts)
  opts = opts or {}
  -- Snapshot context now; the cursor will move into the prompt float.
  local snapshot = M.capture_context(opts)
  open_prompt("Ask Pi", prefix or "", function(prompt)
    if not prompt then return end
    local message = M.substitute_placeholders(prompt, vim.tbl_extend("force", opts, { context = snapshot }))
    find_pi_agent(function(agent, err)
      if err then
        vim.notify("Pi: " .. err, vim.log.levels.ERROR)
        return
      end
      deliver(agent, message)
    end)
  end)
end

--- Send a prompt directly to Pi without opening the input window.
-- Placeholders in text are resolved before sending.
-- @param text string prompt to send
-- @param opts table|nil { mode = "n"|"v", range = { start_line, end_line } }
function M.prompt(text, opts)
  opts = opts or {}
  if not text or text == "" then return end
  local message = M.substitute_placeholders(text, opts)
  find_pi_agent(function(agent, err)
    if err then
      vim.notify("Pi: " .. err, vim.log.levels.ERROR)
      return
    end
    deliver(agent, message)
  end)
end

--- Select a built-in prompt and ask Pi with it.
function M.select()
  local names = vim.tbl_keys(M.config.prompts)
  table.sort(names)
  vim.ui.select(names, { prompt = "Pi prompt:" }, function(choice)
    if choice then M.ask(M.config.prompts[choice] .. " ") end
  end)
end

--- Operator function: select a motion/textobject, then ask Pi about that range.
-- Use in an expr mapping: `vim.keymap.set("n", "go", function() return require("pi-herdr").operator("@this: ") end, { expr = true })`
-- @param prefix string|nil text to prefill after the range is selected
function M.operator(prefix)
  M._operator_prefix = prefix or ""
  vim.go.operatorfunc = "v:lua.require'pi-herdr'._operator_callback"
  return "g@"
end

--- Callback invoked by Neovim's operatorfunc after a motion is chosen.
-- This must be a public module function so v:lua can call it.
function M._operator_callback(type)
  local start_line = vim.api.nvim_buf_get_mark(0, "[")[1]
  local end_line = vim.api.nvim_buf_get_mark(0, "]")[1]
  -- For visual selections triggered via operator, fall back to visual marks.
  if not start_line or start_line == 0 then start_line = vim.fn.getpos("'<")[2] end
  if not end_line or end_line == 0 then end_line = vim.fn.getpos("'>")[2] end
  M.ask(M._operator_prefix or "", { range = { start_line, end_line } })
end

--- Public entry point for normal mode: prompt with current file/line context.
function M.ask_normal()
  M.ask("", { mode = "n" })
end

--- Public entry point for visual mode: prompt with selection context.
function M.ask_visual()
  M.ask("", { mode = "v" })
end

--- Initialize the plugin. Merge user opts, create commands, and register keymaps.
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  vim.api.nvim_create_user_command("PiAsk", function() M.ask("@this: ", { mode = "n" }) end, {})
  vim.api.nvim_create_user_command("PiAskVisual", function(args)
    M.ask("@this: ", { mode = "v", range = { args.line1, args.line2 } })
  end, { range = true })
  vim.api.nvim_create_user_command("PiPrompt", function(args)
    M.prompt(args.args, { mode = vim.fn.mode() == "v" and "v" or "n" })
  end, { nargs = 1 })
  vim.api.nvim_create_user_command("PiSelect", M.select, {})

  if M.config.keymap then
    vim.keymap.set("n", M.config.keymap, function() M.ask("@this: ", { mode = "n" }) end, { silent = true, desc = "Ask Pi" })
    vim.keymap.set("v", M.config.keymap, function() M.ask("@this: ", { mode = "v" }) end, { silent = true, desc = "Ask Pi selection" })
  end
end

return M
