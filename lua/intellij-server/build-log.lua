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
  vim.cmd("botright 12split")
  vim.api.nvim_win_set_buf(0, buf)
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
