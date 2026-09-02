--- Refresh semantic tokens after indexing.
---
--- A semanticTokens request answered while the server is still
--- importing/indexing yields a degraded result: an error (Neovim drops it
--- without retrying), an empty list, or a partial token set computed against
--- unresolved code. Neovim caches whatever it got as valid for the document
--- version and only re-requests on an edit, so buffers opened before or
--- during indexing keep the degraded highlighting until an edit or :e.
---
--- The server reports indexing through $/progress with the title "Indexing"
--- but never sends workspace/semanticTokens/refresh afterwards: when such a
--- progress ends, invoke Neovim's built-in refresh handler ourselves, as if
--- the server had sent it. Unlike force_refresh (which deletes all highlights
--- immediately and flickers until the response arrives), the built-in handler
--- only invalidates cached results, keeps the old highlights on screen, and
--- swaps them atomically on redraw once fresh tokens arrive; it also
--- debounces, so frequent no-op indexing cycles (e.g. triggered by shell
--- prompts writing .git/index) cause no visible change.
local M = {}

-- client_id -> progress token -> title of live $/progress cycles
local progress = {}

local autocmd_created = false

--- Register the recovery autocmd (idempotent).
function M.setup()
  if autocmd_created then
    return
  end
  autocmd_created = true
  vim.api.nvim_create_autocmd("LspProgress", {
    group = vim.api.nvim_create_augroup("IntellijServerSemanticTokens", { clear = true }),
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      if not client or client.name ~= "intellij-server" then
        progress[ev.data.client_id] = nil
        return
      end
      local params = ev.data.params
      local value = params.value or {}
      local by_token = progress[client.id] or {}
      progress[client.id] = by_token
      if value.kind == "begin" then
        by_token[params.token] = value.title
      elseif value.kind == "end" then
        local title = by_token[params.token]
        by_token[params.token] = nil
        if title == "Indexing" then
          local refresh = vim.lsp.handlers["workspace/semanticTokens/refresh"]
          pcall(refresh, nil, nil, { client_id = client.id })
        end
      end
    end,
    desc = "Refresh semantic tokens once indexing ends",
  })
end

return M
