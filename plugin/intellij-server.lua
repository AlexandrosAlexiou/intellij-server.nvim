if vim.g.loaded_intellij_server then
  return
end
vim.g.loaded_intellij_server = true

vim.api.nvim_create_user_command("IntellijServerStart", function()
  require("intellij-server").start()
end, { desc = "Start IntelliJ LSP server for the current buffer" })

vim.api.nvim_create_user_command("IntellijServerStop", function()
  require("intellij-server.process").kill_all_clients()
end, { desc = "Stop all IntelliJ LSP server instances" })

vim.api.nvim_create_user_command("IntellijServerRestart", function()
  require("intellij-server.process").kill_all_clients()
  vim.defer_fn(function()
    require("intellij-server").start()
  end, 500)
end, { desc = "Restart IntelliJ LSP server" })

vim.api.nvim_create_user_command("IntellijServerInstall", function()
  require("intellij-server.installer").install()
end, { desc = "Download and install the IntelliJ LSP server" })

vim.api.nvim_create_user_command("IntellijServerUpdate", function()
  local installer = require("intellij-server.installer")
  -- Force reinstall
  vim.fn.delete(installer.install_dir() .. "/.version")
  installer.install()
end, { desc = "Force re-download the IntelliJ LSP server" })

vim.api.nvim_create_user_command("IntellijServerVersion", function()
  local v = require("intellij-server.version")
  local installer = require("intellij-server.installer")
  local status = installer.is_installed() and "installed" or "not installed"
  vim.notify(("intellij-server v%s (build %s) [%s]"):format(v.version, v.build, status))
end, { desc = "Show IntelliJ LSP server version info" })

vim.api.nvim_create_user_command("IntellijServerNewFile", function(cmd_opts)
  local template = cmd_opts.args ~= "" and cmd_opts.args or nil
  require("intellij-server.templates").create_file({ template = template })
end, { nargs = "?", desc = "Create a new file from IntelliJ template" })

vim.api.nvim_create_user_command("IntellijServerClean", function()
  local server = require("intellij-server")
  server.clean_and_restart()
end, { desc = "Clean the current project's IntelliJ server caches and restart" })

vim.api.nvim_create_user_command("IntellijServerBuildLog", function()
  require("intellij-server.build-log").open()
end, { desc = "Open the streamed IntelliJ import/build log" })

vim.api.nvim_create_user_command("IntellijServerLogs", function()
  require("intellij-server.process").show_logs()
end, { desc = "Open the IntelliJ server log and Neovim's LSP log" })

vim.api.nvim_create_user_command("IntellijServerRun", function(cmd_opts)
  local dap = require("intellij-server.dap")
  local main_class, args = dap.parse_run(cmd_opts.args)
  if not main_class then
    main_class = vim.fn.input("Main class: ")
    if main_class == "" then
      return
    end
  end
  dap.run_main({ mainClass = main_class, args = args, noDebug = not cmd_opts.bang })
end, {
  nargs = "*",
  bang = true,
  desc = "Run a main class with optional arguments (! to debug it) — requires nvim-dap",
})

vim.api.nvim_create_user_command("IntellijServerAttach", function(cmd_opts)
  require("intellij-server.dap").attach(cmd_opts.args)
end, { nargs = "?", desc = "Attach the debugger to a JVM on a JDWP port (default 5005)" })

vim.api.nvim_create_user_command("IntellijServerFormat", function(cmd_opts)
  require("intellij-server").format({ async = cmd_opts.bang })
end, { bang = true, desc = "Format the buffer with IntelliJ's code-style engine (! to run async)" })
