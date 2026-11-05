--- nvim-dap integration for IntelliJ LSP debugger.
--- The IntelliJ server exposes a DAP server via workspace/executeCommand "start_debug_server".
---@diagnostic disable-next-line: undefined-field
local uv = vim.uv
local M = {}

local has_dap, dap = pcall(require, "dap")

--- Same budget the VS Code extension gives its server commands.
local COMMAND_TIMEOUT_MS = 30000

--- Code lens command the server emits for main entry points when
--- initializationOptions.runMainCodeLens is on (see intellij-server.start).
M.RUN_MAIN_COMMAND = "intellij.jvm.runMain"

--- `tool` for the `launcher` values of configurations written before server
--- 1.0.86; "auto" maps to no tool, which lets the server choose.
local TOOL_OF_LAUNCHER = { jvm = "java", gradle = "gradle" }

--- Consoles the program output is shown in a terminal buffer for.
local TERMINAL_CONSOLES = { integratedTerminal = true, externalTerminal = true }

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
function M.execute_command(client, command, arguments, on_done)
  local timer = assert(uv.new_timer())
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

--- Since server 1.0.86 the adapter resolves a launch itself, like the VS Code
--- extension's (dap.ts): it builds the module with its build tool, takes the
--- classpath, JDK, module path and working directory from the project model,
--- and runs the program, streaming its output as DAP output events. All a
--- configuration needs is `mainClass`; `file` disambiguates, `tool` picks how
--- it runs ("java": a JVM process, "gradle"/"bazel": the build tool's own run;
--- absent: the server's choice).
---
--- Called by nvim-dap through the adapter's enrich_config hook. Not calling
--- on_config aborts the session.
---@param config table
---@param on_config fun(config: table)
function M.enrich_config(config, on_config)
  -- Attach configurations carry everything they need (a JDWP host and port).
  if config.request ~= "launch" then
    on_config(config)
    return
  end
  if not config.mainClass then
    notify('Launch configurations require "mainClass"')
    return
  end
  if config.tool == nil and config.launcher then
    config.tool = TOOL_OF_LAUNCHER[config.launcher]
  end
  -- The adapter's name for the build tool's arguments, as dap.ts maps them.
  config.toolArgs = config.toolArgs or config.gradleArgs
  config.console = config.console or "integratedTerminal"
  on_config(config)
end

---@type table<integer, { chan: integer, buf: integer }> running session id -> its terminal
local terminals = {}
local run_win ---@type integer?

--- Show the output of a session that is not a test run. The server runs the
--- program itself, so a terminal console gets no runInTerminal request: like
--- the VS Code extension's run terminal, its output goes into a terminal
--- buffer, one per session, in a reused bottom split. Closing the window hides
--- the buffer; a finished run's buffer is wiped when the next run replaces
--- it. Other consoles append to the REPL as nvim-dap would. `telemetry` is
--- what `console = "none"` turns the output into.
---@param session table nvim-dap session
---@param body table DAP output event body
function M.show_output(session, body)
  if body.category == "telemetry" or not body.output then
    return
  end
  if not TERMINAL_CONSOLES[session.config.console] then
    require("dap.repl").append(body.output, "$", { newline = false })
    return
  end
  local terminal = terminals[session.id]
  if not terminal then
    local buf = vim.api.nvim_create_buf(true, true)
    vim.bo[buf].bufhidden = "hide"
    if run_win and vim.api.nvim_win_is_valid(run_win) then
      local previous = vim.api.nvim_win_get_buf(run_win)
      vim.api.nvim_win_set_buf(run_win, buf)
      local running = vim.iter(vim.tbl_values(terminals)):any(function(t)
        return t.buf == previous
      end)
      if not running and vim.api.nvim_buf_get_name(previous):find("^intellij://run/") then
        vim.api.nvim_buf_delete(previous, { force = true })
      end
    else
      local current = vim.api.nvim_get_current_win()
      vim.cmd("botright 15split")
      run_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(run_win, buf)
      vim.api.nvim_set_current_win(current)
    end
    pcall(vim.api.nvim_buf_set_name, buf, ("intellij://run/%d/%s"):format(session.id, session.config.name))
    terminal = { chan = vim.api.nvim_open_term(buf, {}), buf = buf }
    terminals[session.id] = terminal
  end
  vim.api.nvim_chan_send(terminal.chan, (body.output:gsub("\r?\n", "\r\n")))
end

--- Split `:IntellijServerRun` input into the main class and the program
--- arguments that follow it. Arguments are quoted like a shell, so one
--- containing spaces can be written "like this" or 'like this'.
---@param line string
---@return string? main_class, string[] args
function M.parse_run(line)
  local words, word, quote = {}, nil, nil

  local i = 1
  while i <= #line do
    local char = line:sub(i, i)
    if char == "\\" and i < #line then
      i = i + 1
      word = (word or "") .. line:sub(i, i)
    elseif quote then
      if char == quote then
        quote = nil
      else
        word = word .. char
      end
    elseif char == '"' or char == "'" then
      quote, word = char, word or ""
    elseif char:match("%s") then
      if word then
        table.insert(words, word)
        word = nil
      end
    else
      word = (word or "") .. char
    end
    i = i + 1
  end
  if word then
    table.insert(words, word)
  end

  local main_class = table.remove(words, 1)
  return main_class, words
end

--- Run or debug a main entry point. Handles the server's code lens command;
--- also usable directly, e.g. from a keymap.
---@param args { mainClass: string, uri: string?, tool: string?, noDebug: boolean?, args: string[]?, vmArgs: string[]? }
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
    args = args.args,
    vmArgs = args.vmArgs,
    -- The lens names the build tool that runs the module ("gradle"), if any.
    tool = args.tool,
  })
end

--- Attach the debugger to a JVM started with
--- -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:<port>
--- The server reads `hostName` (default localhost), `port` and `timeout`
--- (ms, default 30000).
---@param port integer|string|nil Defaults to 5005.
---@param host string? Defaults to localhost.
function M.attach(port, host)
  if not has_dap then
    notify("nvim-dap is required to attach the debugger")
    return
  end

  port = tonumber(port) or 5005
  dap.run({
    type = "intellij",
    request = "attach",
    name = ("Attach to JVM (%s:%d)"):format(host or "localhost", port),
    hostName = host,
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
        -- The DAP port is opened by the server process, so in socket mode it
        -- lives on the shared server's host, not necessarily localhost.
        local connection = require("intellij-server.connection")
        local host = connection.connect_address()

        cb({
          type = "server",
          host = host,
          port = port,
          -- Sent as `adapterID` in the initialize request. The server looks
          -- its debugger up by this id and refuses to start a session under
          -- nvim-dap's default ("No debugger adapter found for given adapter
          -- id"), so it must match JvmDebuggerAdapter.adapterId.
          id = "intellij_debugger",
          enrich_config = M.enrich_config,
        })
      end
    end)
  end
  -- intellij-server.tests replaces this to take its runs' output first.
  dap.defaults.intellij.on_output = M.show_output
  dap.listeners.after.event_terminated["intellij-server.dap"] = function(session)
    terminals[session.id] = nil
  end

  -- Default configurations for Java and Kotlin. Launch properties, all
  -- passed to the adapter:
  --   mainClass   (string)    fully qualified main class. Required.
  --   file        (string)    source file declaring it. Resolved from
  --               mainClass when omitted; set it to disambiguate when several
  --               files declare the same fully qualified name.
  --   tool        ("java"|"gradle"|"bazel") how the program runs: "java" is a
  --               JVM process after the build tool compiled the module,
  --               "gradle"/"bazel" the build tool's own run. Default: the
  --               server's choice (the build tool when it can run the module).
  --   projectPath (string)    Gradle project (":app") or Bazel target
  --   sourceSet   (string)    Gradle source set ("main", "test")
  --   toolArgs    (string[])  arguments for the build tool invocation itself
  --               (`gradleArgs` is accepted too)
  --   args        (string[])  program arguments
  --   vmArgs      (string[])  JVM arguments, e.g. { "-Xmx512m", "-ea" }
  --   env         (table)     extra environment variables for the process
  --   cwd         (string)    working directory (default: the module's)
  --   stepFilters (table)     { skipClasses = { "java.*" }, skipSynthetics,
  --               skipConstructors, skipGetters, skipClassLoaders }
  --   noDebug     (boolean)   run without attaching the debugger
  --   console     ("integratedTerminal"|"externalTerminal"|"internalConsole"|"none")
  --               where the output goes. Default: "integratedTerminal", a
  --               terminal buffer in a bottom split (see show_output);
  --               "internalConsole" the REPL; "none" nowhere (test runs).
  --
  -- The server builds the module before every launch.
  local configs = {
    {
      type = "intellij",
      request = "launch",
      name = "Launch main class",
      mainClass = function()
        return vim.fn.input("Main class: ")
      end,
      -- A JVM process; use "internalConsole" to keep the output in the REPL.
      tool = "java",
      console = "integratedTerminal",
    },
    {
      type = "intellij",
      request = "launch",
      name = "Launch main class (Gradle)",
      mainClass = function()
        return vim.fn.input("Main class: ")
      end,
      -- Gradle compiles and runs the module.
      tool = "gradle",
      console = "integratedTerminal",
    },
    {
      type = "intellij",
      request = "attach",
      name = "Attach to JVM",
      -- hostName defaults to localhost, timeout to 30000 ms.
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
