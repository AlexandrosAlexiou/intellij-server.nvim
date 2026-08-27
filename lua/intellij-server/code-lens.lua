--- Code lens presentation fixes for the IntelliJ server.
---
--- The server writes lenses the way VS Code wants them:
---   * titles carry codicon markup — "$(play) Run", "$(debug) Debug" — which
---     Neovim renders literally;
---   * each lens is anchored to the identifier it belongs to (the `main`
---     token), and Neovim indents the virtual line to that column, leaving
---     the lens floating far right of the code it sits above.
--- Both are rewritten before the built-in handler sees the response.
local M = {}

local wrapped = "_intellij_code_lens_wrapped"

--- @class IntellijServerCodeLensOpts
--- @field icons table<string, string>|false? Codicon name -> replacement text
--- @field align boolean? Align lenses with the line's indent (default: true)

---@type IntellijServerCodeLensOpts
local opts = {}

--- Replace VS Code codicon markup with the configured text, or drop it.
---@param title string
---@return string
local function retitle(title)
  return (
    title:gsub("%$%(([%w_.-]+)%)%s*", function(icon)
      local replacement = opts.icons and opts.icons[icon]
      return replacement and (replacement .. " ") or ""
    end)
  )
end

--- Column the lens should be drawn at: the indent of the line it belongs to.
--- Neovim pads the virtual line with that many spaces, so tabs are counted as
--- the width they display at.
---@param bufnr integer
---@param row integer
---@return integer?
local function indent_col(bufnr, row)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return nil
  end

  local indent = line:match("^[ \t]*") or ""
  local tabs = select(2, indent:gsub("\t", ""))
  local col = #indent - tabs + tabs * vim.bo[bufnr].tabstop

  -- The column is resolved against the line before it is used, so it cannot
  -- point past the end of it.
  return math.min(col, #line)
end

---@param result lsp.CodeLens[]?
---@param bufnr integer?
---@return lsp.CodeLens[]?
local function normalize(result, bufnr)
  for _, lens in ipairs(result or {}) do
    if lens.command and lens.command.title then
      lens.command.title = retitle(lens.command.title)
    end

    if opts.align ~= false and bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
      local col = indent_col(bufnr, lens.range.start.line)
      if col then
        lens.range.start.character = col
      end
    end
  end

  return result
end

---@param config IntellijServerCodeLensOpts?
function M.setup(config)
  opts = config or {}
end

--- Rewrite code lens responses for one client. Neovim's code lens provider
--- passes its own handler to every request, so there is no handler to override
--- in the client config; wrapping the method on the client instance leaves
--- every other LSP client alone (same approach as intellij-server.navigation).
---@param client vim.lsp.Client
function M.attach(client)
  if client[wrapped] then
    return
  end
  client[wrapped] = true

  local request = client.request
  ---@diagnostic disable-next-line: duplicate-set-field
  client.request = function(self, method, params, handler, bufnr)
    if handler and method == "textDocument/codeLens" then
      local inner = handler
      handler = function(err, result, ctx, config)
        return inner(err, normalize(result, ctx and ctx.bufnr or bufnr), ctx, config)
      end
    end
    return request(self, method, params, handler, bufnr)
  end
end

return M
