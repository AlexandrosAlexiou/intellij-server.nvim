--- Semantic token corrections for the IntelliJ server.
---
--- Two independent problems, both leaving highlighting that disagrees with what
--- the server actually resolved: overlapping tokens in the response (attach),
--- and tokens computed before indexing has finished (setup).
local M = {}

-- Marker key on the client, so a reconnect does not stack wrappers.
local wrapped = "intellij_server_semantic_tokens"

--- Decode LSP's delta-encoded token array.
---
--- Each token is five integers: line delta, start-column delta (relative to the
--- previous token when on the same line, absolute otherwise), length, type
--- index, modifier bitmask. Zero-length tokens colour nothing and are dropped.
---@param data integer[]
---@return { line: integer, s: integer, e: integer, t: integer, m: integer }[]
local function decode(data)
  local tokens = {}
  local line, col = 0, 0
  for i = 1, #data - 4, 5 do
    local dline, dcol, len = data[i], data[i + 1], data[i + 2]
    line = line + dline
    col = dline == 0 and col + dcol or dcol
    if len > 0 then
      tokens[#tokens + 1] = { line = line, s = col, e = col + len, t = data[i + 3], m = data[i + 4] }
    end
  end
  return tokens
end

--- Re-encode tokens, which must be ordered by line and then start column.
---@param tokens { line: integer, s: integer, e: integer, t: integer, m: integer }[]
---@return integer[]
local function encode(tokens)
  local data = {}
  local line, col = 0, 0
  for _, tok in ipairs(tokens) do
    local dline = tok.line - line
    data[#data + 1] = dline
    data[#data + 1] = dline == 0 and tok.s - col or tok.s
    data[#data + 1] = tok.e - tok.s
    data[#data + 1] = tok.t
    data[#data + 1] = tok.m
    line, col = tok.line, tok.s
  end
  return data
end

--- Reduce one line's tokens to the non-overlapping cover in which the innermost
--- token owns every column it spans, appending the result in column order.
---
--- Sorting by start ascending and end descending puts every token after the
--- ones enclosing it, so a stack holds the tokens covering the current column
--- with the innermost on top. An enclosing token contributes only the columns
--- left over once the tokens nested in it have been emitted.
---@param line { line: integer, s: integer, e: integer, t: integer, m: integer }[]
---@param out { line: integer, s: integer, e: integer, t: integer, m: integer }[]
local function cover(line, out)
  table.sort(line, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.e > b.e
  end)

  -- Nothing overlaps: the common case, and the tokens already are their cover.
  local overlaps = false
  for i = 2, #line do
    if line[i].s < line[i - 1].e then
      overlaps = true
      break
    end
  end
  if not overlaps then
    for _, tok in ipairs(line) do
      out[#out + 1] = tok
    end
    return
  end

  local stack = {}
  local col = line[1].s

  --- Emit [col, upto) coloured as `tok`, if that range is not already covered.
  local function emit(tok, upto)
    if col < upto then
      out[#out + 1] = { line = tok.line, s = col, e = upto, t = tok.t, m = tok.m }
      col = upto
    end
  end

  for _, tok in ipairs(line) do
    -- Close the tokens that end before this one starts.
    while #stack > 0 and stack[#stack].e <= tok.s do
      local top = table.remove(stack)
      emit(top, top.e)
    end
    -- The token still enclosing us owns the gap up to this one.
    if #stack > 0 then
      emit(stack[#stack], tok.s)
    end
    if col < tok.s then
      col = tok.s
    end
    stack[#stack + 1] = tok
  end

  while #stack > 0 do
    local top = table.remove(stack)
    emit(top, top.e)
  end
end

--- Rewrite a semantic token response so that no two tokens overlap.
---
--- IntelliJ answers with nested tokens rather than a flat cover: every prefix of
--- a qualified name is reported as its own token, all starting at the same
--- column, longest first. `import org.pkl.parser.syntax.Expr.AmendsExpr;` comes
--- back as six tokens on the one line:
---
---     [7,44) class     +static     org.pkl.parser.syntax.Expr.AmendsExpr
---     [7,33) class     +abstract   org.pkl.parser.syntax.Expr
---     [7,28) namespace             org.pkl.parser.syntax
---     [7,21) [7,14) [7,10) namespace
---
--- Neovim sets an extmark per token and gives every one of them the same
--- priority (vim.hl.priorities.semantic_tokens), so where several start at the
--- same column the winner is decided by their order in the marktree, and that
--- order is not stable. An import whose qualifier is itself a class — a nested
--- class — is the case with two overlapping `class` tokens, and those lines
--- flip between "namespace-coloured package, typed tail" and "the whole name in
--- the class colour" as unrelated edits land. Measured on ParserImpl.java in
--- the pkl repo: 16 of 71 import lines alternated between the two renderings
--- across six observations, and every one of them imported a nested class;
--- flattening left all 71 constant.
---
--- Collapsing each response to the cover the nesting describes removes the
--- choice: an enclosing token keeps only the columns no inner token claims.
--- Applies to full and range responses alike. A delta response carries edits
--- rather than tokens and is left alone; the server advertises no delta
--- support, so Neovim never asks for one.
---@param data integer[]
---@return integer[]
local function flatten(data)
  local tokens = decode(data)
  local out = {}
  local i, n = 1, #tokens
  while i <= n do
    local j = i
    while j < n and tokens[j + 1].line == tokens[i].line do
      j = j + 1
    end
    if i == j then
      out[#out + 1] = tokens[i]
    else
      cover(vim.list_slice(tokens, i, j), out)
    end
    i = j + 1
  end
  return encode(out)
end

--- Flatten this client's semantic token responses.
---
--- Neovim's semantic token module passes its own callback to the client, so a
--- textDocument/semanticTokens entry in `handlers` is never consulted: the
--- request is the only place the plugin can reach the result. Wrapping the
--- method on the client instance leaves every other LSP client alone.
---@param client vim.lsp.Client
function M.attach(client)
  if client[wrapped] then
    return
  end
  client[wrapped] = true

  local request = client.request
  ---@diagnostic disable-next-line: duplicate-set-field
  client.request = function(self, method, params, handler, bufnr)
    if handler and vim.startswith(method, "textDocument/semanticTokens/") then
      local inner = handler
      handler = function(err, result, ctx, config)
        if result and result.data then
          result.data = flatten(result.data)
        end
        return inner(err, result, ctx, config)
      end
    end
    return request(self, method, params, handler, bufnr)
  end
end

-- client_id -> progress token -> title of live $/progress cycles
local progress = {}

local autocmd_created = false

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
---
--- Idempotent.
function M.setup()
  if autocmd_created then
    return
  end

  autocmd_created = true

  local group = vim.api.nvim_create_augroup("IntellijServerSemanticTokens", { clear = true })

  vim.api.nvim_create_autocmd("LspProgress", {
    group = group,

    callback = function(ev)
      local data = ev.data
      if not data or not data.client_id then
        return
      end

      local client = vim.lsp.get_client_by_id(data.client_id)
      if not client or client.name ~= "intellij-server" then
        progress[data.client_id] = nil
        return
      end

      local params = data.params
      if not params or not params.token then
        return
      end

      local value = params.value
      if type(value) ~= "table" then
        return
      end

      local by_token = progress[client.id]

      if not by_token then
        by_token = {}
        progress[client.id] = by_token
      end

      if value.kind == "begin" then
        by_token[params.token] = value.title
        return
      end

      if value.kind ~= "end" then
        return
      end

      local title = by_token[params.token]
      by_token[params.token] = nil

      if title ~= "Indexing" then
        return
      end

      local refresh = vim.lsp.handlers["workspace/semanticTokens/refresh"]
      if not refresh then
        return
      end

      pcall(refresh, nil, nil, {
        client_id = client.id,
        method = "workspace/semanticTokens/refresh",
      })
    end,

    desc = "Refresh semantic tokens once indexing ends",
  })
end

return M
