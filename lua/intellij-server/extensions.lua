--- The server's own additions to LSP: the `intellij/*` notifications and
--- requests it sends to a client that enabled them with
--- `initializationOptions.intellijExtensions` (the VS Code extension always
--- does), plus the import status it reports to every client.
---
--- Each one is something an IDE would do for the server mid-feature: run an
--- editor action after an edit, let the user choose between the ways a
--- refactoring can go, confirm it despite conflicts, put text on the clipboard.
---
---   intellij/runEditorCommand      editor action to run after an edit (notification)
---   intellij/chooseAction          pick one of several continuations (notification)
---   intellij/showConflicts         go ahead despite conflicts? (request)
---   intellij/copyToClipboard       text for the clipboard (notification)
---   intellij/workspaceImportStatus folders the server will not import (notification)
---   intellij/workspaceImportState  import phase per folder (notification)
local M = {}

local function notify(msg, level)
  vim.notify("[intellij-server] " .. msg, level or vim.log.levels.WARN)
end

-- intellij/runEditorCommand -------------------------------------------------

--- Some ModCommands drive the editor instead of changing the document — an
--- "introduce variable" quick fix applies its edit, then asks the editor to
--- start an inline rename on the new name. LSP cannot express that (a server
--- cannot send workspace/executeCommand to a client), so the server sends a
--- VS Code command id and the client runs the equivalent. The server emits
--- exactly these ids (language-server.api.features.impl.common).
---@type table<string, fun(arguments: any[])>
M.editor_commands = {
  ["editor.action.rename"] = function()
    vim.lsp.buf.rename()
  end,
  ["editor.action.triggerParameterHints"] = function()
    vim.lsp.buf.signature_help()
  end,
  -- Start LSP completion at the cursor. The edit leaves normal mode behind
  -- the inserted text: enter insert mode there first, then complete.
  ["editor.action.triggerSuggest"] = function()
    if vim.fn.mode() ~= "i" then
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
  end,
}

local reported_commands = {}

---@param params { command: string, arguments?: any[] }
local function run_editor_command(params)
  if type(params) ~= "table" or type(params.command) ~= "string" then
    return
  end
  local run = M.editor_commands[params.command]
  if not run then
    if not reported_commands[params.command] then
      reported_commands[params.command] = true
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

-- intellij/chooseAction -----------------------------------------------------

--- A ModCommand or refactoring that can go several ways — where to initialize
--- an extracted field, whether inlining a method removes it — stops and sends
--- its options; running the chosen one's command continues it. With
--- `lazyIntentions` on, the server resolves the action only once it is run,
--- so the choice arrives here instead of inside the code action.
---@param params { title: string, entries: { name: string, command: lsp.Command }[] }
---@param ctx lsp.HandlerContext
local function choose_action(params, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client or type(params) ~= "table" or type(params.entries) ~= "table" then
    return
  end
  vim.ui.select(params.entries, {
    prompt = params.title,
    kind = "intellij_action",
    format_item = function(entry)
      return entry.name
    end,
  }, function(entry)
    if entry and entry.command then
      client:exec_cmd(entry.command)
    end
  end)
end

-- intellij/showConflicts ----------------------------------------------------

--- A refactoring found problems — inlining would move a call where a private
--- member is not accessible — and asks whether to go ahead anyway. This is a
--- request the server waits on, and Neovim answers server requests from the
--- handler's return value, so the question is a blocking confirm(). The
--- conflicts go to the quickfix list to be visited afterwards.
---@param params { title: string, conflicts: { messages: string[], location?: lsp.Location }[], continueLabel: string, cancelLabel: string }
---@return { decision: "continue"|"cancel" }
local function show_conflicts(params)
  local items, lines = {}, {}
  for _, conflict in ipairs(params.conflicts or {}) do
    local text = table.concat(vim.tbl_map(vim.trim, conflict.messages or {}), " ")
    local item = { text = text }
    local where = ""
    if conflict.location then
      item.filename = vim.uri_to_fname(conflict.location.uri)
      item.lnum = conflict.location.range.start.line + 1
      item.col = conflict.location.range.start.character + 1
      where = ("%s:%d: "):format(vim.fn.fnamemodify(item.filename, ":t"), item.lnum)
    end
    table.insert(items, item)
    table.insert(lines, where .. text)
  end
  vim.fn.setqflist({}, " ", { title = params.title, items = items })

  local shown = vim.list_slice(lines, 1, 8)
  if #lines > #shown then
    table.insert(shown, ("… and %d more (:copen)"):format(#lines - #shown))
  end
  local choice = vim.fn.confirm(
    params.title .. "\n\n" .. table.concat(shown, "\n"),
    ("&%s\n&%s"):format(params.continueLabel or "Continue", params.cancelLabel or "Cancel"),
    2
  )
  return { decision = choice == 1 and "continue" or "cancel" }
end

-- intellij/copyToClipboard --------------------------------------------------

---@param params { content: string }
local function copy_to_clipboard(params)
  if type(params) ~= "table" or type(params.content) ~= "string" then
    return
  end
  vim.fn.setreg("+", params.content)
  vim.fn.setreg('"', params.content)
end

-- intellij/workspaceImportStatus --------------------------------------------

--- Workspace folders whose import the server will not start on its own —
--- because more than one build system claims the folder (`reason =
--- "ambiguousBuildSystem"`, a pom.xml next to a build.gradle) — with the
--- candidate tools. VS Code shows a "Choose Build Tool…" prompt; here the
--- choice is made in the setup config.
---@param folder { folderUri: string, reason: string, candidates: string[], dismissed: boolean }
local function describe_blocked(folder)
  local path = vim.fn.fnamemodify(vim.uri_to_fname(folder.folderUri), ":~")
  local candidates = table.concat(folder.candidates or {}, ", ")
  local msg = ("Project import of %s is blocked (%s)"):format(path, folder.reason)
  if candidates ~= "" then
    msg = msg .. (": %s can import it"):format(candidates)
  end
  if folder.reason == "ambiguousBuildSystem" then
    msg = msg
      .. (".\nPick one in setup(): build_tools = { [%q] = %q } (or an explicit `projects` entry), then :IntellijServerRestart"):format(
        path,
        (folder.candidates or {})[1] or "gradle"
      )
  end
  return msg
end

local reported_folders = {}

---@param params { blockedFolders?: table[] }
local function import_status(params)
  if type(params) ~= "table" or type(params.blockedFolders) ~= "table" then
    return
  end
  local current = {}
  for _, folder in ipairs(params.blockedFolders) do
    if type(folder) == "table" and folder.folderUri then
      current[folder.folderUri] = true
      if not reported_folders[folder.folderUri] then
        reported_folders[folder.folderUri] = true
        notify(describe_blocked(folder))
      end
    end
  end
  -- A folder that is no longer blocked may be reported again if it comes back.
  for uri in pairs(reported_folders) do
    if not current[uri] then
      reported_folders[uri] = nil
    end
  end
end

-- intellij/workspaceImportState ---------------------------------------------

--- `{ phase: "IN_PROGRESS"|"FINISHED", folders: { folderUri, tool, status }[] }`,
--- also available as a request. Test discovery only works once the import is
--- done, so its end is when the test lenses can first be computed: refresh
--- the lenses of every attached buffer, as if the server had asked for it.
---@param params { phase: string }
---@param ctx lsp.HandlerContext
local function import_state(params, ctx)
  if type(params) ~= "table" or params.phase == "IN_PROGRESS" then
    return
  end
  vim.lsp.handlers["workspace/codeLens/refresh"](nil, nil, ctx)
end

--- LSP handlers for the client config.
---@return table<string, lsp.Handler>
function M.handlers()
  return {
    ["intellij/runEditorCommand"] = function(_, params)
      run_editor_command(params)
    end,
    ["intellij/chooseAction"] = function(_, params, ctx)
      choose_action(params, ctx)
    end,
    ["intellij/showConflicts"] = function(_, params)
      return show_conflicts(params)
    end,
    ["intellij/copyToClipboard"] = function(_, params)
      copy_to_clipboard(params)
    end,
    ["intellij/workspaceImportStatus"] = function(_, params)
      import_status(params)
    end,
    ["intellij/workspaceImportState"] = function(_, params, ctx)
      import_state(params, ctx)
    end,
  }
end

return M
