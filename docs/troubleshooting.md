# Troubleshooting

[Configuration](configuration.md) · [Features](features.md) · [Debugging](debugging.md) · [README](../README.md)

## Gradle projects: go-to-definition opens decompiled classes instead of library sources

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

## The server dies with `java.lang.OutOfMemoryError: Java heap space`

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

## File paths

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
