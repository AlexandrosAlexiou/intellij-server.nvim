--- IntelliJ LSP server plugin for Neovim.
local M = {}

---@class IntellijProjectSpec
---@field type "gradle"|"maven"|"bazel"|"jps"|"gomodules"|"gomodules-recursive-scan"|"json" Build system used to import the project.
---@field path string Workspace root or build file — a file:// URI or a filesystem path.

---@class IntellijServerConfig
---@field server_path string? Path to the intellij-server binary. Auto-detected if nil.
---@field java_home string? Path to the JDK used by the server process. Defaults to the bundled JBR.
---@field filetypes string[]? File types to attach to.
---@field root_markers string[]? Files/dirs used for the nearest-root fallback.
---@field autostart boolean? Start the LSP automatically when opening a matching file.
---@field on_attach fun(client: vim.lsp.Client, bufnr: integer)? Callback after attaching.
---@field capabilities table? Additional LSP capabilities to merge.
---@field settings table? LSP workspace settings.
---@field inlay_hints { enabled?: boolean }? Enable inlay hints on attach (default: on).
---@field folding { enabled?: boolean }? Use LSP folding ranges for folds (default: on).
---@field code_lens { enabled?: boolean }? Refresh and display code lenses (default: on).
---@field inline_completion { enabled?: boolean, keymaps?: { show?: string, accept?: string, dismiss?: string } }?
---@field dap { enabled?: boolean }?
---@field build_log { enabled?: boolean, open_on_start?: boolean, open_on_failure?: boolean, notify?: boolean }? Streamed import/build output (intellij/importLog).
---@field projects (IntellijProjectSpec[]|fun(root_dir: string): IntellijProjectSpec[])? Explicit project imports (initializationOptions.projects). Overrides marker-based auto-import.
---@field disable_rocksdb_wal boolean? Disable the RocksDB write-ahead log for the server's index storage.
M.defaults = {
  server_path = nil,
  java_home = nil,
  filetypes = { "java", "kotlin" },
  projects = nil,
  disable_rocksdb_wal = nil,
  root_markers = {
    "pom.xml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
    "WORKSPACE",
    "WORKSPACE.bazel",
    "BUILD",
    ".git",
  },
  autostart = true,
  on_attach = nil,
  capabilities = nil,
	-- Server-side hint categories default to OFF unless the client answers
	-- workspace/configuration. The server string-matches the flattened keys
	-- against IntelliJ's declarative inlay hint optionIds — note four of these
	-- deliberately differ from the VS Code extension's package.json, which
	-- contributes bundle nameKeys (hints.settings.types.property, ...) the
	-- server never matches.
	-- stylua: ignore
	settings = {
		["jetbrains.kotlin.hints.parameters"] = true,
		["jetbrains.kotlin.hints.parameters.compiled"] = true,
		["jetbrains.kotlin.hints.parameters.excluded"] = false,
		["jetbrains.kotlin.hints.parameters.context"] = false,
		["jetbrains.kotlin.hints.type.property"] = true,
		["jetbrains.kotlin.hints.type.variable"] = true,
		["jetbrains.kotlin.hints.type.function.return"] = true,
		["jetbrains.kotlin.hints.type.function.parameter"] = true,
		["jetbrains.kotlin.hints.lambda.return"] = true,
		["jetbrains.kotlin.hints.lambda.receivers.parameters"] = true,
		["jetbrains.kotlin.hints.value.ranges"] = true,
		["jetbrains.kotlin.hints.value.kotlin.time"] = true,
		["jetbrains.kotlin.hints.call.chains"] = false,
		["jetbrains.java.hints.collapse complex types"] = true,
		["jetbrains.java.hints.settings.method parameter"] = true,
		["jetbrains.java.hints.types.local variable"] = true,
		["jetbrains.java.hints.types.call chain"] = true,
	},
  inlay_hints = { enabled = true },
  folding = { enabled = true },
  code_lens = { enabled = true },
  inline_completion = { enabled = true },
  dap = { enabled = true },
  build_log = { enabled = true, open_on_start = false, open_on_failure = true, notify = true },
}

---@type IntellijServerConfig
M.config = {}

--- Setup the plugin.
---@param opts IntellijServerConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})

  vim.api.nvim_create_autocmd("FileType", {
    pattern = M.config.filetypes,
    group = vim.api.nvim_create_augroup("IntellijServer", { clear = true }),
    callback = function(ev)
      if not M.config.autostart then
        return
      end
      -- Skip virtual/readonly buffers (decompiled sources attach separately)
      if vim.bo[ev.buf].buftype ~= "" then
        return
      end
      M.start(ev.buf)
    end,
    desc = "Start IntelliJ LSP server",
  })

  -- Kill the full server process tree (launcher, jbr, maven) on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("IntellijServerCleanup", { clear = true }),
    callback = function()
      require("intellij-server.process").kill_all_clients()
    end,
    desc = "Kill IntelliJ server process tree on exit",
  })

  -- Inlay hints, LSP folding, and code lens need client-side opt-in.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("IntellijServerAttach", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if not client or client.name ~= "intellij-server" then
        return
      end

      local hints = M.config.inlay_hints or {}
      if hints.enabled ~= false and client.server_capabilities.inlayHintProvider then
        vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
      end

      local folding = M.config.folding or {}
      if folding.enabled ~= false and client.server_capabilities.foldingRangeProvider then
        vim.wo[0][0].foldmethod = "expr"
        vim.wo[0][0].foldexpr = "v:lua.vim.lsp.foldexpr()"
        vim.wo[0][0].foldlevel = 99 -- start with folds open
      end

      local lens = M.config.code_lens or {}
      if lens.enabled ~= false and client.server_capabilities.codeLensProvider then
        -- enable() auto-refreshes on buffer changes.
        vim.lsp.codelens.enable(true, { bufnr = args.buf })
      end

      require("intellij-server.content-provider").attach_open_buffers(client.id)
    end,
    desc = "Enable inlay hints and LSP folding for intellij-server buffers",
  })

  -- Virtual document handling (jar:/jrt: URIs -> decompiled sources)
  require("intellij-server.content-provider").setup()

  local ic = M.config.inline_completion or {}
  if ic.enabled ~= false then
    require("intellij-server.inline-completion").setup_keymaps(ic.keymaps)
  end

  local dap_cfg = M.config.dap or {}
  if dap_cfg.enabled ~= false and pcall(require, "dap") then
    require("intellij-server.dap").setup()
  end
end

--- Check for an absolute path on any platform (Unix, drive letter, UNC).
---@param path string
---@return boolean
local function is_abs_path(path)
  if vim.startswith(path, "/") then
    return true
  end
  if vim.fn.has("win32") == 1 then
    return path:match("^%a:[/\\]") ~= nil or path:match("^\\\\") ~= nil
  end
  return false
end

--- Start or attach the LSP client to a buffer.
---@param bufnr integer?
function M.start(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- Only start for real, named files — unnamed/scratch buffers would produce
  -- a relative or empty root and an invalid rootUri (crashes the server).
  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  if buf_path == "" or not is_abs_path(buf_path) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  local server = require("intellij-server.server")
  local process = require("intellij-server.process")

  local server_bin = M.config.server_path or server.find_binary()
  local cmd = server.build_cmd(server_bin)
  if not server_bin or not cmd then
    return
  end

  local server_dir = vim.fn.fnamemodify(server_bin, ":h:h") -- server/ directory
  local root_dir = server.find_root(bufnr, M.config.root_markers)

  local data_dir = process.data_dir()
  vim.fn.mkdir(data_dir .. "/config", "p")
  vim.fn.mkdir(data_dir .. "/system", "p")

  local build_log = require("intellij-server.build-log")
  build_log.opts = vim.tbl_extend("force", build_log.opts, M.config.build_log or {})

  local capabilities = vim.lsp.protocol.make_client_capabilities()
  if M.config.capabilities then
    capabilities = vim.tbl_deep_extend("force", capabilities, M.config.capabilities)
  end

  -- The server uses flat dotted setting keys (VS Code style, e.g.
  -- "jetbrains.kotlin.hints.parameters") and may request a prefix section.
  -- Neovim's default workspace/configuration handler nests by dots, so it
  -- would never find them — answer from the flat settings table instead.
  local function configuration_handler(_, params, ctx)
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    local settings = client and client.settings or {}
    local response = {}
    for _, item in ipairs(params.items or {}) do
      local section = item.section
      if not section or section == "" then
        table.insert(response, settings)
      elseif settings[section] ~= nil then
        table.insert(response, settings[section])
      else
        -- Collect flat keys under "<section>." into an object
        local nested, found = {}, false
        local prefix = section .. "."
        for k, v in pairs(settings) do
          if type(k) == "string" and vim.startswith(k, prefix) then
            nested[k:sub(#prefix + 1)] = v
            found = true
          end
        end
        table.insert(response, found and nested or vim.NIL)
      end
    end
    return response
  end

  -- Note: 0.0.8 clients sent `eulaHash` here; since 0.0.10 the server
  -- requires it as the `--eula` CLI flag instead (see server.build_cmd).
  local init_options = {}

  -- Explicit project imports, mirroring the VS Code `intellij.projects`
  -- setting. Paths are normalized to file:// URIs as the server expects.
  local projects = M.config.projects
  if type(projects) == "function" then
    projects = projects(root_dir)
  end
  if type(projects) == "table" and not vim.tbl_isempty(projects) then
    init_options.projects = vim.tbl_map(function(project)
      local path = project.path
      if type(path) == "string" and not path:match("^%a[%w+.-]*://") then
        path = vim.uri_from_fname(vim.fn.fnamemodify(path, ":p"))
      end
      return { type = project.type, path = path }
    end, projects)
  end

  if M.config.disable_rocksdb_wal ~= nil then
    init_options.disableRocksDBWriteAheadLog = M.config.disable_rocksdb_wal
  end

  local handlers = {
    ["workspace/configuration"] = configuration_handler,
    -- The completion apply command positions the caret via showDocument;
    -- place it in the current buffer instead of switching windows/scrolling.
    ["window/showDocument"] = function(_, params, ctx)
      return require("intellij-server.completion").show_document(params, ctx)
    end,
  }
  -- Streamed import/build output (Maven downloads, compilation, …),
  -- same channel the VS Code extension shows as its "Build" panel.
  if (M.config.build_log or {}).enabled ~= false then
    handlers["intellij/importLog"] = function(_, params, ctx)
      build_log.handler(_, params, ctx)
    end
  end

  vim.lsp.start({
    name = "intellij-server",
    cmd = cmd,
    cmd_env = server.build_env(server_dir, data_dir, M.config.java_home),
    cmd_cwd = root_dir,
    root_dir = root_dir,
    capabilities = capabilities,
    settings = M.config.settings,
    handlers = handlers,
    -- Make command-driven completion behave like the VS Code client (client
    -- inserts nothing, server applies text/imports/caret). Completion is
    -- otherwise broken in Neovim. See lua/intellij-server/completion.lua.
    on_init = function(client)
      require("intellij-server.completion").attach(client)
    end,
    on_attach = M.config.on_attach,
    init_options = init_options,
  }, {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return client.name == config.name and client.config.root_dir == config.root_dir
    end,
  })
end

--- Clean all IntelliJ server indexes/caches and restart.
function M.clean_and_restart()
  require("intellij-server.process").clean_and_restart()
end

return M
