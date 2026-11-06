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
--- Test runs (intellij-server.tests) write their output here too.
---@param lines string[]
function M.append(lines)
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

local next_build = 0

--- Build on the server (`intellij.build`, server 1.0.86+), the VS Code
--- extension's `intellij: build` task: the module of `uri`, or every module
--- without one. The server runs the build tool and streams its lines as
--- `intellij/buildOutput` (see output_handler); the answer carries the exit
--- code, or none and the reason nothing could build.
---@param client vim.lsp.Client
---@param uri string?
function M.build(client, uri)
  next_build = next_build + 1
  local target = uri and vim.fn.fnamemodify(vim.uri_to_fname(uri), ":~:.") or "workspace"
  M.append({ "", ("── build started: %s ──"):format(target) })
  if M.opts.notify then
    vim.notify(("[intellij-server] Build of %s started — :IntellijServerBuildLog to follow"):format(target))
  end
  if M.opts.open_on_start then
    M.open()
  end
  -- checkoutTools: a module no build tool imported may be built by a tool
  -- present in the checkout, as the VS Code task allows.
  local args = { uri = uri, buildId = "nvim-" .. next_build, checkoutTools = true }
  client:request("workspace/executeCommand", { command = "intellij.build", arguments = { args } }, function(err, result)
    result = type(result) == "table" and result or {}
    local failed, summary
    if err then
      failed, summary = true, "could not start: " .. (err.message or vim.inspect(err))
    elseif type(result.exitCode) ~= "number" then
      summary = result.reason or "nothing to build"
    else
      failed = result.exitCode ~= 0
      summary = failed and ("failed (exit code %d)"):format(result.exitCode) or "finished"
    end
    if type(result.unsupported) == "table" and #result.unsupported > 0 then
      summary = summary .. "; not built: " .. table.concat(result.unsupported, ", ")
    end
    M.append({ ("── build of %s %s ──"):format(target, summary) })
    if M.opts.notify then
      vim.notify(("[intellij-server] Build of %s %s"):format(target, summary), failed and vim.log.levels.ERROR or nil)
    end
    if failed and M.opts.open_on_failure then
      M.open()
    end
  end)
end

--- LSP handler for `intellij/buildOutput`: one line of a build's output.
---@param params { buildId: string, category: string, line: string }
function M.output_handler(_, params, _)
  if params and type(params.line) == "string" then
    M.append(vim.split(params.line, "\n", { plain = true }))
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
      M.append({ "", ("── %s started ──"):format(tool) })
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
    M.append(vim.split(params.message, "\n", { plain = true }))
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
