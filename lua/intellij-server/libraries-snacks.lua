--- "External Libraries" node in the snacks.nvim explorer, below the project
--- files as in the IDE's Project view.
---
--- The explorer builds its list from the filesystem only (snacks.explorer.tree
--- scans real directories), so the node is grafted onto its output instead:
---   * the explorer finder is wrapped to append the node after the real tree,
---     with the libraries and their packages as children, expanded on demand
---     from the same trees the oil adapter lists (libraries.lua);
---   * the explorer's actions are wrapped so that on these items `confirm`
---     expands / opens, `explorer_close` collapses, and the file operations
---     refuse instead of acting on a path that does not exist;
---   * Actions.update is wrapped so following a jar:// / jrt:// buffer reveals
---     it under the node instead of creating folders for its name.
---
--- Items carry an `intellij` field and a made-up `file` path under
--- "<cwd>/External Libraries" that is only used as a key; files open through
--- their jar:// buffer (`item.buf`), never through `file`.
local M = {}

local NODE = "External Libraries"
local READ_ONLY = "[intellij-server] External Libraries are read-only"

--- Expanded node keys (item.file).
---@type table<string, boolean>
local expanded = {}
--- Loads in flight and roots that failed, so a redraw does not retry them.
local loading = {} ---@type table<any, boolean>
local failed = {} ---@type table<any, boolean>

local patched = false

local function libraries()
  return require("intellij-server.libraries")
end

--- intellij-server project root whose libraries belong under an explorer cwd.
---@param cwd string
---@return string?
local function root_for(cwd)
  local server = require("intellij-server.server")
  for _, client in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
    local root = vim.fs.normalize(client.root_dir or (client.config or {}).root_dir or "")
    if root ~= "" and server.is_under(cwd, root) then
      return root
    end
  end
end

---@param picker table snacks.Picker
---@param target string? Item key to put the cursor on.
local function refresh(picker, target)
  if not picker or picker.closed then
    return
  end
  picker.list:set_target()
  picker:find({
    on_done = function()
      if target then
        require("snacks.explorer.actions").reveal(picker, target)
      end
    end,
  })
end

--- Run an async load once; redraw the explorer when it succeeds.
---@param picker table
---@param key any
---@param start fun(cb: fun(err: string?))
---@param after fun()?
local function load_once(picker, key, start, after)
  if loading[key] or failed[key] then
    return
  end
  loading[key] = true
  start(function(err)
    loading[key] = nil
    if err then
      failed[key] = true
      vim.notify("[intellij-server] " .. err, vim.log.levels.WARN)
      return
    end
    if after then
      after()
    else
      refresh(picker)
    end
  end)
end

---@param picker table
---@param root string
---@param after fun()?
local function load_model(picker, root, after)
  load_once(picker, root, function(cb)
    libraries().load(root, {}, cb)
  end, after)
end

---@param picker table
---@param lib IntellijLibrary
---@param after fun()?
local function load_index(picker, lib, after)
  load_once(picker, lib, function(cb)
    libraries().library_index(lib, cb)
  end, after)
end

---@param a { name: string, type: string }
---@param b { name: string, type: string }
local function by_type_then_name(a, b)
  if (a.type == "directory") ~= (b.type == "directory") then
    return a.type == "directory"
  end
  return a.name < b.name
end

--- Items of the node and of everything expanded under it. The first item is
--- the node; its parent (the cwd item) is linked when the tree is emitted.
---@param picker table
---@param cwd string
---@return table[]?
local function build(picker, cwd)
  local root = root_for(cwd)
  if not root then
    return nil
  end
  local base = cwd .. "/" .. NODE
  local top = {
    file = base,
    text = NODE,
    dir = true,
    open = expanded[base] or false,
    type = "directory",
    intellij = { kind = "node", root = root },
  }
  local items = { top }
  if not top.open then
    return items
  end

  local model = libraries().model(root)
  if not model then
    load_model(picker, root)
    return items
  end

  local function add_children(parent, lib, path)
    local children = libraries().children(root, lib, path)
    if not children then
      load_index(picker, lib)
      return
    end
    table.sort(children, by_type_then_name)
    for i, child in ipairs(children) do
      local key = parent.file .. "/" .. child.name
      local dir = child.type == "directory"
      local item = {
        file = key,
        text = key,
        parent = parent,
        last = i == #children,
        dir = dir,
        open = dir and (expanded[key] or false) or nil,
        type = child.type,
        intellij = { kind = dir and "dir" or "file", root = root, lib = lib.name, path = child.path, target = child.target },
      }
      table.insert(items, item)
      if item.open then
        add_children(item, lib, child.path)
      end
    end
  end

  for i, lib in ipairs(model.libraries) do
    local key = base .. "/" .. lib.name
    local item = {
      file = key,
      text = key,
      parent = top,
      last = i == #model.libraries,
      dir = true,
      open = expanded[key] or false,
      type = "directory",
      intellij = { kind = "lib", root = root, lib = lib.name, path = "" },
    }
    table.insert(items, item)
    if item.open then
      add_children(item, lib, "")
    end
  end
  return items
end

---@param orig function The explorer finder.
---@return function
local function wrap_finder(orig)
  return function(opts, ctx)
    local result = orig(opts, ctx)
    -- Not while searching: that view comes from fd, over real files only.
    if type(result) ~= "function" or not ctx.filter:is_empty() or libraries().opts.explorer == false then
      return result
    end
    local cwd = ctx.filter.cwd
    local ok, virtual = pcall(build, ctx.picker, vim.fs.normalize(cwd))
    if not ok or not virtual then
      return result
    end
    return function(cb)
      local root_item, last_top
      result(function(item)
        if item.file == cwd then
          root_item = item
        elseif root_item and item.parent == root_item then
          last_top = item
        end
        cb(item)
      end)
      if not root_item then
        return
      end
      if last_top then
        last_top.last = false
      end
      virtual[1].parent = root_item
      virtual[1].last = true
      for _, item in ipairs(virtual) do
        cb(item)
      end
    end
  end
end

--- Expand the node down to a jar:// / jrt:// buffer and put the cursor on it.
---@param picker table
---@param bufname string
local function reveal_file(picker, bufname)
  local cwd = vim.fs.normalize(picker:cwd())
  local root = root_for(cwd)
  if not root then
    return
  end
  local model = libraries().model(root)
  if not model then
    return load_model(picker, root, function()
      reveal_file(picker, bufname)
    end)
  end
  local lib, entry = libraries().locate_entry(model, bufname)
  if not lib or not entry then
    return
  end
  local names = libraries().display_path(lib, entry)
  if not names then
    return load_index(picker, lib, function()
      reveal_file(picker, bufname)
    end)
  end
  local key = cwd .. "/" .. NODE
  expanded[key] = true
  key = key .. "/" .. lib.name
  expanded[key] = true
  for i = 1, #names - 1 do
    key = key .. "/" .. names[i]
    expanded[key] = true
  end
  refresh(picker, key .. "/" .. names[#names])
end

---@param picker table
---@param item table?
---@return boolean
local function touches_libraries(picker, item)
  if item and item.intellij then
    return true
  end
  for _, selected in ipairs(picker:selected() or {}) do
    if selected.intellij then
      return true
    end
  end
  return false
end

--- Wrap the explorer once. Safe to call repeatedly; false while snacks is not
--- available yet.
---@return boolean
function M.patch()
  if patched then
    return true
  end
  local ok, Source = pcall(require, "snacks.picker.source.explorer")
  if not ok or type(Source) ~= "table" or type(Source.explorer) ~= "function" then
    return false
  end
  local Actions = require("snacks.explorer.actions")
  local actions = Actions.actions
  patched = true

  Source.explorer = wrap_finder(Source.explorer)

  local confirm = actions.confirm
  actions.confirm = function(picker, item, action)
    local v = item and item.intellij
    if not v or picker.input.filter.meta.searching then
      return confirm(picker, item, action)
    end
    if item.dir then
      expanded[item.file] = not item.open or nil
      if v.kind == "node" then
        -- Reopening the node retries a load that failed.
        failed = {}
      end
      refresh(picker, item.file)
    else
      item.buf = vim.fn.bufadd(v.target)
      require("snacks.picker.actions").jump(picker, item, action)
    end
  end

  local close = actions.explorer_close
  actions.explorer_close = function(picker, item)
    if not (item and item.intellij) then
      return close(picker, item)
    end
    local target = (item.dir and item.open) and item or item.parent
    if target and target.intellij then
      expanded[target.file] = nil
      refresh(picker, target.file)
    end
  end

  local close_all = actions.explorer_close_all
  actions.explorer_close_all = function(picker, ...)
    expanded = {}
    return close_all(picker, ...)
  end

  local update = actions.explorer_update
  actions.explorer_update = function(picker, ...)
    failed = {}
    local root = root_for(vim.fs.normalize(picker:cwd()))
    if root and libraries().model(root) then
      libraries().load(root, { refresh = true }, function()
        refresh(picker)
      end)
    end
    return update(picker, ...)
  end

  for _, name in ipairs({
    "explorer_add",
    "explorer_del",
    "explorer_rename",
    "explorer_move",
    "explorer_copy",
    "explorer_paste",
    "explorer_open",
    "explorer_focus",
    "explorer_yank",
  }) do
    local orig = actions[name]
    if type(orig) == "function" then
      actions[name] = function(picker, item, ...)
        if touches_libraries(picker, item) then
          vim.notify(READ_ONLY, vim.log.levels.WARN)
          return
        end
        return orig(picker, item, ...)
      end
    end
  end

  -- follow_file passes the buffer name of a jar:// buffer here; the explorer
  -- would otherwise create tree nodes for it as if it were a path.
  local orig_update = Actions.update
  Actions.update = function(picker, opts)
    local target = opts and opts.target
    if type(target) == "string" and (target:match("^jar:") or target:match("^jrt:")) then
      if libraries().opts.explorer ~= false then
        reveal_file(picker, target)
      end
      return
    end
    return orig_update(picker, opts)
  end

  -- Preview (P) of a library file: show its jar:// buffer.
  local Preview = require("snacks.picker.preview")
  local preview_file = Preview.file
  Preview.file = function(ctx)
    local v = ctx.item and ctx.item.intellij
    if v and v.kind == "file" then
      if not ctx.item.buf or not vim.api.nvim_buf_is_valid(ctx.item.buf) then
        ctx.item.buf = vim.fn.bufadd(v.target)
      end
      ctx.item.preview_title = vim.fs.basename(ctx.item.file)
    end
    return preview_file(ctx)
  end

  return true
end

--- Redraw open explorers, e.g. once a server attaches and the node can show.
local function refresh_explorers()
  local snacks = package.loaded["snacks"]
  if not (patched and snacks and snacks.picker and snacks.picker.get) then
    return
  end
  for _, picker in ipairs(snacks.picker.get({ source = "explorer" })) do
    refresh(picker)
  end
end

function M.setup()
  M.patch()
  local seen = {} ---@type table<integer, boolean>
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("IntellijServerLibrariesSnacks", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "intellij-server" or seen[client.id] then
        return
      end
      seen[client.id] = true
      -- snacks may have been lazy-loaded after setup.
      if M.patch() then
        vim.schedule(refresh_explorers)
      end
    end,
    desc = "Add External Libraries to the snacks explorer",
  })
end

return M
