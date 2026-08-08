--- File template support for IntelliJ LSP server.
--- Uses workspace/executeCommand "interpolateFileTemplate" to generate file content.
local M = {}

--- Default templates (matching the VS Code extension's package.json).
M.templates = {
  kotlin = {
    ["Class"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nclass ${NAME} {\n\t|\n}',
    ["File"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\n|',
    ["Interface"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\ninterface ${NAME} {\n\t|\n}',
    ["Data Class"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\ndata class ${NAME}(|)\n',
    ["Enum"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nenum class ${NAME} {\n\t|\n}',
    ["Annotation"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nannotation class ${NAME}(|)',
    ["Object"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME}\n\n#end\nobject ${NAME} {\n\t|\n}',
  },
  java = {
    ["Class"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic class ${NAME} {\n\t|\n}',
    ["Interface"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic interface ${NAME} {\n\t|\n}',
    ["Record"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic record ${NAME}(|) {\n}',
    ["Enum"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic enum ${NAME} {\n\t|\n}',
    ["Annotation"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic @interface ${NAME} {\n\t|\n}',
    ["Exception"] = '#if (${PACKAGE_NAME} && ${PACKAGE_NAME} != "")package ${PACKAGE_NAME};\n\n#end\npublic class ${NAME} extends RuntimeException {\n    public ${NAME}(String message) {\n        super(message);\n    }\n}',
  },
}

--- Determine language from file extension.
---@param filepath string
---@return string?
local function lang_from_path(filepath)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  if ext == "kt" or ext == "kts" then
    return "kotlin"
  elseif ext == "java" then
    return "java"
  end
  return nil
end

--- Create a new file from a template.
---@param opts { filepath?: string, template?: string }?
function M.create_file(opts)
  opts = opts or {}

  -- Get file path
  local filepath = opts.filepath
  if not filepath then
    filepath = vim.fn.input("File path: ", vim.fn.expand("%:h") .. "/", "file")
    if filepath == "" then
      return
    end
  end

  -- Determine language
  local lang = lang_from_path(filepath)
  if not lang then
    vim.notify("[intellij-server] Cannot determine language for: " .. filepath, vim.log.levels.WARN)
    return
  end

  -- Pick template
  local templates = M.templates[lang]
  if not templates then
    return
  end

  local template_name = opts.template
  if not template_name then
    local choices = vim.tbl_keys(templates)
    table.sort(choices)
    vim.ui.select(choices, { prompt = "Select template:" }, function(choice)
      if not choice then
        return
      end
      M._apply_template(filepath, templates[choice])
    end)
    return
  end

  local tmpl = templates[template_name]
  if not tmpl then
    vim.notify("[intellij-server] Unknown template: " .. template_name, vim.log.levels.ERROR)
    return
  end
  M._apply_template(filepath, tmpl)
end

--- Apply a template by sending it to the LSP for interpolation.
---@param filepath string
---@param template string
function M._apply_template(filepath, template)
  local uri = vim.uri_from_fname(vim.fn.fnamemodify(filepath, ":p"))

  local clients = vim.lsp.get_clients({ name = "intellij-server" })
  if #clients == 0 then
    -- Fallback: apply template locally without LSP interpolation
    M._apply_local(filepath, template)
    return
  end

  local client = clients[1]
  client:request("workspace/executeCommand", {
    command = "interpolateFileTemplate",
    arguments = { uri, template },
  }, function(err, result)
    vim.schedule(function()
      if err or not result or type(result) ~= "string" then
        -- Fallback to local application
        M._apply_local(filepath, template)
        return
      end

      M._write_and_open(filepath, result)
    end)
  end, 0)
end

--- Fallback: apply template locally (basic variable substitution).
---@param filepath string
---@param template string
function M._apply_local(filepath, template)
  local name = vim.fn.fnamemodify(filepath, ":t:r")
  local dir = vim.fn.fnamemodify(filepath, ":h")

  -- Derive package name from directory structure (heuristic)
  local package_name = ""
  local src_match = dir:match("src/main/[^/]+/(.+)$") or dir:match("src/test/[^/]+/(.+)$") or dir:match("src/(.+)$")
  if src_match then
    package_name = src_match:gsub("/", ".")
  end

  local content = template
  content = content:gsub("${NAME}", name)
  content = content:gsub("${PACKAGE_NAME}", package_name)

  -- Process #if/#end conditionals
  if package_name ~= "" then
    content = content:gsub("#if %([^)]+%)\n?", "")
    content = content:gsub("#end\n?", "")
  else
    content = content:gsub("#if %([^)]+%).-(#end)", "")
  end

  -- Unescape \n and \t
  content = content:gsub("\\n", "\n"):gsub("\\t", "\t")

  M._write_and_open(filepath, content)
end

--- Write content to file and open it.
---@param filepath string
---@param content string
function M._write_and_open(filepath, content)
  -- Find cursor position marker "|" or "$0"
  local cursor_offset = nil
  local cleaned = content:gsub("|", function()
    if not cursor_offset then
      cursor_offset = true
      return ""
    end
    return "|"
  end)
  cleaned = cleaned:gsub("%$0", "")

  local full_path = vim.fn.fnamemodify(filepath, ":p")
  vim.fn.mkdir(vim.fn.fnamemodify(full_path, ":h"), "p")

  local lines = vim.split(cleaned, "\n", { plain = true })
  vim.fn.writefile(lines, full_path)
  vim.cmd.edit(full_path)

  vim.notify("[intellij-server] Created: " .. filepath, vim.log.levels.INFO)
end

return M
