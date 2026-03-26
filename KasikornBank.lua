-- ============================================================
-- MoneyMoney Web Banking Extension
-- Kasikorn Bank (KBank) Thailand – K BIZ Online Banking
-- Version: 3.62
-- 3.62: Referer-Header im redirectToIB-Request korrigiert (loginAuthen.do);
--       MM.sleep(0.3) zwischen Detail-Calls; origRqUid als Cache-Key;
--       valueDate aus effectiveDate; MM.urlencode UTF-8; Cleanup
-- 3.61: Detail-Call für alle FTOB-Transaktionen (nicht nur PromptPay), um
--       Empfängernamen bei Payment/Transfer-Umsätzen zu laden
-- 3.60: os.execute("sleep") entfernt (nicht in MoneyMoney-Sandbox verfügbar)
-- 3.59: POST-Endpoint /authen/login.do → /authen/loginAuthen.do (Bank-Update),
--       captcha-Feld durch maxTouchPoint ersetzt
--
-- Login-Flow:
--   1. GET  /authen/login.jsp?lang=en          → tokenId aus Hidden-Field
--   2. POST /authen/loginAuthen.do             → userName, password, tokenId, ...
--   3. Response-JS: window.location = '/authen/ib/redirectToIB.jsp'
--   4. GET  /authen/ib/redirectToIB.jsp        → dataRsso-Token
--   5. GET  /login?dataRsso=...                → Angular-App Session
--
-- API-Endpoints (aus Browser-DevTools ermittelt):
--   Konten:   POST /services/api/bankaccountget/getOwnBankAccountFromList
--   Umsätze:  POST /services/api/accountsummary/getRecentTransactionList
--             (max. 1 Monat pro Abfrage, paginiert mit rowPerPage/pageNo)
-- ============================================================

WebBanking {
  version     = 3.62,
  url         = "https://kbiz.kasikornbank.com",
  services    = {"Kasikorn Bank (KBiz)"},
  description = "Kasikorn Bank (KBank) Thailand – K BIZ Online Banking"
}

-- ============================================================
-- Konstanten
-- ============================================================
local BASE_URL              = "https://kbiz.kasikornbank.com"
local MAX_HISTORY_DAYS      = 180
local DETAIL_CALL_DAYS      = 30
local PROXY_CACHE_TTL_DAYS  = 90
local SECONDS_PER_DAY       = 86400
local MAX_PAGES_PER_PERIOD  = 20
local ROWS_PER_PAGE         = 100

-- Monatsnamen für parseDate (einmal definiert, nicht bei jedem Call neu)
local MONTH_NAMES = {
  Jan=1, Feb=2, Mar=3, Apr=4, May=5,  Jun=6,
  Jul=7, Aug=8, Sep=9, Oct=10,Nov=11, Dec=12
}

-- PromptPay proxyTypeCode → lesbares Label
local PROXY_TYPE_LABELS = {
  M = "PromptPay Mobile",
  A = "PromptPay Acc",
  T = "PromptPay ID",
  E = "PromptPay ID",
  I = "PromptPay NatID",
}

-- ============================================================
-- Session-State (wird in InitializeSession befüllt)
-- ============================================================
local session = {
  connection  = nil,
  ownerId     = nil,
  custType    = nil,
  ownerType   = nil,
  authToken   = nil,    -- x-session-token = Authorization Header
  ibId        = nil,    -- x-ib-id / x-session-ibid
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
  -- Zufallsgenerator initialisieren (einmalig)
  math.randomseed(os.time())

  session.connection          = Connection()
  session.connection.language  = "en-US,en;q=0.9"
  session.connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " ..
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  -- --------------------------------------------------------
  -- Schritt 1: Login-Seite laden → tokenId holen
  -- --------------------------------------------------------
  MM.printStatus("Lade Login-Seite ...")
  local content, charset = session.connection:get(BASE_URL .. "/authen/login.jsp?lang=en")
  if not content or #content == 0 then
    return "Fehler: Login-Seite nicht erreichbar."
  end

  local html    = HTML(content, charset)
  local tokenId = html:xpath("//input[@name='tokenId']"):attr("value")
  if not tokenId or #tokenId == 0 then
    tokenId = content:match('name="tokenId"[^>]*value="(%d+)"')
  end
  if not tokenId or #tokenId == 0 then
    tokenId = tostring(math.floor(MM.time() * 1000))
    print("tokenId Fallback: " .. tokenId)
  else
    print("tokenId: " .. tokenId)
  end

  -- --------------------------------------------------------
  -- Schritt 2: Login-POST
  -- --------------------------------------------------------
  MM.printStatus("Anmelden ...")
  local postBody = "userName="  .. MM.urlencode(username, "UTF-8") ..
                   "&password=" .. MM.urlencode(password, "UTF-8") ..
                   "&tokenId="  .. MM.urlencode(tokenId)  ..
                   "&cmd=authenticate" ..
                   "&locale=en"  ..
                   "&custType="  ..
                   "&maxTouchPoint=" ..
                   "&app=0"

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
    return "Fehler: Login-Request fehlgeschlagen."
  end

  -- Login-Erfolg prüfen
  if not (loginContent:find("event_action.*success") or
          loginContent:find("redirectToIB") or
          loginContent:find("dataRsso")) then
    local errHtml = HTML(loginContent, loginCharset)
    local errMsg  = errHtml:xpath("//*[@id='errorText']"):text()
    print("Login fehlgeschlagen: " .. (errMsg or "unbekannt"))
    return LoginFailed
  end

  print("Login erfolgreich!")

  -- --------------------------------------------------------
  -- Schritt 3: JS-Redirect zu redirectToIB.jsp manuell folgen
  -- --------------------------------------------------------
  local redirectURL = loginContent:match("window%.location%s*=%s*['\"]([^'\"]+)['\"]")
                   or "/authen/ib/redirectToIB.jsp"
  if redirectURL:sub(1, 1) == "/" then
    redirectURL = BASE_URL .. redirectURL
  end
  print("Folge Redirect: " .. redirectURL)

  local redirectContent = session.connection:request(
    "GET", redirectURL, nil, nil,
    {
      ["Referer"] = BASE_URL .. "/authen/loginAuthen.do",
      ["Accept"]  = "text/html,application/xhtml+xml,*/*",
    }
  )

  if not redirectContent then
    return "Fehler: redirectToIB.jsp nicht erreichbar."
  end

  -- --------------------------------------------------------
  -- Schritt 4: dataRsso-Token extrahieren und Angular-App laden
  -- --------------------------------------------------------
  local dataRssoURL = redirectContent:match(
    'window%.top%.location%.href%s*=%s*"(https://kbiz%.kasikornbank%.com/login%?dataRsso=[^"]+)"'
  )
  if not dataRssoURL then
    dataRssoURL = redirectContent:match(
      "window%.top%.location%.href%s*=%s*['\"]([^'\"]+dataRsso[^'\"]+)['\"]"
    )
  end

  if not dataRssoURL then
    return "Fehler: dataRsso URL nicht gefunden in redirectToIB-Antwort."
  end

  local dataRsso = dataRssoURL:match("dataRsso=(.+)$")
  if not dataRsso then
    return "Fehler: dataRsso Token nicht extrahierbar."
  end
  print("dataRsso Token extrahiert, Laenge: " .. #dataRsso)

  print("Lade Angular-App ...")
  session.connection:request("GET", dataRssoURL, nil, nil,
    {
      ["Referer"] = redirectURL,
      ["Accept"]  = "text/html,application/xhtml+xml,*/*",
    }
  )

  -- --------------------------------------------------------
  -- Schritt 5: validateSession → x-session-token + ibId
  -- --------------------------------------------------------
  print("Rufe validateSession auf ...")
  local vsBody = JSON():set({ dataRsso = dataRsso }):json()
  local vsContent, _, _, _, vsHeaders = session.connection:request(
    "POST",
    BASE_URL .. "/services/api/authentication/validateSession",
    vsBody,
    "application/json;charset=UTF-8",
    {
      ["Accept"]       = "application/json, text/plain, */*",
      ["x-re-fresh"]   = "N",
      ["x-request-id"] = makeRequestId(),
      ["Referer"]      = dataRssoURL,
      ["Origin"]       = BASE_URL,
    }
  )

  -- x-session-token aus Response-Headers lesen
  if vsHeaders then
    local tok = vsHeaders["x-session-token"]
    if tok and #tok > 0 then
      session.authToken = tok
      print("x-session-token erhalten, Laenge: " .. #session.authToken)
    else
      print("WARNUNG: Kein x-session-token in validateSession Response Headers")
      for k, v in pairs(vsHeaders) do
        print("  Header: " .. k .. " = " .. tostring(v):sub(1, 80))
      end
    end
  else
    print("WARNUNG: Keine Response Headers von validateSession")
  end

  -- ibId, ownerId, custType aus Response-Body lesen
  if vsContent and #vsContent > 0 then
    local ok, vsData = pcall(function() return JSON(vsContent):dictionary() end)
    if ok and vsData and vsData["data"] then
      local d        = vsData["data"]
      local profiles = d["userProfiles"] or {}
      local profile  = profiles[1] or {}

      session.ibId      = profile["ibId"]      or d["ownerIbId"] or ""
      session.ownerId   = profile["companyId"] or session.ibId
      session.custType  = profile["custType"]  or "IX"
      session.ownerType = "Company"

      print("validateSession OK: ibId=" .. session.ibId ..
            " ownerId=" .. session.ownerId)
    else
      print("validateSession: JSON-Parse Fehler")
      if vsContent then print("Response: " .. vsContent:sub(1, 200)) end
    end
  end

  -- --------------------------------------------------------
  -- Schritt 6: refreshSession → neuen Token holen
  -- --------------------------------------------------------
  if session.authToken and #session.authToken > 0 and
     session.ibId      and #session.ibId      > 0 then
    print("Rufe refreshSession auf ...")
    local rsContent, _, _, _, rsHeaders = session.connection:request(
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
        print("refreshSession: neuer x-session-token erhalten")
      end
    end
    if rsContent then
      print("refreshSession: " .. rsContent:sub(1, 100))
    end
  end

  MM.printStatus("Erfolgreich angemeldet.")
  return nil
end

-- ============================================================
-- ListAccounts
-- ============================================================
function ListAccounts(knownAccounts)
  MM.printStatus("Lade Konten ...")

  if not session.ownerId or #session.ownerId == 0 then
    print("Warnung: ownerId nicht gesetzt, versuche ohne...")
    session.ownerId   = ""
    session.ibId      = session.ibId      or ""
    session.custType  = session.custType  or "IX"
    session.ownerType = session.ownerType or "Company"
  else
    print("ownerId=" .. session.ownerId .. " ibId=" .. (session.ibId or "?"))
  end

  local payload = {
    language              = "en",
    custType              = session.custType  or "IX",
    nicknameType          = "OWNAC",
    ownerId               = session.ownerId   or "",
    ownerType             = session.ownerType or "Company",
    accountType           = "CA,FD,SA",
    checkBalance          = "N",
    checkBalanceAccountNo = "",
  }

  local data = apiPost("/services/api/bankaccountget/getOwnBankAccountFromList", payload)

  if not data or not data["data"] or not data["data"]["ownAccountList"] then
    return "Fehler: Kontoliste konnte nicht geladen werden."
  end

  local accounts = {}
  for _, acc in ipairs(data["data"]["ownAccountList"]) do
    local number  = tostring(acc["accountNo"] or "")
    local name    = acc["accountNoNickNameEN"] or acc["accountName"] or "KBank Konto"
    local accType = acc["accountType"] or "SA"

    local mmType = AccountTypeGiro
    if     accType == "SA" then mmType = AccountTypeSavings
    elseif accType == "FD" then mmType = AccountTypeFixedTermDeposit
    elseif accType == "CA" then mmType = AccountTypeGiro
    end

    if #number > 0 then
      -- Session-Daten pro Konto persistieren
      local prefix = number
      LocalStorage[prefix .. "_accType"]   = accType
      LocalStorage[prefix .. "_ownerId"]   = session.ownerId   or ""
      LocalStorage[prefix .. "_ibId"]      = session.ibId      or ""
      LocalStorage[prefix .. "_custType"]  = session.custType  or "IX"
      LocalStorage[prefix .. "_ownerType"] = session.ownerType or "Company"

      table.insert(accounts, {
        name          = name,
        owner         = acc["accountName"] or "",
        accountNumber = number,
        bankCode      = "004",
        currency      = "THB",
        bic           = "KASITHBK",
        type          = mmType,
      })
      print("Konto: " .. number .. " (" .. name .. ", " .. accType .. ")")
      print("  Saldo: " .. tostring(acc["availableBalance"] or "?") .. " THB")
    end
  end

  if #accounts == 0 then
    return "Fehler: Keine Konten gefunden."
  end

  return accounts
end

-- ============================================================
-- RefreshAccount
-- ============================================================
function RefreshAccount(account, since)
  MM.printStatus("Lade Umsaetze fuer " .. account.accountNumber .. " ...")

  -- Session-Daten aus LocalStorage wiederherstellen
  local prefix  = account.accountNumber
  local accType = LocalStorage[prefix .. "_accType"]   or "SA"
  local oId     = LocalStorage[prefix .. "_ownerId"]   or session.ownerId or ""
  local oIbId   = LocalStorage[prefix .. "_ibId"]      or session.ibId    or ""
  local cType   = LocalStorage[prefix .. "_custType"]  or session.custType  or "IX"
  local oType   = LocalStorage[prefix .. "_ownerType"] or session.ownerType or "Company"

  if oIbId and #oIbId > 0 then session.ibId    = oIbId end
  if oId   and #oId   > 0 then session.ownerId = oId   end

  -- --------------------------------------------------------
  -- Saldo abrufen
  -- --------------------------------------------------------
  local balPayload = {
    language              = "en",
    custType              = cType,
    nicknameType          = "OWNAC",
    ownerId               = oId,
    ownerType             = oType,
    accountType           = "CA,FD,SA",
    checkBalance          = "Y",
    checkBalanceAccountNo = account.accountNumber,
  }
  local balData = apiPost(
    "/services/api/bankaccountget/getOwnBankAccountFromList",
    balPayload
  )

  local balance = 0
  if balData and balData["data"] and balData["data"]["ownAccountList"] then
    for _, acc in ipairs(balData["data"]["ownAccountList"]) do
      if tostring(acc["accountNo"]) == account.accountNumber then
        balance = tonumber(acc["availableBalance"] or acc["acctBalance"] or 0) or 0
        break
      end
    end
  end
  print("Saldo: " .. balance .. " THB")

  -- --------------------------------------------------------
  -- Zeitraum bestimmen (max. 6 Monate)
  -- --------------------------------------------------------
  local now          = os.time()
  local maxHistoryTS = now - MAX_HISTORY_DAYS * SECONDS_PER_DAY
  local fromTS       = since or maxHistoryTS

  if fromTS < maxHistoryTS then
    print("since zu alt, begrenze auf " .. MAX_HISTORY_DAYS .. " Tage")
    fromTS = maxHistoryTS
  end

  -- --------------------------------------------------------
  -- Umsätze monatsweise laden
  -- --------------------------------------------------------
  local transactions = {}
  local periods      = buildMonthPeriods(fromTS, now)
  print("Zeitraeume: " .. #periods)

  for _, period in ipairs(periods) do
    print("Lade: " .. period.startDate .. " bis " .. period.endDate)
    local pageTxns = fetchTransactionPage(
      account.accountNumber, accType, oId, cType, oType,
      period.startDate, period.endDate, fromTS
    )
    for _, t in ipairs(pageTxns) do
      table.insert(transactions, t)
    end
  end

  -- --------------------------------------------------------
  -- Detail-Calls für FTPP/FTOB-Transaktionen ohne Empfängernamen
  -- Cache-Key: origRqUid (eindeutig pro Transaktion, TTL 90 Tage)
  -- --------------------------------------------------------
  local detailCutoff      = now - DETAIL_CALL_DAYS * SECONDS_PER_DAY
  local cacheTtl          = PROXY_CACHE_TTL_DAYS * SECONDS_PER_DAY
  local detailCount       = 0
  local cacheHits         = 0
  local detailRateLimited = false

  for _, t in ipairs(transactions) do
    if t._detail and t.bookingDate >= detailCutoff then
      local cacheKey   = "pc_" .. t._detail.origRqUid
      local cachedName = nil

      -- Cache prüfen (origRqUid als Schlüssel)
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
          print("Detail-Call fehlgeschlagen (Rate-Limit?), breche ab.")
          detailRateLimited = true
        elseif detailData["data"] then
          local d      = detailData["data"]
          local nameEn = d["toAccountNameEn"] or ""
          if #nameEn > 0 then
            t.name    = nameEn
            t.purpose = t.purpose:gsub(" %(PromptPay[^)]*%)", "")
            LocalStorage[cacheKey] = tostring(now) .. "|" .. nameEn
          end
          detailCount = detailCount + 1
        end
      end
    end

    -- Hilfs-Sub-Table bereinigen (egal ob genutzt oder nicht)
    t._detail = nil
  end

  if detailCount > 0 or cacheHits > 0 then
    print("Detail-Calls: " .. detailCount .. ", Cache-Treffer: " .. cacheHits)
  end

  -- Neueste zuerst
  table.sort(transactions, function(a, b)
    return a.bookingDate > b.bookingDate
  end)

  print("Umsaetze gesamt: " .. #transactions)

  return {
    balance      = balance,
    transactions = transactions,
  }
end

-- ============================================================
-- EndSession
-- ============================================================
function EndSession()
  MM.printStatus("Melde ab ...")
  if session.connection then
    local ok, err = pcall(function()
      session.connection:get(BASE_URL .. "/authen/logout.do")
    end)
    if not ok then
      print("Logout-Fehler (ignoriert): " .. tostring(err))
    end
  end
  return nil
end

-- ============================================================
-- API-Hilfsfunktion: JSON-POST
-- ============================================================
function apiPost(path, payload, referer)
  local body = JSON():set(payload):json()
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
    "POST",
    BASE_URL .. path,
    body,
    "application/json;charset=UTF-8",
    headers
  )

  if not content or #content == 0 then
    print("Leere Antwort von: " .. path)
    return nil
  end

  local ok, data = pcall(function() return JSON(content):dictionary() end)
  if not ok or not data then
    print("JSON-Fehler von: " .. path)
    print("Antwort: " .. content:sub(1, 300))
    return nil
  end

  if data["status"] ~= "S" then
    print("API-Status von " .. path .. ": " .. tostring(data["status"] or "?"))
    if data["errorMessage"] then
      print("API-Fehler: " .. data["errorMessage"])
    end
  end

  return data
end

-- ============================================================
-- Alle Seiten eines Zeitraums laden (paginiert)
-- ============================================================
function fetchTransactionPage(acctNo, acctType, oId, cType, oType,
                               startDate, endDate, since)
  local transactions = {}
  local pageNo = 1

  repeat
    local payload = {
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
    }

    local data = apiPost(
      "/services/api/accountsummary/getRecentTransactionList",
      payload
    )

    if not data or not data["data"] then
      print("Keine Daten fuer Seite " .. pageNo)
      break
    end

    local d     = data["data"]
    local list  = d["recentTransactionList"] or {}
    local total = tonumber(d["totalList"] or 0) or 0

    print("Seite " .. pageNo .. ": " .. #list .. " von " .. total .. " Umsaetzen")

    for _, tx in ipairs(list) do
      local t = parseTx(tx, since)
      if t then
        -- Detail-Call-Erkennung: Empfängername fehlt + origRqUid vorhanden
        --   FTPP = PromptPay direkt (KBank zu KBank über PromptPay)
        --   FTOB = Überweisung andere Bank (mit oder ohne PromptPay-proxyId)
        --   Für alle FTPP/FTOB ohne bekannten Empfänger Detail-Call machen
        local proxyId   = tx["proxyId"]    or ""
        local transType = (tx["transType"] or ""):upper()

        local needsDetail = (transType == "FTPP") or (transType == "FTOB")

        if not t.name and needsDetail and (tx["origRqUid"] or "") ~= "" then
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

    local loaded = (pageNo - 1) * ROWS_PER_PAGE + #list
    if loaded >= total or #list == 0 then
      break
    end
    pageNo = pageNo + 1

  until pageNo > MAX_PAGES_PER_PERIOD

  return transactions
end

-- ============================================================
-- Einzelnen Umsatz parsen
-- ============================================================
function parseTx(tx, since)
  local dateStr     = tx["transDate"] or tx["effectiveDate"] or ""
  local bookingDate = parseDate(dateStr)
  if not bookingDate then return nil end
  if since and bookingDate < since then return nil end

  local valueDate = parseDate(tx["effectiveDate"] or "") or bookingDate

  -- Betrag ermitteln
  local deposit   = tonumber(tx["depositAmount"]  or 0) or 0
  local withdraw  = tonumber(tx["withdrawAmount"] or 0) or 0
  local indicator = tx["debitCreditIndicator"] or ""
  local amount    = 0

  if deposit > 0 then
    amount = deposit
  elseif withdraw > 0 then
    amount = -withdraw
  end

  -- Vorzeichen via Indicator korrigieren (bei Mehrdeutigkeit)
  if indicator == "DR" and amount > 0 then
    amount = -amount
  elseif indicator == "CR" and amount < 0 then
    amount = -amount
  end

  -- Beschreibung aufbauen
  local purpose     = tx["transNameEn"]  or tx["transNameTh"]  or ""
  local beneficiary = tx["benefitAccountNameEn"] or tx["benefitAccountNameTh"]
                    or tx["toAccountNameEn"]      or tx["toAccountNameTh"] or ""
  local channel     = tx["channelEn"]    or tx["channelTh"]    or ""
  local toAcc       = tx["toAccountNumber"] or tx["benefitAccountNo"] or ""
  local proxyId     = tx["proxyId"]         or ""
  local proxyType   = tx["proxyTypeCode"]   or ""
  local desc        = tx["descEn"]          or tx["descTh"]        or ""

  if #toAcc > 0 then
    purpose = purpose .. " (" .. toAcc .. ")"
  elseif #proxyId > 0 then
    local label = PROXY_TYPE_LABELS[proxyType] or "PromptPay"
    purpose = purpose .. " (" .. label .. ":" .. proxyId .. ")"
  end

  if #desc > 0 then
    purpose = purpose .. " " .. desc
  end
  if #channel > 0 then
    purpose = purpose .. " [" .. channel .. "]"
  end

  local txName  = #beneficiary > 0 and beneficiary or nil
  local txAccNo = #toAcc > 0 and toAcc
              or (#proxyId > 0 and proxyId or nil)

  return {
    bookingDate   = bookingDate,
    valueDate     = valueDate,
    purpose       = purpose,
    amount        = amount,
    currency      = "THB",
    booked        = true,
    name          = txName,
    accountNumber = txAccNo,
  }
end

-- ============================================================
-- Monatliche Zeiträume generieren
-- ============================================================
function buildMonthPeriods(fromTS, toTS)
  local periods = {}
  local current = fromTS

  while current <= toTS do
    local d = os.date("*t", current)

    -- Erster Tag des aktuellen Monats
    local monthStart = os.time({
      year=d.year, month=d.month, day=1, hour=0, min=0, sec=0
    })

    -- Letzter Tag des aktuellen Monats via Tag=0 des Folgemonats
    -- (korrekt auch bei Sommerzeit-Übergängen, kein -86400 nötig)
    local nextYear  = d.month == 12 and d.year + 1 or d.year
    local nextMonth = d.month == 12 and 1 or d.month + 1
    local monthEnd  = os.time({
      year=nextYear, month=nextMonth, day=0,
      hour=23, min=59, sec=59
    })

    local startTS  = math.max(monthStart, fromTS)
    local finishTS = math.min(monthEnd,   toTS)

    table.insert(periods, {
      startDate = os.date("%d/%m/%Y", startTS),
      endDate   = os.date("%d/%m/%Y", finishTS),
    })

    -- Zum ersten Tag des nächsten Monats springen
    current = os.time({
      year=nextYear, month=nextMonth, day=1, hour=0, min=0, sec=0
    })
  end

  return periods
end

-- ============================================================
-- Request-ID generieren (Timestamp + 6-stellige Zufallszahl)
-- ============================================================
function makeRequestId()
  return os.date("%Y%m%d%H%M%S") .. string.format("%06d", math.random(0, 999999))
end

-- ============================================================
-- Datum parsen (mehrere Formate)
-- ============================================================
function parseDate(str)
  if not str or #str == 0 then return nil end
  str = tostring(str):match("^%s*(.-)%s*$")

  -- Format: "2026-03-02 08:12:45" oder "2026-03-02T08:12:45"
  local y, m, d = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then
    return os.time({
      year=tonumber(y), month=tonumber(m), day=tonumber(d),
      hour=12, min=0, sec=0
    })
  end

  -- Format: "DD/MM/YYYY"
  local d2, m2, y2 = str:match("^(%d%d?)/(%d%d?)/(%d%d%d%d)")
  if d2 then
    return os.time({
      year=tonumber(y2), month=tonumber(m2), day=tonumber(d2),
      hour=12, min=0, sec=0
    })
  end

  -- Format: "Mon Mar 02 07:00:00 ICT 2026"
  local mon, day, year = str:match(
    "%a+%s+(%a+)%s+(%d+)%s+%d+:%d+:%d+%s+%a+%s+(%d%d%d%d)"
  )
  if mon and MONTH_NAMES[mon] then
    return os.time({
      year=tonumber(year), month=MONTH_NAMES[mon], day=tonumber(day),
      hour=12, min=0, sec=0
    })
  end

  print("Datum nicht parsebar: " .. str)
  return nil
end