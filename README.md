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

All fields are optional. The values below are the defaults, with realistic examples
for the fields that default to `nil`/empty:

```lua
require("intellij-server").setup({
  -- Path to the intellij-server binary. Auto-detected if nil:
  -- :IntellijServerInstall download > binary vendored with the plugin
  server_path = "/opt/intellij-server/bin/intellij-server",

  -- File types that trigger the LSP
  filetypes = { "java", "kotlin" },

  -- Extra JVM options for the server process (default: nil).
  -- Appended after bin/intellij-server.vmoptions, so -Xmx wins over the
  -- 2 GB the server ships with — raise it if the server dies with
  -- OutOfMemoryError (see Troubleshooting)
  jvm_args = { "-Xmx8g" },

  -- Files/directories that mark the project root
  root_markers = {
    "pom.xml", "build.gradle", "build.gradle.kts",
    "settings.gradle", "settings.gradle.kts",
    "WORKSPACE", "WORKSPACE.bazel", "BUILD", ".git",
  },

  -- Start automatically on matching filetypes (default: true)
  autostart = true,

  -- Callback after the client attaches to a buffer (default: nil)
  on_attach = function(client, bufnr)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { buffer = bufnr })
    vim.keymap.set("n", "<leader>cl", vim.lsp.codelens.run, { buffer = bufnr })
  end,

  -- Extra LSP capabilities merged into the client's defaults (default: nil).
  -- e.g. from your completion plugin:
  capabilities = require("blink.cmp").get_lsp_capabilities(),

  -- Workspace settings, merged over the plugin defaults. The full list of
  -- supported keys with their defaults (see "Inlay hint settings" below):
  settings = {
    -- Kotlin
    ["jetbrains.kotlin.hints.parameters"] = true,                  -- parameter names
    ["jetbrains.kotlin.hints.parameters.compiled"] = true,         -- parameter names from compiled code
    ["jetbrains.kotlin.hints.parameters.excluded"] = false,        -- parameter names for excluded methods
    ["jetbrains.kotlin.hints.parameters.context"] = false,         -- context parameter hints
    ["jetbrains.kotlin.hints.type.property"] = true,               -- property types
    ["jetbrains.kotlin.hints.type.variable"] = true,               -- local variable types
    ["jetbrains.kotlin.hints.type.function.return"] = true,        -- function return types
    ["jetbrains.kotlin.hints.type.function.parameter"] = true,     -- function parameter types
    ["jetbrains.kotlin.hints.lambda.return"] = true,               -- lambda return types
    ["jetbrains.kotlin.hints.lambda.receivers.parameters"] = true, -- lambda receivers/parameters
    ["jetbrains.kotlin.hints.value.ranges"] = true,                -- value ranges
    ["jetbrains.kotlin.hints.value.kotlin.time"] = true,           -- kotlin.time values
    ["jetbrains.kotlin.hints.call.chains"] = false,                -- call-chain intermediate types
    -- Java
    ["jetbrains.java.hints.settings.method parameter"] = true,     -- parameter names
    ["jetbrains.java.hints.types.local variable"] = true,          -- local variable types
    ["jetbrains.java.hints.collapse complex types"] = true,        -- collapse complex types
    ["jetbrains.java.hints.types.call chain"] = true,              -- call-chain types
  },

  -- Inlay hints: auto-enable vim.lsp.inlay_hint on attach
  inlay_hints = { enabled = true },

  -- LSP-driven folding: sets foldmethod/foldexpr on attach, folds start open
  folding = { enabled = true },

  -- Code lens: auto-refresh on attach and edits; run with vim.lsp.codelens.run()
  code_lens = { enabled = true },

  -- Inline completion (ghost text suggestions)
  inline_completion = {
    enabled = true,
    keymaps = {
      show = "<M-\\>",     -- trigger inline suggestion
      accept = "<Tab>",    -- accept suggestion
      dismiss = "<Esc>",   -- dismiss suggestion
    },
  },

  -- nvim-dap debugger integration
  dap = {
    enabled = true,  -- requires nvim-dap
  },

  -- Explicit project imports (initializationOptions.projects), equivalent to
  -- the VS Code `intellij.projects` setting. Overrides marker-based
  -- auto-import. Types: gradle, maven, bazel, jps, gomodules,
  -- gomodules-recursive-scan, json. Paths may be file:// URIs or plain paths.
  -- Can also be a function(root_dir) returning the list.
  -- projects = {
  --   { type = "gradle", path = "/path/to/project" },
  -- },
  projects = nil,

  -- Disable the RocksDB write-ahead log for the server's index storage
  -- (initializationOptions.disableRocksDBWriteAheadLog).
  disable_rocksdb_wal = nil,

  -- Streamed import/build log (Maven downloads, compilation output, …)
  -- The same detail the VS Code extension shows in its "Build" panel.
  -- View with :IntellijServerBuildLog
  build_log = {
    enabled = true,
    open_on_start = false,   -- auto-open the log window when an import/build starts
    open_on_failure = true,  -- auto-open the log window on failure
    notify = true,           -- vim.notify on start/success/failure
  },
})
```

### Inlay hint settings

The server pulls hint categories from the client via `workspace/configuration`; the plugin
answers with the flat keys below (defaults shown). Override any of them through `settings`
Your values are merged over the defaults:

```lua
require("intellij-server").setup({
  settings = {
    ["jetbrains.kotlin.hints.parameters"] = false, -- e.g. turn off parameter name hints
  },
})
```

This is the complete set the server supports, verified against the server's
declarative inlay hint optionIds. Note that four Kotlin keys deliberately differ
from the JetBrains VS Code extension's manifest. The extension contributes
bundle nameKeys (`hints.settings.types.property`, ...) that the server never
matches, so copying them disables those hint types:

| Key | Default | Hint |
|---|---|---|
| `jetbrains.kotlin.hints.parameters` | `true` | Parameter names |
| `jetbrains.kotlin.hints.parameters.compiled` | `true` | Parameter names from compiled code |
| `jetbrains.kotlin.hints.parameters.excluded` | `false` | Parameter names for excluded methods |
| `jetbrains.kotlin.hints.parameters.context` | `false` | Context parameter hints |
| `jetbrains.kotlin.hints.type.property` | `true` | Property types |
| `jetbrains.kotlin.hints.type.variable` | `true` | Local variable types |
| `jetbrains.kotlin.hints.type.function.return` | `true` | Function return types |
| `jetbrains.kotlin.hints.type.function.parameter` | `true` | Function parameter types |
| `jetbrains.kotlin.hints.lambda.return` | `true` | Lambda return types |
| `jetbrains.kotlin.hints.lambda.receivers.parameters` | `true` | Lambda receivers/parameters |
| `jetbrains.kotlin.hints.value.ranges` | `true` | Value ranges |
| `jetbrains.kotlin.hints.value.kotlin.time` | `true` | `kotlin.time` values |
| `jetbrains.kotlin.hints.call.chains` | `false` | Call-chain intermediate types |
| `jetbrains.java.hints.settings.method parameter` | `true` | Parameter names (Java) |
| `jetbrains.java.hints.types.local variable` | `true` | Local variable types (Java) |
| `jetbrains.java.hints.collapse complex types` | `true` | Collapse complex types (Java) |
| `jetbrains.java.hints.types.call chain` | `true` | Call-chain types (Java) |

The inconsistent `settings.`/spaces in the Java key names are server-side quirks so use them verbatim.

## Commands

| Command | Description |
|---|---|
| `:IntellijServerInstall` | Download the server from JetBrains CDN |
| `:IntellijServerUpdate` | Force re-download the server |
| `:IntellijServerStart` | Start/attach the server for the current buffer |
| `:IntellijServerStop` | Stop all running server instances |
| `:IntellijServerRestart` | Restart the server |
| `:IntellijServerClean` | Clean indexes/caches and restart |
| `:IntellijServerVersion` | Show installed version info |
| `:IntellijServerLogs` | Open the server log and Neovim's LSP log |
| `:IntellijServerBuildLog` | Open the streamed import/build log (Maven downloads, compilation, …) |
| `:IntellijServerNewFile [template]` | Create a new file from an IntelliJ template |

## Features

### Standard LSP

Everything the server (v0.0.10) advertises is supported. Features marked *automatic* work through
Neovim's built-in LSP client with no configuration.

| Feature | How to use |
|---|---|
| Code completion | *automatic* — `<C-x><C-o>` or your completion plugin (nvim-cmp, blink.cmp) |
| Hover documentation | `K` / `vim.lsp.buf.hover()` |
| Go to definition | `gd` / `vim.lsp.buf.definition()` (works into decompiled JDK/library sources) |
| Go to implementation | `gri` / `vim.lsp.buf.implementation()` |
| Go to type definition | `vim.lsp.buf.type_definition()` |
| Find references | `grr` / `vim.lsp.buf.references()` |
| Document symbols | `gO` / `vim.lsp.buf.document_symbol()` |
| Workspace symbols | `vim.lsp.buf.workspace_symbol()` |
| Code actions & quick fixes | `gra` / `vim.lsp.buf.code_action()` |
| Rename | `grn` / `vim.lsp.buf.rename()` |
| Formatting (document) | `vim.lsp.buf.format()` |
| Diagnostics (pull) | *automatic* — `vim.diagnostic.*` |
| Signature help | `<C-s>` (insert mode) / `vim.lsp.buf.signature_help()` |
| Semantic tokens | *automatic* — IntelliJ-quality highlighting layered over treesitter |
| Inlay hints | enabled on attach by the plugin — `inlay_hints = { enabled = false }` to opt out, or toggle with `vim.lsp.inlay_hint.enable()` |
| Folding range | wired on attach: `foldexpr = v:lua.vim.lsp.foldexpr()`, folds start open — `folding = { enabled = false }` to opt out; use `zc`/`zo`/`za` |
| Code lens | refreshed on attach and on edits by the plugin — run with `vim.lsp.codelens.run()`; `code_lens = { enabled = false }` to opt out |
| Call hierarchy | `vim.lsp.buf.incoming_calls()` / `vim.lsp.buf.outgoing_calls()` |
| Type hierarchy | `vim.lsp.buf.typehierarchy("subtypes")` / `("supertypes")` |

Not provided by the server: go to declaration, range/on-type formatting, selection range.

### Completion insertion fix

The server does not put the inserted text in its completion items. Each item
carries an empty `textEdit` plus a `jetbrains.java.completion.apply` /
`jetbrains.kotlin.completion.apply` command, and the server applies the real
text + caret afterwards via `workspace/applyEdit` and `window/showDocument`.
VS Code's client inserts nothing on accept and lets the command do the work, so
it just works there. Neovim frontends (builtin completion, nvim-cmp, blink.cmp)
insert the item text *and* run the command, so the server's edit lands on top
and the caret ends up mid-identifier (accepting `App` produces `Ap|p`).

The plugin fixes this automatically by making Neovim behave like the VS Code
client: it turns the client's own insertion into a no-op and keeps the apply
command, so the server performs the real insertion. You get the full
behaviour (text, **auto-import**, parentheses and caret) in every completion
engine (builtin completion, nvim-cmp, blink.cmp). No configuration required.

> [!NOTE]
> This relies on the frontend executing the completion item's `command` (builtin,
> nvim-cmp and blink.cmp all do). The proper fix is still upstream returning a
> real `textEdit`.

> [!TIP]
> Since the server inserts brackets itself (e.g. `firstOrNull { }`), disable your
> frontend's client-side auto-brackets for these filetypes or you'll get an extra
> trailing `()`. For blink.cmp:
>
> ```lua
> completion = {
>   accept = { auto_brackets = { blocked_filetypes = { "java", "kotlin" } } },
> }
> ```
>
> For nvim-cmp + nvim-autopairs, don't wire `cmp.event:on("confirm_done", ...)`
> for these filetypes (use its `filetypes` blocklist).

### Formatting

The server formats with IntelliJ's code-style engine (whole document only):

```lua
vim.lsp.buf.format()
-- or, to be explicit when multiple LSP clients are attached:
vim.lsp.buf.format({ name = "intellij-server" })
```

A keymap example for `on_attach`:

```lua
on_attach = function(client, bufnr)
  vim.keymap.set({ "n", "v" }, "<leader>fi", function()
    vim.lsp.buf.format({ async = true, name = "intellij-server" })
  end, { buffer = bufnr, desc = "Format buffer with IntelliJ" })
end,
```

If you use [conform.nvim](https://github.com/stevearc/conform.nvim), the LSP formatter is used
whenever no CLI formatter is configured for the filetype (`lsp_format = "fallback"`), or you can
select it explicitly:

```lua
require("conform").setup({
  formatters_by_ft = {
    java = { lsp_format = "prefer" },
    kotlin = { lsp_format = "prefer" },
  },
})
```

There are no formatting-related LSP settings. Customize the style per project via
`.editorconfig` using IntelliJ's `ij_java_*` / `ij_kotlin_*` properties, exactly like the IDE.

### Inline Completion

The server supports `textDocument/inlineCompletion` (proposed LSP spec). The plugin renders suggestions as ghost text:

- `<M-\>` — trigger a suggestion
- `<Tab>` — accept
- `<Esc>` — dismiss

### Debugging (nvim-dap)

With [nvim-dap](https://github.com/mfussenegger/nvim-dap) installed, the plugin registers an `intellij` DAP adapter that communicates with the IntelliJ debug server:

- **Launch**: Run a main class with debugging
- **Attach**: Connect to a running JVM via JDWP (default port 5005)

The adapter sends `workspace/executeCommand("start_debug_server")` to the LSP, which returns a DAP port.

Launch configurations support these properties (server 0.0.10+):

| Property     | Type       | Description |
|--------------|------------|-------------|
| `mainClass`  | `string`   | Fully qualified main class to launch |
| `args`       | `string[]` | Program arguments |
| `env`        | `table`    | Extra environment variables for the launched process |
| `javaExec`   | `string`   | Path to the `java` executable (default: project SDK) |
| `modulePath` | `string[]` | JPMS module path override; resolved from the project model if empty |
| `moduleName` | `string`   | JPMS module owning the main class, launched as `-m moduleName/mainClass`; resolved automatically if empty |
| `console`    | `string`   | Where to run the program: `internalConsole`, `integratedTerminal` (default), or `externalTerminal` |

With `integratedTerminal` (the default) the adapter sends a DAP `runInTerminal`
reverse request, which nvim-dap answers by opening a terminal buffer for the
program's stdio. Use `internalConsole` to keep output in the DAP REPL instead.

Example custom configuration:

```lua
table.insert(require("dap").configurations.java, {
  type = "intellij",
  request = "launch",
  name = "Run MyApp",
  mainClass = "com.example.MyApp",
  args = { "--port", "8080" },
  env = { MY_FLAG = "1" },
  console = "internalConsole",
})
```

### File Templates

`:IntellijServerNewFile` creates new files using IntelliJ's template engine. Available templates:

**Kotlin:** Class, File, Interface, Data Class, Enum, Annotation, Object
**Java:** Class, Interface, Record, Enum, Annotation, Exception

Templates are interpolated server-side via `workspace/executeCommand("interpolateFileTemplate")` with fallback to local variable substitution.

## File Paths

### Server binary

The plugin looks for the server binary in this order:

1. `server_path` from config (if set explicitly)
2. `~/.local/share/nvim/intellij-server/server/bin/intellij-server` (downloaded via `:IntellijServerInstall`)
3. `<plugin-root>/server/bin/intellij-server` (vendored, if present)

### Data directories

The plugin stores all IntelliJ server indexes, caches, config, and logs under Neovim's data directory:

```
~/.local/share/nvim/intellij-server/data/
├── config/    # server configuration
├── system/    # project indexes and caches
└── log/       # server logs
```

These persist across reboots (unlike the default temp directory behavior). To clean and re-index:

```vim
:IntellijServerClean
```

### Plugin download location

`:IntellijServerInstall` downloads and extracts the server to:

```
~/.local/share/nvim/intellij-server/
├── server/          # extracted server (bin, lib, jbr, plugins, etc.)
└── .version         # version marker (e.g., "0.0.10+263.3533.0")
```

## How it works

The plugin launches the IntelliJ LSP server (`server/bin/intellij-server --stdio`) which is a headless IntelliJ IDEA
instance stripped for language server use. It communicates over stdin/stdout using the standard LSP protocol. The server
bundles its own JBR (JetBrains Runtime), no external JDK is required to run the server itself.

The server binary is downloaded from JetBrains CDN. The plugin vendors binaries from the
[JetBrains IntelliJ LSP VS Code extension](https://marketplace.visualstudio.com/items?itemName=JetBrains.intellij-server):

```
https://download-cdn.jetbrains.com/language-server/intellij-server/{build}/intellij-server-{version}-{platform}.vsix
```

> [!important]
> During the preview period (current), the server is **free to use without a [license](https://blog.jetbrains.com/idea/2026/08/intellij-idea-goes-lsp/#licensing)**. Each preview build expires after
> 30 days. Update the plugin to get a fresh build. Licensing will be introduced with the 1.0 release.

## Troubleshooting

### Gradle projects: go-to-definition opens decompiled classes instead of library sources

The server resolves dependency sources from the shared Gradle cache (`~/.gradle/caches/modules-2`), same as full
IntelliJ IDEA. But unlike the full IDE there is no "Download Sources" button, so if the `-sources.jar`s were never
fetched you land in decompiled stubs.

**Fix 1: Download sources automatically on every Gradle sync.** Create `~/.gradle/init.d/idea-download-sources.gradle`:

```groovy
allprojects {
    // Plain Java and kotlin("jvm") projects both apply the "java" plugin, which
    // extends "java-base". Matching "java-base" additionally catches Kotlin
    // Multiplatform JVM targets, which apply only "java-base".
    plugins.withId("java-base") {
        apply plugin: "idea"
        idea {
            module {
                downloadSources = true
                downloadJavadoc = false
            }
        }
    }
}
```

The IntelliJ Gradle importer (used by intellij-server during project sync) honors `idea.module.downloadSources`, so
sources are fetched on import for every project on the machine.

**Fix 2: Prefetch sources for an already-imported project.** Save this as `~/.gradle/download-sources.init.gradle`:

```groovy
import org.gradle.api.attributes.Category
import org.gradle.api.attributes.DocsType

allprojects { project ->
    project.tasks.register("downloadSources") {
        notCompatibleWithConfigurationCache("resolves configurations at execution time")
        doLast {
            // compileClasspath/testCompileClasspath exist in plain Java and
            // kotlin("jvm") projects alike (both apply the "java" plugin); the
            // jvm* names are only for Kotlin Multiplatform JVM targets.
            ["compileClasspath", "testCompileClasspath",
             "jvmCompileClasspath", "jvmTestCompileClasspath"].each { cfgName ->
                def cfg = project.configurations.findByName(cfgName)
                if (cfg == null || !cfg.canBeResolved) {
                    return
                }
                def view = cfg.incoming.artifactView { v ->
                    v.withVariantReselection()
                    v.lenient(true)
                    v.attributes { a ->
                        a.attribute(Category.CATEGORY_ATTRIBUTE, project.objects.named(Category, Category.DOCUMENTATION))
                        a.attribute(DocsType.DOCS_TYPE_ATTRIBUTE, project.objects.named(DocsType, DocsType.SOURCES))
                    }
                }
                view.files.each { f ->
                    logger.lifecycle("sources: ${f.name}")
                }
            }
        }
    }
}
```

Then run it from the project root (requires Gradle 7.5+ for variant reselection):

```bash
./gradlew --init-script ~/.gradle/download-sources.init.gradle downloadSources --no-configuration-cache
```

Either way, re-sync the project afterwards (restart the server or reload the project) so the freshly cached sources
jars are picked up.

### The server dies with `java.lang.OutOfMemoryError: Java heap space`

The server ships with a 2 GB heap (`-Xmx2048m` in `server/bin/intellij-server.vmoptions`), which large or
dependency-heavy projects can exhaust — typically during or shortly after project import. In `:IntellijServerLogs` this
shows up as repeated `LowMemoryWatcher - Low memory signal received` followed by the OOM and a heap dump.

Raise the heap with `jvm_args`, then restart with `:IntellijServerRestart`:

```lua
require("intellij-server").setup({
  jvm_args = { "-Xmx8g" },
})
```

`IJ_JAVA_OPTIONS` is applied after the vmoptions file, so a `-Xmx` here wins without editing (or losing on reinstall)
anything inside the server directory.

Heap dumps land in the plugin's log directory (`:IntellijServerLogs`); each one is roughly the size of the heap that
overflowed, so delete them once you are done with them. Note that the JetBrains launcher otherwise writes them to
`$HOME/java_error_in_intellij-server.hprof` and then refuses to overwrite that file, so a stale ~1 GB dump may be
sitting in your home directory from before this was redirected.

## License

[MIT](LICENSE)
