--- Server binary discovery and launch configuration.
local M = {}

--- Resolve a JDK home from the current environment.
--- Preference: explicit `JAVA_HOME`, then the `java` executable on PATH.
---@return string?
local function detect_java_home()
  local java_home = vim.env.JAVA_HOME
  if java_home and java_home ~= "" then
    return java_home
  end

  local java_bin = vim.fn.exepath("java")
  if java_bin == "" then
    return nil
  end

  local real_java_bin = (vim.uv or vim.loop).fs_realpath(java_bin) or java_bin
  local bin_dir = vim.fn.fnamemodify(real_java_bin, ":h")
  if vim.fn.fnamemodify(bin_dir, ":t") == "bin" then
    return vim.fn.fnamemodify(bin_dir, ":h")
  end

  return nil
end

--- Get the plugin's own root directory.
---@return string
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

--- Locate the intellij-server binary.
--- Priority: installed (data dir) > vendored in plugin repo.
---@return string?
function M.find_binary()
  -- 1. Installed via :IntellijServerInstall
  local installed_bin = require("intellij-server.installer").server_bin()
  if vim.fn.executable(installed_bin) == 1 then
    return installed_bin
  end

  -- 2. Vendored binary shipped with this plugin
  local suffix = vim.fn.has("win32") == 1 and ".exe" or ""
  local vendored = plugin_root() .. "/server/bin/intellij-server" .. suffix
  if vim.fn.executable(vendored) == 1 then
    return vendored
  end

  return nil
end

--- Build the command to launch the LSP server.
--- On Unix the launcher spawns child processes (jbr JVM, Maven imports) — we
--- run it as a process-group leader so the whole group can be killed on exit,
--- catching even children reparented to PID 1. Uses `setsid` when available
--- (Linux/util-linux), falling back to `perl` (always present on macOS).
--- On Windows there are no process groups; process.kill_tree uses taskkill /T.
--- Note: the native launcher reads bin/intellij-server.vmoptions itself —
--- do NOT pass vmoptions as CLI arguments.
---@param server_path string? Explicit binary path from config.
---@return string[]?
function M.build_cmd(server_path)
  local bin = server_path or M.find_binary()
  if not bin then
    vim.notify(
      "[intellij-server] Server binary not found.\n"
        .. "Run :IntellijServerInstall to download it, or set `server_path` in the plugin config.",
      vim.log.levels.ERROR
    )
    return nil
  end

  local args = { bin, "--stdio" }
  -- Since 0.0.10 the server refuses to start unless the accepted EULA hash is
  -- passed via --eula (previously initializationOptions.eulaHash).
  local eula = M.eula_hash(vim.fn.fnamemodify(bin, ":h:h"))
  if eula then
    table.insert(args, "--eula")
    table.insert(args, eula)
  end

  if vim.fn.has("win32") == 1 then
    return args
  end
  if vim.fn.executable("setsid") == 1 then
    return vim.list_extend({ "setsid", "-w" }, args)
  end
  if vim.fn.executable("perl") == 1 then
    return vim.list_extend({ "perl", "-e", "setpgrp(0,0); exec @ARGV or die" }, args)
  end
  return args
end

--- Compute the EULA acceptance hash the server requires.
--- Hash = first 16 chars of SHA-256 of server/EULA.txt.
--- Up to server 0.0.8 this was sent as initializationOptions.eulaHash; since
--- 0.0.10 it must be passed as the `--eula` command-line option instead.
---@param server_dir string The server/ directory next to the binary.
---@return string?
function M.eula_hash(server_dir)
  local eula_path = server_dir .. "/EULA.txt"
  if vim.fn.filereadable(eula_path) == 0 then
    return nil
  end
  -- readfile in binary mode + concat reconstructs the exact file bytes
  -- (EULA.txt contains no NUL bytes), matching `shasum -a 256` output.
  local content = table.concat(vim.fn.readfile(eula_path, "b"), "\n")
  return vim.fn.sha256(content):sub(1, 16)
end

--- Build the environment for the server process.
--- Points indexes/config/logs at a persistent data dir instead of $TMPDIR.
---@param server_dir string
---@param data_dir string
---@param java_home string? Explicit JDK home override.
---@return table<string, string>
function M.build_env(server_dir, data_dir, java_home)
  -- The bundled JBR uses the macOS app-bundle layout on mac, plain jbr/ elsewhere
  local jbr_home = server_dir .. "/jbr/Contents/Home"
  if vim.fn.isdirectory(jbr_home) == 0 then
    jbr_home = server_dir .. "/jbr"
  end
  return {
    JAVA_HOME = java_home or detect_java_home() or jbr_home,
    IJ_JAVA_OPTIONS = table.concat({
      "-Didea.config.path=" .. data_dir .. "/config",
      "-Didea.system.path=" .. data_dir .. "/system",
      "-Didea.log.path=" .. data_dir .. "/log",
    }, " "),
    -- Skip common Maven validation plugins during project import
    MAVEN_ARGS = "-Dcheckstyle.skip=true -Dpmd.skip=true -Dspotbugs.skip=true -Djacoco.skip=true",
  }
end

local build_markers = {
  "pom.xml",
  "build.gradle",
  "build.gradle.kts",
  "settings.gradle",
  "settings.gradle.kts",
  "WORKSPACE",
  "WORKSPACE.bazel",
}

--- Find the project root for a buffer.
--- For multimodule projects this must be the TOPMOST directory containing a
--- build marker, not the nearest one (which vim.fs.root would return).
---@param bufnr integer
---@param fallback_markers string[] Markers for the nearest-root fallback.
---@return string
function M.find_root(bufnr, fallback_markers)
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local root_dir = nil
  local dir = vim.fn.fnamemodify(buf_path, ":h")

  while dir and dir ~= "" do
    for _, marker in ipairs(build_markers) do
      if vim.fn.filereadable(dir .. "/" .. marker) == 1 then
        root_dir = dir
        break
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end

  return root_dir or vim.fs.root(bufnr, fallback_markers) or vim.fn.fnamemodify(buf_path, ":h")
end

return M
