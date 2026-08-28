# Debugging and running (nvim-dap)

[Configuration](configuration.md) · [Features](features.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)

With [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed, the plugin registers an `intellij` DAP adapter that communicates with the IntelliJ debug server:

- **Run/Debug code lenses** above every `main` entry point, like the VS Code extension
- **Launch**: run a main class, with or without the debugger
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

| Missing | Resolved via |
|---------|--------------|
| `file` | `intellij.java.resolveClassDocument` |
| `classPaths` (plus `modulePaths`, `moduleName`) | `intellij.java.resolveClasspath` |
| `cwd` | `intellij.java.resolveWorkingDirectory` |
| `javaExec` | `intellij.java.resolveJavaExecutable` |

So `mainClass` on its own is enough. Launch configurations support:

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
| `noDebug`     | `boolean`  | Run without attaching the debugger |
| `console`     | `string`   | Where to run the program: `internalConsole`, `integratedTerminal` (default), or `externalTerminal` |

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
-- where the integrated terminal opens
require("dap").defaults.intellij.terminal_win_cmd = "belowright 15new"
```

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

## Attach to a running JVM

Start the JVM with JDWP enabled:

```text
-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005
```

Then `:IntellijServerAttach 5005`, or pick the `Attach to JVM` configuration.

## Limitations (server 0.0.10)

- **Tests cannot be run or debugged.** The server exposes no test discovery or
  test-run support at all — the same limitation the VS Code extension has. Until
  it does, run the test under the build tool with JDWP enabled and attach:

  ```bash
  mvnDebug test -Dtest=MyTest              # Maven, listens on 5005, suspended
  gradle test --tests MyTest --debug-jvm   # Gradle, listens on 5005, suspended
  ```

  Then `:IntellijServerAttach 5005`. Both suspend until the debugger connects, so
  set breakpoints first. With plain `mvn`, pass the flag yourself — and keep the
  test in the same JVM, or the flag lands on the wrong one:

  ```bash
  mvn test -Dtest=MyTest -DforkCount=0 \
    -DargLine="-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"
  ```

- **Attach is local only.** The debugger always connects to `127.0.0.1`; the
  `hostName` and `timeout` fields the VS Code documentation lists are declared
  in the extension's schema but never reach the server.
- Execution is not delegated to Maven or Gradle, so launch parameters set in a
  build script do not apply.
- The Run/Debug lenses carry only the main class, so they always launch a
  program bare. Use `:IntellijServerRun` or a configuration to pass arguments.
