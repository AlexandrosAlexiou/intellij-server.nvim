--- Handler for the `intellij/workspaceImportStatus` notification (server
--- 0.0.12+). The server reports workspace folders whose import it will not
--- start on its own — today because more than one build system claims the
--- folder (`reason = "ambiguousBuildSystem"`, e.g. a pom.xml next to a
--- build.gradle) — together with the candidate tools. VS Code shows a
--- "Choose Build Tool…" prompt; here the choice is made in the setup config.
---
--- Payload: { blockedFolders: { folderUri, reason, candidates: string[], dismissed }[] }
local M = {}

local reported = {}

---@param folder { folderUri: string, reason: string, candidates: string[], dismissed: boolean }
local function describe(folder)
  local path = vim.uri_to_fname(folder.folderUri)
  local candidates = table.concat(folder.candidates or {}, ", ")
  local msg = ("Project import of %s is blocked (%s)"):format(vim.fn.fnamemodify(path, ":~"), folder.reason)
  if candidates ~= "" then
    msg = msg .. (": %s can import it"):format(candidates)
  end
  if folder.reason == "ambiguousBuildSystem" then
    msg = msg
      .. (".\nPick one in setup(): build_tools = { [%q] = %q } (or an explicit `projects` entry), then :IntellijServerRestart"):format(
        vim.fn.fnamemodify(path, ":~"),
        (folder.candidates or {})[1] or "gradle"
      )
  end
  return msg
end

--- LSP handler.
---@param params { blockedFolders?: table[] }
function M.handler(_, params, _)
  if type(params) ~= "table" or type(params.blockedFolders) ~= "table" then
    return
  end
  local current = {}
  for _, folder in ipairs(params.blockedFolders) do
    if type(folder) == "table" and folder.folderUri then
      current[folder.folderUri] = true
      if not reported[folder.folderUri] then
        reported[folder.folderUri] = true
        vim.notify("[intellij-server] " .. describe(folder), vim.log.levels.WARN)
      end
    end
  end
  -- A folder that is no longer blocked may be reported again if it comes back.
  for uri in pairs(reported) do
    if not current[uri] then
      reported[uri] = nil
    end
  end
end

return M
