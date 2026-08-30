--- Process and cache management.
--- On Unix the server runs as a process-group leader (the client is started
--- with `detached = true`, so libuv setsid()s it), meaning all its descendants
--- (jbr JVM, Maven imports) share its PGID and can be killed as a group, even
--- after being reparented to PID 1.
--- On Windows, taskkill /T kills the process tree instead.
local M = {}

--- Kill the server and all its descendants (SIGTERM, then SIGKILL stragglers).
---@param pid integer The group leader's PID (== PGID on Unix).
function M.kill_tree(pid)
  if vim.fn.has("win32") == 1 then
    vim.fn.system(("taskkill /PID %d /T /F"):format(pid))
    return
  end
  -- /bin/kill: shell builtins may reject the `-- -PGID` group syntax
  vim.fn.system(("/bin/kill -TERM -- -%d 2>/dev/null"):format(pid))
  vim.fn.system(("sleep 0.3; /bin/kill -KILL -- -%d 2>/dev/null"):format(pid))
end

--- PIDs of the server processes we spawned: our direct children running the
--- server binary. Neovim used to expose this as client.rpc.pid(), but 0.12
--- dropped it from vim.lsp.rpc.PublicClient, so look it up ourselves.
--- The server is detached, hence its own group leader, so each PID is a PGID.
---@return integer[]
local function server_pids()
  local pids = {}
  local ok, children = pcall(vim.api.nvim_get_proc_children, vim.fn.getpid())
  if not ok then
    return pids
  end
  for _, pid in ipairs(children) do
    local info = vim.api.nvim_get_proc(pid)
    -- Linux truncates comm to 15 chars, which "intellij-server" just fits.
    if type(info) == "table" and info.name and info.name:find("intellij%-server") then
      table.insert(pids, pid)
    end
  end
  return pids
end

--- Kill process groups of all running intellij-server clients.
function M.kill_all_clients()
  local pids = server_pids()

  for _, client in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
    -- rpc.pid() only exists on Neovim < 0.12; server_pids() covers the rest.
    ---@diagnostic disable-next-line: undefined-field
    local pid = client.rpc and client.rpc.pid and client.rpc.pid()
    if pid and not vim.tbl_contains(pids, pid) then
      table.insert(pids, pid)
    end
    client:stop(true)
  end

  for _, pid in ipairs(pids) do
    M.kill_tree(pid)
  end
end

--- Persistent data directory for indexes, config, and logs.
---@return string
function M.data_dir()
  return vim.fn.stdpath("data") .. "/intellij-server/data"
end

--- Open the server log (see -Didea.log.path in server.build_env) alongside
--- Neovim's LSP RPC log, both scrolled to the end.
function M.show_logs()
  local server_log = M.data_dir() .. "/log/intellij-server.log"
  if vim.fn.filereadable(server_log) == 1 then
    vim.cmd("split | edit " .. vim.fn.fnameescape(server_log) .. " | normal! G")
  else
    vim.notify("[intellij-server] Server log not found yet: " .. server_log, vim.log.levels.INFO)
  end

  -- Neovim's LSP RPC log (shared across clients).
  vim.cmd("vsplit | edit " .. vim.fn.fnameescape(vim.lsp.log.get_filename()) .. " | normal! G")
end

--- Paths removed by :IntellijServerClean for one project root.
--- The server keeps per-workspace state (workspace-model.cache with the
--- imported modules and SDK bindings, plus the workspace index) under
--- JetBrains/IntelliJServer/workspaces/<hash>. The hash is opaque, but each
--- workspace-model.cache embeds the project's paths, so the dirs belonging to
--- a root are found by content. Shared stores (the data dir, the analyzer
--- RocksDB cache) hold state for every project and are left alone.
---@param root_dir string
---@return string[]
function M.get_data_paths(root_dir)
  local caches_root
  if vim.fn.has("win32") == 1 then
    caches_root = os.getenv("LOCALAPPDATA") or ((os.getenv("USERPROFILE") or "") .. "/AppData/Local")
  elseif vim.fn.has("mac") == 1 then
    caches_root = (os.getenv("HOME") or "") .. "/Library/Caches"
  else
    caches_root = os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "") .. "/.cache")
  end

  local paths = {}
  for _, dir in ipairs(vim.fn.glob(caches_root .. "/JetBrains/IntelliJServer/workspaces/*", true, true)) do
    local cache = io.open(dir .. "/index/intellij-server/workspace-model.cache", "rb")
    if cache then
      local content = cache:read("*a") or ""
      cache:close()
      -- Trailing slash so /a/foo cannot match a workspace of /a/foo-bar.
      if content:find(root_dir:gsub("/$", "") .. "/", 1, true) then
        table.insert(paths, dir)
      end
    end
  end
  return paths
end

--- Clean the current project's workspace caches and restart its server.
--- Other projects' servers and caches are untouched.
function M.clean_and_restart()
  local client = vim.lsp.get_clients({ name = "intellij-server", bufnr = 0 })[1]
    or vim.lsp.get_clients({ name = "intellij-server" })[1]
  local root_dir = client and client.config.root_dir
  if not root_dir then
    vim.notify("[intellij-server] No running client to determine the project root.", vim.log.levels.WARN)
    return
  end

  if client then
    vim.notify("[intellij-server] Stopping LSP for " .. root_dir .. "...", vim.log.levels.INFO)
    -- rpc.pid() only exists on Neovim < 0.12; stop(true) kills the direct
    -- process either way, kill_tree additionally reaps import children.
    ---@diagnostic disable-next-line: undefined-field
    local pid = client.rpc and client.rpc.pid and client.rpc.pid()
    client:stop(true)
    if pid then
      M.kill_tree(pid)
    end
  end
  vim.cmd("sleep 500m")

  local cleaned = {}
  for _, dir in ipairs(M.get_data_paths(root_dir)) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.fn.delete(dir, "rf")
      table.insert(cleaned, dir)
    end
  end

  if #cleaned > 0 then
    vim.notify("[intellij-server] Cleaned:\n  " .. table.concat(cleaned, "\n  "), vim.log.levels.INFO)
  else
    vim.notify("[intellij-server] No workspace caches found for " .. root_dir, vim.log.levels.INFO)
  end

  vim.defer_fn(function()
    require("intellij-server").start()
    vim.notify("[intellij-server] Restarted.", vim.log.levels.INFO)
  end, 500)
end

return M
