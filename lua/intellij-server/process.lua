--- Process and cache management.
--- On Unix the server runs as a process-group leader (the client is started
--- with `detached = true`, so libuv setsid()s it), meaning all its descendants
--- (jbr JVM, Maven imports) share its PGID and can be killed as a group, even
--- after being reparented to PID 1.
--- On Windows, taskkill /T kills the process tree instead.
---@diagnostic disable-next-line: undefined-field
local uv = vim.uv
local M = {}

--- Kill the server and all its descendants (SIGTERM, then SIGKILL stragglers).
--- Synchronous by necessity: it runs on VimLeavePre, where nothing scheduled
--- would ever fire. But instead of an unconditional grace sleep it polls with
--- signal 0, so a tree that dies in 20 ms costs 20 ms; only one that ignores
--- TERM pays the full ~300 ms before the KILL.
--- On Unix the process group is signalled (uv.kill with a negative pid, no
--- external `kill` binary needed). A server the plugin spawned leads its own
--- group; one started by hand without job control (a script, `nohup … &`)
--- does not, and is then signalled directly — a group signal alone would miss
--- it and report success.
---@param pid integer The server's PID (== PGID when it leads its group).
function M.kill_tree(pid)
  if vim.fn.has("win32") == 1 then
    vim.fn.system({ "taskkill", "/PID", tostring(pid), "/T", "/F" })
    return
  end
  local target = -pid
  if not uv.kill(target, "sigterm") then
    target = pid
    if not uv.kill(target, "sigterm") then
      return -- already gone
    end
  end
  for _ = 1, 6 do
    if not uv.kill(target, 0) then
      return -- gone
    end
    uv.sleep(50)
  end
  uv.kill(target, "sigkill")
end

--- Kill all running intellij-server clients.
--- The server is shared between Neovim instances, so only the local LSP
--- clients are stopped. The shared server is killed separately by
--- kill_if_idle() when no other clients remain.
function M.kill_all_clients()
  local connection = require("intellij-server.connection")

  for _, client in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
    -- Deliberate: prevent the connection module from automatically
    -- reconnecting.
    connection.mark_stopped(client.id)
    client:stop(true)
  end
end

--- Pid of the shared server *we* spawned, from the pidfile — validated,
--- because the pidfile can outlive the process (crash, reboot) and the pid can
--- be recycled: it only counts if it still looks like the server. A stale
--- pidfile is removed. The second line is the server build it was spawned
--- from; pidfiles written before the plugin recorded it have none.
---@return integer? pid, string? build
local function spawned_server_pid()
  local pidfile = require("intellij-server.connection").pidfile()
  local ok, lines = pcall(vim.fn.readfile, pidfile)
  local pid = ok and tonumber(lines[1] or "") or nil
  if not pid then
    return nil
  end
  local info_ok, info = pcall(vim.api.nvim_get_proc, pid)
  if info_ok and type(info) == "table" and info.name and info.name:find("intellij%-server") then
    return pid, lines[2]
  end
  vim.fn.delete(pidfile)
  return nil
end

--- Stop a shared server we spawned from another server build — one an older
--- plugin version left running. It would otherwise keep serving every editor
--- that connects to the port, and keep using that build's caches. Editors
--- still attached to it reconnect to the new server once it is up
--- (connection.on_client_exit).
---@return boolean killed
function M.kill_outdated_server()
  local pid, build = spawned_server_pid()
  if not pid or build == require("intellij-server.version").build then
    return false
  end
  M.kill_tree(pid)
  vim.fn.delete(require("intellij-server.connection").pidfile())
  return true
end

--- Kill the shared socket-mode server: the pidfile written at spawn time
--- first (works across Neovim instances), then a name-based fallback for
--- servers started externally. Local LSP clients should be stopped first.
---@return boolean killed
function M.kill_socket_server()
  local pid = spawned_server_pid()
  if pid then
    M.kill_tree(pid)
    vim.fn.delete(require("intellij-server.connection").pidfile())
    return true
  end

  -- Externally launched server: find it by its command line.
  local out
  if vim.fn.has("win32") == 1 then
    -- wmic is gone from current Windows 11 installs; CIM is what PowerShell
    -- (present on every supported Windows) offers instead. Matching on the
    -- image name keeps the query from finding its own command line.
    out = vim.fn.system({
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "Get-CimInstance Win32_Process -Filter \"Name = 'intellij-server.exe'\""
        .. " | Where-Object { $_.CommandLine -like '*--socket*' }"
        .. " | ForEach-Object { $_.ProcessId }",
    })
  elseif vim.fn.executable("pgrep") == 1 then
    -- List form: no shell whose own command line would match the pattern.
    out = vim.fn.system({ "pgrep", "-f", "intellij-server.*--socket" })
  else
    return false
  end
  local killed = false
  for line in out:gmatch("[^\r\n]+") do
    local found = tonumber(vim.trim(line))
    if found and found ~= vim.fn.getpid() then
      M.kill_tree(found)
      killed = true
    end
  end
  return killed
end

--- Another process — an editor without a lease, e.g. an older plugin version
--- or a non-Neovim client — holding an established connection to the server.
--- Extra safety where lsof exists (macOS, most Linux); leases are the primary
--- signal and work without it.
---@param server_pid integer
---@return boolean
local function foreign_connections(server_pid)
  if vim.fn.executable("lsof") ~= 1 then
    return false
  end
  local _, port = require("intellij-server.connection").connect_address()
  local me = vim.fn.getpid()
  -- Our own just-stopped connections may take a moment to close; wait for
  -- them (bounded), then see who else is attached.
  for _ = 1, 10 do
    local mine, others = false, false
    local out = vim.fn.system({ "lsof", "-t", "-nP", ("-iTCP:%d"):format(port), "-sTCP:ESTABLISHED" })
    for line in out:gmatch("[^\n]+") do
      local p = tonumber(line)
      if p == me then
        mine = true
      elseif p and p ~= server_pid then
        others = true
      end
    end
    if others then
      return true
    end
    if not mine then
      return false
    end
    uv.sleep(50)
  end
  return false
end

--- Stop the shared server on exit when no other editor uses it anymore.
--- The server does not shut itself down when its last client disconnects
--- (0.0.12: measured still listening 90 s after the last disconnect), so the
--- last Neovim out turns off the lights instead of leaving an orphan JVM.
--- "Last" is decided by client leases (see connection.acquire_lease), which
--- work the same on Windows, macOS and Linux; where lsof exists, connections
--- from lease-less clients also keep the server alive.
--- Scope is deliberately narrow: only a server this plugin spawned (live,
--- validated pidfile) and only when `autostart_server` is on; an externally
--- managed server is never touched.
--- Synchronous and bounded: runs on VimLeavePre, where nothing async would
--- ever fire. A brand-new editor connecting at this exact moment races the
--- check; its reconnect loop finds the dead port and respawns.
--- An editor that dies without VimLeavePre (SIGKILL, crash) leaves its lease
--- and the server behind; the lease is pruned and the server adopted by the
--- next editor, which stops it on its own exit.
function M.kill_if_idle()
  local connection = require("intellij-server.connection")
  connection.release_lease()

  if not connection.opts().autostart_server then
    return
  end

  local pid = spawned_server_pid()
  if not pid then
    return
  end

  if connection.other_editors() > 0 or foreign_connections(pid) then
    return
  end

  M.kill_tree(pid)
  vim.fn.delete(connection.pidfile())
end

--- Persistent data directory for config, logs, and the plugin's own state.
---@return string
function M.data_dir()
  return vim.fn.stdpath("data") .. "/intellij-server/data"
end

--- The platform's per-user cache directory.
---@return string
local function caches_root()
  if vim.fn.has("win32") == 1 then
    return os.getenv("LOCALAPPDATA") or ((os.getenv("USERPROFILE") or "") .. "/AppData/Local")
  elseif vim.fn.has("mac") == 1 then
    return (os.getenv("HOME") or "") .. "/Library/Caches"
  end
  return os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "") .. "/.cache")
end

--- The server's `--system-path`: per-workspace indexes and the workspace
--- model, under workspaces/<hash>. One directory per server version, as the
--- VS Code extension does since 1.0, so a new version never opens caches an
--- older one wrote. Without the option the server uses the unversioned
--- JetBrains/IntelliJServer itself.
---@return string
function M.system_path()
  return caches_root() .. "/JetBrains/IntelliJServer/" .. require("intellij-server.version").version
end

--- Cache directories of other server versions: the unversioned workspaces/
--- of servers started before the plugin passed `--system-path`, and the
--- system paths of other versions. Never removed automatically — another
--- editor may still run an older plugin.
---@return string[]
function M.stale_caches()
  local current = M.system_path()
  local stale = {}
  for _, dir in ipairs(vim.fn.glob(vim.fn.fnamemodify(current, ":h") .. "/*", true, true)) do
    if dir ~= current and vim.fn.isdirectory(dir) == 1 then
      table.insert(stale, dir)
    end
  end
  return stale
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
--- <system path>/workspaces/<hash>. The hash is opaque, but each
--- workspace-model.cache embeds the project's paths, so the dirs belonging to
--- a root are found by content. Shared stores (the data dir, the analyzer
--- RocksDB cache) hold state for every project and are left alone.
---@param root_dir string
---@return string[]
function M.get_data_paths(root_dir)
  local paths = {}
  for _, dir in ipairs(vim.fn.glob(M.system_path() .. "/workspaces/*", true, true)) do
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

--- Does any process still hold files under one of `paths` open? Async and
--- best-effort: needs lsof (macOS/Linux); without it the check reports "free"
--- and deletion proceeds. Used to keep a clean from pulling caches out from
--- under a server still serving this workspace to another editor.
---@param paths string[]
---@param cb fun(in_use: boolean) May be called off the main loop.
local function paths_in_use(paths, cb)
  if #paths == 0 or vim.fn.executable("lsof") ~= 1 then
    cb(false)
    return
  end
  local pending, held = #paths, false
  for _, dir in ipairs(paths) do
    -- lsof matches kernel paths, so symlinked components (e.g. macOS /var ->
    -- /private/var) must be resolved. -t prints bare pids. The exit code is
    -- useless with +D (nonzero whenever any file in the tree is not open),
    -- so test the output instead.
    vim.system({ "lsof", "-t", "+D", uv.fs_realpath(dir) or dir }, { text = true }, function(result)
      if vim.trim(result.stdout or "") ~= "" then
        held = true
      end
      pending = pending - 1
      if pending == 0 then
        cb(held)
      end
    end)
  end
end

--- Run the async condition `check` every `interval` ms until it reports true
--- or `timeout_ms` pass, then call `cb(ok)` on the main loop. This is the
--- deterministic replacement for fixed sleeps: it completes on the tick the
--- condition actually holds, and the interval only bounds detection latency.
---@param check fun(done: fun(ok: boolean)) Runs on the main loop.
---@param interval integer ms between checks
---@param timeout_ms integer
---@param cb fun(ok: boolean)
local function poll_until(check, interval, timeout_ms, cb)
  local deadline = uv.now() + timeout_ms
  local timer = uv.new_timer()
  local busy = false

  local function finish(ok)
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end

    vim.schedule(function()
      cb(ok)
    end)
  end

  if not timer then
    finish(false)
    return
  end

  timer:start(0, interval, function()
    if busy then
      return
    end

    busy = true

    vim.schedule(function()
      check(function(ok)
        busy = false

        if ok then
          finish(true)
        elseif uv.now() > deadline then
          finish(false)
        end
      end)
    end)
  end)
end

--- Call `cb` once every intellij-server client has actually stopped (bounded
--- by `timeout_ms`, then proceeds anyway — stop(true) force-kills stragglers).
---@param timeout_ms integer
---@param cb fun()
function M.await_clients_stopped(timeout_ms, cb)
  poll_until(
    function(done)
      for _, client in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
        if not client:is_stopped() then
          done(false)
          return
        end
      end
      done(true)
    end,
    100,
    timeout_ms,
    function()
      cb()
    end
  )
end

--- Clean the current project's workspace caches and restart its server.
--- Other projects' servers and caches are untouched. Shared
--- server closes and flushes a workspace as soon as its client disconnects
--- (and exits entirely when the last one does), so stopping our own client is
--- enough to free the cache files — the server keeps running for everyone
--- else. If another editor still has this same project open, its caches stay
--- in use and the clean is aborted instead of corrupting them.
--- Fully asynchronous: each step proceeds on its actual precondition (client
--- stopped, cache files free) instead of a fixed sleep, and the UI never
--- blocks. Completion is reported through vim.notify.
function M.clean_and_restart()
  local client = vim.lsp.get_clients({
    name = "intellij-server",
    bufnr = 0,
  })[1] or vim.lsp.get_clients({
    name = "intellij-server",
  })[1]

  local root_dir = client and client.config.root_dir
  if not root_dir then
    vim.notify("[intellij-server] No running client to determine the project root.", vim.log.levels.WARN)
    return
  end

  vim.notify("[intellij-server] Stopping LSP for " .. root_dir .. "...", vim.log.levels.INFO)

  if client then
    -- Prevent the connection module from automatically reconnecting.
    require("intellij-server.connection").mark_stopped(client.id)
    client:stop(true)

    -- Neovim < 0.12 exposed the process PID through client.rpc.pid().
    -- LuaLS does not declare this legacy field, so access it through an
    -- explicitly typed compatibility value.
    ---@type { pid: fun(): integer }|nil
    local rpc = client.rpc

    local pid = rpc and rpc.pid and rpc.pid()
    if pid then
      M.kill_tree(pid)
    end
  end

  local function delete_and_restart(paths)
    local cleaned = {}

    for _, dir in ipairs(paths) do
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

    require("intellij-server").start()
    vim.notify("[intellij-server] Restarted.", vim.log.levels.INFO)
  end

  -- Wait for the client to finish shutting down before touching the
  -- workspace. This gives the server/process time to flush and close files.
  poll_until(
    function(done)
      done(client == nil or client:is_stopped())
    end,
    100,
    3000,
    function()
      local paths = M.get_data_paths(root_dir)

      -- Once the client has exited, wait for any remaining cache handles
      -- to be released before deleting the workspace data.
      poll_until(
        function(done)
          paths_in_use(paths, function(held)
            done(not held)
          end)
        end,
        250,
        5000,
        function(free)
          if not free then
            vim.notify(
              "[intellij-server] Workspace caches for "
                .. root_dir
                .. " are still in use — another editor probably has this project open.\n"
                .. "Close it and retry, or :IntellijServerStop! to force the shared server down first.",
              vim.log.levels.ERROR
            )

            -- Reattach without cleaning.
            require("intellij-server").start()
            return
          end

          delete_and_restart(paths)
        end
      )
    end
  )
end
return M
