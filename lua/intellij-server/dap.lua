--- nvim-dap integration for IntelliJ LSP debugger.
--- The IntelliJ server exposes a DAP server via workspace/executeCommand "start_debug_server".
local M = {}

local has_dap, dap = pcall(require, "dap")

--- Same budget the VS Code extension gives its launch-resolution commands.
local COMMAND_TIMEOUT_MS = 30000

--- Code lens command the server emits for main entry points when
--- initializationOptions.runMainCodeLens is on (see intellij-server.start).
M.RUN_MAIN_COMMAND = "intellij_debugger.runMain"

---@return vim.lsp.Client?
local function lsp_client()
  return vim.lsp.get_clients({ name = "intellij-server" })[1]
end

local function notify(msg, level)
  vim.notify("[intellij-server] " .. msg, level or vim.log.levels.ERROR)
end

--- workspace/executeCommand with a timeout, so a wedged resolution cannot
--- leave a debug session hanging forever.
---@param client vim.lsp.Client
---@param command string
---@param arguments table[]
---@param on_done fun(err: string?, result: any)
local function execute_command(client, command, arguments, on_done)
  local timer = assert(vim.uv.new_timer())
  local finished = false

  local function finish(err, result)
    if finished then
      return
    end
    finished = true
    timer:stop()
    timer:close()
    on_done(err, result)
  end

  timer:start(COMMAND_TIMEOUT_MS, 0, function()
    vim.schedule(function()
      finish(("%s timed out after %dms"):format(command, COMMAND_TIMEOUT_MS))
    end)
  end)

  client:request("workspace/executeCommand", { command = command, arguments = arguments }, function(err, result)
    finish(err and (err.message or vim.inspect(err)) or nil, result)
  end, 0)
end

--- Start the debug server and return the port.
---@param callback fun(port: integer?)
function M.start_debug_server(callback)
  local client = lsp_client()
  if not client then
    notify("LSP not running, cannot start debugger")
    callback(nil)
    return
  end

  local root_uri = client.config.root_dir and vim.uri_from_fname(client.config.root_dir) or nil

  client:request("workspace/executeCommand", {
    command = "start_debug_server",
    arguments = { root_uri },
  }, function(err, result)
    if err then
      notify("Failed to start debug server: " .. vim.inspect(err))
      callback(nil)
      return
    end

    local port = tonumber(result)
    if not port then
      notify("Debug server returned invalid port: " .. vim.inspect(result))
      callback(nil)
      return
    end

    callback(port)
  end, 0)
end

--- Fill in what a launch configuration leaves out, from the project model.
--- This mirrors the VS Code extension's resolveLaunchConfig: the adapter only
--- ever receives fully resolved arguments, which is why `mainClass` (or a
--- `file`) is enough to launch anything.
---
---   file        -> intellij.java.resolveClassDocument { fqn }
---   classPaths  -> intellij.java.resolveClasspath { uri }
---                  (also yields modulePaths and moduleName)
---   cwd         -> intellij.java.resolveWorkingDirectory { uri }
---   javaExec    -> intellij.java.resolveJavaExecutable { uri }
---
--- Called by nvim-dap through the adapter's enrich_config hook. Not calling
--- on_config aborts the session, which is what we do on resolution errors.
---@param config table
---@param on_config fun(config: table)
function M.enrich_config(config, on_config)
  -- Attach configurations carry everything they need (a JDWP port).
  if config.request ~= "launch" then
    on_config(config)
    return
  end

  local client = lsp_client()
  if not client then
    notify("LSP not running, cannot resolve the launch configuration")
    return
  end
  if not config.mainClass then
    notify('Launch configurations require "mainClass"')
    return
  end

  local function resolve_from(uri)
    local steps = {}

    if not config.classPaths or vim.tbl_isempty(config.classPaths) then
      table.insert(steps, {
        command = "intellij.java.resolveClasspath",
        apply = function(result)
          config.classPaths = result.classpath
          if result.modulePath and not vim.tbl_isempty(result.modulePath) then
            config.modulePaths = result.modulePath
          end
          if result.moduleName then
            config.moduleName = result.moduleName
          end
        end,
      })
    end

    if not config.cwd then
      table.insert(steps, {
        command = "intellij.java.resolveWorkingDirectory",
        -- Not fatal: the launcher falls back to its own default.
        optional = true,
        apply = function(result)
          config.cwd = result.workingDirectory
        end,
      })
    end

    if not config.javaExec then
      table.insert(steps, {
        command = "intellij.java.resolveJavaExecutable",
        apply = function(result)
          config.javaExec = result.javaExec
        end,
      })
    end

    local pending = #steps
    local aborted = false

    local function finish()
      config.console = config.console or "integratedTerminal"
      on_config(config)
    end

    if pending == 0 then
      finish()
      return
    end

    for _, step in ipairs(steps) do
      execute_command(client, step.command, { { uri = uri } }, function(err, result)
        if aborted then
          return
        end
        if err then
          if not step.optional then
            aborted = true
            notify(("Cannot start debugging: %s failed: %s"):format(step.command, err))
            return
          end
          notify(("%s failed, using the default: %s"):format(step.command, err), vim.log.levels.WARN)
        elseif result then
          step.apply(result)
        end

        pending = pending - 1
        if pending == 0 then
          finish()
        end
      end)
    end
  end

  if config.file then
    resolve_from(vim.uri_from_fname(vim.fn.fnamemodify(config.file, ":p")))
    return
  end

  execute_command(client, "intellij.java.resolveClassDocument", { { fqn = config.mainClass } }, function(err, result)
    local uri = type(result) == "table" and result.uri or nil
    if err or not uri then
      notify(("Cannot start debugging: no source file for %s%s"):format(config.mainClass, err and (": " .. err) or ""))
      return
    end
    resolve_from(uri)
  end)
end

--- Run or debug a main entry point. Handles the server's code lens command;
--- also usable directly, e.g. from a keymap.
---@param args { mainClass: string, uri: string?, noDebug: boolean? }
function M.run_main(args)
  if not has_dap then
    notify("nvim-dap is required to run main classes")
    return
  end
  if type(args) ~= "table" or not args.mainClass then
    notify("Run request without a main class: " .. vim.inspect(args))
    return
  end

  dap.run({
    type = "intellij",
    request = "launch",
    name = args.mainClass:match("[^.]+$") or args.mainClass,
    mainClass = args.mainClass,
    -- The Run lens passes noDebug, the Debug lens does not.
    noDebug = args.noDebug or false,
    -- Disambiguates same-named main classes; consumed by enrich_config.
    file = args.uri and vim.uri_to_fname(args.uri) or nil,
  })
end

--- Attach the debugger to a JVM started with
--- -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:<port>
--- Server 0.0.10 only reads the port and always connects to 127.0.0.1.
---@param port integer|string|nil Defaults to 5005.
function M.attach(port)
  if not has_dap then
    notify("nvim-dap is required to attach the debugger")
    return
  end

  port = tonumber(port) or 5005
  dap.run({
    type = "intellij",
    request = "attach",
    name = "Attach to JVM (port " .. port .. ")",
    port = port,
  })
end

--- Client-side LSP commands, passed to vim.lsp.start so only our client
--- dispatches them (see :h vim.lsp.ClientConfig).
---@return table<string, fun(command: lsp.Command, ctx: table)>
function M.lsp_commands()
  return {
    [M.RUN_MAIN_COMMAND] = function(command)
      M.run_main((command.arguments or {})[1])
    end,
  }
end

--- Register the IntelliJ debugger adapter with nvim-dap.
function M.setup()
  if not has_dap then
    vim.notify("[intellij-server] nvim-dap is required for debugging support", vim.log.levels.WARN)
    return
  end

  dap.adapters.intellij = function(cb)
    M.start_debug_server(function(port)
      if port then
        cb({
          type = "server",
          host = "127.0.0.1",
          port = port,
          -- Sent as `adapterID` in the initialize request. The server looks
          -- its debugger up by this id and refuses to start a session under
          -- nvim-dap's default ("No debugger adapter found for given adapter
          -- id"), so it must match JvmDebuggerAdapter.adapterId.
          id = "intellij_debugger",
          -- Resolve classpath, cwd and JDK from the project model before the
          -- session starts, like the VS Code extension does.
          enrich_config = M.enrich_config,
        })
      end
    end)
  end

  -- Default configurations for Java and Kotlin.
  --
  -- Launch properties understood by the adapter (server 0.0.10+):
  --   mainClass   (string)    fully qualified main class. Required.
  --   file        (string)    source file declaring it. Resolved from
  --               mainClass when omitted; set it to disambiguate when several
  --               files declare the same fully qualified name.
  --   args        (string[])  program arguments
  --   vmArgs      (string[])  JVM arguments, e.g. { "-Xmx512m", "-ea" }
  --   env         (table)     extra environment variables for the process
  --   cwd         (string)    working directory
  --   javaExec    (string)    path to the java executable (default: project SDK)
  --   classPaths  (string[])  runtime classpath override
  --   modulePaths (string[])  JPMS module path override; if empty, resolved
  --               from the project model when mainClass is in a named module
  --   moduleName  (string)    JPMS module owning the main class, launched as
  --               `-m moduleName/mainClass`; resolved automatically if empty
  --   noDebug     (boolean)   run without attaching the debugger
  --   console     ("internalConsole"|"integratedTerminal"|"externalTerminal")
  --               where to run the program. Default: "integratedTerminal" —
  --               the adapter sends a DAP runInTerminal reverse request,
  --               which nvim-dap answers by opening a terminal buffer.
  --
  -- Everything except mainClass is resolved from the project model when left
  -- out, so the defaults below are enough for most programs.
  local configs = {
    {
      type = "intellij",
      request = "launch",
      name = "Launch main class",
      mainClass = function()
        return vim.fn.input("Main class: ")
      end,
      -- Run the program in a Neovim terminal buffer (nvim-dap handles the
      -- runInTerminal request). Use "internalConsole" to keep output in the
      -- REPL/console instead.
      console = "integratedTerminal",
    },
    {
      type = "intellij",
      request = "attach",
      name = "Attach to JVM",
      -- Only the port is used: the server always connects to 127.0.0.1.
      port = function()
        return tonumber(vim.fn.input("JDWP port: ", "5005")) or 5005
      end,
    },
  }

  dap.configurations.java = dap.configurations.java or {}
  dap.configurations.kotlin = dap.configurations.kotlin or {}

  for _, config in ipairs(configs) do
    table.insert(dap.configurations.java, config)
    table.insert(dap.configurations.kotlin, config)
  end
end

return M
