--- Inline completion support for IntelliJ LSP server.
--- Uses the `textDocument/inlineCompletion` LSP request (non-standard, proposed spec).
local M = {}

---@class InlineCompletionItem
---@field insertText string
---@field range? { start: { line: integer, character: integer }, ["end"]: { line: integer, character: integer } }

--- Request inline completions at the current cursor position.
---@param bufnr integer?
---@param callback fun(items: InlineCompletionItem[])
function M.request(bufnr, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "intellij-server" })
  if #clients == 0 then
    callback({})
    return
  end

  local client = clients[1]
  local pos = vim.api.nvim_win_get_cursor(0)
  local row = pos[1] - 1
  local col = pos[2]

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = row, character = col },
    context = {
      triggerKind = 1, -- Invoked
    },
  }

  client:request("textDocument/inlineCompletion", params, function(err, result)
    if err or not result then
      callback({})
      return
    end

    local items = result.items or result
    if not vim.islist(items) then
      items = { items }
    end
    callback(items)
  end, bufnr)
end

--- Show inline completion as virtual text at cursor.
local ns = vim.api.nvim_create_namespace("intellij_inline_completion")
local current_suggestion = nil

function M.dismiss()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  current_suggestion = nil
end

function M.show()
  M.dismiss()
  local bufnr = vim.api.nvim_get_current_buf()

  M.request(bufnr, function(items)
    if #items == 0 then
      return
    end

    vim.schedule(function()
      local item = items[1]
      local text = type(item) == "string" and item or (item.insertText or "")
      if text == "" then
        return
      end

      current_suggestion = { bufnr = bufnr, text = text, item = item }

      local lines = vim.split(text, "\n", { plain = true })
      local pos = vim.api.nvim_win_get_cursor(0)
      local row = pos[1] - 1

      local virt_lines = {}
      for i, line in ipairs(lines) do
        if i == 1 then
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, pos[2], {
            virt_text = { { line, "Comment" } },
            virt_text_pos = "inline",
          })
        else
          table.insert(virt_lines, { { line, "Comment" } })
        end
      end

      if #virt_lines > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
          virt_lines = virt_lines,
        })
      end
    end)
  end)
end

--- Accept the current inline suggestion.
function M.accept()
  if not current_suggestion then
    return
  end

  local text = current_suggestion.text
  M.dismiss()

  -- Insert the text at cursor
  local pos = vim.api.nvim_win_get_cursor(0)
  local row = pos[1] - 1
  local col = pos[2]
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(0, row, col, row, col, lines)

  -- Move cursor to end of inserted text
  local new_row = row + #lines
  local new_col = #lines > 1 and #lines[#lines] or (col + #lines[1])
  vim.api.nvim_win_set_cursor(0, { new_row, new_col })
end

--- Setup keymaps for inline completion.
---@param opts { show?: string, accept?: string, dismiss?: string }?
function M.setup_keymaps(opts)
  opts = opts or {}
  local show_key = opts.show or "<M-\\>"
  local accept_key = opts.accept or "<Tab>"
  local dismiss_key = opts.dismiss or "<Esc>"

  vim.keymap.set("i", show_key, M.show, { desc = "IntelliJ: trigger inline completion" })
  vim.keymap.set("i", accept_key, function()
    if current_suggestion then
      M.accept()
    else
      return vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
    end
  end, { expr = true, desc = "IntelliJ: accept inline completion or Tab" })
  vim.keymap.set("i", dismiss_key, function()
    if current_suggestion then
      M.dismiss()
    else
      return vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    end
  end, { expr = true, desc = "IntelliJ: dismiss inline completion or Esc" })
end

return M
