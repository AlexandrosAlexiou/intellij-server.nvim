--- Workaround for the IntelliJ server's command-driven completion.
---
--- The server does not put the inserted text in its completion items. Each item
--- comes back with an *empty* `textEdit` (newText = "", zero-width range) plus a
--- `command` (`jetbrains.java.completion.apply` / `jetbrains.kotlin.completion.apply`).
--- The real text, imports and caret are applied server-side: when the client
--- runs that command the server replies with `workspace/applyEdit` (text +
--- imports) and `window/showDocument` (caret). VS Code's language client inserts
--- nothing on accept and just runs the command, so it gets the full behaviour
--- for free.
---
--- Neovim frontends (builtin completion, nvim-cmp, blink.cmp) instead fall back
--- to inserting the item's own text (the `label`, since `newText` is empty) and
--- *then* run the command, so the server's edit lands on top of the
--- already-inserted text and the caret ends up mid-identifier (`Ap|p`).
---
--- This module makes Neovim behave like VS Code: we keep the apply command and
--- turn the client's own insertion into a **no-op** (a text edit that replaces
--- the typed prefix with itself). The buffer is therefore unchanged when the
--- command runs, so the server's `applyEdit` — which is a diff against the
--- document it has synced — lands correctly and brings imports + parentheses
--- with it, and `window/showDocument` places the caret. Nothing is lost.
---
--- Requires the frontend to execute the item's `command` (builtin, nvim-cmp and
--- blink.cmp all do) and the server-driven `window/showDocument` to be honoured
--- (handled in init.lua). The proper fix is upstream returning a real
--- `textEdit`.
---
--- Live template items (sout, fori, psvm, …) are the exception: they carry a
--- real snippet `textEdit` and no apply command — but with *absolute*
--- indentation pre-formatted in the server's own code style (4 spaces), which
--- corrupts buffers indented differently. Those edits are rewritten into the
--- conventional relative snippet form; see reindent_template_edit.

local M = {}

-- Kotlin items carry their identity under this data key; Java items don't.
local DATA_KEY = "KotlinCompletionItemKey"

-- Indent size the server's code style uses when it pre-formats live template
-- snippets (IntelliJ's default Java/Kotlin style: 4 spaces, no tabs). The
-- server ignores the buffer's actual indentation — and even a project
-- .editorconfig — when expanding templates, so snippet text arrives with
-- absolute, 4-space-based indentation baked in (see reindent_template_edit).
local SERVER_INDENT = 4

-- No-op edits for the most recent completion list, keyed by the server's
-- completion id (when present). `completionItem/resolve` re-sends the empty
-- server edit, so we restore the no-op from here to keep insertion deferred to
-- the command. `last_edit` is the fallback for items without an id (Java).
local noop_edits = {}
local last_edit = nil

-- Re-anchored live template edits for the most recent completion list, keyed
-- by label, so `completionItem/resolve` can restore them instead of
-- re-transforming (the rewrite is not idempotent).
local template_edits = {}

-- True for items that defer their insertion to the server's apply command
-- (jetbrains.java.completion.apply / jetbrains.kotlin.completion.apply).
local function is_command_driven(item)
  return type(item) == "table"
    and type(item.command) == "table"
    and type(item.command.command) == "string"
    and item.command.command:match("^jetbrains%..+%.completion%.apply$") ~= nil
end

local function item_id(item)
  return item.data and item.data[DATA_KEY]
end

-- Build a no-op text edit over the identifier prefix ending at the completion
-- position: it replaces the typed prefix with itself, so the client inserts
-- nothing and the buffer still matches the document the server will edit.
-- Note: offsets are measured in bytes, which match LSP character offsets for
-- ASCII identifiers (the common case for Java/Kotlin symbols).
local function noop_prefix_edit(params)
  local pos = params.position
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""

  local start = pos.character
  while start > 0 and line:sub(start, start):match("[%w_$]") do
    start = start - 1
  end

  return {
    range = {
      start = { line = pos.line, character = start },
      ["end"] = { line = pos.line, character = pos.character },
    },
    newText = line:sub(start + 1, pos.character),
  }
end

-- Live template items (sout, fori, psvm, …) are the only ones whose textEdit
-- carries real snippet text instead of deferring to the apply command.
local function is_template_snippet(item)
  return type(item) == "table"
    and not is_command_driven(item)
    and item.insertTextFormat == 2 -- Snippet
    and type(item.textEdit) == "table"
    and type(item.textEdit.newText) == "string"
    and item.textEdit.newText ~= ""
end

-- Display width of leading whitespace, using the server's tab size.
local function indent_width(ws)
  local w = 0
  for i = 1, #ws do
    w = w + (ws:sub(i, i) == "\t" and SERVER_INDENT or 1)
  end
  return w
end

-- The server pre-formats live template snippets with *absolute* indentation in
-- its own code style (4 spaces, spaces only), ignoring the buffer's actual
-- indentation:
--   * first line: padded so the statement lands at the server's computed
--     column — either by prepending spaces to newText, or (when the existing
--     indent is tabs) by extending the range to column 0 and rewriting the
--     whole indent;
--   * following lines: absolutely indented relative to that same base.
-- Applied verbatim this breaks any buffer whose indent style differs from the
-- server's (extra spaces, tabs replaced). Rewrite the edit into the
-- conventional relative snippet form instead: keep the buffer's own leading
-- whitespace (shrink the range to start after it, drop the first-line pad) and
-- turn each following line's indent beyond the base into `\t` per level.
-- vim.snippet.expand — used by the builtin frontend, blink.cmp and nvim-cmp —
-- then prepends the current line's indent and materializes `\t` according to
-- 'shiftwidth'/'expandtab', so the expansion follows the buffer's style.
local function reindent_template_edit(item, params)
  local edit = item.textEdit
  local pos = params.position
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ""
  local indent = line:match("^[ \t]*")

  -- Only rewrite edits anchored inside/at the end of the leading whitespace of
  -- the completion line; anything else is not an indent-carrying template.
  local start_char = edit.range.start.character
  if edit.range.start.line ~= pos.line or start_char > #indent then
    return
  end

  local lines = vim.split(edit.newText, "\n", { plain = true })
  local pad = lines[1]:match("^[ \t]*")

  -- Server's base column: what precedes the edit plus the first-line pad.
  local base = indent_width(line:sub(1, start_char)) + indent_width(pad)

  lines[1] = lines[1]:sub(#pad + 1)
  for i = 2, #lines do
    local ws = lines[i]:match("^[ \t]*")
    local rel = math.max(indent_width(ws) - base, 0)
    lines[i] = ("\t"):rep(math.floor(rel / SERVER_INDENT)) .. (" "):rep(rel % SERVER_INDENT) .. lines[i]:sub(#ws + 1)
  end

  edit.newText = table.concat(lines, "\n")
  -- Keep the buffer's own indent characters out of the replaced range. The
  -- range text is what frontends match filterText against, so trim it too.
  if start_char < #indent then
    edit.range.start.character = #indent
    if type(item.filterText) == "string" then
      item.filterText = item.filterText:gsub("^[ \t]+", "")
    end
  end

  template_edits[tostring(item.label)] = { edit = edit, filterText = item.filterText }
end

-- Turn each command-driven item's own insertion into a no-op, keeping the apply
-- command so the server performs the real insertion (like the VS Code client).
local function patch_completion(result, params)
  local items = result.items or result
  if type(items) ~= "table" then
    return
  end

  local edit
  noop_edits = {}
  last_edit = nil
  template_edits = {}
  for _, item in ipairs(items) do
    if is_command_driven(item) then
      edit = edit or noop_prefix_edit(params)
      item.textEdit = { range = edit.range, newText = edit.newText }
      item.insertTextFormat = 1 -- PlainText: no snippet expansion of the no-op
      last_edit = item.textEdit
      local id = item_id(item)
      if id ~= nil then
        noop_edits[id] = item.textEdit
      end
    elseif is_template_snippet(item) then
      reindent_template_edit(item, params)
    end
  end
end

-- `completionItem/resolve` re-sends the empty server edit; restore our no-op so
-- the client still inserts nothing and defers to the command. Live template
-- items get their re-anchored edit back for the same reason. Documentation and
-- other resolved fields are left untouched.
local function patch_resolve(result)
  if is_template_snippet(result) then
    local saved = template_edits[tostring(result.label)]
    if saved then
      result.textEdit = saved.edit
      result.filterText = saved.filterText
    end
    return
  end
  if not is_command_driven(result) then
    return
  end
  local id = item_id(result)
  local edit = (id ~= nil and noop_edits[id]) or last_edit
  if edit then
    result.textEdit = { range = edit.range, newText = edit.newText }
    result.insertTextFormat = 1
  end
end

--- Wrap a client's `request` so completion and resolve responses are normalized
--- before any frontend (builtin completion, nvim-cmp, blink.cmp) sees them.
--- Frontends issue these requests with an inline callback, bypassing the
--- configured `handlers` table, so the client method is the only universal hook.
--- Idempotent.
---@param client vim.lsp.Client
function M.attach(client)
  if client._intellij_completion_wrapped then
    return
  end
  ---@diagnostic disable-next-line: inject-field
  client._intellij_completion_wrapped = true

  local orig_request = client.request
  client.request = function(self, method, params, handler, bufnr)
    if handler and (method == "textDocument/completion" or method == "completionItem/resolve") then
      local inner = handler
      handler = function(err, result, ctx, config)
        if not err and result then
          if method == "textDocument/completion" then
            patch_completion(result, params)
          else
            patch_resolve(result)
          end
        end
        return inner(err, result, ctx, config)
      end
    end
    return orig_request(self, method, params, handler, bufnr)
  end
end

--- Handler for the server-initiated `window/showDocument` request. The apply
--- command uses it to place the caret after inserting; handle that in the
--- current buffer directly (the default handler may switch windows/scroll), and
--- delegate anything else to the default handler.
---@param result lsp.ShowDocumentParams
function M.show_document(result, ctx)
  local ok_uri, bufnr = pcall(vim.uri_to_bufnr, result.uri)
  if ok_uri and not result.external and result.selection and bufnr == vim.api.nvim_get_current_buf() then
    local s = result.selection.start
    pcall(vim.api.nvim_win_set_cursor, 0, { s.line + 1, s.character })
    return { success = true }
  end
  return vim.lsp.handlers["window/showDocument"](nil, result, ctx)
end

return M
