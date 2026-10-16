--- License activation (server 1.0+). The server needs an IntelliJ IDEA
--- Ultimate or All Products Pack license, or the trial. A JetBrains Account
--- already signed in on the machine (through the IDE or Toolbox) is found by
--- the server itself; otherwise the client activates one over the protocol
--- behind the VS Code extension's license panel:
---
---   jetbrains/licensing/state                  whole LicensingState on every change (notification)
---   jetbrains/licensing/state/get              the same, on demand
---   jetbrains/licensing/jba/login              JetBrains Account sign-in, in the browser
---   jetbrains/licensing/jba/logout
---   jetbrains/licensing/subscriptions/use      { assetId } of an account subscription
---   jetbrains/licensing/trial/startAnonymous   -> { isSuccess, errorMessage? }
---   jetbrains/licensing/activationCode/use     { activationCode } -> boolean
---   jetbrains/licensing/licenseServer/add      { serverAddress } -> { status, errorMessage? }
---
--- Without a license the server reports `featuresDeclined` and why
--- (`parkedReason`); a license it loses is tolerated until `graceDeadline`.
--- A server without one still starts and advertises every capability, but
--- refuses every request with ServerCancelled ("Request refused: no active
--- JetBrains license", measured on 1.0.27).
local M = {}

local function notify(msg, level)
  vim.notify("[intellij-server] " .. msg, level or vim.log.levels.WARN)
end

--- Any client will do: the server is shared, and so is its license.
---@return vim.lsp.Client?
local function client()
  return vim.lsp.get_clients({ name = "intellij-server" })[1]
end

---@param method string
---@param params table?
---@param cb fun(result: any)
local function request(method, params, cb)
  local c = client()
  if not c then
    notify("No running intellij-server client.")
    return
  end
  c:request(method, params, function(err, result)
    if err then
      notify(("%s failed: %s"):format(method, err.message or vim.inspect(err)), vim.log.levels.ERROR)
      return
    end
    cb(result)
  end)
end

-- State ---------------------------------------------------------------------

local source_labels = {
  trial = "trial",
  eap = "EAP",
  subscription = "subscription",
  activationCode = "activation code",
  licenseServer = "license server",
  toolbox = "Toolbox",
  productKeyFile = "product key file",
}

local parked_reasons = {
  StartedUnlicensed = "no license found",
  GraceExpired = "the license could not be renewed in time",
  LicenseRemoved = "the license was removed",
  LicenseRevoked = "the license was revoked",
}

---@param ms number Epoch milliseconds.
---@return string
local function format_time(ms)
  return tostring(os.date("%Y-%m-%d %H:%M", math.floor(ms / 1000)))
end

---@param active table An activeLicense.
---@return string
local function describe(active)
  local text = ("%s (%s)"):format(active.product or "?", source_labels[active.source] or active.source)
  if active.licensedTo then
    text = text .. ", licensed to " .. active.licensedTo
  end
  if active.validThrough then
    text = text .. ", valid through " .. active.validThrough
    if active.daysLeft then
      text = text .. (" (%d days left)"):format(active.daysLeft)
    end
  end
  if active.status ~= "Valid" then
    text = text .. ", " .. tostring(active.status)
  end
  return text
end

--- Last state the server pushed.
---@type table?
M.state = nil

--- What the user was last warned about, so each client's copy of the same
--- push warns once.
---@type string?
local reported = nil

--- "grace:<deadline>" or "parked:<reason>" while unlicensed, nil when fine.
---@param state table
---@return string?
local function condition(state)
  if state.activeLicense and state.activeLicense.status == "Valid" then
    return nil
  end
  if state.featuresDeclined then
    return "parked:" .. (state.parkedReason or "StartedUnlicensed")
  end
  if state.graceDeadline then
    return "grace:" .. state.graceDeadline
  end
  return nil
end

---@param state table
local function on_state(state)
  if type(state) ~= "table" then
    return
  end
  M.state = state
  local current = condition(state)
  if current == reported then
    return
  end
  if current and vim.startswith(current, "parked:") then
    notify(
      ("Running without a license (%s), the server declines its features.\n"):format(
        parked_reasons[state.parkedReason] or state.parkedReason or "no license found"
      ) .. "Activate one with :IntellijServerLicense login, trial, code or server."
    )
  elseif current then
    notify(
      ("The license was lost; the server keeps working until %s.\n"):format(format_time(state.graceDeadline))
        .. "Renew it with :IntellijServerLicense."
    )
  elseif reported then
    notify("License active: " .. describe(state.activeLicense), vim.log.levels.INFO)
    -- Everything asked for while unlicensed was refused: ask again.
    for _, c in ipairs(vim.lsp.get_clients({ name = "intellij-server" })) do
      for _, method in ipairs({
        "workspace/diagnostic/refresh",
        "workspace/semanticTokens/refresh",
        "workspace/inlayHint/refresh",
        "workspace/codeLens/refresh",
      }) do
        pcall(vim.lsp.handlers[method], nil, nil, { client_id = c.id, method = method })
      end
    end
  end
  reported = current
end

--- Was the request refused for want of a license? The state push may arrive
--- after the first refusals, so the message counts too.
---@param err lsp.ResponseError?
---@return boolean
local function refused(err)
  if not err or err.code ~= vim.lsp.protocol.ErrorCodes.ServerCancelled then
    return false
  end
  return (M.state ~= nil and M.state.featuresDeclined == true) or (err.message or ""):find("license", 1, true) ~= nil
end

--- Pull diagnostics retry a ServerCancelled request at once unless told not
--- to. A refusal for want of a license would repeat forever, so it is
--- dropped. The server also sends `data: null`, which reaches the handler as
--- vim.NIL and makes Neovim 0.12's handler index it and throw.
---@type lsp.Handler
local function on_diagnostic(err, result, ctx)
  if refused(err) then
    return
  end
  if err and err.data == vim.NIL then
    err.data = nil
  end
  return vim.lsp.diagnostic.on_diagnostic(err, result, ctx)
end

--- LSP handlers for the client config.
---@return table<string, lsp.Handler>
function M.handlers()
  return {
    ["jetbrains/licensing/state"] = function(_, params)
      on_state(params)
    end,
    ["textDocument/diagnostic"] = on_diagnostic,
  }
end

-- Commands ------------------------------------------------------------------

function M.status()
  request("jetbrains/licensing/state/get", nil, function(state)
    on_state(state)
    local lines = { "License: " .. (state.activeLicense and describe(state.activeLicense) or "none") }
    local jba = state.jbaLicensingState or {}
    if jba.accountInfo then
      table.insert(lines, ("JetBrains Account: %s (%s)"):format(jba.accountInfo.displayName, jba.authenticationStatus))
    else
      table.insert(lines, "JetBrains Account: " .. tostring(jba.authenticationStatus))
    end
    local server = state.licenseServerFlowState or {}
    if server.kind == "configured" then
      table.insert(lines, ("License server: %s (%s)"):format(server.serverAddress, server.status))
    end
    if state.featuresDeclined then
      table.insert(lines, "Features declined: " .. (parked_reasons[state.parkedReason] or tostring(state.parkedReason)))
    elseif condition(state) and state.graceDeadline then
      table.insert(lines, "Grace period until " .. format_time(state.graceDeadline))
    end
    notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end)
end

--- Pick one of the account's subscriptions — what sign-in leaves to the user
--- when the account holds several (`NoSuitableLicense`).
function M.subscription()
  request("jetbrains/licensing/state/get", nil, function(state)
    local subscriptions = (state.jbaLicensingState or {}).availableSubscriptions or {}
    if #subscriptions == 0 then
      notify("The JetBrains Account has no subscriptions to choose from (sign in with :IntellijServerLicense login).")
      return
    end
    vim.ui.select(subscriptions, {
      prompt = "Subscription",
      format_item = function(sub)
        return ("%s — %s, valid through %s (%s)"):format(sub.product, sub.licensedTo, sub.validThrough, sub.status)
      end,
    }, function(sub)
      if sub then
        request("jetbrains/licensing/subscriptions/use", { assetId = sub.assetId }, function() end)
      end
    end)
  end)
end

--- Sign in to a JetBrains Account. The server opens the sign-in page with
--- window/showDocument and answers once the browser flow ends.
function M.login()
  notify("Opening the JetBrains Account sign-in page in your browser…", vim.log.levels.INFO)
  request("jetbrains/licensing/jba/login", nil, function(result)
    local status = result and result.status
    if status == "Licensed" then
      notify("Signed in; the license is active.", vim.log.levels.INFO)
    elseif status == "NoSuitableLicense" then
      M.subscription()
    elseif status == "NoLicenses" then
      notify("The JetBrains Account holds no license for the server. Start a trial with :IntellijServerLicense trial.")
    else
      local msg = ("Sign-in did not complete (%s)"):format(tostring(status))
      if result and result.errorMessage then
        msg = msg .. ": " .. result.errorMessage
      end
      notify(msg)
    end
  end)
end

function M.logout()
  request("jetbrains/licensing/jba/logout", nil, function()
    notify("Signed out of the JetBrains Account.", vim.log.levels.INFO)
  end)
end

function M.trial()
  request("jetbrains/licensing/trial/startAnonymous", nil, function(result)
    if result and result.isSuccess then
      notify("Trial started.", vim.log.levels.INFO)
    else
      notify("Could not start the trial" .. (result and result.errorMessage and (": " .. result.errorMessage) or "."))
    end
  end)
end

---@param code string?
function M.activation_code(code)
  local function use(value)
    if not value or vim.trim(value) == "" then
      return
    end
    request("jetbrains/licensing/activationCode/use", { activationCode = vim.trim(value) }, function(ok)
      if ok then
        notify("Activated.", vim.log.levels.INFO)
      else
        notify("The activation code was not accepted.")
      end
    end)
  end
  if code and code ~= "" then
    use(code)
  else
    vim.ui.input({ prompt = "Activation code: " }, use)
  end
end

---@param address string?
function M.license_server(address)
  local function add(value)
    if not value or vim.trim(value) == "" then
      return
    end
    request("jetbrains/licensing/licenseServer/add", { serverAddress = vim.trim(value) }, function(result)
      if result and result.status == "Connected" then
        notify("Connected to the license server.", vim.log.levels.INFO)
      else
        local msg = ("License server: %s"):format(tostring(result and result.status))
        if result and result.errorMessage then
          msg = msg .. ": " .. result.errorMessage
        end
        notify(msg)
      end
    end)
  end
  if address and address ~= "" then
    add(address)
  else
    vim.ui.input({ prompt = "License server URL: " }, add)
  end
end

---@type table<string, fun(arg: string?)>
M.subcommands = {
  status = M.status,
  login = M.login,
  logout = M.logout,
  subscription = M.subscription,
  trial = M.trial,
  code = M.activation_code,
  server = M.license_server,
}

--- :IntellijServerLicense [subcommand [argument]]
---@param args string
function M.command(args)
  local name, arg = vim.trim(args):match("^(%S*)%s*(.-)$")
  local run = M.subcommands[name ~= "" and name or "status"]
  if not run then
    notify("Unknown subcommand " .. name .. "; expected one of: " .. table.concat(vim.tbl_keys(M.subcommands), ", "))
    return
  end
  run(arg ~= "" and arg or nil)
end

return M
