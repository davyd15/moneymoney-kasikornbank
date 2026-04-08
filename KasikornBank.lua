-- ============================================================
-- MoneyMoney Web Banking Extension
-- Kasikorn Bank (KBank) Thailand – K BIZ Online Banking
-- Version: 3.65
--
-- Changelog:
--   3.65: Automatically accept T&C page after login (POST /authen/loginSuccess.do)
--
-- Login flow (6 steps + optional T&C step, no 2FA):
--   1. GET  /authen/login.jsp?lang=en         → tokenId from hidden field
--   2. POST /authen/loginAuthen.do            → userName, password, tokenId
--  2b. (optional) T&C page: POST /authen/loginSuccess.do with cmd=confirmTermCondIB
--   3. Follow JS redirect                     → /authen/ib/redirectToIB.jsp
--   4. GET  /authen/ib/redirectToIB.jsp       → extract dataRsso token
--   5. GET  /login?dataRsso=...               → initialize Angular app
--   6. POST /services/api/authentication/validateSession → x-session-token + ibId/ownerId
--      POST /services/api/refreshSession      → renew token
--
-- API endpoints (from browser DevTools):
--   Accounts:     POST /services/api/bankaccountget/getOwnBankAccountFromList
--   Transactions: POST /services/api/accountsummary/getRecentTransactionList
--                 POST /services/api/accountsummary/getRecentTransactionDetail
-- ============================================================

WebBanking {
  version     = 3.65,
  url         = "https://kbiz.kasikornbank.com",
  services    = {"Kasikorn Bank (KBiz)"},
  description = "Kasikorn Bank (KBank) Thailand – K BIZ Online Banking"
}

-- ============================================================
-- Constants
-- ============================================================
local BASE_URL             = "https://kbiz.kasikornbank.com"
local MAX_HISTORY_DAYS     = 180   -- max fetch window in days
local DETAIL_CALL_DAYS     = 30    -- resolve recipient names only for transactions within the last N days
local DETAIL_CACHE_TTL     = 90    -- cache TTL for recipient names in days
local SECONDS_PER_DAY      = 86400
local MAX_PAGES_PER_PERIOD = 20    -- safety limit per monthly period
local ROWS_PER_PAGE        = 100

-- Month name lookup for parseDate
local MONTH_NAMES = {
  Jan=1, Feb=2, Mar=3, Apr=4, May=5,  Jun=6,
  Jul=7, Aug=8, Sep=9, Oct=10,Nov=11, Dec=12
}

-- proxyTypeCode → human-readable PromptPay label for the purpose field
local PROXY_TYPE_LABELS = {
  M = "PromptPay Mobile",
  A = "PromptPay Acc",
  T = "PromptPay ID",
  E = "PromptPay ID",
  I = "PromptPay NatID",
}

-- ============================================================
-- Session State
-- ============================================================
local session = {
  connection = nil,
  authToken  = nil,  -- x-session-token (Authorization header for all API calls)
  ibId       = nil,  -- x-ib-id / x-session-ibid
  ownerId    = nil,
  custType   = nil,
  ownerType  = nil,
}

-- ============================================================
-- SupportsBank
-- ============================================================
function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Kasikorn Bank (KBiz)"
end

-- ============================================================
-- InitializeSession
-- ============================================================
function InitializeSession(protocol, bankCode, username, reserved, password)
  math.randomseed(os.time())

  session.connection          = Connection()
  session.connection.language  = "en-US,en;q=0.9"
  session.connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " ..
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  -- Step 1: Load login page → tokenId
  MM.printStatus("Loading login page...")
  local content, charset = session.connection:get(BASE_URL .. "/authen/login.jsp?lang=en")
  if not content or #content == 0 then
    return "Login page not reachable."
  end

  local tokenId = HTML(content, charset):xpath("//input[@name='tokenId']"):attr("value")
  if not tokenId or #tokenId == 0 then
    tokenId = content:match('name="tokenId"[^>]*value="(%d+)"')
  end
  if not tokenId or #tokenId == 0 then
    tokenId = tostring(math.floor(MM.time() * 1000))
    print("tokenId fallback: " .. tokenId)
  else
    print("tokenId: " .. tokenId)
  end

  -- Step 2: Submit login POST
  MM.printStatus("Signing in...")
  local postBody = "userName="      .. MM.urlencode(username, "UTF-8") ..
                   "&password="     .. MM.urlencode(password, "UTF-8") ..
                   "&tokenId="      .. MM.urlencode(tokenId) ..
                   "&cmd=authenticate&locale=en&custType=&maxTouchPoint=&app=0"

  local loginContent, loginCharset = session.connection:request(
    "POST",
    BASE_URL .. "/authen/loginAuthen.do",
    postBody,
    "application/x-www-form-urlencoded; charset=UTF-8",
    {
      ["Accept"]  = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      ["Referer"] = BASE_URL .. "/authen/login.jsp?lang=en",
      ["Origin"]  = BASE_URL,
    }
  )

  if not loginContent then
    return "Login request failed."
  end

  -- Step 2b: Automatically accept T&C page (if bank presents it)
  if loginContent:find("confirmTermCondIB") or loginContent:find("loginSuccess%.do") then
    print("T&C page detected, accepting automatically...")
    loginContent, loginCharset = session.connection:request(
      "POST",
      BASE_URL .. "/authen/loginSuccess.do",
      "cmd=confirmTermCondIB",
      "application/x-www-form-urlencoded; charset=UTF-8",
      {
        ["Accept"]  = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Referer"] = BASE_URL .. "/authen/loginAuthen.do",
        ["Origin"]  = BASE_URL,
      }
    )
    if not loginContent then
      return "Failed to accept T&C page."
    end
  end

  if not (loginContent:find("event_action.*success") or
          loginContent:find("redirectToIB") or
          loginContent:find("dataRsso")) then
    local errMsg = HTML(loginContent, loginCharset):xpath("//*[@id='errorText']"):text()
    print("Login failed: " .. (errMsg or "unknown"))
    return LoginFailed
  end

  print("Login successful!")

  -- Step 3: Follow JS redirect to redirectToIB.jsp manually
  local redirectURL = loginContent:match("window%.location%s*=%s*['\"]([^'\"]+)['\"]")
                   or "/authen/ib/redirectToIB.jsp"
  if redirectURL:sub(1, 1) == "/" then
    redirectURL = BASE_URL .. redirectURL
  end
  print("Following redirect: " .. redirectURL)

  local redirectContent = session.connection:request(
    "GET", redirectURL, nil, nil,
    {
      ["Referer"] = BASE_URL .. "/authen/loginAuthen.do",
      ["Accept"]  = "text/html,application/xhtml+xml,*/*",
    }
  )

  if not redirectContent then
    return "redirectToIB.jsp not reachable."
  end

  -- Step 4: Extract dataRsso token
  local dataRssoURL = redirectContent:match(
    'window%.top%.location%.href%s*=%s*"(https://kbiz%.kasikornbank%.com/login%?dataRsso=[^"]+)"'
  ) or redirectContent:match(
    "window%.top%.location%.href%s*=%s*['\"]([^'\"]+dataRsso[^'\"]+)['\"]"
  )

  if not dataRssoURL then
    return "dataRsso URL not found in redirectToIB response."
  end

  local dataRsso = dataRssoURL:match("dataRsso=(.+)$")
  if not dataRsso then
    return "Failed to extract dataRsso token."
  end
  print("dataRsso token extracted, length: " .. #dataRsso)

  -- Step 5: Initialize Angular app
  print("Loading Angular app...")
  session.connection:request("GET", dataRssoURL, nil, nil,
    { ["Referer"] = redirectURL, ["Accept"] = "text/html,application/xhtml+xml,*/*" }
  )

  -- Step 6a: validateSession → x-session-token + ibId/ownerId
  print("Calling validateSession...")
  local vsContent, _, _, _, vsHeaders = session.connection:request(
    "POST",
    BASE_URL .. "/services/api/authentication/validateSession",
    JSON():set({ dataRsso = dataRsso }):json(),
    "application/json;charset=UTF-8",
    {
      ["Accept"]       = "application/json, text/plain, */*",
      ["x-re-fresh"]   = "N",
      ["x-request-id"] = makeRequestId(),
      ["Referer"]      = dataRssoURL,
      ["Origin"]       = BASE_URL,
    }
  )

  if vsHeaders then
    local tok = vsHeaders["x-session-token"]
    if tok and #tok > 0 then
      session.authToken = tok
      print("x-session-token received, length: " .. #tok)
    else
      print("WARNING: No x-session-token in validateSession response headers")
      for k, v in pairs(vsHeaders) do
        print("  Header: " .. k .. " = " .. tostring(v):sub(1, 80))
      end
    end
  else
    print("WARNING: No response headers from validateSession")
  end

  if vsContent and #vsContent > 0 then
    local ok, vsData = pcall(function() return JSON(vsContent):dictionary() end)
    if ok and vsData and vsData["data"] then
      local d       = vsData["data"]
      local profile = (d["userProfiles"] or {})[1] or {}

      session.ibId      = profile["ibId"]      or d["ownerIbId"] or ""
      session.ownerId   = profile["companyId"] or session.ibId
      session.custType  = profile["custType"]  or "IX"
      session.ownerType = "Company"

      print("validateSession OK: ibId=" .. session.ibId .. " ownerId=" .. session.ownerId)
    else
      print("validateSession: JSON parse error")
      if vsContent then print("Response: " .. vsContent:sub(1, 200)) end
    end
  end

  -- Step 6b: refreshSession → renew token
  if session.authToken and #session.authToken > 0 and
     session.ibId      and #session.ibId      > 0 then
    print("Calling refreshSession...")
    local _, _, _, _, rsHeaders = session.connection:request(
      "POST",
      BASE_URL .. "/services/api/refreshSession",
      "{}",
      "application/json;charset=UTF-8",
      {
        ["Accept"]         = "application/json, text/plain, */*",
        ["authorization"]  = session.authToken,
        ["x-app-id"]       = "KBIZWEB",
        ["x-ib-id"]        = session.ibId,
        ["x-session-ibid"] = session.ibId,
        ["x-re-fresh"]     = "Y",
        ["x-verify"]       = "Y",
        ["x-request-id"]   = makeRequestId(),
        ["x-url"]          = dataRssoURL,
        ["Referer"]        = dataRssoURL,
        ["Origin"]         = BASE_URL,
      }
    )
    if rsHeaders then
      local newToken = rsHeaders["x-session-token"]
      if newToken and #newToken > 0 then
        session.authToken = newToken
        print("refreshSession: new x-session-token received")
      end
    end
  end

  MM.printStatus("Successfully signed in.")
  return nil
end

-- ============================================================
-- ListAccounts
-- ============================================================
function ListAccounts(knownAccounts)
  MM.printStatus("Loading accounts...")

  if not session.ownerId or #session.ownerId == 0 then
    print("Warning: ownerId not set, proceeding without...")
    session.ownerId   = ""
    session.ibId      = session.ibId      or ""
    session.custType  = session.custType  or "IX"
    session.ownerType = session.ownerType or "Company"
  else
    print("ownerId=" .. session.ownerId .. " ibId=" .. (session.ibId or "?"))
  end

  local data = apiPost("/services/api/bankaccountget/getOwnBankAccountFromList", {
    language              = "en",
    custType              = session.custType  or "IX",
    nicknameType          = "OWNAC",
    ownerId               = session.ownerId   or "",
    ownerType             = session.ownerType or "Company",
    accountType           = "CA,FD,SA",
    checkBalance          = "N",
    checkBalanceAccountNo = "",
  })

  if not data or not data["data"] or not data["data"]["ownAccountList"] then
    return "Failed to load account list."
  end

  local accounts = {}
  for _, acc in ipairs(data["data"]["ownAccountList"]) do
    local number  = tostring(acc["accountNo"] or "")
    local name    = acc["accountNoNickNameEN"] or acc["accountName"] or "KBank Account"
    local accType = acc["accountType"] or "SA"

    local mmType = AccountTypeGiro
    if     accType == "SA" then mmType = AccountTypeSavings
    elseif accType == "FD" then mmType = AccountTypeFixedTermDeposit
    elseif accType == "CA" then mmType = AccountTypeGiro
    end

    if #number > 0 then
      -- Persist session context per account in LocalStorage so RefreshAccount
      -- can work without re-authenticating (updated on every ListAccounts call)
      LocalStorage[number .. "_accType"]   = accType
      LocalStorage[number .. "_ownerId"]   = session.ownerId   or ""
      LocalStorage[number .. "_ibId"]      = session.ibId      or ""
      LocalStorage[number .. "_custType"]  = session.custType  or "IX"
      LocalStorage[number .. "_ownerType"] = session.ownerType or "Company"

      table.insert(accounts, {
        name          = name,
        owner         = acc["accountName"] or "",
        accountNumber = number,
        bankCode      = "004",
        currency      = "THB",
        bic           = "KASITHBK",
        type          = mmType,
      })
      print("Account: " .. number .. " (" .. name .. ", " .. accType .. ")")
      print("  Balance: " .. tostring(acc["availableBalance"] or "?") .. " THB")
    end
  end

  if #accounts == 0 then
    return "No accounts found."
  end

  return accounts
end

-- ============================================================
-- RefreshAccount
-- ============================================================
function RefreshAccount(account, since)
  MM.printStatus("Fetching transactions for " .. account.accountNumber .. "...")

  -- Restore session context from LocalStorage
  local num     = account.accountNumber
  local accType = LocalStorage[num .. "_accType"]   or "SA"
  local oId     = LocalStorage[num .. "_ownerId"]   or session.ownerId or ""
  local oIbId   = LocalStorage[num .. "_ibId"]      or session.ibId    or ""
  local cType   = LocalStorage[num .. "_custType"]  or session.custType  or "IX"
  local oType   = LocalStorage[num .. "_ownerType"] or session.ownerType or "Company"

  if oIbId and #oIbId > 0 then session.ibId    = oIbId end
  if oId   and #oId   > 0 then session.ownerId = oId   end

  -- Fetch current balance
  local balData = apiPost("/services/api/bankaccountget/getOwnBankAccountFromList", {
    language              = "en",
    custType              = cType,
    nicknameType          = "OWNAC",
    ownerId               = oId,
    ownerType             = oType,
    accountType           = "CA,FD,SA",
    checkBalance          = "Y",
    checkBalanceAccountNo = num,
  })

  local balance = 0
  if balData and balData["data"] and balData["data"]["ownAccountList"] then
    for _, acc in ipairs(balData["data"]["ownAccountList"]) do
      if tostring(acc["accountNo"]) == num then
        balance = tonumber(acc["availableBalance"] or acc["acctBalance"] or 0) or 0
        break
      end
    end
  end
  print("Balance: " .. balance .. " THB")

  -- Determine date range (max 180 days)
  local now          = os.time()
  local maxHistoryTS = now - MAX_HISTORY_DAYS * SECONDS_PER_DAY
  local fromTS       = since or maxHistoryTS

  if fromTS < maxHistoryTS then
    print("since too old, capping at " .. MAX_HISTORY_DAYS .. " days")
    fromTS = maxHistoryTS
  end

  -- Fetch transactions month by month
  local transactions = {}
  local periods      = buildMonthPeriods(fromTS, now)
  print("Periods: " .. #periods)

  for _, period in ipairs(periods) do
    print("Loading: " .. period.startDate .. " to " .. period.endDate)
    for _, t in ipairs(fetchTransactionPage(
      num, accType, oId, cType, oType, period.startDate, period.endDate, fromTS
    )) do
      table.insert(transactions, t)
    end
  end

  -- Detail calls for FTPP/FTOB transactions without a known recipient name.
  -- Only for transactions within the last DETAIL_CALL_DAYS days; results are
  -- cached in LocalStorage for DETAIL_CACHE_TTL days (key: origRqUid).
  local detailCutoff      = now - DETAIL_CALL_DAYS * SECONDS_PER_DAY
  local cacheTtl          = DETAIL_CACHE_TTL * SECONDS_PER_DAY
  local detailCount       = 0
  local cacheHits         = 0
  local detailRateLimited = false

  for _, t in ipairs(transactions) do
    if t._detail and t.bookingDate >= detailCutoff then
      local cacheKey   = "pc_" .. t._detail.origRqUid
      local cachedName = nil

      local cacheEntry = LocalStorage[cacheKey]
      if cacheEntry then
        local ts, name = cacheEntry:match("^(%d+)|(.*)$")
        if ts and (now - tonumber(ts)) < cacheTtl then
          cachedName = name
          cacheHits  = cacheHits + 1
        else
          LocalStorage[cacheKey] = nil
        end
      end

      if cachedName and #cachedName > 0 then
        t.name    = cachedName
        t.purpose = t.purpose:gsub(" %(PromptPay[^)]*%)", "")
      elseif not detailRateLimited then
        MM.sleep(0.3)
        local detailData = apiPost(
          "/services/api/accountsummary/getRecentTransactionDetail",
          {
            acctNo               = t._detail.acctNo,
            origRqUid            = t._detail.origRqUid,
            transDate            = t._detail.transDate,
            transType            = t._detail.transType,
            transCode            = t._detail.transCode,
            originalSourceId     = t._detail.originalSourceId,
            citizenId            = t._detail.citizenId,
            toAcctNoMasking      = t._detail.toAcctNoMasking,
            debitCreditIndicator = t._detail.debitCreditIndicator,
            benefitAccountNameEn = "",
            benefitAccountNameTh = "",
            custType             = cType,
            ownerId              = oId,
            ownerType            = oType,
          }
        )

        if not detailData then
          print("Detail call failed (rate limit?), aborting.")
          detailRateLimited = true
        elseif detailData["data"] then
          local nameEn = detailData["data"]["toAccountNameEn"] or ""
          if #nameEn > 0 then
            t.name    = nameEn
            t.purpose = t.purpose:gsub(" %(PromptPay[^)]*%)", "")
            LocalStorage[cacheKey] = tostring(now) .. "|" .. nameEn
          end
          detailCount = detailCount + 1
        end
      end
    end

    t._detail = nil
  end

  if detailCount > 0 or cacheHits > 0 then
    print("Detail calls: " .. detailCount .. ", cache hits: " .. cacheHits)
  end

  table.sort(transactions, function(a, b) return a.bookingDate > b.bookingDate end)
  print("Transactions total: " .. #transactions)

  return { balance = balance, transactions = transactions }
end

-- ============================================================
-- EndSession
-- ============================================================
function EndSession()
  MM.printStatus("Signing out...")
  if session.connection then
    local ok, err = pcall(function()
      session.connection:get(BASE_URL .. "/authen/logout.do")
    end)
    if not ok then
      print("Logout error (ignored): " .. tostring(err))
    end
  end
  return nil
end

-- ============================================================
-- Helper: JSON POST with standard auth headers
-- ============================================================
function apiPost(path, payload, referer)
  local ref  = referer or (BASE_URL .. "/menu/account/account/recent-transaction")
  local headers = {
    ["Accept"]           = "application/json, text/plain, */*",
    ["Content-Type"]     = "application/json",
    ["X-Requested-With"] = "XMLHttpRequest",
    ["Referer"]          = ref,
    ["Origin"]           = BASE_URL,
    ["x-app-id"]         = "KBIZWEB",
    ["x-re-fresh"]       = "N",
    ["x-verify"]         = "Y",
    ["x-request-id"]     = makeRequestId(),
    ["x-url"]            = ref,
  }

  if session.authToken and #session.authToken > 0 then
    headers["authorization"] = session.authToken
  end
  if session.ibId and #session.ibId > 0 then
    headers["x-ib-id"]        = session.ibId
    headers["x-session-ibid"] = session.ibId
  end

  local content = session.connection:request(
    "POST", BASE_URL .. path, JSON():set(payload):json(),
    "application/json;charset=UTF-8", headers
  )

  if not content or #content == 0 then
    print("Empty response from: " .. path)
    return nil
  end

  local ok, data = pcall(function() return JSON(content):dictionary() end)
  if not ok or not data then
    print("JSON error from: " .. path)
    print("Response: " .. content:sub(1, 300))
    return nil
  end

  if data["status"] ~= "S" then
    print("API error from " .. path .. ": status=" .. tostring(data["status"] or "?") ..
          (data["errorMessage"] and " msg=" .. data["errorMessage"] or ""))
  end

  return data
end

-- ============================================================
-- Fetch transactions for a date range with pagination
-- ============================================================
function fetchTransactionPage(acctNo, acctType, oId, cType, oType,
                               startDate, endDate, since)
  local transactions = {}
  local pageNo = 1

  repeat
    local data = apiPost("/services/api/accountsummary/getRecentTransactionList", {
      acctNo     = acctNo,
      acctType   = acctType,
      custType   = cType,
      ownerType  = oType,
      ownerId    = oId,
      startDate  = startDate,
      endDate    = endDate,
      pageNo     = tostring(pageNo),
      rowPerPage = tostring(ROWS_PER_PAGE),
      refKey     = "",
    })

    if not data or not data["data"] then
      print("No data for page " .. pageNo)
      break
    end

    local d     = data["data"]
    local list  = d["recentTransactionList"] or {}
    local total = tonumber(d["totalList"] or 0) or 0

    print("Page " .. pageNo .. ": " .. #list .. " of " .. total .. " transactions")

    for _, tx in ipairs(list) do
      local t = parseTx(tx, since)
      if t then
        local proxyId   = tx["proxyId"]    or ""
        local transType = (tx["transType"] or ""):upper()

        -- Schedule detail call for FTPP/FTOB without a known recipient
        if not t.name and (transType == "FTPP" or transType == "FTOB")
           and (tx["origRqUid"] or "") ~= "" then
          t._detail = {
            origRqUid            = tx["origRqUid"],
            acctNo               = acctNo,
            transDate            = (tx["transDate"] or ""):sub(1, 10),
            transType            = tx["transType"] or "",
            transCode            = tx["transCode"] or "",
            originalSourceId     = tx["originalSourceId"] or "",
            citizenId            = proxyId,
            toAcctNoMasking      = tx["toAccountNumber"] or "",
            debitCreditIndicator = tx["debitCreditIndicator"] or "",
          }
        end

        table.insert(transactions, t)
      end
    end

    if (pageNo - 1) * ROWS_PER_PAGE + #list >= total or #list == 0 then break end
    pageNo = pageNo + 1

  until pageNo > MAX_PAGES_PER_PERIOD

  return transactions
end

-- ============================================================
-- Convert a single API transaction entry to a MoneyMoney transaction
-- ============================================================
function parseTx(tx, since)
  local bookingDate = parseDate(tx["transDate"] or tx["effectiveDate"] or "")
  if not bookingDate then return nil end
  if since and bookingDate < since then return nil end

  local valueDate = parseDate(tx["effectiveDate"] or "") or bookingDate

  -- Amount: depositAmount is positive, withdrawAmount is negative;
  -- debitCreditIndicator ("DR"/"CR") corrects ambiguous cases
  local deposit   = tonumber(tx["depositAmount"]  or 0) or 0
  local withdraw  = tonumber(tx["withdrawAmount"] or 0) or 0
  local indicator = tx["debitCreditIndicator"] or ""
  local amount    = deposit > 0 and deposit or (withdraw > 0 and -withdraw or 0)

  if indicator == "DR" and amount > 0 then amount = -amount end
  if indicator == "CR" and amount < 0 then amount = -amount end

  -- Build purpose: transaction name + target account/PromptPay ID + description + channel
  local purpose   = tx["transNameEn"]  or tx["transNameTh"]  or ""
  local toAcc     = tx["toAccountNumber"] or tx["benefitAccountNo"] or ""
  local proxyId   = tx["proxyId"]         or ""
  local proxyType = tx["proxyTypeCode"]   or ""
  local desc      = tx["descEn"]          or tx["descTh"]        or ""
  local channel   = tx["channelEn"]       or tx["channelTh"]     or ""

  if #toAcc > 0 then
    purpose = purpose .. " (" .. toAcc .. ")"
  elseif #proxyId > 0 then
    purpose = purpose .. " (" .. (PROXY_TYPE_LABELS[proxyType] or "PromptPay") .. ":" .. proxyId .. ")"
  end
  if #desc    > 0 then purpose = purpose .. " " .. desc    end
  if #channel > 0 then purpose = purpose .. " [" .. channel .. "]" end

  -- name: prefer English recipient name from the transaction list;
  -- for FTPP/FTOB it may be loaded later via a detail call (t._detail)
  local beneficiary = tx["benefitAccountNameEn"] or tx["benefitAccountNameTh"]
                   or tx["toAccountNameEn"]       or tx["toAccountNameTh"] or ""

  return {
    bookingDate   = bookingDate,
    valueDate     = valueDate,
    purpose       = purpose,
    amount        = amount,
    currency      = "THB",
    booked        = true,
    name          = #beneficiary > 0 and beneficiary or nil,
    accountNumber = #toAcc > 0 and toAcc or (#proxyId > 0 and proxyId or nil),
  }
end

-- ============================================================
-- Generate monthly date ranges between fromTS and toTS
-- ============================================================
function buildMonthPeriods(fromTS, toTS)
  local periods = {}
  local current = fromTS

  while current <= toTS do
    local d = os.date("*t", current)

    local nextYear  = d.month == 12 and d.year + 1 or d.year
    local nextMonth = d.month == 12 and 1 or d.month + 1

    -- Month end: day=0 of the following month (handles DST transitions correctly)
    local monthEnd = os.time({ year=nextYear, month=nextMonth, day=0,
                                hour=23, min=59, sec=59 })

    table.insert(periods, {
      startDate = os.date("%d/%m/%Y", math.max(
        os.time({ year=d.year, month=d.month, day=1, hour=0, min=0, sec=0 }), fromTS
      )),
      endDate = os.date("%d/%m/%Y", math.min(monthEnd, toTS)),
    })

    current = os.time({ year=nextYear, month=nextMonth, day=1, hour=0, min=0, sec=0 })
  end

  return periods
end

-- ============================================================
-- Request-ID: Timestamp (YYYYMMDDHHmmss) + 6-stellige Zufallszahl
-- ============================================================
function makeRequestId()
  return os.date("%Y%m%d%H%M%S") .. string.format("%06d", math.random(0, 999999))
end

-- ============================================================
-- Parse date — supported formats:
--   "2026-03-02 08:12:45"  or  "2026-03-02T08:12:45"  (transDate)
--   "2026-03-02"                                        (date-only field)
--   "DD/MM/YYYY"                                        (API request format)
--   "Mon Mar 02 07:00:00 ICT 2026"                      (effectiveDate)
-- ============================================================
function parseDate(str)
  if not str or #str == 0 then return nil end
  str = tostring(str):match("^%s*(.-)%s*$")

  local y, m, d, h, mi, s = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if y then
    return os.time({ year=tonumber(y), month=tonumber(m), day=tonumber(d),
                     hour=tonumber(h), min=tonumber(mi), sec=tonumber(s) })
  end

  local y2, m2, d2 = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y2 then
    return os.time({ year=tonumber(y2), month=tonumber(m2), day=tonumber(d2),
                     hour=0, min=0, sec=0 })
  end

  local dd, mm, yy = str:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)")
  if dd then
    return os.time({ year=tonumber(yy), month=tonumber(mm), day=tonumber(dd),
                     hour=12, min=0, sec=0 })
  end

  local mon, day, year = str:match("%a+%s+(%a+)%s+(%d+)%s+%d+:%d+:%d+%s+%a+%s+(%d%d%d%d)")
  if mon and MONTH_NAMES[mon] then
    return os.time({ year=tonumber(year), month=MONTH_NAMES[mon], day=tonumber(day),
                     hour=12, min=0, sec=0 })
  end

  print("Date not parseable: " .. str)
  return nil
end
