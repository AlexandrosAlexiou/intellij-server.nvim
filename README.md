intellij-server.nvim &mdash; IntelliJ IDEA's LSP in Neovim
======================================================================

[<img alt="github" src="https://img.shields.io/badge/github-AlexandrosAlexiou/intellij--server.nvim-8da0cb?style=for-the-badge&labelColor=555555&logo=github" height="20">](https://github.com/AlexandrosAlexiou/intellij-server.nvim)
[<img alt="neovim" src="https://img.shields.io/badge/neovim-0.12+-57A143?style=for-the-badge&labelColor=555555&logo=neovim" height="20">](https://neovim.io/)
[<img alt="intellij-server" src="https://img.shields.io/badge/intellij--server-263.7084.0-FE315D?style=for-the-badge&labelColor=555555&logo=intellijidea" height="20">](https://blog.jetbrains.com/idea/2026/08/intellij-idea-goes-lsp)
[<img alt="license" src="https://img.shields.io/github/license/AlexandrosAlexiou/intellij-server.nvim?style=for-the-badge" height="20">](LICENSE)

This plugin runs the [JetBrains IntelliJ Language Server][announcement], the
same engine that powers IntelliJ IDEA, in Neovim and gives Java and Kotlin
files IntelliJ's completion, diagnostics, navigation, refactoring and
formatting through the built-in LSP client.

The server is written for its VS Code extension and expects an IDE on the
other end: it inserts completions through commands, asks the editor to show
refactoring prompts, and leaves running, debugging and testing to the client.
intellij-server.nvim supplies those pieces, downloads and updates the server,
and can share one server process across every project and Neovim instance.

```lua
-- lazy.nvim
{
  "AlexandrosAlexiou/intellij-server.nvim",
  ft = { "java", "kotlin" },
  dependencies = { "mfussenegger/nvim-dap" }, -- optional
  build = ":IntellijServerInstall",
  opts = {},
}
```

*Requires Neovim 0.12+, `curl` and `unzip` (`tar` on Windows); macOS, Linux or Windows on x86_64 or ARM64*<br>
*[Release notes](https://github.com/AlexandrosAlexiou/intellij-server.nvim/releases)*

<br>

## Documentation

| | |
|---|---|
| [Installation](docs/installation.md) | Requirements, plugin managers, how the server is downloaded and run, licensing |
| [Configuration](docs/configuration.md) | Every option with defaults, project root, shared server (socket mode), project JDK, inlay hints |
| [Features](docs/features.md) | Commands, what works, and the behaviours the plugin fixes up |
| [Debugging and running](docs/debugging.md) | Code lenses, `:IntellijServerRun`, tests, attach, breakpoints |
| [Code style](docs/code-style.md) | `.editorconfig` properties: import collapsing, import order, every `ij_java_*` / `ij_kotlin_*` setting |
| [Troubleshooting](docs/troubleshooting.md) | Gradle sources, server heap, logs, file paths |
| [Server changelog](docs/server-changelog.md) | What changed between pinned server versions and what the plugin must support |

<br>

## Overview

`:IntellijServerInstall` downloads the server from JetBrains and the plugin
starts it on the project root when you open a Java or Kotlin file. The server
is a headless IntelliJ IDEA with its own runtime, so no JDK is needed to run
it. Everything the server advertises works through Neovim's LSP client:
completion, diagnostics, hover, navigation, references, rename, code actions,
inlay hints and code lenses. On top of that the plugin provides what the
server expects from an IDE:

- **Completion that inserts once,** with IntelliJ's own text, imports and
  caret placement, in the built-in completion, nvim-cmp and blink.cmp.

- **Refactoring prompts.** The questions refactorings ask (pick one of several
  outcomes, confirm despite conflicts, rename what was just extracted) appear
  as Neovim prompts.

- **External Libraries.** Dependency and JDK sources as a browsable tree in
  oil.nvim and the snacks explorer, and go-to-definition on a `package` opens
  its folder.

- **Running, debugging and testing** through nvim-dap: Run and Debug lenses,
  `:IntellijServerRun` and `:IntellijServerTest`, and attaching to a running
  JVM.

- **Formatting and file templates** with IntelliJ's code-style engine and its
  New File templates.

- **One server for everything.** In socket mode a single shared process serves
  every project and Neovim instance instead of one IntelliJ per project.

<br>

## Example

```lua
require("intellij-server").setup({
  -- Raise the server's heap for large projects (default: the JVM's own)
  jvm_args = { "-Xmx8g" },

  -- One shared server for all projects and Neovim instances
  connection = { mode = "socket" },

  on_attach = function(client, bufnr)
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = bufnr })
  end,
})
```

Every option is listed in [docs/configuration.md](docs/configuration.md), and
every command in [docs/features.md](docs/features.md#commands).

> [!important]
> **The server needs a JetBrains license.** The free preview period, when the
> server ran without one, ended with server 1.0. The server is JetBrains'
> product and now requires an **IntelliJ IDEA Ultimate** or **All Products
> Pack** subscription, or the 30-day IntelliJ IDEA Ultimate trial (see
> [pricing](https://www.jetbrains.com/idea/buy/)).
>
> **This plugin is free and open source, and it takes no money.** It sells
> nothing, does not provide or resell licenses, and has no connection to
> JetBrains' billing. It only lets you use the server from Neovim if you already
> hold a valid IntelliJ IDEA license. If you are signed in to your JetBrains
> Account through the IDE or Toolbox, the server finds that license by itself;
> otherwise use `:IntellijServerLicense` (see
> [docs/installation.md](docs/installation.md#licensing)).

[announcement]: https://blog.jetbrains.com/idea/2026/08/intellij-idea-goes-lsp

<br>

#### License

<sup>
Licensed under the <a href="LICENSE">MIT license</a>.
</sup>
