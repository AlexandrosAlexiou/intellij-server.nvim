return {
  version = "0.0.10",
  build = "263.3533.0",
  product = "2026.3",
  base_url = "https://download-cdn.jetbrains.com/language-server/intellij-server",
  -- CDN platform key -> uname sysname and normalized arch (see installer.lua).
  platforms = {
    ["linux-amd64"] = { os = "Linux", arch = "x64" },
    ["linux-aarch64"] = { os = "Linux", arch = "arm64" },
    ["mac-amd64"] = { os = "Darwin", arch = "x64" },
    ["mac-aarch64"] = { os = "Darwin", arch = "arm64" },
    ["win-amd64"] = { os = "Windows_NT", arch = "x64" },
    ["win-aarch64"] = { os = "Windows_NT", arch = "arm64" },
  },
}
