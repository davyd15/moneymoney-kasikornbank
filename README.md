# MoneyMoney Extension – Kasikorn Bank (K BIZ)

A [MoneyMoney](https://moneymoney-app.com) extension for **Kasikorn Bank (KBank) Thailand** via the [K BIZ Online Banking](https://kbiz.kasikornbank.com) web portal. Fetches account balances and transactions for personal and business accounts.

---

## Features

- Supports **Current (CA)**, **Savings (SA)**, and **Fixed Deposit (FD)** accounts in THB
- Fetches up to **180 days** of transaction history, paginated by month
- Resolves **PromptPay recipient names** for FTPP and FTOB transactions with a 90-day cache
- **No 2FA / SMS OTP required** — authenticates directly via RSSO session token
- Handles the bank's occasional **Terms & Conditions interstitial** automatically

## How It Works

The extension implements MoneyMoney's `WebBanking` Lua API and communicates with the K BIZ portal at `kbiz.kasikornbank.com`.

### Authentication

Login is a 6-step flow with no 2FA:

| Step | Action |
|------|--------|
| 1 | `GET /authen/login.jsp` → extract `tokenId` (anti-CSRF token) |
| 2 | `POST /authen/loginAuthen.do` with credentials + tokenId |
| 2b | (if shown) T&C interstitial automatically accepted via `POST /authen/loginSuccess.do` |
| 3–4 | Follow JS redirect → `GET /authen/ib/redirectToIB.jsp` → extract `dataRsso` token |
| 5 | `GET /login?dataRsso=...` → initialize the Angular app session |
| 6 | `POST /services/api/authentication/validateSession` → receive `x-session-token` + `ibId`/`ownerId` |

The session token is sent as an `Authorization` header on all subsequent API calls and periodically renewed via `POST /services/api/refreshSession`.

### Data Retrieval

- **Accounts:** `POST /services/api/bankaccountget/getOwnBankAccountFromList`
- **Transactions:** `POST /services/api/accountsummary/getRecentTransactionList`, paginated by calendar month (up to 180 days)
- **PromptPay recipient names:** resolved via `POST /services/api/accountsummary/getRecentTransactionDetail` for FTPP/FTOB transactions within the last 30 days, then cached in `LocalStorage` for 90 days to minimize API calls

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS (any recent version)
- A **K BIZ Online Banking** account at Kasikorn Bank
- Your **K BIZ User ID** and **Password**

> **Note:** This extension uses the K BIZ portal (`kbiz.kasikornbank.com`), not the K PLUS app. Both personal and business KBank customers can use K BIZ — you just need to register for K BIZ access at your branch or via the KBank website. If you only have K PLUS and have never set up K BIZ, this extension will not work for you.

## Installation

### Option A — Direct download

1. Download [`KasikornBank.lua`](KasikornBank.lua)
2. Move it into MoneyMoney's Extensions folder:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```
3. In MoneyMoney, go to **Help → Show Database in Finder** if you need to locate the folder.
4. Reload extensions in MoneyMoney: right-click any account → **Reload Extensions** (or restart the app).

### Option B — Clone the repository

```bash
git clone https://github.com/davyd15/moneymoney-kasikornbank.git
cp moneymoney-kasikornbank/KasikornBank.lua \
  ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/
```

## Setup in MoneyMoney

1. Open MoneyMoney and add a new account: **File → Add Account…**
2. Search for **"Kasikorn Bank"** or **"KBiz"**
3. Select **Kasikorn Bank (KBiz)**
4. Enter your **K BIZ User ID** as username and your **K BIZ Password**
5. Click **Next** — MoneyMoney will connect and import your accounts

## Supported Transaction Types

| Code | Description |
|------|-------------|
| FTPP | PromptPay transfer (recipient name resolved) |
| FTOB | Other bank transfer (recipient name resolved) |
| FT   | Internal / same-bank transfer |
| DD   | Direct debit |
| INT  | Interest |
| FEE  | Fee |
| Others | Shown with raw transaction type code |

## Limitations

- **K BIZ access required** — both personal and business KBank customers can use K BIZ, but you must have registered for it (not the same as K PLUS)
- **THB only** — foreign currency accounts are not supported
- **Max 180 days** history per refresh (bank API limit)
- PromptPay recipient name lookup only for transactions within the last 30 days (cached for 90 days thereafter)

## Troubleshooting

**"Login failed" / credentials rejected**
- Make sure you are using your **K BIZ User ID and Password**, which may differ from your K PLUS credentials
- Try logging in at [kbiz.kasikornbank.com](https://kbiz.kasikornbank.com) in your browser to verify your credentials
- If you have not registered for K BIZ yet, you can do so at a KBank branch or via the KBank website

**Extension not appearing in MoneyMoney**
- Confirm the `.lua` file is in the correct Extensions folder (see Installation above)
- Reload extensions or restart MoneyMoney

**Transactions missing / history too short**
- The bank limits history to 180 days. Older transactions cannot be retrieved.

## Changelog

| Version | Changes |
|---------|---------|
| 3.65 | Automatically accept Terms & Conditions interstitial after login |
| 3.64 | Final cleanup, comments and code optimisation |
| 3.63 | Fix: parse date with time from `transDate` field |
| 3.62 | Multiple bug fixes and code cleanup |
| 3.61 | Enable detail API call for all FTOB transactions |
| 3.60 | Remove `os.execute` (not available in MoneyMoney sandbox) |
| 3.59 | Update login endpoint to `/authen/loginAuthen.do` (bank update) |
| 3.58 | Initial public release: login, account list, transaction fetch |

## Contributing

Bug reports and pull requests are welcome. If the bank changes its login flow or API (which happens occasionally), please open an issue with the MoneyMoney log output — that makes it much easier to diagnose.

To test changes locally, copy the `.lua` file into the Extensions folder and reload extensions in MoneyMoney.

## Disclaimer

This extension is an independent community project and is **not affiliated with, endorsed by, or supported by Kasikorn Bank** or the MoneyMoney developers. Use at your own risk. Credentials are handled solely by MoneyMoney's built-in secure storage and are never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
