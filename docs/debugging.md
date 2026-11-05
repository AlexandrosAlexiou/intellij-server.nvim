# Debugging and running (nvim-dap)

[Installation](installation.md) · [Configuration](configuration.md) · [Features](features.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)

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

The server resolves the rest itself (since server 1.0.86, as for the VS Code extension): it
finds the file declaring `mainClass`, builds the module with its build tool, takes the
classpath, JDK, module path and working directory from the project model, and runs the
program. The build's output and the program's arrive in the same console. `tool` picks how
the program runs:

- **`"java"`**: a JVM process, after the build tool compiled the module.
- **`"gradle"`** / **`"bazel"`**: the build tool's own run, which compiles as part of running;
  `projectPath`, `sourceSet` and `toolArgs` speak its vocabulary.
- **unset**: the server's choice — the build tool when it can run the module (Gradle), else a
  JVM process. The Run/Debug lenses pass the tool the server named for the module.

Configurations written for older versions keep working: `launcher = "jvm"` / `"gradle"` map
to `tool`, `"auto"` to no tool, and `gradleArgs` to `toolArgs`.

Launch configurations support:

| Property      | Type       | Description |
|---------------|------------|-------------|
| `mainClass`   | `string`   | Fully qualified main class to launch. Required. |
| `file`        | `string`   | Source file declaring it. Resolved from `mainClass`; set it to disambiguate when several files declare the same fully qualified name |
| `args`        | `string[]` | Program arguments |
| `vmArgs`      | `string[]` | JVM arguments, e.g. `{ "-Xmx512m", "-ea" }` |
| `env`         | `table`    | Extra environment variables for the launched process |
| `cwd`         | `string`   | Working directory |
| `tool`        | `string`   | `"java"`, `"gradle"` or `"bazel"` — see above. Default: the server's choice |
| `projectPath` | `string`   | Gradle project to run in (`":app"`) or Bazel target. Default: the module's |
| `sourceSet`   | `string`   | Gradle only: source set whose runtime classpath the program runs on (`"main"`, `"test"`). Default: the module's |
| `toolArgs`    | `string[]` | Arguments for the build tool invocation itself (`"--offline"`, `"-Pkey=value"`); `gradleArgs` is accepted too |
| `stepFilters` | `table`    | `{ skipClasses = { "java.*" }, skipSynthetics = true, skipConstructors = true, skipGetters = true, skipClassLoaders = true }` |
| `noDebug`     | `boolean`  | Run without attaching the debugger |
| `console`     | `string`   | Where to run the program: `internalConsole`, `integratedTerminal` (default), `externalTerminal`, or `none` (output as DAP events; what test runs use) |

The server runs the program itself and streams its stdout and stderr as DAP output events.
With `integratedTerminal` (the default) or `externalTerminal` the plugin writes them into a
terminal buffer in a bottom split (`intellij://run/…`), one per session in the same window,
like the VS Code extension's run terminal. `internalConsole` sends them to the DAP REPL. The
program gets no stdin either way — one that waits for input hangs.

### Managing the program terminal

**Hide** the `intellij://run/…` window by closing it (`<C-w>q`); the program keeps running and its
output keeps collecting in the buffer (`:ls` lists it, `:sb N` shows it again). The next launch
opens the split again and replaces a finished run's buffer. **Stop** the program with `:DapTerminate` (or
`require("dap").terminate()`) — a `Run` lens launch (`noDebug`) has a DAP session behind it too.
The terminal buffer only shows output: `Ctrl-C` in it or deleting it does not reach the program,
which the server runs.

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

Java and Kotlin tests run the way IntelliJ runs them: the server finds them,
resolves a launch of its own JUnit starter for exactly the tests asked for, and
the plugin runs that launch through nvim-dap like a main class — compiled first,
with breakpoints when debugging. Kotlin tests need server 1.0.86.

| | Run | Debug |
|---|---|---|
| Code lens above a test method or class | `Run Test` | `Debug Test` |
| Test at the cursor | `:IntellijServerTest` | `:IntellijServerTest!` |
| Every test in the file | `:IntellijServerTest file` | `:IntellijServerTest! file` |
| Every test in the module | `:IntellijServerTest module` | `:IntellijServerTest! module` |
| Lua | `require("intellij-server.tests").run({ scope = "cursor" })` | `{ scope = "cursor", debug = true }` |

JVM arguments, environment variables, a working directory and a tag filter for
test runs come from the `tests` option (the VS Code `java.test.config` setting):

```lua
require("intellij-server").setup({
  tests = { vm_args = { "-Xmx1g" }, env = { SPRING_PROFILES_ACTIVE = "test" }, tags = { "!slow" } },
})
```

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
and the adapter builds the module and runs the starter on its test runtime. The runner reports every test as a TeamCity service message
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
- A `"java"` launch runs `java` against the output directories the build tool
  fills; a build whose outputs lie elsewhere runs stale classes or none. Mill
  projects hit this out of the box, see
  [Troubleshooting](troubleshooting.md#mill-projects-rundebug-fails-with-classnotfoundexception-for-the-main-class).
- Tests are run by IntelliJ's starter, not by Maven or Gradle: surefire and
  Gradle `test {}` settings (system properties, JVM arguments, forking) do not
  apply; the `tests` option covers JVM arguments and environment. For the rest, run the test under the build tool with JDWP enabled and
  attach — `mvnDebug test -Dtest=MyTest` or `gradle test --tests MyTest
  --debug-jvm`, then `:IntellijServerAttach 5005`.
