--- Shared-server (socket) connection management.
--- In socket mode one server process (`intellij-server --socket=<host>:<port>
--- --multi-client`) serves every project and every Neovim instance at once.
--- This module answers "is something listening?", spawns the shared server on
--- demand, and hands callers a ready-to-connect address.
---@diagnostic disable-next-line: undefined-field
local uv = vim.uv
local M = {}

--- Callbacks queued while a spawn is in flight, so ten FileType events during
--- the JVM's cold start produce one server and ten connections.
---@type fun(ok: boolean)[]?
local waiters = nil

--- Exit state of the process we spawned, used to fail the poll early instead
--- of waiting out the full connect timeout on a crashed launcher.
---@type integer?
local spawn_exit_code = nil

--- Hosts the plugin is willing to spawn a server for. Anything else is
--- connect-only (we cannot start a process on a remote machine).
local local_hosts = {
  ["127.0.0.1"] = true,
  ["localhost"] = true,
  ["::1"] = true,
  ["0.0.0.0"] = true,
  ["::"] = true,
}

--- The connection section of the plugin config, with defaults applied even if
--- the user replaced the table wholesale.
---@return { mode: string, host: string, port: integer, autostart_server: boolean, connect_timeout_ms: integer }
function M.opts()
  local config = require("intellij-server").config or {}

  return vim.tbl_extend("keep", config.connection or {}, {
    mode = "stdio",
    host = "127.0.0.1",
    port = 9999,
    autostart_server = true,
    connect_timeout_ms = 60000,
  })
end

--- Address to *connect* to. A server listening on a wildcard address is
--- reached via loopback.
---@return string host, integer port
function M.connect_address()
  local opts = M.opts()
  local host = opts.host

  if host == "0.0.0.0" or host == "::" then
    host = "127.0.0.1"
  end

  return host, opts.port
end

--- Resolve a hostname to an IP address.
---@param host string
---@return string?
local function resolve(host)
  if host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
    return host
  end

  local ok, addrs = pcall(uv.getaddrinfo, host, nil, {
    family = "inet",
    socktype = "stream",
    protocol = 0,
    addrconfig = false,
    v4mapped = false,
    all = false,
    numerichost = false,
    passive = false,
    numericserv = false,
    canonname = false,
  })

  if not ok or type(addrs) ~= "table" then
    return nil
  end

  local first = addrs[1]
  if type(first) == "table" and type(first.addr) == "string" then
    return first.addr
  end

  return nil
end

--- LSP `cmd` connecting to the shared server. vim.lsp.rpc.connect takes an IP
--- address, so hostnames are resolved here.
---@return (fun(dispatchers: table): table)?
function M.lsp_cmd()
  local host, port = M.connect_address()
  local ip = resolve(host)

  if not ip then
    vim.notify("[intellij-server] Cannot resolve host: " .. host, vim.log.levels.ERROR)
    return nil
  end

  return vim.lsp.rpc.connect(ip, port)
end

--- Close a libuv timer safely.
local function close_timer(timer)
  if not timer then
    return
  end

  timer:stop()

  if not timer:is_closing() then
    timer:close()
  end
end

--- Is anything accepting TCP connections at host:port?
---@param host string
---@param port integer
---@param cb fun(ok: boolean)
function M.probe(host, port, cb)
  local ip = resolve(host)

  if not ip then
    cb(false)
    return
  end

  local tcp = uv.new_tcp()
  if not tcp then
    cb(false)
    return
  end

  local timer = uv.new_timer()
  if not timer then
    tcp:close()
    cb(false)
    return
  end

  local done = false

  local function finish(ok)
    if done then
      return
    end

    done = true

    close_timer(timer)

    if not tcp:is_closing() then
      tcp:close()
    end

    cb(ok)
  end

  -- A dead loopback port refuses instantly, but a firewalled remote host can
  -- hang the connect — cap each attempt.
  timer:start(2000, 0, function()
    finish(false)
  end)

  tcp:connect(ip, port, function(err)
    finish(err == nil)
  end)
end

--- Pidfile recording the shared server we spawned, so :IntellijServerStop!
--- and :IntellijServerClean can find it later — possibly from a different
--- Neovim instance than the one that spawned it.
---@return string
function M.pidfile()
  return require("intellij-server.process").data_dir() .. "/socket-server.pid"
end

--- Launcher stdout/stderr. The server proper logs to idea.log (see
--- -Didea.log.path in server.build_env); this catches early launcher errors.
---@return string
function M.launch_log()
  return require("intellij-server.process").data_dir() .. "/log/socket-server-launch.log"
end

--- Is `pid` a running Neovim? Process names are "nvim" / "nvim.exe" on every
--- platform; checking the name keeps a recycled pid from passing as an editor.
---@param pid integer
---@return boolean
function M.is_editor(pid)
  local ok, info = pcall(vim.api.nvim_get_proc, pid)
  return ok and type(info) == "table" and type(info.name) == "string" and info.name:lower():find("nvim", 1, true) ~= nil
end

--- Directory of client leases: one file per Neovim using the shared server,
--- named after its pid and holding the port. The server does not shut itself
--- down when its last client disconnects (0.0.12, measured), so the last
--- editor out stops it — and leases are how an editor learns it is the last,
--- on every platform, without lsof/netstat.
---@return string
function M.lease_dir()
  return require("intellij-server.process").data_dir() .. "/socket-clients"
end

--- Record that this Neovim uses the shared server. Idempotent.
function M.acquire_lease()
  local _, port = M.connect_address()
  local dir = M.lease_dir()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ tostring(port) }, dir .. "/" .. vim.fn.getpid())
end

--- Drop this Neovim's lease.
function M.release_lease()
  os.remove(M.lease_dir() .. "/" .. vim.fn.getpid())
end

--- Number of *other* live editors holding a lease on the configured port.
--- Leases of editors that are gone (crashed, killed) are pruned on the way.
---@return integer
function M.other_editors()
  local _, port = M.connect_address()
  local me = vim.fn.getpid()
  local count = 0
  for _, path in ipairs(vim.fn.glob(M.lease_dir() .. "/*", true, true)) do
    local pid = tonumber(vim.fn.fnamemodify(path, ":t"))
    if pid and pid ~= me then
      if M.is_editor(pid) then
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok and tonumber(lines[1] or "") == port then
          count = count + 1
        end
      else
        os.remove(path)
      end
    end
  end
  return count
end

--- Lock serializing spawns across Neovim instances. Without it two editors
--- starting at once both spawn; the loser exits on the busy port, but its
--- pidfile write can land last, and its exit then deletes the pidfile — leaving
--- the winner unrecorded and never stopped.
---@return string
local function spawn_lock()
  return require("intellij-server.process").data_dir() .. "/socket-server.spawn.lock"
end

--- Take the spawn lock, breaking it when its owner is gone or it outlived a
--- spawn's whole connect timeout.
---@param timeout_ms integer
---@return boolean
local function acquire_spawn_lock(timeout_ms)
  local path = spawn_lock()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  for _ = 1, 2 do
    local fd = uv.fs_open(path, "wx", 420)
    if fd then
      uv.fs_write(fd, tostring(vim.fn.getpid()))
      uv.fs_close(fd)
      return true
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    local owner = ok and tonumber(lines[1] or "") or nil
    local stat = uv.fs_stat(path)
    local age_ms = stat and (os.time() - stat.mtime.sec) * 1000 or 0
    if (owner and not M.is_editor(owner)) or age_ms > timeout_ms then
      os.remove(path)
    else
      return false
    end
  end
  return false
end

local function release_spawn_lock()
  local path = spawn_lock()
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and tonumber(lines[1] or "") == vim.fn.getpid() then
    os.remove(path)
  end
end

--- Spawn the shared server, detached (its own session/process-group leader, so
--- process.kill_tree can reap it and its Maven/Gradle children as a group).
---@return integer? pid
local function spawn_server()
  local config = require("intellij-server").config or {}
  local server = require("intellij-server.server")
  local process = require("intellij-server.process")

  local bin = config.server_path or server.find_binary()

  if not bin then
    vim.notify(
      "[intellij-server] Server binary not found.\n"
        .. "Run :IntellijServerInstall to download it, "
        .. "or set `server_path` in the plugin config.",
      vim.log.levels.ERROR
    )
    return nil
  end

  local opts = M.opts()

  local args = {
    ("--socket=%s:%d"):format(opts.host, opts.port),
    "--multi-client",
    "--system-path",
    process.system_path(),
  }

  local eula = server.eula_hash(vim.fn.fnamemodify(bin, ":h:h"))

  if eula then
    table.insert(args, "--eula")
    table.insert(args, eula)
  end

  local data_dir = process.data_dir()

  vim.fn.mkdir(data_dir .. "/config", "p")
  vim.fn.mkdir(data_dir .. "/system", "p")
  vim.fn.mkdir(data_dir .. "/log", "p")

  -- uv.spawn replaces the environment outright, so merge our overrides into
  -- the current one (vim.system would merge, but cannot redirect to a file).
  local server_dir = vim.fn.fnamemodify(bin, ":h:h")

  local env = vim.fn.environ()

  for k, v in pairs(server.build_env(server_dir, data_dir, config.java_home, config.jvm_args)) do
    env[k] = v
  end

  local env_list = {}

  for k, v in pairs(env) do
    table.insert(env_list, k .. "=" .. v)
  end

  local log_fd = uv.fs_open(M.launch_log(), "a", 420)

  spawn_exit_code = nil

  local handle
  local pid

  --- LuaLS's Neovim uv.spawn definition currently marks uid/gid/verbatim
  --- as required even though they are optional at runtime.
  ---@diagnostic disable-next-line: missing-fields
  handle = uv.spawn(bin, {
    args = args,
    env = env_list,
    cwd = data_dir,
    detached = true,
    hide = true,
    stdio = { nil, log_fd, log_fd },
  }, function(code)
    spawn_exit_code = code

    if handle and not handle:is_closing() then
      handle:close()
    end
    -- Two instances can race to spawn; the loser fails to bind and exits.
    -- Drop its pidfile so it cannot shadow the winner's.
    vim.schedule(function()
      local ok, lines = pcall(vim.fn.readfile, M.pidfile())

      if code ~= 0 and ok and lines[1] == tostring(pid) then
        vim.fn.delete(M.pidfile())
      end
    end)
  end)

  if log_fd then
    uv.fs_close(log_fd)
  end

  if not handle then
    vim.notify("[intellij-server] Failed to spawn the shared server: " .. bin, vim.log.levels.ERROR)
    return nil
  end

  -- Do not keep Neovim alive for it, and do not kill it on exit — it is
  -- shared with other instances. :IntellijServerStop! ends it explicitly.
  handle:unref()

  pid = handle:get_pid()

  -- The build too, so a later plugin version can tell this server is not its
  -- own (process.kill_outdated_server).
  vim.fn.writefile({ tostring(pid), require("intellij-server.version").build }, M.pidfile())

  return pid
end

--- Ensure a server is listening on the configured address, spawning one if
--- allowed, and call `cb(ok)` on the main loop when it is (or never will be)
--- reachable. Concurrent calls during a spawn are queued, not re-spawned.
---@param cb fun(ok: boolean)
function M.ensure_server(cb)
  local opts = M.opts()
  local host, port = M.connect_address()

  if waiters then
    table.insert(waiters, cb)
    return
  end

  -- A server an older plugin version spawned still holds the port: replace
  -- it rather than connect to the wrong build.
  if opts.autostart_server and require("intellij-server.process").kill_outdated_server() then
    vim.notify("[intellij-server] Stopped the shared server of another server version.", vim.log.levels.INFO)
  end

  M.probe(host, port, function(ok)
    if ok then
      vim.schedule(function()
        cb(true)
      end)
      return
    end

    if not opts.autostart_server or not local_hosts[opts.host] then
      vim.schedule(function()
        vim.notify(
          ("[intellij-server] No server listening on %s:%d.\n"):format(opts.host, opts.port)
            .. "Start it with: intellij-server --socket="
            .. ("%s:%d --multi-client --eula <hash>"):format(opts.host, opts.port),
          vim.log.levels.ERROR
        )

        cb(false)
      end)

      return
    end

    vim.schedule(function()
      -- Someone else got here first while we were probing.
      if waiters then
        table.insert(waiters, cb)
        return
      end

      waiters = { cb }

      local timeout_ms = opts.connect_timeout_ms or 60000
      -- Another editor holding the lock is mid-spawn: wait for its server
      -- instead of racing it with a second one.
      local spawned = acquire_spawn_lock(timeout_ms)

      if spawned then
        local pid = spawn_server()

        if not pid then
          release_spawn_lock()

          local queued = waiters
          waiters = nil

          for _, waiter in ipairs(queued or {}) do
            waiter(false)
          end

          return
        end

        vim.notify(
          ("[intellij-server] Starting shared server on %s:%d (pid %d)..."):format(opts.host, opts.port, pid),
          vim.log.levels.INFO
        )
      else
        vim.notify(
          ("[intellij-server] Waiting for the shared server another Neovim is starting on %s:%d..."):format(
            opts.host,
            opts.port
          ),
          vim.log.levels.INFO
        )
      end

      local deadline = uv.now() + timeout_ms

      local timer = uv.new_timer()

      if not timer then
        local queued = waiters
        waiters = nil

        vim.notify("[intellij-server] Failed to create server startup timer.", vim.log.levels.ERROR)

        for _, waiter in ipairs(queued or {}) do
          waiter(false)
        end

        return
      end

      local function finish(up)
        close_timer(timer)

        vim.schedule(function()
          if spawned then
            release_spawn_lock()
          end

          local queued = waiters or {}
          waiters = nil

          if up then
            vim.notify("[intellij-server] Shared server is up.", vim.log.levels.INFO)
          else
            local reason

            if spawned and spawn_exit_code ~= nil then
              reason = "the server exited with code " .. spawn_exit_code
            else
              reason = "timed out waiting for it to accept connections"
            end

            vim.notify(
              "[intellij-server] Shared server failed to start: "
                .. reason
                .. ".\nSee "
                .. M.launch_log()
                .. " and :IntellijServerLogs.",
              vim.log.levels.ERROR
            )
          end

          for _, waiter in ipairs(queued) do
            waiter(up)
          end
        end)
      end

      local polling = false
      -- Connect-retry is the deterministic primitive here: no OS event exists
      -- for "another process bound a port", so the loop terminates on its
      -- actual condition (a successful connect) and the interval only bounds
      -- detection latency.
      timer:start(500, 500, function()
        if polling then
          return
        end
        -- A spawn race with another Neovim instance is benign: the loser's
        -- process fails to bind and exits, while this poll succeeds against
        -- the winner. Only give up on exit if nothing is listening.
        polling = true

        M.probe(host, port, function(up)
          polling = false

          if up then
            finish(true)
          elseif (spawned and spawn_exit_code ~= nil) or uv.now() > deadline then
            finish(false)
          end
        end)
      end)
    end)
  end)
end

--- Clients the plugin stopped on purpose (Stop/Restart/Clean/exit), so their
--- on_exit is not mistaken for a lost connection. Ids are session-unique.
---@type table<integer, boolean>
local stopped_clients = {}

--- Record that `client_id` is about to be stopped deliberately; call before
--- client:stop().
---@param client_id integer
function M.mark_stopped(client_id)
  stopped_clients[client_id] = true
end

--- Roots with a reconnect loop already running.
---@type table<string, boolean>
local reconnecting = {}

--- A loaded buffer belonging to `root_dir`, to hand to start() — looked up at
--- reconnect time, since the buffer that started the client may be gone.
---@param root_dir string
---@return integer?
local function find_buffer_for_root(root_dir)
  local config = require("intellij-server").config or {}
  local server = require("intellij-server.server")

  local filetypes = {}

  for _, filetype in ipairs(config.filetypes or {}) do
    filetypes[filetype] = true
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buftype == ""
      and filetypes[vim.bo[bufnr].filetype]
      and server.is_under(vim.api.nvim_buf_get_name(bufnr), root_dir)
    then
      return bufnr
    end
  end

  return nil
end

--- Handle a client exiting in socket mode. A deliberate stop is ignored; a
--- lost connection (the shared server was killed or crashed — e.g. another
--- editor ran :IntellijServerClean) starts a loop that probes the port and
--- reattaches this root's buffers once a server is listening again.
--- Probe-only by design: spawning here could race another instance's Clean
--- while it is deleting caches. If the server never comes back, whoever wants
--- it runs :IntellijServerStart and ensure_server respawns it.
---@param root_dir string
---@param client_id integer
function M.on_client_exit(root_dir, client_id)
  vim.schedule(function()
    if stopped_clients[client_id] then
      stopped_clients[client_id] = nil
      return
    end

    if vim.v.exiting ~= vim.NIL or reconnecting[root_dir] then
      return
    end

    reconnecting[root_dir] = true

    local host, port = M.connect_address()

    vim.notify(
      ("[intellij-server] Lost connection to the shared server " .. "— will reattach %s when it is back."):format(
        root_dir
      ),
      vim.log.levels.WARN
    )

    local deadline = uv.now() + 300000

    local timer = uv.new_timer()

    if not timer then
      reconnecting[root_dir] = nil

      vim.notify("[intellij-server] Failed to create reconnect timer.", vim.log.levels.ERROR)

      return
    end

    local probing = false
    -- Same connect-retry rationale as ensure_server: the server lives in
    -- another process (possibly spawned by another editor), so there is no
    -- event to subscribe to — the poll terminates on the first successful
    -- connect.
    timer:start(2000, 2000, function()
      if probing then
        return
      end

      probing = true

      M.probe(host, port, function(up)
        probing = false

        if up then
          close_timer(timer)

          vim.schedule(function()
            reconnecting[root_dir] = nil

            local bufnr = find_buffer_for_root(root_dir)

            if bufnr then
              require("intellij-server").start(bufnr)
            end
          end)
        elseif uv.now() > deadline then
          close_timer(timer)

          vim.schedule(function()
            reconnecting[root_dir] = nil

            vim.notify(
              "[intellij-server] Shared server did not come back; " .. "reconnect with :IntellijServerStart.",
              vim.log.levels.INFO
            )
          end)
        end
      end)
    end)
  end)
end

return M
