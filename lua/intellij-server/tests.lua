--- Running and debugging tests through the server's test commands (server
--- 0.0.13+), the way the VS Code extension's Test Explorer does:
---
---   intellij.jvm.discoverTestsInFile { uri }  -> classes and methods of a file
---   intellij.jvm.discoverTestModules          -> module names
---   intellij.jvm.discoverTestsInModule name   -> classes of a module
---   intellij.jvm.resolveTestLaunch { testIds, uniqueIds }
---     -> { mainClass, args, runtimeClasspath }[]: a JVM launch per test
---        framework involved, running IntelliJ's own JUnit starter.
---
--- A launch runs through nvim-dap like a main class (intellij-server.dap), on
--- the project's runtime classpath (intellij.java.resolveLaunch) behind the
--- runner's jars, after the module is built. The runner reports progress as
--- TeamCity service messages on stdout — `##teamcity[testFailed name='…' …]`
--- — which arrive as DAP output events and become the results: a summary
--- notification, a diagnostic on every failed test, the rest of the output in
--- the build log.
local M = {}

local has_dap, dap = pcall(require, "dap")

---@class IntellijTestItem
---@field id string "demo.CalcTest" or "demo.CalcTest#adds"
---@field kind "CLASS"|"METHOD"
---@field displayName string
---@field uri string
---@field range lsp.Range The name identifier.
---@field parentId string?
---@field location string? "java:test://demo.CalcTest/adds"; the runner's locationHint.
---@field className string
---@field moduleName string?
---@field runnable boolean?

--- Client-side command of the Run Test / Debug Test lenses.
M.RUN_TEST_COMMAND = "intellij-server.runTest"

local NS = vim.api.nvim_create_namespace("intellij-server.tests")

local function notify(msg, level)
  vim.notify("[intellij-server] " .. msg, level or vim.log.levels.ERROR)
end

---@return vim.lsp.Client?
local function lsp_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "intellij-server" })[1]
end

local function execute(client, command, arguments, on_done)
  require("intellij-server.dap").execute_command(client, command, arguments, on_done)
end

-- Discovery ------------------------------------------------------------------

--- Tests declared in a file. Empty until the project import is done.
---@param client vim.lsp.Client
---@param uri string
---@param on_done fun(err: string?, items: IntellijTestItem[])
function M.discover(client, uri, on_done)
  execute(client, "intellij.jvm.discoverTestsInFile", { { uri = uri } }, function(err, result)
    on_done(err, type(result) == "table" and result or {})
  end)
end

--- Run/Debug lenses for the tests of a buffer, shaped like the server's own
--- run-main lenses (codicon titles, anchored to the name) so code-lens.lua
--- presents both the same way.
---@param items IntellijTestItem[]
---@return lsp.CodeLens[]
function M.lenses(items)
  local lenses = {}
  for _, item in ipairs(items) do
    if item.runnable ~= false then
      for _, lens in ipairs({ { "$(play) Run Test", true }, { "$(debug) Debug Test", false } }) do
        table.insert(lenses, {
          range = item.range,
          command = { title = lens[1], command = M.RUN_TEST_COMMAND, arguments = { { item = item, noDebug = lens[2] } } },
        })
      end
    end
  end
  return lenses
end

--- The test the cursor is in: the last method declared at or above the
--- cursor line, else the class. Items only carry the position of the name.
---@param items IntellijTestItem[]
---@param line integer 0-based
---@return IntellijTestItem?
local function at_cursor(items, line)
  local best
  for _, kind in ipairs({ "METHOD", "CLASS" }) do
    for _, item in ipairs(items) do
      if item.kind == kind and item.range.start.line <= line and (not best or item.range.start.line > best.range.start.line) then
        best = item
      end
    end
    if best then
      return best
    end
  end
end

---@param items IntellijTestItem[]
---@return IntellijTestItem[]
local function top_level_classes(items)
  return vim.tbl_filter(function(item)
    return item.kind == "CLASS" and not item.parentId
  end, items)
end

-- Service messages -----------------------------------------------------------

local ESCAPES = { n = "\n", r = "\r", ["|"] = "|", ["'"] = "'", ["["] = "[", ["]"] = "]" }

---@param value string
---@return string
local function unescape(value)
  return (value:gsub("|0x(%x%x%x%x)", function(hex)
    return vim.fn.nr2char(tonumber(hex, 16))
  end):gsub("|(.)", ESCAPES))
end

--- Parse `##teamcity[name key='value' …]`; nil for any other line.
---@param line string
---@return string? name, table<string, string> attributes
local function parse_message(line)
  local name, rest = line:match("^%s*##teamcity%[(%S+)%s*(.*)%]%s*$")
  if not name then
    return nil, {}
  end
  local attributes, pos = {}, 1
  while true do
    local _, quote, key = rest:find("^%s*([%w_.-]+)%s*=%s*'", pos)
    if not quote then
      break
    end
    local i, chars = quote + 1, {}
    while i <= #rest and rest:sub(i, i) ~= "'" do
      local n = rest:sub(i, i) == "|" and 2 or 1
      table.insert(chars, rest:sub(i, i + n - 1))
      i = i + n
    end
    attributes[key] = unescape(table.concat(chars))
    pos = i + 1
  end
  return name, attributes
end

-- Runs -----------------------------------------------------------------------

---@class IntellijTestRun
---@field id integer
---@field label string
---@field items IntellijTestItem[]
---@field by_location table<string, IntellijTestItem>
---@field by_node table<string, IntellijTestItem> runner node id -> item
---@field outcomes table<string, string> item id -> worst outcome so far
---@field failures table<string, table> item id -> failure attributes
---@field counts { started: integer, failed: integer, skipped: integer }
---@field pending string partial last output line
---@field tail string[] last plain output lines, for a run that reports nothing
---@field launches table[] remaining DAP configurations
---@field exit_code integer?
---@field started integer

---@type table<integer, IntellijTestRun>
local runs = {}
local next_run_id = 0

local SEVERITY = { skipped = 0, passed = 1, failed = 2 }

---@param run IntellijTestRun
---@param item IntellijTestItem
---@param outcome string
local function conclude(run, item, outcome)
  local current = run.outcomes[item.id]
  if not current or SEVERITY[outcome] > SEVERITY[current] then
    run.outcomes[item.id] = outcome
  end
end

--- The item a service message is about: by the location the server gave the
--- item, else the item of the runner's parent node (a parameterized test's
--- invocations), else the single item asked for.
---@param run IntellijTestRun
---@param attributes table<string, string>
---@return IntellijTestItem?
local function item_of(run, attributes)
  local item = (attributes.locationHint and run.by_location[attributes.locationHint])
    or (attributes.parentNodeId and run.by_node[attributes.parentNodeId])
    or (#run.items == 1 and run.items[1])
    or nil
  if item and attributes.nodeId then
    run.by_node[attributes.nodeId] = item
  end
  return item
end

---@param run IntellijTestRun
---@param name string
---@param attributes table<string, string>
local function on_message(run, name, attributes)
  local item = item_of(run, attributes)
  if name == "testStarted" then
    run.counts.started = run.counts.started + 1
  elseif name == "testFailed" then
    run.counts.failed = run.counts.failed + 1
    if item then
      conclude(run, item, "failed")
      run.failures[item.id] = run.failures[item.id] or attributes
    end
  elseif name == "testIgnored" then
    run.counts.skipped = run.counts.skipped + 1
    if item then
      conclude(run, item, "skipped")
    end
  elseif name == "testFinished" then
    if item then
      conclude(run, item, "passed")
    end
  elseif name == "testStdOut" or name == "testStdErr" then
    if attributes.out and attributes.out ~= "" then
      require("intellij-server.build-log").append(vim.split((attributes.out:gsub("\n$", "")), "\n", { plain = true }))
    end
  end
end

---@param run IntellijTestRun
---@param text string
local function feed(run, text)
  local lines = vim.split(run.pending .. text:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
  run.pending = table.remove(lines)
  local plain = {}
  for _, line in ipairs(lines) do
    local name, attributes = parse_message(line)
    if name then
      on_message(run, name, attributes)
    else
      table.insert(plain, line)
      table.insert(run.tail, line)
      if #run.tail > 20 then
        table.remove(run.tail, 1)
      end
    end
  end
  if #plain > 0 then
    require("intellij-server.build-log").append(plain)
  end
end

-- Results --------------------------------------------------------------------

--- Diagnostics of failed tests, per buffer and test id, so a rerun of one
--- test replaces only its own.
---@type table<integer, table<string, vim.Diagnostic>>
local diagnostics = {}

---@param bufnr integer
local function publish(bufnr)
  vim.diagnostic.set(NS, bufnr, vim.tbl_values(diagnostics[bufnr] or {}))
end

--- Stack frames that only say how the assertion library threw.
local LIBRARY_FRAMES = { "org.junit.", "org.opentest4j.", "org.hamcrest.", "org.assertj.", "org.testng.", "kotlin.test." }

--- Where and what to report for a failed test: the assertion's own line when
--- the stack trace has a frame in the test's file, else the test's name; the
--- message with expected/actual, and the frames down to that line minus the
--- assertion library's own.
---@param item IntellijTestItem
---@param failure table<string, string>
---@return vim.Diagnostic
local function failure_diagnostic(item, failure)
  local message = vim.trim(failure.message or "")
  if failure.expected ~= nil or failure.actual ~= nil then
    message = ("%s%sexpected <%s> but was <%s>"):format(message, message == "" and "" or " ", failure.expected, failure.actual)
  end
  if message == "" then
    message = "Test failed"
  end

  local file = vim.fn.fnamemodify(vim.uri_to_fname(item.uri), ":t")
  local lnum, frames = item.range.start.line, {}
  for _, frame in ipairs(vim.split(failure.details or "", "\n", { plain = true })) do
    frame = vim.trim(frame)
    local class = frame:match("^at ([%w$.]+)%.[%w$<>]+%(")
    local is_library = class
      and vim.iter(LIBRARY_FRAMES):any(function(prefix)
        return vim.startswith(class, prefix)
      end)
    if frame ~= "" and not is_library then
      table.insert(frames, frame)
      local frame_file, line = frame:match("%(([^:)]+):(%d+)%)$")
      if frame_file == file then
        lnum = tonumber(line) - 1
        break
      end
    end
  end
  if #frames > 0 then
    message = message .. "\n" .. table.concat(frames, "\n")
  end

  return {
    lnum = lnum,
    col = lnum == item.range.start.line and item.range.start.character or 0,
    severity = vim.diagnostic.severity.ERROR,
    source = "intellij-server tests",
    message = message,
  }
end

---@param run IntellijTestRun
local function finish(run)
  runs[run.id] = nil
  if run.pending ~= "" then
    feed(run, "\n")
  end

  local touched = {}
  for _, item in ipairs(run.items) do
    local bufnr = vim.uri_to_bufnr(item.uri)
    diagnostics[bufnr] = diagnostics[bufnr] or {}
    local failure = run.failures[item.id]
    diagnostics[bufnr][item.id] = failure and failure_diagnostic(item, failure) or nil
    touched[bufnr] = true
  end
  for bufnr in pairs(touched) do
    publish(bufnr)
  end

  local counts = run.counts
  local passed = counts.started - counts.failed - counts.skipped
  local seconds = (vim.uv.hrtime() - run.started) / 1e9
  local summary, level
  if counts.started == 0 then
    summary = ("%s: no test ran (exit code %s) — see :IntellijServerBuildLog"):format(run.label, tostring(run.exit_code))
    level = vim.log.levels.WARN
  else
    summary = ("%s: %d passed, %d failed, %d skipped in %.1fs"):format(run.label, passed, counts.failed, counts.skipped, seconds)
    level = counts.failed > 0 and vim.log.levels.ERROR or vim.log.levels.INFO
  end
  require("intellij-server.build-log").append({ ("── %s ──"):format(summary) })
  notify(summary, level)
end

-- Launching ------------------------------------------------------------------

---@param run IntellijTestRun
local function launch_next(run)
  local config = table.remove(run.launches, 1)
  if config then
    dap.run(config, { new = true })
  else
    finish(run)
  end
end

---@param session table nvim-dap session
---@return IntellijTestRun?
local function run_of(session)
  return session and session.config and runs[session.config.jvmTest]
end

--- Hook the DAP events of test sessions. Output goes through
--- `dap.defaults.intellij.on_output`, which replaces nvim-dap's own REPL
--- append: a test run's output is service messages for the results above, and
--- the REPL keeps receiving everything else, as nvim-dap would have done.
local function hook_dap()
  dap.defaults.intellij.on_output = function(session, body)
    local run = run_of(session)
    if run then
      feed(run, body.output or "")
    elseif body.category ~= "telemetry" then
      require("dap.repl").append(body.output, "$", { newline = false })
    end
  end
  dap.listeners.after.event_exited["intellij-server.tests"] = function(session, body)
    local run = run_of(session)
    if run then
      run.exit_code = run.exit_code or (body and body.exitCode)
    end
  end
  dap.listeners.after.event_terminated["intellij-server.tests"] = function(session)
    local run = run_of(session)
    if run then
      launch_next(run)
    end
  end
end

--- Run or debug tests; `items` come from one file or module.
---@param items IntellijTestItem[]
---@param opts { debug?: boolean, label?: string }?
function M.run_items(items, opts)
  opts = opts or {}
  if not has_dap then
    notify("nvim-dap is required to run tests")
    return
  end
  if #items == 0 then
    return
  end
  local client = lsp_client(vim.uri_to_bufnr(items[1].uri)) or vim.lsp.get_clients({ name = "intellij-server" })[1]
  if not client then
    notify("intellij-server is not running")
    return
  end
  local ij_dap = require("intellij-server.dap")
  local uri = items[1].uri

  next_run_id = next_run_id + 1
  ---@type IntellijTestRun
  local run = {
    id = next_run_id,
    label = opts.label or (#items == 1 and items[1].displayName or ("%d tests"):format(#items)),
    items = items,
    by_location = {},
    by_node = {},
    outcomes = {},
    failures = {},
    counts = { started = 0, failed = 0, skipped = 0 },
    pending = "",
    tail = {},
    launches = {},
    started = vim.uv.hrtime(),
  }
  for _, item in ipairs(items) do
    if item.location then
      run.by_location[item.location] = item
    end
  end

  local build_log = require("intellij-server.build-log")
  build_log.append({ "", ("── %s: %s ──"):format(opts.debug and "debugging" or "running", run.label) })

  -- Like a JVM launch, the module is compiled first unless setup() says not to.
  local function build(on_done)
    if (require("intellij-server").config.dap or {}).build_before_launch == false then
      on_done(true)
    else
      ij_dap.build_module(client, uri, on_done)
    end
  end

  build(function(ok)
    if not ok then
      notify(("%s: the build failed — see :IntellijServerBuildLog"):format(run.label))
      return
    end
    execute(client, "intellij.java.resolveLaunch", { { uri = uri, overrides = vim.empty_dict() } }, function(err, paths)
      if err then
        notify(("%s: intellij.java.resolveLaunch failed: %s"):format(run.label, err))
        return
      end
      local test_ids = vim.tbl_map(function(item)
        return item.id
      end, items)
      execute(client, "intellij.jvm.resolveTestLaunch", { { testIds = test_ids, uniqueIds = {} } }, function(err2, launches)
        if err2 or type(launches) ~= "table" or #launches == 0 then
          notify(("%s: intellij.jvm.resolveTestLaunch failed: %s"):format(run.label, err2 or "no way to run these tests"))
          return
        end
        for _, launch in ipairs(launches) do
          local class_paths = vim.list_extend(vim.list_extend({}, launch.runtimeClasspath or {}), paths.classpath or {})
          table.insert(run.launches, {
            type = "intellij",
            request = "launch",
            name = run.label,
            mainClass = launch.mainClass,
            args = launch.args,
            file = vim.uri_to_fname(uri),
            classPaths = class_paths,
            javaExec = paths.javaExec,
            cwd = paths.workingDirectory,
            vmArgs = paths.vmArgs,
            noDebug = not opts.debug,
            -- Output comes back as DAP output events, not a terminal.
            console = "none",
            -- Marks the session as this run's; also tells the adapter's
            -- enrich_config the configuration is complete.
            jvmTest = run.id,
          })
        end
        runs[run.id] = run
        launch_next(run)
      end)
    end)
  end)
end

--- Run the tests of a module: all of them when the module is known, else a
--- vim.ui.select over the modules the server has tests for.
---@param client vim.lsp.Client
---@param module_name string?
---@param opts { debug?: boolean }
local function run_module(client, module_name, opts)
  local function run_named(name)
    execute(client, "intellij.jvm.discoverTestsInModule", { name }, function(err, items)
      if err then
        notify("intellij.jvm.discoverTestsInModule failed: " .. err)
      elseif type(items) ~= "table" or #items == 0 then
        notify(("no tests in module %s"):format(name), vim.log.levels.WARN)
      else
        M.run_items(top_level_classes(items), vim.tbl_extend("force", opts, { label = name }))
      end
    end)
  end
  if module_name then
    run_named(module_name)
    return
  end
  execute(client, "intellij.jvm.discoverTestModules", {}, function(err, modules)
    if err then
      notify("intellij.jvm.discoverTestModules failed: " .. err)
    elseif type(modules) ~= "table" or #modules == 0 then
      notify("no module has tests (or the project import is not finished)", vim.log.levels.WARN)
    elseif #modules == 1 then
      run_named(modules[1])
    else
      vim.ui.select(modules, { prompt = "Run tests of module", kind = "intellij_module" }, function(name)
        if name then
          run_named(name)
        end
      end)
    end
  end)
end

--- Run or debug tests of the current buffer.
---@param opts { scope?: "cursor"|"file"|"module", debug?: boolean }?
function M.run(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local client = lsp_client(bufnr)
  if not client then
    notify("intellij-server is not attached to this buffer")
    return
  end
  local scope = opts.scope or "cursor"
  M.discover(client, vim.uri_from_bufnr(bufnr), function(err, items)
    if err then
      notify("intellij.jvm.discoverTestsInFile failed: " .. err)
      return
    end
    if scope == "module" then
      run_module(client, items[1] and items[1].moduleName, opts)
      return
    end
    local chosen
    if scope == "file" then
      chosen = top_level_classes(items)
    else
      chosen = { at_cursor(items, vim.api.nvim_win_get_cursor(0)[1] - 1) }
    end
    if #chosen == 0 then
      notify(#items == 0 and "no tests in this file (or the project import is not finished)" or "no test at the cursor", vim.log.levels.WARN)
      return
    end
    M.run_items(chosen, opts)
  end)
end

--- Client-side LSP commands (the lenses'), for vim.lsp.start's `commands`.
---@return table<string, fun(command: lsp.Command)>
function M.lsp_commands()
  return {
    [M.RUN_TEST_COMMAND] = function(command)
      local args = (command.arguments or {})[1] or {}
      M.run_items({ args.item }, { debug = not args.noDebug })
    end,
  }
end

function M.setup()
  if has_dap then
    hook_dap()
  end
end

return M
