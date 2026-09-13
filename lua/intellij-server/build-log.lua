--- Build/import log streamed from the server via the custom
--- `intellij/importLog` notification (the same channel the VS Code
--- extension shows as its "Build" output panel).
---
--- Payload: { started?: boolean, message?: string, failed?: boolean,
---            succeeded?: boolean, tool?: string }
local M = {}

local bufnr = nil ---@type integer?

---@type { enabled?: boolean, open_on_start?: boolean, open_on_failure?: boolean, notify?: boolean }
M.opts = {
  enabled = true,
  open_on_start = false, -- auto-open the log window when an import/build starts
  open_on_failure = true, -- auto-open the log window when it fails
  notify = true, -- vim.notify on start/success/failure
}

--- Get (or create) the scratch buffer holding the build log.
---@return integer
local function get_buf()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "intellij://build-log")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "intellij-build-log"
  return bufnr
end

--- Append lines to the log buffer, following the tail in any window showing it.
---@param lines string[]
local function append(lines)
  local buf = get_buf()
  local last = vim.api.nvim_buf_line_count(buf)
  -- Replace the initial empty line on first write
  local start = (last == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "") and 0 or last
  vim.api.nvim_buf_set_lines(buf, start, last, false, lines)
  local new_last = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_set_cursor(win, { new_last, 0 })
  end
end

--- Open the build log in a bottom split (reuses an existing window).
function M.open()
  local buf = get_buf()
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
    return
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.floor(vim.o.lines * 0.5))
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.wrap = false
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
end

--- Clear the log buffer.
function M.clear()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  end
end

--- Run a build the server resolved (`intellij.java.resolveBuildCommand`) and
--- stream its output into the log — what the VS Code extension's
--- "intellij: build" pre-launch task does before a JVM launch. Runs
--- asynchronously; `on_done` gets whether the command exited with 0.
---@param build { tool?: string, command: string[], cwd?: string }
---@param on_done fun(ok: boolean)
function M.run(build, on_done)
  local tool = build.tool or "Build"
  local buf = get_buf()
  if vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "" then
    append({ "" })
  end
  append({ ("── %s build started: %s ──"):format(tool, table.concat(build.command, " ")) })
  if build.cwd then
    append({ "in " .. build.cwd })
  end
  if M.opts.notify then
    vim.notify(("[intellij-server] %s build started — :IntellijServerBuildLog to follow"):format(tool))
  end
  if M.opts.open_on_start then
    M.open()
  end

  -- Output arrives in chunks that need not end on a line boundary: keep the
  -- partial last line per stream until the next chunk (or exit) completes it.
  local pending = { stdout = "", stderr = "" }
  local function on_output(stream)
    return function(_, data)
      if not data then
        return
      end
      vim.schedule(function()
        local text = pending[stream] .. data:gsub("\r\n", "\n"):gsub("\r", "\n")
        local lines = vim.split(text, "\n", { plain = true })
        pending[stream] = table.remove(lines)
        if #lines > 0 then
          append(lines)
        end
      end)
    end
  end

  local function flush()
    for _, stream in ipairs({ "stdout", "stderr" }) do
      if pending[stream] ~= "" then
        append({ pending[stream] })
        pending[stream] = ""
      end
    end
  end

  local ok, err = pcall(vim.system, build.command, {
    cwd = build.cwd,
    text = true,
    stdout = on_output("stdout"),
    stderr = on_output("stderr"),
  }, function(result)
    vim.schedule(function()
      flush()
      if result.code == 0 then
        append({ ("── %s build finished ──"):format(tool) })
        if M.opts.notify then
          vim.notify(("[intellij-server] %s build finished"):format(tool))
        end
        on_done(true)
      else
        append({ ("── %s build failed (exit code %d) ──"):format(tool, result.code) })
        if M.opts.notify then
          vim.notify(("[intellij-server] %s build failed — see :IntellijServerBuildLog"):format(tool), vim.log.levels.ERROR)
        end
        if M.opts.open_on_failure then
          M.open()
        end
        on_done(false)
      end
    end)
  end)
  if not ok then
    append({ ("── could not run %s: %s ──"):format(build.command[1], tostring(err)) })
    vim.notify(("[intellij-server] could not run %s: %s"):format(build.command[1], tostring(err)), vim.log.levels.ERROR)
    on_done(false)
  end
end

--- LSP handler for the `intellij/importLog` notification.
---@param params { started?: boolean, message?: string, failed?: boolean, succeeded?: boolean, tool?: string }
function M.handler(_, params, _)
  if not params then
    return
  end
  local tool = params.tool or "Build"

  if params.started then
    -- VS Code keeps prior output and just reveals/scrolls; mark a new run.
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= "" then
      append({ "", ("── %s started ──"):format(tool) })
    end
    if M.opts.notify then
      vim.notify(("[intellij-server] %s started — :IntellijServerBuildLog to follow"):format(tool))
    end
    if M.opts.open_on_start then
      M.open()
    end
    return
  end

  if params.message then
    append(vim.split(params.message, "\n", { plain = true }))
  end

  if params.failed then
    if M.opts.notify then
      vim.notify(("[intellij-server] %s failed — see :IntellijServerBuildLog"):format(tool), vim.log.levels.ERROR)
    end
    if M.opts.open_on_failure then
      M.open()
    end
  elseif params.succeeded then
    if M.opts.notify then
      vim.notify(("[intellij-server] %s finished successfully"):format(tool))
    end
  end
end

return M
