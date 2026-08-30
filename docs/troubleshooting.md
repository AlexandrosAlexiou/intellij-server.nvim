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

## JPS projects: the wrong JDK is picked

Only JPS (`.idea`) projects are affected by the `misc.xml` mechanism below. For Maven and Gradle projects, pin the
JDK with the `javaHome` field of a `projects` entry instead, see "Project JDK" in
[Configuration](configuration.md).
Symptoms: go-to-definition into JDK classes opens `jar://` buffers under a JDK you never chose (a Homebrew
`/opt/homebrew/opt/openjdk/...` is the classic case), or the language level and available APIs don't match your
project's JDK.

The `java_home` setup option and `JAVA_HOME` only choose the JVM that runs the server process, not the project SDK.
The JPS importer reads the SDK name from `.idea/misc.xml` (`project-jdk-name="zulu-21"`) and matches it against the
JDKs installed in the standard locations (`/Library/Java/JavaVirtualMachines`, `~/.sdkman`, Homebrew, `/usr/lib/jvm`,
...), using IntelliJ's naming convention of vendor plus major version: `zulu-21`, `temurin-19`, `jbr-21`, `graalvm-22`.
When nothing matches (a bare version like `21.0.9`, a JDK that isn't installed, or no `misc.xml` yet), it silently
falls back to the first JDK it finds, with no version matching, and writes that choice back to `misc.xml`. Note that
the importer does not read `jdk.table.xml` from the server's config directory, so seeding SDK entries there has no
effect.

Each import logs the binding in `:IntellijServerLogs`, name in brackets, resolved home after the colon:

```
INFO - #c.j.l.i.j.JpsWorkspaceImporterKt - Detected SDK [21.0.9]: /opt/homebrew/opt/java/libexec/openjdk.jdk/Contents/Home
```

**Fix:** set `project-jdk-name` in `.idea/misc.xml` to the name of an installed JDK. On macOS,
`/usr/libexec/java_home -V` lists vendors and homes to pick from:

```xml
<component name="ProjectRootManager" version="2" languageLevel="JDK_21" default="false"
           project-jdk-name="zulu-21" project-jdk-type="JavaSDK" />
```

`.idea/` is typically gitignored, so the edit stays local to your machine. Restart with `:IntellijServerRestart` and
check that the `Detected SDK` line now shows the right home. If the JDK you need lives somewhere the scan cannot find,
install or symlink it into a scanned location such as `~/.jdks/`, since pointing config files at it is not enough.

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

These persist across reboots (unlike the default temp directory behavior). Per-project workspace state
(imported modules, SDK bindings, the workspace index) lives under the system cache directory, on macOS
`~/Library/Caches/JetBrains/IntelliJServer/workspaces/`. To clean the current project's workspace caches and
reimport:

```vim
:IntellijServerClean
```

Other projects' caches and servers are not affected. The shared stores (the data directory above and the analyzer
cache in `~/Library/Caches/JetBrains/analyzer`) are not removed; delete them manually if they get corrupted.

### Plugin download location

`:IntellijServerInstall` downloads and extracts the server to:

```
~/.local/share/nvim/intellij-server/
├── server/          # extracted server (bin, lib, jbr, plugins, etc.)
└── .version         # version marker (e.g., "0.0.10+263.3533.0")
```
