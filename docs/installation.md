# Installation

[Configuration](configuration.md) · [Features](features.md) · [Debugging](debugging.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)

## Requirements

- Neovim ≥ 0.12
- `curl` and `unzip` on PATH (for `:IntellijServerInstall`; on Windows the bundled `tar` is used instead of `unzip`)
- macOS, Linux or Windows on x86_64 or ARM64 — every platform JetBrains publishes the server for
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) (optional, for debugging)

## lazy.nvim

```lua
{
  "AlexandrosAlexiou/intellij-server.nvim",
  ft = { "java", "kotlin" },
  dependencies = { "mfussenegger/nvim-dap" }, -- optional
  build = ":IntellijServerInstall",  -- auto-download on install/update
  opts = {},
}
```

## Manual

Clone this repo into your Neovim packages directory:

```sh
git clone https://github.com/AlexandrosAlexiou/intellij-server.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/intellij-server.nvim
```

Then add to your `init.lua`:

```lua
require("intellij-server").setup()
```

Run `:IntellijServerInstall` to download the server binary.

## How it works

The plugin launches the IntelliJ LSP server (`server/bin/intellij-server --stdio`) which is a headless IntelliJ IDEA
instance stripped for language server use. It communicates over stdin/stdout using the standard LSP protocol. The server
bundles its own JBR (JetBrains Runtime), no external JDK is required to run the server itself.

The server is started detached, so it leads its own process group: the JVM and
Maven or Gradle processes it spawns share that group and are killed with it on
`:IntellijServerStop`, `:IntellijServerRestart` and `:IntellijServerClean`, even
after being reparented to PID 1.

In [socket mode](configuration.md#shared-server-socket-mode) the plugin instead connects to a single shared
server (`--socket=<host>:<port> --multi-client`) over TCP, spawning it on demand. One process serves every project
and every Neovim instance. The server does not exit on its own, so the last Neovim to quit stops it (on Windows,
macOS and Linux alike), and `:IntellijServerStop!` force-kills it.

The server binary is downloaded from JetBrains CDN. The plugin vendors binaries from the
[JetBrains IntelliJ LSP VS Code extension](https://marketplace.visualstudio.com/items?itemName=JetBrains.intellij-server):

```
https://download.jetbrains.com/language-server/intellij-server/{build}/intellij-server-{version}-{platform}.vsix
```

That address redirects to a signed `download-cdn.jetbrains.com` URL; the CDN host itself no longer serves
the files unsigned (a plain request gets 404).

## Licensing

During the preview period (current), the server is **free to use without a
[license](https://blog.jetbrains.com/idea/2026/08/intellij-idea-goes-lsp/#licensing)**. Each preview build expires
after 30 days. Update the plugin to get a fresh build. Licensing will be introduced with the 1.0 release.
