# Debugging and running (nvim-dap)

[Configuration](configuration.md) · [Features](features.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)

With [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed, the plugin registers an `intellij` DAP adapter that communicates with the IntelliJ debug server:

- **Run/Debug code lenses** above every `main` entry point, like the VS Code extension
- **Launch**: run a main class, with or without the debugger
- **Tests**: run or debug a test, a file or a module, with lenses above every test
- **Attach**: connect to a running JVM via JDWP

The adapter sends `workspace/executeCommand("start_debug_server")` to the LSP, which returns a DAP port.

## Run and debug a main class

Four ways to start a program, all equivalent:

| | Run | Debug |
|---|---|---|
| Code lens above `main` | `Run` | `Debug` |
| Command | `:IntellijServerRun com.example.Main` | `:IntellijServerRun!` |
| nvim-dap | `dap.continue()` → `Launch main class` | same, with breakpoints set |
| Lua | `run_main({ mainClass = …, noDebug = true })` | drop `noDebug` |

The plugin asks the server for run code lenses (`initializationOptions.runMainCodeLens`),
so `Run` and `Debug` lenses appear above every `main` method:

Put the cursor on the `main` line itself (any column — the lens line cannot hold a
cursor) and call `vim.lsp.codelens.run()`; because the line carries two lenses,
Neovim asks which one to use. Off that line it reports `No codelens at current line`.
Lenses only appear once the project import has finished — watch `:IntellijServerBuildLog`.

```lua
vim.keymap.set("n", "<leader>cl", vim.lsp.codelens.run, { desc = "Run code lens" })
```

`:IntellijServerRun com.example.Main` runs a class by name from anywhere in the
file, and `:IntellijServerRun!` debugs it instead.

Anything after the class name is passed to `main(String[])`, quoted like a shell:

```vim
:IntellijServerRun com.example.Main --port 8080 --name "two words"
```

For JVM arguments, environment variables or a working directory, use a nvim-dap
configuration (further down) — those are per-program settings worth keeping around.

Before a session starts, whatever the configuration leaves out is resolved from the
project model, the same way the VS Code extension resolves it:

| Step | Resolved via |
|------|--------------|
| `file` from `mainClass` | `intellij.java.resolveClassDocument` |
| which launcher (`launcher = "auto"`, what the lenses use) | `intellij.java.resolveBuildToolLaunch` — Gradle when it can run the module, otherwise a JVM launch |
| build before a JVM launch | `intellij.java.resolveBuildCommand` — the tool's own compile command (`mvn -pl :app -am compile`, `gradle :app:classes`, …), run with its output in `:IntellijServerBuildLog` |
| `javaExec`, `classPaths`, `modulePaths`, `moduleName`, `moduleContentPaths`, `cwd`, `vmArgs` | `intellij.java.resolveLaunch` — one request; values the configuration sets are sent as overrides and the server merges them |
| Gradle launch: `buildToolTarget`, `classPaths` (breakpoint scope) | `intellij.java.resolveBuildToolLaunch` |

So `mainClass` on its own is enough. Two ways to run exist, selected by `launcher`:

- **`"jvm"`** (default for your own nvim-dap configurations): the module is compiled with its
  build tool first, then `java` is spawned with the resolved classpath. Set `build = false` on a
  configuration, or `dap = { build_before_launch = false }` in `setup()`, to skip the compile.
- **`"gradle"`**: the adapter hands the launch to Gradle, which compiles as part of running. No
  classpath or JDK is decided on this side; `projectPath`, `sourceSet` and `gradleArgs` speak
  Gradle's vocabulary instead. Refused when Gradle cannot launch the module.
- **`"auto"`**: what the Run/Debug lenses and `:IntellijServerRun` use — `"gradle"` when Gradle can
  run the module, otherwise `"jvm"`. Maven and plain projects always launch as `"jvm"`; no single
  Maven invocation can both build the reactor and exec one module.

Launch configurations support:

| Property      | Type       | Description |
|---------------|------------|-------------|
| `mainClass`   | `string`   | Fully qualified main class to launch. Required. |
| `file`        | `string`   | Source file declaring it. Resolved from `mainClass`; set it to disambiguate when several files declare the same fully qualified name |
| `args`        | `string[]` | Program arguments |
| `vmArgs`      | `string[]` | JVM arguments, e.g. `{ "-Xmx512m", "-ea" }` |
| `env`         | `table`    | Extra environment variables for the launched process |
| `cwd`         | `string`   | Working directory |
| `javaExec`    | `string`   | Path to the `java` executable (default: project SDK) |
| `classPaths`  | `string[]` | Runtime classpath override |
| `modulePaths` | `string[]` | JPMS module path override; resolved from the project model if empty |
| `moduleName`  | `string`   | JPMS module owning the main class, launched as `-m moduleName/mainClass`; resolved automatically if empty |
| `launcher`    | `string`   | `"jvm"` (default), `"gradle"`, or `"auto"` — see above |
| `build`       | `boolean`  | Compile the module before a `"jvm"` launch. Default: `dap.build_before_launch` (on) |
| `projectPath` | `string`   | Gradle only: project to run in, as Gradle names it (`":app"`). Default: the project the module came from |
| `sourceSet`   | `string`   | Gradle only: source set whose runtime classpath the program runs on (`"main"`, `"test"`). Default: the module's |
| `gradleArgs`  | `string[]` | Gradle only: arguments for the Gradle invocation itself (`"--offline"`, `"-Pkey=value"`) |
| `noDebug`     | `boolean`  | Run without attaching the debugger |
| `console`     | `string`   | Where to run the program: `internalConsole`, `integratedTerminal` (default), `externalTerminal`, or `none` (output as DAP events; what test runs use) |

With `integratedTerminal` (the default) the adapter sends a DAP `runInTerminal`
reverse request, which nvim-dap answers by opening a terminal buffer for the
program's stdio. It is a real terminal, so a program that reads `System.in`
can be typed into while the debugger is attached.

`internalConsole` keeps output in the DAP REPL instead, but DAP gives that mode
no stdin channel — a program that waits for input hangs. `externalTerminal`
needs a terminal configured, otherwise nvim-dap warns and falls back to the
integrated one:

```lua
require("dap").defaults.fallback.external_terminal = {
  command = "/opt/homebrew/bin/wezterm",
  args = { "start", "--" },
}
-- where the integrated terminal opens, and whether the cursor moves into it
require("dap").defaults.intellij.terminal_win_cmd = "belowright 15new"
require("dap").defaults.intellij.focus_terminal = false
```

### Managing the program terminal

The terminal buffer is nvim-dap's, not the plugin's — it is named
`[dap-terminal] <name>` after the launch configuration (the lenses and
`:IntellijServerRun` use the class's simple name).

**Hide** it by closing the window (`<C-w>q` or `:hide`); the buffer and the
program keep running. **Show** it again with `:ls` and `:sb N`, or bind a toggle:

```lua
vim.keymap.set("n", "<leader>dt", function()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match("%[dap%-terminal%]") then
      return vim.api.nvim_win_close(win, true)             -- visible → hide
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.api.nvim_buf_get_name(buf):match("%[dap%-terminal%]") then
      vim.cmd("belowright 15split")                        -- hidden → show
      return vim.api.nvim_win_set_buf(0, buf)
    end
  end
end, { desc = "Toggle DAP terminal" })
```

**Kill** the program, from polite to guaranteed:

1. `:DapTerminate` (or `require("dap").terminate()`) — even a `Run` lens launch
   (`noDebug`) has a live DAP session behind it, so this asks the adapter to
   kill the debuggee and ends the session. The normal way.
2. `Ctrl-C` in the terminal — `i` on the buffer enters terminal-mode, `<C-c>`
   sends the program SIGINT. Interrupts a server or a loop without touching the
   session.
3. `:bd!` on the terminal buffer — deleting a terminal buffer makes Neovim kill
   its job unconditionally. Works even when the session or adapter is wedged.

Note that nvim-dap does not kill the job when a session merely closes, so after
an abnormal session end the program can linger in the hidden buffer — `:bd!` is
the cleanup for that case.

Example custom configuration:

```lua
table.insert(require("dap").configurations.java, {
  type = "intellij",
  request = "launch",
  name = "Run MyApp",
  mainClass = "com.example.MyApp",
  args = { "--port", "8080" },
  vmArgs = { "-Xmx512m" },
  env = { MY_FLAG = "1" },
  console = "internalConsole",
})
```

The same launches are available from Lua, for keymaps:

```lua
local ij = require("intellij-server.dap")
vim.keymap.set("n", "<leader>rr", function()
  ij.run_main({ mainClass = "com.example.Main", args = { "--port", "8080" } })
end)
vim.keymap.set("n", "<leader>ra", function() ij.attach(5005) end)
```

## Breakpoints and stepping

A debug session only stops where you tell it to: launched with no breakpoints set,
a program runs to completion and `Debug` looks no different from `Run`. Breakpoints
are nvim-dap's, not the plugin's:

```lua
local dap = require("dap")
vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint)
vim.keymap.set("n", "<leader>dc", dap.continue)
vim.keymap.set("n", "<leader>do", dap.step_over)
vim.keymap.set("n", "<leader>di", dap.step_into)
vim.keymap.set("n", "<leader>dr", dap.repl.open)
```

They can be set before launching or while the program runs — anything not yet
executed is still hit. Conditional and exception breakpoints work too, the latter
being the quickest way to find a throw site:

```lua
dap.set_breakpoint(vim.fn.input("Condition: "))  -- e.g. i == 42
dap.set_exception_breakpoints({ "uncaught" })
```

## Tests

Tests run the way IntelliJ runs them (server 0.0.13+): the server finds them,
resolves a launch of its own JUnit starter for exactly the tests asked for, and
the plugin runs that launch through nvim-dap like a main class — compiled first,
with breakpoints when debugging.

| | Run | Debug |
|---|---|---|
| Code lens above a test method or class | `Run Test` | `Debug Test` |
| Test at the cursor | `:IntellijServerTest` | `:IntellijServerTest!` |
| Every test in the file | `:IntellijServerTest file` | `:IntellijServerTest! file` |
| Every test in the module | `:IntellijServerTest module` | `:IntellijServerTest! module` |
| Lua | `require("intellij-server.tests").run({ scope = "cursor" })` | `{ scope = "cursor", debug = true }` |

The test at the cursor is the last test method declared at or above the cursor
line, or the class when the cursor is above the first one. `module` runs the
module the file belongs to; outside a file with tests it asks which module,
when there is more than one.

Results come back three ways:

- a notification: `CalcTest: 2 passed, 1 failed, 0 skipped in 1.3s`;
- a diagnostic on every failed test, placed on the assertion that failed when
  the stack trace points into the test's file, else on the test's name. It
  carries the message, the expected and actual values, and the frames down to
  that line (minus the assertion library's own); rerunning the test replaces
  it. Diagnostics live in the `intellij-server.tests` namespace;
- the program's own output in `:IntellijServerBuildLog`, after the build that
  preceded it.

Lenses appear once the project import has finished (they need the module), and
only above tests the server can run — JUnit, with the runtime the server
bundles. The `code_lens = { tests = false }` option turns them off; the
commands still work.

How it works: `intellij.jvm.discoverTestsInFile` / `discoverTestsInModule` list
the test classes and methods, `intellij.jvm.resolveTestLaunch` turns the chosen
ids into a `com.intellij.rt.junit.JUnitStarter` launch with the runner's jars,
and `intellij.java.resolveLaunch` supplies the project's own classpath, JDK and
working directory. The runner reports every test as a TeamCity service message
on stdout (`##teamcity[testFailed name='fails()' message='…' expected='4'
actual='3' …]`); with `console = "none"` those arrive as DAP output events,
which the plugin turns into the results above. nvim-dap's REPL does not see
them: the plugin sets `require("dap").defaults.intellij.on_output` to route
test output and forwards everything else to the REPL as nvim-dap itself would.

## Attach to a running JVM

Start the JVM with JDWP enabled:

```text
-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005
```

Then `:IntellijServerAttach 5005`, or pick the `Attach to JVM` configuration. Attach
configurations take `port`, `hostName` (default `localhost`) and `timeout` (ms, default 30000).

## Limitations

- The Run/Debug lenses carry only the main class, so they always launch a
  program bare. Use `:IntellijServerRun` or a configuration to pass arguments.
- A `"jvm"` launch runs `java` against the output directories the build tool
  fills; a build whose outputs lie elsewhere runs stale classes or none. Mill
  projects hit this out of the box, see
  [Troubleshooting](troubleshooting.md#mill-projects-rundebug-fails-with-classnotfoundexception-for-the-main-class).
- Tests are run by IntelliJ's starter, not by Maven or Gradle: surefire and
  Gradle `test {}` settings (system properties, JVM arguments, forking) do not
  apply. For those, run the test under the build tool with JDWP enabled and
  attach — `mvnDebug test -Dtest=MyTest` or `gradle test --tests MyTest
  --debug-jvm`, then `:IntellijServerAttach 5005`.
