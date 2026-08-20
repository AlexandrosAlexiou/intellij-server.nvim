--- nvim-dap integration for IntelliJ LSP debugger.
--- The IntelliJ server exposes a DAP server via workspace/executeCommand "start_debug_server".
local M = {}

local has_dap, dap = pcall(require, "dap")

--- Start the debug server and return the port.
---@param callback fun(port: integer?)
function M.start_debug_server(callback)
  local clients = vim.lsp.get_clients({ name = "intellij-server" })
  if #clients == 0 then
    vim.notify("[intellij-server] LSP not running, cannot start debugger", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local client = clients[1]
  local root_uri = client.config.root_dir and vim.uri_from_fname(client.config.root_dir) or nil

  client:request("workspace/executeCommand", {
    command = "start_debug_server",
    arguments = { root_uri },
  }, function(err, result)
    if err then
      vim.notify("[intellij-server] Failed to start debug server: " .. vim.inspect(err), vim.log.levels.ERROR)
      callback(nil)
      return
    end

    local port = tonumber(result)
    if not port then
      vim.notify("[intellij-server] Debug server returned invalid port: " .. vim.inspect(result), vim.log.levels.ERROR)
      callback(nil)
      return
    end

    callback(port)
  end, 0)
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
        })
      end
    end)
  end

  -- Default configurations for Java and Kotlin.
  --
  -- Launch properties understood by the adapter (server 0.0.10+):
  --   mainClass   (string)    fully qualified main class
  --   args        (string[])  program arguments
  --   env         (table)     extra environment variables for the process
  --   javaExec    (string)    path to the java executable (default: project SDK)
  --   modulePath  (string[])  JPMS module path override; if empty, resolved
  --               from the project model when mainClass is in a named module
  --   moduleName  (string)    JPMS module owning the main class, launched as
  --               `-m moduleName/mainClass`; resolved automatically if empty
  --   console     ("internalConsole"|"integratedTerminal"|"externalTerminal")
  --               where to run the program. Default: "integratedTerminal" —
  --               the adapter sends a DAP runInTerminal reverse request,
  --               which nvim-dap answers by opening a terminal buffer.
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
      name = "Attach to JVM (port 5005)",
      hostName = "localhost",
      port = 5005,
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
