# intellij-server.nvim

Neovim plugin for the [JetBrains IntelliJ Language Server](https://blog.jetbrains.com/idea/2026/08/intellij-idea-goes-lsp) the same engine that powers IntelliJ IDEA, now available as an LSP server.

Provides Java and Kotlin language support including code completion, diagnostics, navigation, refactoring, and formatting.

## Requirements

- Neovim ≥ 0.12
- `curl` and `unzip` on PATH (for `:IntellijServerInstall`; on Windows the bundled `tar` is used instead of `unzip`)
- macOS, Linux or Windows on x86_64 or ARM64 — every platform JetBrains publishes the server for
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) (optional, for debugging)

## Installation

### lazy.nvim

```lua
{
  "Alexandros-Alexiou/intellij-server.nvim",
  ft = { "java", "kotlin" },
  dependencies = { "mfussenegger/nvim-dap" }, -- optional
  build = ":IntellijServerInstall",  -- auto-download on install/update
  opts = {},
}
```

### Manual

Clone this repo into your Neovim packages directory:

```sh
git clone https://github.com/Alexandros-Alexiou/intellij-server.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/intellij-server.nvim
```

Then add to your `init.lua`:

```lua
require("intellij-server").setup()
```

Run `:IntellijServerInstall` to download the server binary.

## Configuration

The plugin works with no configuration — `opts = {}` (or `require("intellij-server").setup()`)
attaches to Java and Kotlin files and starts the server on the working directory.

```lua
require("intellij-server").setup({
  -- Raise the server's heap for large projects (default: the JVM's own)
  jvm_args = { "-Xmx8g" },

  on_attach = function(client, bufnr)
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = bufnr })
  end,
})
```

Every option — filetypes, project import, inlay hints, folding, code lenses, inline
completion, the build log — is documented in **[docs/configuration.md](docs/configuration.md)**.

## Commands

| Command | Description |
|---|---|
| `:IntellijServerInstall` | Download the server from JetBrains CDN |
| `:IntellijServerUpdate` | Force re-download the server |
| `:IntellijServerStart` | Start/attach the server for the current buffer |
| `:IntellijServerStop` | Stop all running server instances |
| `:IntellijServerRestart` | Restart the server |
| `:IntellijServerClean` | Clean the current project's caches and restart |
| `:IntellijServerVersion` | Show installed version info |
| `:IntellijServerLogs` | Open the server log and Neovim's LSP log |
| `:IntellijServerBuildLog` | Open the streamed import/build log (Maven downloads, compilation, …) |
| `:IntellijServerNewFile [template]` | Create a new file from an IntelliJ template |
| `:IntellijServerRun [main.Class] [args...]` | Run a main class with program arguments (`:IntellijServerRun!` debugs it) |
| `:IntellijServerAttach [port]` | Attach the debugger to a JVM over JDWP (default 5005) |

## Features

Java and Kotlin support from the same engine IntelliJ IDEA runs on: completion,
diagnostics, navigation, refactoring, formatting, inlay hints, code lenses and
inline completion — all through Neovim's built-in LSP client. On top of that the
plugin supplies the client-side pieces the server expects an IDE to provide:
package navigation, completion insertion, formatting, inline completion, file
templates, and running and debugging through nvim-dap.

## Documentation

| | |
|---|---|
| [Configuration](docs/configuration.md) | Every option, with defaults |
| [Features](docs/features.md) | What works, and the behaviours the plugin fixes up |
| [Debugging and running](docs/debugging.md) | Code lenses, `:IntellijServerRun`, attach, breakpoints, tests |
| [Troubleshooting](docs/troubleshooting.md) | Gradle sources, server heap, logs, file paths |

## How it works

The plugin launches the IntelliJ LSP server (`server/bin/intellij-server --stdio`) which is a headless IntelliJ IDEA
instance stripped for language server use. It communicates over stdin/stdout using the standard LSP protocol. The server
bundles its own JBR (JetBrains Runtime), no external JDK is required to run the server itself.

The server is started detached, so it leads its own process group: the JVM and
Maven or Gradle processes it spawns share that group and are killed with it on
`:IntellijServerStop`, `:IntellijServerRestart` and `:IntellijServerClean`, even
after being reparented to PID 1.

The server binary is downloaded from JetBrains CDN. The plugin vendors binaries from the
[JetBrains IntelliJ LSP VS Code extension](https://marketplace.visualstudio.com/items?itemName=JetBrains.intellij-server):

```
https://download-cdn.jetbrains.com/language-server/intellij-server/{build}/intellij-server-{version}-{platform}.vsix
```

> [!important]
> During the preview period (current), the server is **free to use without a [license](https://blog.jetbrains.com/idea/2026/08/intellij-idea-goes-lsp/#licensing)**. Each preview build expires after
> 30 days. Update the plugin to get a fresh build. Licensing will be introduced with the 1.0 release.

## License

[MIT](LICENSE)
