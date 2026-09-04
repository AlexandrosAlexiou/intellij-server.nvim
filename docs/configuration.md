# Configuration

[Features](features.md) · [Debugging](debugging.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)

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
  -- OutOfMemoryError (see docs/troubleshooting.md)
  jvm_args = { "-Xmx8g" },

  -- JDK that runs the server process itself (default: nil). Resolution:
  -- this value > $JAVA_HOME > `java` on PATH > the bundled JBR.
  -- NOTE: this does NOT choose the JDK your project compiles/resolves
  -- against — that is the project SDK. See "Project JDK" below.
  java_home = "/Library/Java/JavaVirtualMachines/zulu-21.jdk/Contents/Home",

  -- The working directory is the project root; these only matter for files
  -- opened from outside it. See "Project root" below.
  root_markers = {
    "pom.xml", "build.gradle", "build.gradle.kts",
    "settings.gradle", "settings.gradle.kts",
    "WORKSPACE", "WORKSPACE.bazel", "BUILD", ".git",
  },

  -- Pin the root, bypassing cwd and detection (default: nil). Either a path or
  -- a function(bufnr) returning one; returning nil falls back to the default
  -- resolution, so you can pin just the projects that need it.
  root_dir = nil,

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
  code_lens = {
    enabled = true,
    -- The server titles its lenses the VS Code way, with codicon markup:
    -- "$(play) Run". Map a codicon name to the text to show instead; anything
    -- left unmapped is dropped. Defaults to the Nerd Font glyphs below; set
    -- `icons = false` for plain "Run" and "Debug".
    icons = { play = "\u{f04b}", debug = "\u{f188}" },  -- nf-fa-play, nf-fa-bug
    -- Lenses are anchored to the identifier they belong to, which Neovim
    -- indents the virtual line to. Draw them at the indent of the code
    -- instead; false keeps Neovim's placement.
    align = true,
  },

  -- Package navigation: open package definitions as a directory listing
  navigation = { enabled = true },

  -- nvim-dap debugger integration. Also turns on the server's Run/Debug code
  -- lenses above main methods (initializationOptions.runMainCodeLens).
  dap = {
    enabled = true,  -- requires nvim-dap
  },

  -- Explicit project imports (initializationOptions.projects), equivalent to
  -- the VS Code `intellij.projects` setting. Overrides marker-based
  -- auto-import. Types: gradle, maven, bazel, jps, gomodules,
  -- gomodules-recursive-scan, json. Paths may be file:// URIs or plain paths.
  -- Can also be a function(root_dir) returning the list.
  -- Optional fields per project: javaHome pins the JDK used as the project SDK
  -- for the import (see "Project JDK" below); env and systemProperties pass
  -- extra environment/properties to the import process.
  -- projects = {
  --   { type = "maven", path = "/path/to/project",
  --     javaHome = "/Library/Java/JavaVirtualMachines/zulu-25.jdk/Contents/Home" },
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

## Project root

One server runs per root, and a buffer joins an existing server only when its
root resolves to the same directory — so a wrong root shows up as a second
server importing part of your project on its own.

The root is the **working directory** whenever the file is inside it. You `cd`
into a project to work on it, so this states intent rather than guessing at it,
and every buffer in the session agrees on it. It is the window's cwd, so `:lcd`
and `:tcd` scope it per split or per tab.

For files opened from outside the cwd — a grep hit in another project, a
dependency's source — the root is the topmost directory containing a build or
project marker (`pom.xml`, `settings.gradle`, `.idea`, `*.iml`, …), searching up
to the top of the enclosing checkout and no further. Topmost, so a module in a
multimodule build resolves to the build root; bounded by the checkout, so one
stray marker above it cannot capture everything beneath. Failing that, the
nearest `root_markers` directory, then the file's own directory.

`root_dir` overrides all of it.

## Project JDK

Three separate JDKs are involved, and they are chosen by different mechanisms:

1. **The JVM that runs the server itself.** Chosen by the `java_home` option, then `$JAVA_HOME`, then `java` on
   PATH, then the bundled JBR. It has no influence on what your code resolves against.
2. **The project SDK.** The JDK your code is compiled and resolved against: JDK classes, language level, `jar://`
   and `jrt://` sources you land in with go-to-definition. How it is picked depends on the importer, see below.
3. **The JVM that runs Maven or Gradle during import.** Resolved from the `JB_MAVEN_JAVA_HOME` system property
   (settable through `jvm_args`), then the server process `$JAVA_HOME`, then the server's own JVM.

How the project SDK is picked per importer:

**Maven and Gradle.** The import is pinned to a JDK by the first of these that applies:

1. An explicit `projects` entry in the setup config with a `javaHome` field.
2. `.intellij-server.lua` in the project root. The file goes through Neovim's standard trust prompt (like `exrc`)
   and returns a project spec, or a list of them; `type` and `path` default to the detected build system and the
   root:

   ```lua
   return {
     javaHome = "/Library/Java/JavaVirtualMachines/zulu-25.jdk/Contents/Home",
   }
   ```

3. `$JAVA_HOME`, when it points at a real JDK. Per-project env managers (direnv, mise, sdkman) therefore pick the
   SDK without any configuration.

Without a pin the server picks the first JDK its filesystem scan finds, with no regard for what the project needs.
The scan prefers the newest version, so a Homebrew OpenJDK pulled in as a dependency of another formula routinely
wins over the JDK your project targets. The pom or build.gradle only controls the language level of the modules,
not which installed JDK becomes the SDK.

**JPS (`.idea` projects).** The SDK name in `.idea/misc.xml` (`project-jdk-name="zulu-21"`) is matched against the
installed JDKs by IntelliJ's vendor-major naming convention (`zulu-21`, `temurin-19`, `jbr-21`, `graalvm-22`). When
the name matches nothing, the same first-detected fallback applies. The JPS importer does not accept a java home,
so `.intellij-server.lua` and `$JAVA_HOME` cannot pin it; fix the name in `misc.xml` instead. See "JPS projects:
the wrong JDK is picked" in [Troubleshooting](troubleshooting.md) for the symptoms and the fix.

Notes that apply to all importers:

- The server does not read `jdk.table.xml` from its config directory, so IDE-style SDK tables have no effect.
- The SDK binding is persisted in the workspace model cache. After changing `javaHome`, `misc.xml`, or the installed
  JDKs, run `:IntellijServerClean` so a stale cached binding cannot survive the reimport.
- JDKs are only found in standard locations (`/Library/Java/JavaVirtualMachines`, `~/.jdks`, SDKMAN, Homebrew,
  `/usr/lib/jvm`, ...). A JDK outside of them must be pinned explicitly with `javaHome` or symlinked into one.

## Inlay hint settings

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
