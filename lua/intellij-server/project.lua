--- Per-project import configuration.
---
--- Resolution for a root without an explicit `projects` setup entry:
--- 1. `.intellij-server.lua` in the project root (read via vim.secure.read,
---    so it goes through Neovim's standard trust prompt). It returns either a
---    single project spec or a list of them; `type` and `path` default to the
---    detected build system and the root.
--- 2. `$JAVA_HOME`, when it points at a real JDK: the Maven/Gradle import is
---    pinned to it, so per-project env managers (direnv, mise, sdkman) choose
---    the SDK. Without a pin the server binds the newest JDK it finds on the
---    machine, which is routinely wrong (e.g. a Homebrew openjdk dependency).
---
--- JPS roots are never pinned: the JPS importer resolves the SDK by name from
--- .idea/misc.xml natively and does not accept a java home.
local M = {}

---@param home string
---@return boolean
local function is_jdk_home(home)
  local java = home .. (vim.fn.has("win32") == 1 and "/bin/java.exe" or "/bin/java")
  return vim.fn.filereadable(home .. "/release") == 1 and vim.fn.executable(java) == 1
end

--- Build system of the root, by marker.
---@param root_dir string
---@return string?
local function project_type(root_dir)
  if vim.fn.filereadable(root_dir .. "/pom.xml") == 1 then
    return "maven"
  end
  for _, marker in ipairs({ "settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts" }) do
    if vim.fn.filereadable(root_dir .. "/" .. marker) == 1 then
      return "gradle"
    end
  end
  for _, marker in ipairs({ "WORKSPACE", "WORKSPACE.bazel" }) do
    if vim.fn.filereadable(root_dir .. "/" .. marker) == 1 then
      return "bazel"
    end
  end
  if vim.fn.isdirectory(root_dir .. "/.idea") == 1 then
    return "jps"
  end
  return nil
end

--- Project specs from <root>/.intellij-server.lua, nil when absent, untrusted
--- or invalid. The file returns one spec or a list; omitted `type`/`path`
--- default to the detected build system and the root.
---@param root_dir string
---@return IntellijProjectSpec[]?
local function project_file_specs(root_dir)
  local path = root_dir .. "/.intellij-server.lua"
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local content = vim.secure.read(path)
  if type(content) ~= "string" then
    return nil -- user declined the trust prompt
  end

  local chunk, load_err = load(content, "@" .. path)
  if not chunk then
    vim.notify("[intellij-server] " .. path .. ": " .. load_err, vim.log.levels.ERROR)
    return nil
  end
  local ok, specs = pcall(chunk)
  if not ok or type(specs) ~= "table" then
    vim.notify("[intellij-server] " .. path .. " must return a table", vim.log.levels.ERROR)
    return nil
  end

  if not vim.islist(specs) then
    specs = { specs }
  end
  for _, spec in ipairs(specs) do
    spec.path = spec.path or root_dir
    spec.type = spec.type or project_type(root_dir)
    if not spec.type then
      vim.notify("[intellij-server] " .. path .. ": no `type` and none detectable", vim.log.levels.ERROR)
      return nil
    end
  end
  return specs
end

--- Implicit project specs for a root, nil when nothing applies.
---@param root_dir string
---@return IntellijProjectSpec[]?
function M.projects(root_dir)
  local specs = project_file_specs(root_dir)
  if specs then
    return specs
  end

  local java_home = vim.env.JAVA_HOME
  if not java_home or java_home == "" or not is_jdk_home(java_home) then
    return nil
  end
  local build = project_type(root_dir)
  if build ~= "maven" and build ~= "gradle" then
    return nil
  end
  return { { type = build, path = root_dir, javaHome = java_home } }
end

return M
