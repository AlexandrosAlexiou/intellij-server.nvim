--- Go-to-definition on a package name.
---
--- IntelliJ resolves a package to the directories that make it up — one per
--- source root, and often the same one repeated once per package fragment.
--- Neovim cannot show a directory: with a single location it opens an empty
--- buffer named after the path, and with several it fills the quickfix list with
--- entries that all read `src/main/kotlin/org/pkl/core|1 col 1|`.
---
local M = {}

--- Set on the client instance once its requests are wrapped.
local wrapped = "intellij_server_navigation"

---@param path string
---@return boolean
local function is_directory(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

--- Location-returning requests, the ones whose results the server repeats.
local location_methods = {
  ["textDocument/definition"] = true,
  ["textDocument/typeDefinition"] = true,
  ["textDocument/declaration"] = true,
  ["textDocument/implementation"] = true,
}

---@param location lsp.Location|lsp.LocationLink
---@return string
local function location_key(location)
  local uri = location.uri or location.targetUri or ""
  local range = location.range or location.targetSelectionRange or location.targetRange or {}
  local start = range.start or {}
  return ("%s:%d:%d"):format(uri, start.line or 0, start.character or 0)
end

--- Drop locations that point at the same place. The server repeats a package
--- directory once per fragment, so this is what turns those 30-odd identical
--- quickfix entries into a single jump.
---@param result any Response to a location request: nil, one location, or a list.
---@return any
local function dedupe(result)
  if type(result) ~= "table" or not vim.islist(result) then
    return result
  end
  local seen = {}
  local unique = {}
  for _, location in ipairs(result) do
    local key = location_key(location)
    if not seen[key] then
      seen[key] = true
      table.insert(unique, location)
    end
  end
  return unique
end

--- The filesystem paths of a result, when every location in it is a directory.
--- A mixed result means the server found real declarations too, and those belong
--- in Neovim's usual handling.
---@param result any
---@return string[]? paths nil unless the result is a non-empty list of directories.
local function directory_paths(result)
  if type(result) ~= "table" or not vim.islist(result) or vim.tbl_isempty(result) then
    return nil
  end
  local paths = {}
  for _, location in ipairs(result) do
    local uri = location.uri or location.targetUri
    if type(uri) ~= "string" or not vim.startswith(uri, "file://") then
      return nil
    end
    local path = vim.uri_to_fname(uri)
    if not is_directory(path) then
      return nil
    end
    table.insert(paths, path)
  end
  return paths
end

--- Drop buffers named after this directory that are not on screen. Oil adopts a
--- directory buffer by renaming it to oil://, and adopting an empty one looks to
--- oil like every entry in the package was deleted — that is what shows an empty
--- listing and then asks whether to save the oil buffer. Only plain directory
--- names are touched, never an oil:// buffer that may hold edits.
---@param path string
local function drop_placeholders(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(bufnr) == path and #vim.fn.win_findbuf(bufnr) == 0 then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

--- Open a directory listing, preferring oil.nvim and falling back to :edit
--- (netrw, or oil itself when it is lazily loaded on BufReadCmd).
---
--- The current buffer must not be the directory being opened. Requiring oil is
--- what loads it under a plugin manager — it is commonly lazy-loaded on `:Oil`
--- and a keymap — and oil finishes its setup by adopting the current buffer if
--- that is a directory, which mid-jump is the very buffer being replaced.
---@param path string
function M.open_directory(path)
  drop_placeholders(path)
  local ok, oil = pcall(require, "oil")
  if ok then
    oil.open(path)
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
end

--- Show the directories a package resolves to, asking which source root when
--- there is more than one. Leaves a jumplist entry first, the way Neovim's own
--- go-to-definition does, so `<C-o>` comes back.
---@param paths string[]
local function open_package(paths)
  local function jump(path)
    vim.cmd("normal! m'")
    M.open_directory(path)
  end

  if #paths == 1 then
    jump(paths[1])
    return
  end
  vim.ui.select(paths, {
    prompt = "Package directory",
    format_item = function(path)
      return vim.fn.fnamemodify(path, ":~:.")
    end,
  }, function(choice)
    if choice then -- cancelling leaves the jump undone, and says nothing
      jump(choice)
    end
  end)
end

--- Fix up the locations in this client's responses: collapse the duplicates, and
--- take package directories out of Neovim's hands.
---
--- vim.lsp.buf.definition() passes its own callback to the client, which means a
--- textDocument/definition entry in `handlers` is never consulted — the request
--- itself is the only place the plugin can reach the result without the caller
--- passing `on_list`. Wrapping the method on the client instance leaves every
--- other LSP client alone.
---@param client vim.lsp.Client
function M.attach(client)
  if client[wrapped] then
    return
  end
  client[wrapped] = true

  local request = client.request
  ---@diagnostic disable-next-line: duplicate-set-field
  client.request = function(self, method, params, handler, bufnr)
    if handler and location_methods[method] then
      local inner = handler
      handler = function(err, result, ctx, config)
        result = dedupe(result)

        -- Nothing but package directories: open the listing and let the request
        -- end here. Handing these on means Neovim either opens an empty buffer
        -- for the path or, with several of them, a quickfix list whose entries
        -- have nothing to show and whose window is left stranded next to the
        -- listing once one has been picked.
        local paths = directory_paths(result)
        if paths then
          open_package(paths)
          return
        end

        return inner(err, result, ctx, config)
      end
    end
    return request(self, method, params, handler, bufnr)
  end
end

--- Is this buffer served by the IntelliJ server? Used to tell a jump that came
--- out of a Java/Kotlin file from ordinary directory browsing, which belongs to
--- whatever file explorer the user has set up.
---@param bufnr integer
---@return boolean
local function is_served(bufnr)
  return bufnr > 0
    and vim.api.nvim_buf_is_valid(bufnr)
    and next(vim.lsp.get_clients({ bufnr = bufnr, name = "intellij-server" })) ~= nil
end

--- Is this the empty placeholder Neovim opens for a directory, rather than a
--- listing a file explorer has already put there (netrw sets 'filetype')?
---@param bufnr integer
---@return boolean
local function is_placeholder(bufnr)
  return vim.bo[bufnr].filetype == ""
    and vim.api.nvim_buf_line_count(bufnr) == 1
    and (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == ""
end

--- Replace the empty directory buffer a jump landed in with a listing.
---@param bufnr integer
local function handle_directory_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].intellij_navigated then
    return
  end
  -- Not the buffer on screen: the jump never got this far, or a file explorer
  -- claimed it (oil renames directory buffers to oil://).
  if bufnr ~= vim.api.nvim_get_current_buf() then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" or not is_directory(path) or not is_placeholder(bufnr) then
    return
  end
  -- Only jumps out of a file the IntelliJ server serves. Browsing directories
  -- any other way belongs to whatever explorer the user has set up.
  local previous = vim.fn.bufnr("#")
  if not is_served(previous) then
    return
  end

  vim.b[bufnr].intellij_navigated = true -- the fallback :edit re-enters this buffer
  -- Step back onto the file the jump came from before opening the listing, so
  -- that the placeholder is off screen and can be dropped: it is what oil would
  -- otherwise adopt while being loaded. open_directory takes it from there.
  vim.api.nvim_win_set_buf(0, previous)
  M.open_directory(path)
end

--- Catch a package directory that reached Neovim from a mixed answer or a picker
--- of the user's own, rather than through the response handler above.
function M.setup()
  -- BufNew covers the buffer the jump creates, BufEnter the one a previous jump
  -- (or a `:edit <dir>`) left behind — that one is not new, so BufNew is silent
  -- and without this the package would open as an empty buffer again.
  vim.api.nvim_create_autocmd({ "BufNew", "BufEnter" }, {
    group = vim.api.nvim_create_augroup("IntellijServerNavigation", { clear = true }),
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      if path == "" or not is_directory(path) then
        return
      end
      -- Neovim creates the buffer before putting it in the window, so wait for
      -- the jump to finish: only then is the directory the current buffer and
      -- the file it was requested from the alternate one.
      vim.schedule(function()
        handle_directory_buffer(args.buf)
      end)
    end,
    desc = "Open package definitions in oil instead of an empty directory buffer",
  })
end

return M
