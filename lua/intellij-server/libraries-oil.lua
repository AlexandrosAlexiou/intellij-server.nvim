--- oil.nvim adapter for the External Libraries tree (oil-intellij:// URLs).
---
--- Directories are oil buffers listed from libraries.lua. Files are not oil
--- URLs at all: each entry carries the jar:// / jrt:// buffer name it opens
--- as, and the content provider loads it like a go-to-definition target.
---
--- Oil has no public API for adapters. It resolves a scheme through
--- `config.adapters` (scheme -> name) and `require("oil.adapters.<name>")`,
--- and registers its BufReadCmd only for the schemes known at its setup. So
--- the scheme is (re)registered before every use, the module is preloaded
--- under oil's name, and this plugin owns the BufReadCmd for its scheme.
local M = {}

local NAME = "intellij_server"
local FIELD_META = 4

local function libraries()
  return require("intellij-server.libraries")
end

---@param url string
---@param callback fun(url: string)
function M.normalize_url(url, callback)
  if not vim.endswith(url, "/") then
    url = url .. "/"
  end
  callback(url)
end

---@param url string
---@param entry { meta: { target: string }? }
---@param callback fun(path: string)
function M.get_entry_path(url, entry, callback)
  callback(entry.meta and entry.meta.target or url)
end

---@param bufname string
---@return string
function M.get_parent(bufname)
  return libraries().parent(bufname)
end

---@param url string
---@param _ string[]
---@param callback fun(err?: string, entries?: table[], fetch_more?: fun())
function M.list(url, _, callback)
  local cache = require("oil.cache")
  libraries().list(url, function(err, items)
    if err or not items then
      return callback(err)
    end
    local entries = {}
    for _, item in ipairs(items) do
      local entry = cache.create_entry(url, item.name, item.type)
      entry[FIELD_META] = { target = item.target }
      table.insert(entries, entry)
    end
    callback(nil, entries)
  end)
end

---@return boolean
function M.is_modifiable()
  return false
end

---@return nil
function M.get_column()
  return nil
end

M.supported_cross_adapter_actions = {}

---@param action { type: string, url: string? }
---@return string
function M.render_action(action)
  return ("%s %s (read-only)"):format(action.type:upper(), action.url or "")
end

---@param _ table
---@param callback fun(err: string?)
function M.perform_action(_, callback)
  callback("External Libraries are read-only")
end

--- Only directory URLs are ever produced; a file URL typed by hand is sent to
--- the buffer it stands for.
---@param bufnr integer
function M.read_file(bufnr)
  vim.notify("[intellij-server] Library files open as jar:// buffers", vim.log.levels.WARN)
  vim.bo[bufnr].modifiable = false
end

--- Make oil resolve oil-intellij:// to this adapter. Idempotent; oil's own
--- setup resets its adapter tables, so this runs before each use.
---@return boolean registered False when oil is not installed.
function M.register()
  local ok, config = pcall(require, "oil.config")
  if not ok then
    return false
  end
  local scheme = libraries().SCHEME
  package.loaded["oil.adapters." .. NAME] = M
  config.adapters = config.adapters or {}
  config.adapter_to_scheme = config.adapter_to_scheme or {}
  config._adapter_by_scheme = config._adapter_by_scheme or {}
  config.adapters[scheme] = NAME
  config.adapter_to_scheme[NAME] = scheme
  M.name = NAME
  config._adapter_by_scheme[scheme] = M
  return true
end

function M.setup()
  local scheme = libraries().SCHEME
  vim.filetype.add({
    pattern = { [vim.pesc(scheme) .. ".*"] = { "oil", { priority = 10 } } },
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = vim.api.nvim_create_augroup("IntellijServerLibraries", { clear = true }),
    pattern = scheme .. "*",
    nested = true,
    callback = function(ev)
      local ok, oil = pcall(require, "oil")
      if not ok or not M.register() then
        vim.notify("[intellij-server] The library tree needs oil.nvim", vim.log.levels.WARN)
        return
      end
      oil.load_oil_buffer(ev.buf)
    end,
    desc = "Load IntelliJ External Libraries directories in oil",
  })
end

return M
