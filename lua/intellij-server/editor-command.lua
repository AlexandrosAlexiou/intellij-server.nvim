--- Handler for the `intellij/runEditorCommand` notification (server 0.0.12+).
---
--- Some ModCommands drive the editor instead of changing the document — an
--- "introduce variable" quick fix applies its edit, then asks the editor to
--- start an inline rename on the new name. LSP cannot express that (a server
--- cannot send workspace/executeCommand to a client), so the server sends this
--- notification with a VS Code command id and the client runs the equivalent.
---
--- The server emits exactly these ids (see language-server.api.features.impl):
---   editor.action.rename                 -> vim.lsp.buf.rename()
---   editor.action.triggerSuggest         -> LSP completion at the cursor
---   editor.action.triggerParameterHints  -> vim.lsp.buf.signature_help()
local M = {}

local function notify(msg, level)
  vim.notify("[intellij-server] " .. msg, level or vim.log.levels.WARN)
end

--- Start LSP completion at the cursor (insert mode, or right after an edit).
local function trigger_completion()
  if vim.fn.mode() ~= "i" then
    -- The edit left us in normal mode after the inserted text: enter insert
    -- mode at the cursor first, then complete.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a", true, false, true), "n", false)
  end
  vim.schedule(function()
    local completion = vim.lsp.completion
    if completion and completion.get then
      completion.get()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
    end
  end)
end

---@type table<string, fun(arguments: any[])>
M.commands = {
  ["editor.action.rename"] = function()
    vim.lsp.buf.rename()
  end,
  ["editor.action.triggerSuggest"] = trigger_completion,
  ["editor.action.triggerParameterHints"] = function()
    vim.lsp.buf.signature_help()
  end,
}

local reported = {}

--- LSP handler.
---@param params { command: string, arguments?: any[] }
function M.handler(_, params, _)
  if type(params) ~= "table" or type(params.command) ~= "string" then
    return
  end
  local run = M.commands[params.command]
  if not run then
    if not reported[params.command] then
      reported[params.command] = true
      notify(("server asked for editor command %q, which has no Neovim equivalent yet"):format(params.command))
    end
    return
  end
  -- The notification follows the workspace/applyEdit it belongs to; run after
  -- that edit has landed in the buffer.
  vim.schedule(function()
    local ok, err = pcall(run, params.arguments or {})
    if not ok then
      notify(("editor command %s failed: %s"):format(params.command, tostring(err)), vim.log.levels.ERROR)
    end
  end)
end

return M
