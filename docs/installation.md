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

The free preview period, when the server ran without a license, ended with server 1.0. The server now requires an
IntelliJ IDEA Ultimate or All Products Pack subscription, or the 30-day IntelliJ IDEA Ultimate trial (see
[pricing](https://www.jetbrains.com/idea/buy/)).

This plugin is free and open source and takes no money: it does not sell, provide or resell licenses, and has no
connection to JetBrains' billing. It only lets you use the server from Neovim if you already hold a valid IntelliJ IDEA
license; the license itself is between you and JetBrains.

If you are already signed in to your JetBrains
Account on this machine (for example through IntelliJ IDEA or Toolbox), the server finds that license by itself.
Otherwise activate one from Neovim:

```vim
:IntellijServerLicense            " what the server is licensed with
:IntellijServerLicense login      " sign in to a JetBrains Account in the browser
:IntellijServerLicense trial      " start the 30-day trial
:IntellijServerLicense code       " enter an activation code
:IntellijServerLicense server     " use a floating license server
```

The plugin warns when the server loses its license (with the grace deadline) or runs without one. Without a license
the server still starts, but refuses every request, so nothing works until you activate one.

On a machine without a browser (over SSH), use the server's own command line instead, with the path to the installed
server:

```sh
~/.local/share/nvim/intellij-server/server/bin/intellij-server license status
~/.local/share/nvim/intellij-server/server/bin/intellij-server license login     # or: activate, trial
```

or set `INTELLIJ_SERVER_LICENSE` / `INTELLIJ_SERVER_LICENSE_FILE` (license key) or `JETBRAINS_LICENSE_SERVER` (license
server URL) in the environment Neovim starts the server from. See
[server-changelog.md](server-changelog.md#licensing) for the protocol.
