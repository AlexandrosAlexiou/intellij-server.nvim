local M = {}

local version = require("intellij-server.version")

-- uname's machine string differs per OS for the same hardware: x86_64 on
-- Linux/macOS but AMD64 on Windows, aarch64 on Linux but arm64 on macOS and
-- Windows. Normalize to the two names used in version.platforms.
local ARCH_ALIASES = {
  x86_64 = "x64",
  amd64 = "x64",
  AMD64 = "x64",
  aarch64 = "arm64",
  arm64 = "arm64",
  ARM64 = "arm64",
}

--- Detect the current platform key (e.g., "mac-aarch64").
---@return string?
local function detect_platform()
  local os_name = vim.uv.os_uname().sysname
  local arch = ARCH_ALIASES[vim.uv.os_uname().machine]

  for platform_key, info in pairs(version.platforms) do
    if os_name == info.os and arch == info.arch then
      return platform_key
    end
  end
  return nil
end

--- Get the download URL for the current platform.
---@return string?, string?
function M.get_url()
  local platform = detect_platform()
  if not platform then
    return nil, "Unsupported platform: " .. vim.uv.os_uname().sysname .. "/" .. vim.uv.os_uname().machine
  end
  local filename = ("intellij-server-%s-%s.vsix"):format(version.version, platform)
  local url = ("%s/%s/%s"):format(version.base_url, version.build, filename)
  return url, nil
end

--- Get the installation directory.
---@return string
function M.install_dir()
  return vim.fn.stdpath("data") .. "/intellij-server"
end

--- Get the path to the server binary (after installation).
---@return string
function M.server_bin()
  local dir = M.install_dir()
  local sysname = vim.uv.os_uname().sysname
  if sysname == "Windows_NT" then
    return dir .. "/server/bin/intellij-server.exe"
  end
  return dir .. "/server/bin/intellij-server"
end

--- Check if the server is already installed at the current version.
---@return boolean
function M.is_installed()
  local marker = M.install_dir() .. "/.version"
  if vim.fn.filereadable(marker) == 0 then
    return false
  end
  local content = vim.fn.readfile(marker)
  return content[1] == version.version .. "+" .. version.build
end

--- Download and install the server.
---@param opts { on_complete: fun(ok: boolean, msg: string)? }?
function M.install(opts)
  opts = opts or {}

  local function fail(msg)
    vim.notify("[intellij-server] " .. msg, vim.log.levels.ERROR)
    if opts.on_complete then
      opts.on_complete(false, msg)
    end
  end

  local url, err = M.get_url()
  if not url then
    fail(err or "unknown error")
    return
  end

  -- Extract tool (vsix is a zip): Windows ships bsdtar, which reads zips;
  -- GNU tar on Linux does not, so Unix uses unzip.
  local extract_tool = vim.fn.has("win32") == 1 and "tar" or "unzip"
  for _, tool in ipairs({ "curl", extract_tool }) do
    if vim.fn.executable(tool) == 0 then
      fail(("`%s` not found on PATH — install it and retry :IntellijServerInstall."):format(tool))
      return
    end
  end

  local install_dir = M.install_dir()
  local tmp_file = vim.fn.tempname() .. ".vsix"

  vim.notify("[intellij-server] Downloading IntelliJ server v" .. version.version .. "...", vim.log.levels.INFO)

  -- Download asynchronously. vim.system raises on spawn failure (ENOENT, no
  -- permission, ...) instead of calling the callback — surface it as a notify.
  local spawn_ok, spawn_err = pcall(
    vim.system,
    { "curl", "-fSL", "--progress-bar", "-o", tmp_file, url },
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          fail("Download failed: " .. (result.stderr or "unknown error"))
          return
        end

        vim.fn.mkdir(install_dir, "p")

        local extract_cmd
        if vim.fn.has("win32") == 1 then
          extract_cmd = { "tar", "-xf", tmp_file, "-C", install_dir, "extension/server" }
        else
          extract_cmd = { "unzip", "-qo", tmp_file, "extension/server/*", "-d", install_dir }
        end

        local extract_ok, extract_err = pcall(vim.system, extract_cmd, { text = true }, function(unzip_result)
          vim.schedule(function()
            os.remove(tmp_file)

            if unzip_result.code ~= 0 then
              fail("Extraction failed: " .. (unzip_result.stderr or "unknown error"))
              return
            end

            -- The vsix extracts to extension/server/, move it up
            local extracted = install_dir .. "/extension/server"
            local target = install_dir .. "/server"
            vim.fn.delete(target, "rf")
            vim.fn.rename(extracted, target)
            vim.fn.delete(install_dir .. "/extension", "rf")

            -- Make the binary executable
            vim.fn.setfperm(M.server_bin(), "rwxr-xr-x")

            -- Write version marker
            vim.fn.writefile({ version.version .. "+" .. version.build }, install_dir .. "/.version")

            vim.notify(
              "[intellij-server] Installed v" .. version.version .. " (build " .. version.build .. ")",
              vim.log.levels.INFO
            )
            if opts.on_complete then
              opts.on_complete(true, "ok")
            end
          end)
        end)
        if not extract_ok then
          os.remove(tmp_file)
          fail("Could not run " .. extract_tool .. ": " .. tostring(extract_err))
        end
      end)
    end
  )
  if not spawn_ok then
    fail("Could not run curl: " .. tostring(spawn_err))
  end
end

return M
