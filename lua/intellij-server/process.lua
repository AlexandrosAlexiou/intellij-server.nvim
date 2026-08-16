--- Process and cache management.
--- On Unix the server runs as a process-group leader (see server.build_cmd),
--- so all its descendants (jbr JVM, Maven imports) share its PGID and can be
--- killed as a group, even after being reparented to PID 1.
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

--- Kill process groups of all running intellij-server clients.
function M.kill_all_clients()
  for _, client in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
    local pid = client.rpc and client.rpc.pid and client.rpc.pid()
    if pid then
      M.kill_tree(pid)
    end
    client:stop(true)
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
  local get_path = vim.lsp.log and vim.lsp.log.get_filename or vim.lsp.get_log_path
  vim.cmd("vsplit | edit " .. vim.fn.fnameescape(get_path()) .. " | normal! G")
end

--- Paths removed by :IntellijServerClean.
---@return string[]
function M.get_data_paths()
  local paths = { M.data_dir() }

  -- The analyzer writes RocksDB indexes to a separate cache dir
  local analyzer_cache
  if vim.fn.has("win32") == 1 then
    local local_app_data = os.getenv("LOCALAPPDATA") or ((os.getenv("USERPROFILE") or "") .. "/AppData/Local")
    analyzer_cache = local_app_data .. "/JetBrains/analyzer"
  elseif vim.fn.has("mac") == 1 then
    analyzer_cache = (os.getenv("HOME") or "") .. "/Library/Caches/JetBrains/analyzer"
  else
    local xdg_cache = os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "") .. "/.cache")
    analyzer_cache = xdg_cache .. "/JetBrains/analyzer"
  end
  if vim.fn.isdirectory(analyzer_cache) == 1 then
    table.insert(paths, analyzer_cache)
  end

  return paths
end

--- Clean all indexes/caches and restart the server.
function M.clean_and_restart()
  local clients = vim.lsp.get_clients({ name = "intellij-server" })
  if #clients > 0 then
    vim.notify("[intellij-server] Stopping LSP...", vim.log.levels.INFO)
    M.kill_all_clients()
  end
  vim.cmd("sleep 500m")

  local cleaned = {}
  for _, dir in ipairs(M.get_data_paths()) do
    if vim.fn.isdirectory(dir) == 1 then
      vim.fn.delete(dir, "rf")
      table.insert(cleaned, dir)
    end
  end

  if #cleaned > 0 then
    vim.notify("[intellij-server] Cleaned:\n  " .. table.concat(cleaned, "\n  "), vim.log.levels.INFO)
  else
    vim.notify("[intellij-server] No caches found to clean.", vim.log.levels.INFO)
  end

  vim.defer_fn(function()
    require("intellij-server").start()
    vim.notify("[intellij-server] Restarted.", vim.log.levels.INFO)
  end, 500)
end

return M
