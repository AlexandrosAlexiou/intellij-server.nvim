--- Code lens presentation fixes for the IntelliJ server, and the test lenses.
---
--- The server writes lenses the way VS Code wants them:
---   * titles carry codicon markup — "$(play) Run", "$(debug) Debug" — which
---     Neovim renders literally;
---   * each lens is anchored to the identifier it belongs to (the `main`
---     token), and Neovim indents the virtual line to that column, leaving
---     the lens floating far right of the code it sits above.
--- Both are rewritten before the built-in handler sees the response.
---
--- The server has no lenses for tests (VS Code has a Test Explorer instead),
--- so Run Test / Debug Test lenses are added here from the server's test
--- discovery (intellij-server.tests), requested alongside every code lens
--- request and merged into its response.
local M = {}

local wrapped = "_intellij_code_lens_wrapped"

--- @class IntellijServerCodeLensOpts
--- @field icons table<string, string>|false? Codicon name -> replacement text.
--- Defaults to Nerd Font glyphs; `false` (or an empty table) shows text only.
--- @field align boolean? Align lenses with the line's indent (default: true)
--- @field tests boolean? Run Test / Debug Test lenses (default: true; needs nvim-dap)

--- Nerd Font stand-ins for the codicons the server asks for: nf-fa-play and
--- nf-fa-bug. Set `code_lens.icons` to replace them, or to `false` for text
--- only ("Run", "Debug").
---@type table<string, string>
local DEFAULT_ICONS = {
  play = "\u{f04b}",
  debug = "\u{f188}",
}

---@type IntellijServerCodeLensOpts
local opts = {}

--- @return table<string, string>|false
local function icons()
  if opts.icons == nil then
    return DEFAULT_ICONS
  end
  return opts.icons
end

--- Replace VS Code codicon markup with the configured text, or drop it.
---@param title string
---@return string
local function retitle(title)
  return (
    title:gsub("%$%(([%w_.-]+)%)%s*", function(icon)
      local set = icons()
      local replacement = set and set[icon]
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

--- Discover the tests of the document and hand the handler the server's
--- lenses plus theirs, whichever answer comes last. The context stays the
--- code lens response's, so Neovim's staleness check (buffer version) holds.
---@param client vim.lsp.Client
---@param uri string
---@param inner lsp.Handler
---@param bufnr integer?
---@return lsp.Handler
local function with_test_lenses(client, uri, inner, bufnr)
  local tests = require("intellij-server.tests")
  local test_lenses, pending ---@type lsp.CodeLens[]?, table?

  local function deliver(err, result, ctx, config)
    local merged = vim.list_extend(vim.list_extend({}, result or {}), test_lenses or {})
    return inner(err, normalize(merged, ctx and ctx.bufnr or bufnr), ctx, config)
  end

  tests.discover(client, uri, function(_, items)
    test_lenses = tests.lenses(items)
    if pending then
      deliver(pending.err, pending.result, pending.ctx, pending.config)
    end
  end)

  return function(err, result, ctx, config)
    if test_lenses then
      return deliver(err, result, ctx, config)
    end
    pending = { err = err, result = result, ctx = ctx, config = config }
  end
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
      if opts.tests then
        handler = with_test_lenses(self, params.textDocument.uri, inner, bufnr)
      else
        handler = function(err, result, ctx, config)
          return inner(err, normalize(result, ctx and ctx.bufnr or bufnr), ctx, config)
        end
      end
    end
    return request(self, method, params, handler, bufnr)
  end
end

return M
