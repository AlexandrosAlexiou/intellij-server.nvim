--- External Libraries: the IDE's library tree, for browsing dependency and JDK
--- sources without first jumping into them with go to definition.
---
--- The server has no request that lists libraries or archive contents. Two
--- executeCommands cover it instead:
---   * `exportWorkspace <dir>` writes the imported workspace model to
---     `<dir>/workspace.json`: every library with its class and source roots,
---     and the SDKs. Paths are abbreviated with `<MAVEN_REPO>` / `<HOME>`.
---   * `decompile <uri>` returns the text of any entry of an archive that is
---     part of that model (see content-provider.lua).
--- The tree is built here from the export, with archive entries listed
--- locally (unzip/tar, jimage for a JDK without src.zip). Files open as the
--- same jar:// / jrt:// buffers go to definition produces.
---
--- Each library's classes and sources archives are merged into one tree. A
--- class with a matching source file is shown as the source only, since the
--- server decompiles classes to signature stubs. Inner classes are hidden.
local M = {}

local uv = vim.uv

M.SCHEME = "oil-intellij://"

---@class IntellijLibraryOpts
---@field compact_packages boolean? Merge chains of single-child packages ("org.springframework.boot") like the IDE.
---@field explorer boolean? Show an "External Libraries" node in the snacks.nvim explorer.
M.opts = { compact_packages = true, explorer = true }

---@class IntellijLibraryIndexEntry
---@field type "file"|"directory"
---@field target string? Buffer name a file opens as.

---@alias IntellijLibraryIndex table<string, table<string, IntellijLibraryIndexEntry>> Directory path ("" = root) -> children.

---@class IntellijLibrary
---@field name string Display name, unique within the workspace.
---@field classes string[] Class roots (archives or directories).
---@field sources string[] Source roots (archives or directories).
---@field jdk_home string? Set for a JDK.
---@field jimage boolean? List the JDK's classes from lib/modules (no src.zip).
---@field index IntellijLibraryIndex? Built on first listing.

---@class IntellijWorkspaceModel
---@field root string
---@field libraries IntellijLibrary[]
---@field by_name table<string, IntellijLibrary>
---@field loaded_at integer

---@type table<string, IntellijWorkspaceModel>
local models = {}

---@type table<string, { key: string, entries: string[] }>
local listings = {}

--- A model younger than this is reused instead of exporting again; listing the
--- top level right after opening it would otherwise export twice.
local REFRESH_AFTER_MS = 2000

local SOURCE_EXT = { java = true, kt = true, groovy = true, scala = true }

---@param a string
---@param b string
---@return string
local function join(a, b)
  if a == "" then
    return b
  end
  return a .. "/" .. b
end

---@param path string
---@return string dir, string base
local function split(path)
  local dir, base = path:match("^(.*)/([^/]+)$")
  if not dir then
    return "", path
  end
  return dir, base
end

---@param client vim.lsp.Client
---@return string
local function client_root(client)
  return vim.fs.normalize(client.root_dir or (client.config or {}).root_dir or "")
end

---@param root string
---@return vim.lsp.Client?
local function client_for_root(root)
  for _, client in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
    if client_root(client) == root then
      return client
    end
  end
end

-- ---------------------------------------------------------------------------
-- URLs: oil-intellij://<project root>!/<library>/<path inside it>/
-- ---------------------------------------------------------------------------

---@param root string
---@param lib string?
---@param path string?
---@return string
function M.url(root, lib, path)
  local url = M.SCHEME .. root .. "!/"
  if lib then
    url = url .. lib .. "/"
    if path and path ~= "" then
      url = url .. path .. "/"
    end
  end
  return url
end

---@param url string
---@return { root: string, lib: string?, path: string }?
function M.parse_url(url)
  if not vim.startswith(url, M.SCHEME) then
    return nil
  end
  local root, inner = url:sub(#M.SCHEME + 1):match("^(.-)!/(.*)$")
  if not root then
    return nil
  end
  inner = inner:gsub("/+$", "")
  local lib, path = inner:match("^([^/]+)/?(.*)$")
  return { root = root, lib = lib, path = path or "" }
end

-- ---------------------------------------------------------------------------
-- Workspace model
-- ---------------------------------------------------------------------------

---@return string
local function maven_repo()
  local home = assert(uv.os_homedir())
  local settings = vim.fs.joinpath(home, ".m2", "settings.xml")
  local f = io.open(settings, "r")
  if f then
    local text = f:read("*a")
    f:close()
    -- Drop comments: settings.xml ships a commented-out example.
    text = text:gsub("<!%-%-.-%-%->", "")
    local repo = text:match("<localRepository>%s*(.-)%s*</localRepository>")
    if repo and repo ~= "" then
      return (repo:gsub("%${user%.home}", function()
        return home
      end))
    end
  end
  return vim.fs.joinpath(home, ".m2", "repository")
end

---@param path string
---@return string
local function expand(path)
  if path:match("^<MAVEN_REPO>") then
    local repo = maven_repo()
    path = path:gsub("^<MAVEN_REPO>", function()
      return repo
    end)
  end
  if path:match("^<HOME>") then
    local home = assert(uv.os_homedir())
    path = path:gsub("^<HOME>", function()
      return home
    end)
  end
  return vim.fs.normalize(path)
end

---@param home string
---@return string?
local function jdk_version(home)
  local f = io.open(home .. "/release", "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text:match('JAVA_VERSION="([^"]+)"')
end

---@param root string
---@param ws table Decoded workspace.json.
---@return IntellijWorkspaceModel
local function parse_workspace(root, ws)
  ---@type IntellijWorkspaceModel
  local model = { root = root, libraries = {}, by_name = {}, loaded_at = uv.now() }

  ---@param lib IntellijLibrary
  local function add(lib)
    -- "/" would split the name into URL segments.
    local name = lib.name:gsub("/", "∕")
    local unique, n = name, 1
    while model.by_name[unique] do
      n = n + 1
      unique = ("%s (%d)"):format(name, n)
    end
    lib.name = unique
    model.by_name[unique] = lib
    table.insert(model.libraries, lib)
  end

  for _, lib in ipairs(ws.libraries or {}) do
    local classes, sources = {}, {}
    for _, r in ipairs(lib.roots or {}) do
      -- CLASSES roots are exported without a type.
      if type(r.path) == "string" then
        if r.type == nil or r.type == vim.NIL or r.type == "CLASSES" then
          table.insert(classes, expand(r.path))
        elseif r.type == "SOURCES" then
          table.insert(sources, expand(r.path))
        end
      end
    end
    if #classes > 0 or #sources > 0 then
      add({ name = type(lib.name) == "string" and lib.name or "?", classes = classes, sources = sources })
    end
  end

  table.sort(model.libraries, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  -- The export lists SDKs by home only; their content comes from the JDK
  -- itself: lib/src.zip when installed, else the class list of lib/modules.
  for _, sdk in ipairs(ws.sdks or {}) do
    local home = type(sdk.homePath) == "string" and expand(sdk.homePath) or nil
    if home and vim.fn.isdirectory(home) == 1 then
      local version = jdk_version(home)
      local lib = {
        name = ("< %s >"):format(version or sdk.name or "JDK"),
        classes = {},
        sources = {},
        jdk_home = home,
      }
      if vim.fn.filereadable(home .. "/lib/src.zip") == 1 then
        lib.sources = { home .. "/lib/src.zip" }
      elseif vim.fn.filereadable(home .. "/lib/modules") == 1 then
        lib.jimage = true
      end
      add(lib)
    end
  end

  return model
end

---@param root string
---@return string
local function export_dir(root)
  return vim.fn.stdpath("cache") .. "/intellij-server/workspaces/" .. vim.fn.sha256(root):sub(1, 16)
end

--- Load (or refresh) the workspace model of a project.
---@param root string
---@param opts { refresh: boolean? }
---@param cb fun(err: string?, model: IntellijWorkspaceModel?)
function M.load(root, opts, cb)
  local model = models[root]
  if model and not (opts.refresh and uv.now() - model.loaded_at > REFRESH_AFTER_MS) then
    return cb(nil, model)
  end

  local client = client_for_root(root)
  if not client then
    return cb(("intellij-server is not running for %s"):format(vim.fn.fnamemodify(root, ":~")))
  end

  local dir = export_dir(root)
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/workspace.json"
  os.remove(file)

  client:request(
    "workspace/executeCommand",
    { command = "exportWorkspace", arguments = { dir } },
    vim.schedule_wrap(function(err)
      if err then
        return cb("exportWorkspace failed: " .. (err.message or vim.inspect(err)))
      end
      local f = io.open(file, "r")
      if not f then
        -- A shared server on another host writes the file over there.
        return cb("the server did not write " .. file)
      end
      local ok, ws = pcall(vim.json.decode, f:read("*a"))
      f:close()
      if not ok or type(ws) ~= "table" then
        return cb("could not parse " .. file)
      end

      local new = parse_workspace(root, ws)
      -- Keep the trees of libraries whose roots did not change.
      if model then
        for _, lib in ipairs(new.libraries) do
          local old = model.by_name[lib.name]
          if old and vim.deep_equal(old.classes, lib.classes) and vim.deep_equal(old.sources, lib.sources) then
            lib.index = old.index
          end
        end
      end
      models[root] = new
      cb(nil, new)
    end)
  )
end

-- ---------------------------------------------------------------------------
-- Archive listing and library trees
-- ---------------------------------------------------------------------------

--- Expanding many libraries at once would otherwise start one process per
--- archive at the same time.
local MAX_JOBS = 8
local running_jobs = 0
local job_queue = {} ---@type fun()[]

--- vim.system with at most MAX_JOBS processes running.
---@param cmd string[]
---@param on_exit fun(err: string?, res: vim.SystemCompleted?) Called in the main loop.
local function run_job(cmd, on_exit)
  local function start()
    running_jobs = running_jobs + 1
    local function finish(err, res)
      running_jobs = running_jobs - 1
      local next_job = table.remove(job_queue, 1)
      if next_job then
        next_job()
      end
      on_exit(err, res)
    end
    local ok, err = pcall(vim.system, cmd, { text = true }, vim.schedule_wrap(function(res)
      finish(nil, res)
    end))
    if not ok then
      finish(("cannot run %s: %s"):format(cmd[1], err))
    end
  end
  if running_jobs < MAX_JOBS then
    start()
  else
    table.insert(job_queue, start)
  end
end

--- List the entries of a library root: archive entries ("a/b/", "a/b/C.class"),
--- or the files under a directory root.
---@param path string
---@param jimage_home string? List a JDK's lib/modules with jimage instead.
---@param cb fun(err: string?, entries: string[]?)
local function list_root(path, jimage_home, cb)
  local stat = uv.fs_stat(path)
  if not stat then
    return cb(("%s does not exist"):format(vim.fn.fnamemodify(path, ":~")))
  end
  if stat.type == "directory" then
    local entries = {}
    for name, kind in vim.fs.dir(path, { depth = 100 }) do
      table.insert(entries, kind == "directory" and name .. "/" or name)
    end
    return cb(nil, entries)
  end

  local key = ("%d:%d"):format(stat.mtime.sec, stat.size)
  local cached = listings[path]
  if cached and cached.key == key then
    return cb(nil, cached.entries)
  end

  local cmd
  if jimage_home then
    cmd = { jimage_home .. "/bin/jimage", "list", path }
  elseif vim.fn.executable("unzip") == 1 then
    cmd = { "unzip", "-Z1", path }
  else
    cmd = { "tar", "-tf", path }
  end

  run_job(cmd, function(job_err, res)
    if job_err or not res then
      return cb(job_err)
    end
    if res.code ~= 0 then
      return cb(("listing %s failed: %s"):format(vim.fn.fnamemodify(path, ":~"), vim.trim(res.stderr or "")))
    end
    local entries = {}
    local module
    for line in (res.stdout or ""):gmatch("[^\r\n]+") do
      if jimage_home then
        -- "Module: java.base" followed by indented entries of that module.
        local m = line:match("^Module:%s*(%S+)")
        if m then
          module = m
        elseif module then
          local entry = vim.trim(line)
          if entry ~= "" then
            table.insert(entries, module .. "/" .. entry)
          end
        end
      else
        table.insert(entries, line)
      end
    end
    listings[path] = { key = key, entries = entries }
    cb(nil, entries)
  end)
end

---@param root_path string
---@param entry string
---@param kind "archive"|"directory"|"jimage"
---@param jdk_home string?
---@return string
local function target_for(root_path, entry, kind, jdk_home)
  if kind == "directory" then
    return root_path .. "/" .. entry
  elseif kind == "jimage" then
    return "jrt://" .. jdk_home .. "!/" .. entry
  end
  return "jar://" .. root_path .. "!/" .. entry
end

---@param index IntellijLibraryIndex
---@param path string
---@param kind "file"|"directory"
---@param target string?
local function add_entry(index, path, kind, target)
  local parent, name = split(path)
  if not index[parent] then
    add_entry(index, parent, "directory")
  end
  local children = index[parent]
  if kind == "directory" then
    index[path] = index[path] or {}
    children[name] = children[name] or { type = "directory" }
  elseif not children[name] then
    children[name] = { type = "file", target = target }
  end
end

---@param lib IntellijLibrary
---@param roots { path: string, kind: "sources"|"classes", entries: string[]?, is_dir: boolean }[]
---@return IntellijLibraryIndex
local function build_index(lib, roots)
  ---@type IntellijLibraryIndex
  local index = { [""] = {} }
  local source_stems = {} ---@type table<string, table<string, boolean>>

  local function walk(root, on_file)
    local kind = root.is_dir and "directory" or (lib.jimage and root.kind == "classes") and "jimage" or "archive"
    for _, entry in ipairs(root.entries or {}) do
      entry = entry:gsub("^/+", "")
      if entry:sub(-1) == "/" then
        if #entry > 1 then
          add_entry(index, entry:sub(1, -2), "directory")
        end
      elseif entry ~= "" then
        on_file(entry, target_for(root.path, entry, kind, lib.jdk_home))
      end
    end
  end

  for _, root in ipairs(roots) do
    if root.kind == "sources" then
      walk(root, function(entry, target)
        add_entry(index, entry, "file", target)
        local dir, base = split(entry)
        local stem, ext = base:match("^(.*)%.([^.]+)$")
        if stem and SOURCE_EXT[ext] then
          source_stems[dir] = source_stems[dir] or {}
          source_stems[dir][stem] = true
        end
      end)
    end
  end

  for _, root in ipairs(roots) do
    if root.kind == "classes" then
      walk(root, function(entry, target)
        local dir, base = split(entry)
        local stem = base:match("^(.*)%.class$")
        if stem then
          if stem:find("$", 1, true) then
            return
          end
          local stems = source_stems[dir]
          -- Kotlin file facades: Foo.kt compiles to FooKt.class.
          if stems and (stems[stem] or (stem:match("Kt$") and stems[stem:sub(1, -3)])) then
            return
          end
        end
        add_entry(index, entry, "file", target)
      end)
    end
  end

  return index
end

--- Build (once) and return the merged tree of a library.
---@param lib IntellijLibrary
---@param cb fun(err: string?, index: IntellijLibraryIndex?)
function M.library_index(lib, cb)
  if lib.index then
    return cb(nil, lib.index)
  end

  local roots = {}
  for _, path in ipairs(lib.sources) do
    table.insert(roots, { path = path, kind = "sources" })
  end
  for _, path in ipairs(lib.classes) do
    table.insert(roots, { path = path, kind = "classes" })
  end
  if lib.jimage then
    table.insert(roots, { path = lib.jdk_home .. "/lib/modules", kind = "classes", jimage = true })
  end
  if #roots == 0 then
    lib.index = { [""] = {} }
    return cb(nil, lib.index)
  end

  local pending = #roots
  for _, root in ipairs(roots) do
    root.is_dir = vim.fn.isdirectory(root.path) == 1
    list_root(root.path, root.jimage and lib.jdk_home or nil, function(err, entries)
      root.err, root.entries = err, entries
      pending = pending - 1
      if pending > 0 then
        return
      end
      -- A missing sources archive is fine; a library with nothing listable is not.
      local first_err
      local any = false
      for _, r in ipairs(roots) do
        if r.entries then
          any = true
        else
          first_err = first_err or r.err
        end
      end
      if not any then
        return cb(first_err)
      end
      lib.index = build_index(lib, roots)
      cb(nil, lib.index)
    end)
  end
end

---@param name string
---@return boolean
local function is_identifier(name)
  return name:match("^[%a_$][%w_$]*$") ~= nil
end

--- The only child of a directory, when that child is a package directory the
--- IDE would fold into its parent.
---@param index IntellijLibraryIndex
---@param path string
---@return string?
local function sole_package_child(index, path)
  local children = index[path]
  if not children then
    return nil
  end
  local only
  for name, entry in pairs(children) do
    if only or entry.type ~= "directory" then
      return nil
    end
    only = name
  end
  if only and is_identifier(only) then
    return only
  end
  return nil
end

--- Whether a directory is folded into a compacted name and never shown itself.
---@param index IntellijLibraryIndex
---@param path string
---@return boolean
local function is_folded(index, path)
  if not M.opts.compact_packages or path == "" then
    return false
  end
  local _, base = split(path)
  return is_identifier(base) and sole_package_child(index, path) ~= nil
end

---@class IntellijLibraryItem
---@field name string
---@field type "file"|"directory"
---@field target string Buffer name (files) or oil-intellij:// URL (directories).
---@field path string? Path inside the library (directories).

--- Display name and real path of a directory entry, folding a chain of
--- single-child packages into one dotted name the way the IDE does.
---@param index IntellijLibraryIndex
---@param parent string
---@param name string
---@return string display, string path, integer segments Number of path segments folded in.
local function fold(index, parent, name)
  local display, path, segments = name, join(parent, name), 1
  if M.opts.compact_packages and is_identifier(name) then
    local child = sole_package_child(index, path)
    while child do
      display = display .. "." .. child
      path = path .. "/" .. child
      segments = segments + 1
      child = sole_package_child(index, path)
    end
  end
  return display, path, segments
end

--- Children of a directory of a library whose tree is built.
---@param root string
---@param lib IntellijLibrary
---@param path string Directory inside the library ("" for its root).
---@return IntellijLibraryItem[]?
function M.children(root, lib, path)
  local children = lib.index and lib.index[path]
  if not children then
    return nil
  end
  local items = {}
  for name, entry in pairs(children) do
    if entry.type == "directory" then
      local display, real = fold(lib.index, path, name)
      table.insert(items, { name = display, type = "directory", target = M.url(root, lib.name, real), path = real })
    else
      table.insert(items, { name = name, type = "file", target = entry.target })
    end
  end
  return items
end

--- Display names leading to an entry of a library: folded package directories,
--- then the file name. Nil until the library's tree is built.
---@param lib IntellijLibrary
---@param entry string
---@return string[]?
function M.display_path(lib, entry)
  if not lib.index then
    return nil
  end
  local segments = vim.split(entry, "/", { plain = true })
  local names, path, i = {}, "", 1
  while i < #segments do
    local display, real, folded = fold(lib.index, path, segments[i])
    table.insert(names, display)
    path = real
    i = i + folded
  end
  table.insert(names, segments[#segments])
  return names
end

---@param root string
---@return IntellijWorkspaceModel?
function M.model(root)
  return models[root]
end

--- List the children of an oil-intellij:// URL.
---@param url string
---@param cb fun(err: string?, items: IntellijLibraryItem[]?)
function M.list(url, cb)
  local parsed = M.parse_url(url)
  if not parsed then
    return cb("not a library URL: " .. url)
  end
  local root = parsed.root

  -- Listing the top level re-exports, so a re-import shows up on refresh.
  M.load(root, { refresh = parsed.lib == nil }, function(err, model)
    if err or not model then
      return cb(err)
    end

    if not parsed.lib then
      local items = {}
      for _, lib in ipairs(model.libraries) do
        table.insert(items, { name = lib.name, type = "directory", target = M.url(root, lib.name) })
      end
      if #items == 0 then
        vim.notify("[intellij-server] The workspace has no libraries yet (still importing?)", vim.log.levels.INFO)
      end
      return cb(nil, items)
    end

    local lib = model.by_name[parsed.lib]
    if not lib then
      return cb(("%s is not a library of this workspace"):format(parsed.lib))
    end
    M.library_index(lib, function(index_err, index)
      if index_err or not index then
        return cb(index_err)
      end
      local items = index and M.children(root, lib, parsed.path)
      if not items then
        return cb(("%s not found in %s"):format(parsed.path, lib.name))
      end
      cb(nil, items)
    end)
  end)
end

--- Parent URL, skipping directories folded into a compacted package name.
---@param url string
---@return string
function M.parent(url)
  local parsed = M.parse_url(url)
  if not parsed then
    return url
  end
  if not parsed.lib then
    -- Above the library list: the project itself.
    return "oil://" .. parsed.root .. "/"
  end
  if parsed.path == "" then
    return M.url(parsed.root)
  end
  local path = split(parsed.path)
  local model = models[parsed.root]
  local lib = model and model.by_name[parsed.lib]
  local index = lib and lib.index
  if index then
    while is_folded(index, path) do
      path = split(path)
    end
  end
  return M.url(parsed.root, parsed.lib, path)
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

--- Project root to show libraries for, from the current buffer.
---@param bufnr integer
---@return string?
function M.resolve_root(bufnr)
  local clients = vim.lsp.get_clients({ name = "intellij-server" })
  if #clients == 0 then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local parsed = M.parse_url(name)
  if parsed then
    return parsed.root
  end

  local server = require("intellij-server.server")
  local path = name:gsub("^oil://", "")
  for _, candidate in ipairs({ path, vim.fn.getcwd() }) do
    for _, client in ipairs(clients) do
      if candidate ~= "" and server.is_under(candidate, client_root(client)) then
        return client_root(client)
      end
    end
  end
  -- jar:// buffers and anything else: the client attached to it, or any.
  local attached = vim.lsp.get_clients({ name = "intellij-server", bufnr = bufnr })
  return client_root(attached[1] or clients[1])
end

---@param a string
---@param b string
---@return boolean
local function same_path(a, b)
  if a == b then
    return true
  end
  local ra, rb = uv.fs_realpath(a), uv.fs_realpath(b)
  return ra ~= nil and ra == rb
end

--- Library and entry path of a jar:// / jrt:// buffer. Accepts the
--- slash-collapsed forms (jar:/Users/...) path normalization produces.
---@param model IntellijWorkspaceModel
---@param bufname string
---@return IntellijLibrary? lib, string? entry
function M.locate_entry(model, bufname)
  local archive, entry = bufname:match("^jar:/+(.-)!/(.*)$")
  local home
  if archive then
    archive = "/" .. archive
  else
    home, entry = bufname:match("^jrt:/+(.-)!/(.*)$")
    home = home and "/" .. home
  end
  if not entry then
    return nil
  end
  for _, lib in ipairs(model.libraries) do
    if archive then
      for _, path in ipairs(vim.list_extend(vim.list_extend({}, lib.sources), lib.classes)) do
        if same_path(path, archive) then
          return lib, entry
        end
      end
    elseif lib.jdk_home and same_path(lib.jdk_home, home) then
      return lib, entry
    end
  end
  return nil
end

--- Library directory URL and file name of a jar:// / jrt:// buffer.
---@param model IntellijWorkspaceModel
---@param bufname string
---@return string? url, string? basename
local function locate(model, bufname)
  local lib, entry = M.locate_entry(model, bufname)
  if not lib or not entry then
    return nil
  end
  local dir, base = split(entry)
  return M.url(model.root, lib.name, dir), base
end

--- Open the library tree in oil. From a jar:// / jrt:// buffer it opens on the
--- directory of that file with the cursor on it.
---@param opts { refresh: boolean? }?
function M.open(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local root = M.resolve_root(bufnr)
  if not root then
    vim.notify("[intellij-server] The server is not running", vim.log.levels.WARN)
    return
  end
  local has_oil, oil = pcall(require, "oil")
  if not has_oil then
    vim.notify("[intellij-server] :IntellijServerLibraries needs oil.nvim", vim.log.levels.WARN)
    return
  end
  require("intellij-server.libraries-oil").register()

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  M.load(root, { refresh = opts.refresh }, function(err, model)
    if err or not model then
      vim.notify("[intellij-server] " .. err, vim.log.levels.WARN)
      return
    end
    local url, basename = locate(model, bufname)
    url = url or M.url(root)
    if basename then
      require("oil.view").set_last_cursor(url, basename)
    end
    vim.cmd("normal! m'")
    oil.open(url)
  end)
end

--- Drop cached models (e.g. after a server restart).
function M.reset()
  models = {}
end

---@param opts IntellijLibraryOpts?
function M.setup(opts)
  M.opts = vim.tbl_extend("force", M.opts, opts or {})
  require("intellij-server.libraries-oil").setup()
  if M.opts.explorer ~= false then
    require("intellij-server.libraries-snacks").setup()
  end
end

return M
