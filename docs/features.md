# Features

[Configuration](configuration.md) · [Debugging](debugging.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)

## Standard LSP

Everything the server (v0.0.12) advertises is supported. Features marked *automatic* work through
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
| Semantic tokens | *automatic* — IntelliJ-quality highlighting layered over treesitter; the server's overlapping tokens are flattened by the plugin, see below |
| Inlay hints | enabled on attach by the plugin — `inlay_hints = { enabled = false }` to opt out, or toggle with `vim.lsp.inlay_hint.enable()` |
| Folding range | wired on attach: `foldexpr = v:lua.vim.lsp.foldexpr()`, folds start open — `folding = { enabled = false }` to opt out; use `zc`/`zo`/`za` |
| Code lens | refreshed on attach and on edits by the plugin — run with `vim.lsp.codelens.run()`; includes the Run/Debug lenses above `main` methods when nvim-dap is available. VS Code codicon markup in titles is swapped for Nerd Font glyphs and lenses are aligned with the code they sit above (`icons`, `align`); `code_lens = { enabled = false }` to opt out |
| Call hierarchy | `vim.lsp.buf.incoming_calls()` / `vim.lsp.buf.outgoing_calls()` |
| Type hierarchy | `vim.lsp.buf.typehierarchy("subtypes")` / `("supertypes")` |

Not provided by the server: go to declaration, range/on-type formatting, selection range.

## Package navigation (go to definition on a package)

Asking for the definition of a package name — the `org.pkl.core` in a `package`
or `import` statement — makes the server answer with the directories that make
up that package: one per source root, repeated once per package fragment.
Neovim has nothing to show for a directory, so plain `vim.lsp.buf.definition()`
either opens an empty buffer named after the path, or, once there is more than
one location, fills the quickfix list with dozens of entries that all read
`pkl-core/src/test/kotlin/org/pkl/core|1 col 1|`.

The plugin takes those answers out of Neovim's hands, so `gd` can stay mapped to
plain `vim.lsp.buf.definition()` and nothing has to change in your LSP config:

- duplicate locations are collapsed, so a package comes down to one entry per
  source root instead of one per fragment;
- an answer that is nothing but directories is opened as a listing directly, in
  [oil.nvim](https://github.com/stevearc/oil.nvim) (or with `:edit`, i.e. netrw,
  when oil is not installed), leaving a jumplist entry so `<C-o>` comes back;
- when more than one source root is left (`src/main` and `src/test` of the same
  package), `vim.ui.select` asks which one first. Cancelling does nothing, in
  silence.

The prompt is drawn by whatever `vim.ui.select` you already use — snacks,
dressing, telescope, fzf-lua — so it matches the rest of your editor, and falls
back to Neovim's built-in numbered list when there is none. It is tagged
`kind = "intellij_package"`, for a layout or formatter of its own.

No location for a directory is ever handed back to Neovim, which is what keeps it
from opening a buffer for the path — an empty buffer that oil, being lazy-loaded
in most configurations, then adopts halfway through the jump and reports as an
unsaved listing.

This only touches directories the server answered with; browsing directories any
other way is left to your file explorer. Set `navigation = { enabled = false }`
to opt out.

A mixed answer — directories plus real declarations — is left to Neovim's usual
behaviour: jump when there is one location, quickfix list when there are more.

`vim.lsp.buf.definition()` hands the client its own callback, so this cannot live
in a `textDocument/definition` entry in `handlers` — the plugin wraps the request
on its own client instead, which leaves every other LSP client alone. It covers
`textDocument/definition`, `typeDefinition`, `declaration` and `implementation`.

## Completion insertion fix

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

## Live template indentation fix

Live template completions (`sout`, `fori`, `psvm`, …) are the one case where
the server sends a real snippet `textEdit` — but pre-formatted with *absolute*
indentation in the server's own code style (4 spaces, spaces only, ignoring
even the project's `.editorconfig`). Applied verbatim, a `sout` in a 2-space or
tab-indented buffer gains extra leading spaces or has its tabs replaced.

The plugin rewrites these edits into the standard relative snippet form: the
buffer's existing leading whitespace is kept, and inner lines use `\t` per
indent level, which `vim.snippet` (used by builtin completion, nvim-cmp and
blink.cmp) materializes according to `'shiftwidth'`/`'expandtab'`. Template
expansions follow your buffer's indentation. No configuration required.

## Semantic token overlap fix

The server reports every prefix of a qualified name as its own token, nested
rather than side by side. `import org.pkl.parser.syntax.Expr.AmendsExpr;` comes
back as six tokens that all start at the same column: the whole name as a
`class`, the enclosing `org.pkl.parser.syntax.Expr` as a `class`, then
`org.pkl.parser.syntax`, `org.pkl.parser`, `org.pkl` and `org` as `namespace`.

Neovim sets one extmark per token and gives them all the same priority, so
where several start at the same column the winner comes down to extmark
ordering, which is not stable. Imports of nested classes are the case with two
overlapping `class` tokens, and those lines flip between a namespace-coloured
package with a typed tail and the whole name in the class colour as unrelated
edits land. On `ParserImpl.java` in the pkl repo, 16 of 71 import lines
alternated between the two renderings.

The plugin rewrites each response as the non-overlapping cover the nesting
describes: the innermost token owns every column it spans, and an enclosing
token keeps only the columns no inner token claims. Highlighting then matches
the resolved symbols and stays put. No configuration required.

## Formatting

The server formats with IntelliJ's code-style engine (whole document only):

```vim
:IntellijServerFormat   " synchronous
:IntellijServerFormat!  " async
```

or from Lua, `require("intellij-server").format({ async = true })`, which wraps:

```lua
vim.lsp.buf.format()
-- or, to be explicit when multiple LSP clients are attached:
vim.lsp.buf.format({ name = "intellij-server" })
```

A keymap example for `on_attach`:

```lua
on_attach = function(client, bufnr)
  vim.keymap.set({ "n", "v" }, "<leader>fi", function()
    require("intellij-server").format({ async = true })
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

## File Templates

`:IntellijServerNewFile` creates new files using IntelliJ's template engine. Available templates:

**Kotlin:** Class, File, Interface, Data Class, Enum, Annotation, Object
**Java:** Class, Interface, Record, Enum, Annotation, Exception

Templates are interpolated server-side via `workspace/executeCommand("interpolateFileTemplate")` with fallback to local variable substitution.
