--- Virtual document content provider for IntelliJ LSP server.
--- Handles `jar:` and `jrt:` URIs returned by the server for library/JDK sources.
--- Content is fetched via workspace/executeCommand "decompile".
---
--- Server URIs (jar:file:///..., jrt:/...) contain no "://" so Vim would treat
--- them as relative paths. Buffers are therefore named jar://... / jrt://...
--- and translated back to server URIs on every outgoing request.
---
--- A BufReadCmd autocmd populates any jar://* / jrt://* buffer on load, no
--- matter how it was opened (gd, gv, quickfix, :edit, ...).
local M = {}

--- Check if a string is a virtual URI or virtual buffer name.
---@param uri string?
---@return boolean
function M.is_virtual(uri)
  if not uri then
    return false
  end
  return uri:match("^jar:") ~= nil or uri:match("^jrt:") ~= nil
end

--- Server URI -> buffer name (jar:file:///... -> jar://file:///...).
---@param uri string
---@return string
function M.to_bufname(uri)
  if uri:match("^jar://") or uri:match("^jrt://") then
    return uri -- already in buffer-name form
  end
  local jar_rest = uri:match("^jar:(.*)$")
  if jar_rest then
    return "jar://" .. jar_rest
  end
  local jrt_rest = uri:match("^jrt:/?(.*)$")
  if jrt_rest then
    return "jrt://" .. jrt_rest
  end
  return uri
end

--- Buffer name -> server URI (jar://file:///... -> jar:file:///...).
---@param bufname string
---@return string
function M.to_uri(bufname)
  local jar_rest = bufname:match("^jar://(.*)$")
  if jar_rest then
    return "jar:" .. jar_rest
  end
  -- jrt:///<jdk home>!/<module>/... (absolute JDK path) is what the server
  -- accepts as is; only the jrt:/<module> form was rewritten by to_bufname.
  if bufname:match("^jrt:///") then
    return bufname
  end
  local jrt_rest = bufname:match("^jrt://(.*)$")
  if jrt_rest then
    return "jrt:/" .. jrt_rest
  end
  return bufname
end

--- Synchronously fetch decompiled content for a server URI.
--- The server only serves archives of its own workspace model and answers null
--- for anything else, so with several projects (one client each) every client
--- is asked until one knows the file.
---@param uri string
---@return string? content
---@return string? err
---@return vim.lsp.Client? client The client that served it.
local function fetch_content(uri)
  local clients = vim.lsp.get_clients({ name = "intellij-server" })
  if #clients == 0 then
    return nil, "LSP not running"
  end

  local err = "empty response (the server returns none until indexing finishes)"
  for _, client in ipairs(clients) do
    local response = client:request_sync("workspace/executeCommand", {
      command = "decompile",
      arguments = { uri },
    }, 10000, 0)

    if not response then
      err = "timeout"
    elseif response.err then
      err = vim.inspect(response.err)
    else
      local result = response.result
      if type(result) == "string" then
        return result, nil, client
      elseif type(result) == "table" and (result.code or result.text) then
        return result.code or result.text, nil, client
      end
    end
  end
  return nil, err
end

--- Populate a virtual buffer with decompiled content and set it up.
---@param bufnr integer
local function populate(bufnr)
  local uri = M.to_uri(vim.api.nvim_buf_get_name(bufnr))

  local content, err, served_by = fetch_content(uri)
  if not content then
    vim.notify("[intellij-server] Failed to decompile: " .. (err or "unknown"), vim.log.levels.WARN)
    content = "// Failed to load decompiled content: " .. (err or "unknown")
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].swapfile = false
  -- A snacks preview (it marks the buffers it loads, e.g. the explorer's
  -- preview of a library file) should not leave every previewed file in the
  -- buffer list; opening it lists it.
  if not vim.b[bufnr].snacks_picker_loaded then
    vim.bo[bufnr].buflisted = true
  end

  local lang = uri:match("%.kt$") and "kotlin" or "java"
  vim.bo[bufnr].filetype = lang
  pcall(vim.treesitter.start, bufnr, lang)

  -- Attach the LSP client; the patched vim.uri_from_bufnr translates the
  -- buffer name back to the server URI for didOpen and all requests.
  local client = served_by or vim.lsp.get_clients({ name = "intellij-server" })[1]
  if client then
    vim.lsp.buf_attach_client(bufnr, client.id)
  end
end

--- Open a virtual document (in the current window).
---@param uri string Server URI or buffer name form.
---@param range? { start: { line: integer, character: integer } }
function M.open(uri, range)
  local bufnr = vim.fn.bufadd(M.to_bufname(uri))
  vim.api.nvim_set_current_buf(bufnr) -- triggers BufReadCmd on first load
  if range then
    local line = math.min(range.start.line + 1, vim.api.nvim_buf_line_count(bufnr))
    pcall(vim.api.nvim_win_set_cursor, 0, { line, range.start.character })
  end
end

--- Attach the IntelliJ LSP client to all already-open virtual buffers.
---@param client_id integer
function M.attach_open_buffers(client_id)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("^jar://") or name:match("^jrt://") then
      pcall(vim.lsp.buf_attach_client, bufnr, client_id)
    end
  end
end

--- Setup autocmds and URI translation patches.
function M.setup()
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = vim.api.nvim_create_augroup("IntellijServerContent", { clear = true }),
    pattern = { "jar://*", "jrt://*" },
    callback = function(ev)
      populate(ev.buf)
    end,
    desc = "Load decompiled content for IntelliJ virtual documents",
  })

  -- vim.uri_to_fname errors on non-file schemes; return the buffer-name form
  -- so locations_to_items/bufadd create correctly named virtual buffers.
  local orig_uri_to_fname = vim.uri_to_fname
  vim.uri_to_fname = function(uri)
    if M.is_virtual(uri) then
      return M.to_bufname(uri)
    end
    return orig_uri_to_fname(uri)
  end

  -- Outgoing requests must carry the server URI, not the buffer name.
  local orig_uri_from_bufnr = vim.uri_from_bufnr
  vim.uri_from_bufnr = function(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:match("^jar://") or name:match("^jrt://") then
      return M.to_uri(name)
    end
    return orig_uri_from_bufnr(bufnr)
  end
end

return M
