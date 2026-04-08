# MoneyMoney Extension – {{BANK_NAME}}

A [MoneyMoney](https://moneymoney-app.com) extension for **{{BANK_NAME}} ({{BANK_SHORT}}) {{COUNTRY}}** via the [{{PORTAL_NAME}}]({{PORTAL_URL}}) web portal. Fetches account balances and transactions for personal and business accounts.

---

## Features

- Supports **{{ACCOUNT_TYPES}}** accounts in {{CURRENCY}}
- Fetches up to **{{MAX_HISTORY}} days** of transaction history
- **No 2FA / SMS OTP required** — authenticates directly via session token
- {{EXTRA_FEATURE_1}}
- {{EXTRA_FEATURE_2}}

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS (any recent version)
- A **{{PORTAL_NAME}}** account at {{BANK_NAME}}
- Your **{{PORTAL_NAME}} username** and **password**

> **Note:** {{ACCESS_NOTE}}

## Installation

### Option A — Direct download

1. Download [`{{EXTENSION_FILE}}`]({{EXTENSION_FILE}})
2. Move it into MoneyMoney's Extensions folder:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```
3. In MoneyMoney, go to **Help → Show Database in Finder** if you need to locate the folder.
4. Reload extensions in MoneyMoney: right-click any account → **Reload Extensions** (or restart the app).

### Option B — Clone the repository

```bash
git clone https://github.com/davyd15/{{REPO_NAME}}.git
cp {{REPO_NAME}}/{{EXTENSION_FILE}} \
  ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/
```

## Setup in MoneyMoney

1. Open MoneyMoney and add a new account: **File → Add Account…**
2. Search for **"{{BANK_NAME}}"** or **"{{BANK_SHORT}}"**
3. Select **{{MONEYMONEY_SERVICE_NAME}}**
4. Enter your **{{PORTAL_NAME}} username** and **password**
5. Click **Next** — MoneyMoney will connect and import your accounts

## Supported Account Types

| Type | Description |
|------|-------------|
| {{ACCOUNT_TYPE_1}} | {{ACCOUNT_TYPE_1_DESC}} |
| {{ACCOUNT_TYPE_2}} | {{ACCOUNT_TYPE_2_DESC}} |

## Limitations

- **{{CURRENCY}} only** — foreign currency accounts are not supported
- **Max {{MAX_HISTORY}} days** history per refresh (portal limitation)
- {{OTHER_LIMITATION}}

## Troubleshooting

**"Login failed" / credentials rejected**
- Make sure you are using your **{{PORTAL_NAME}} credentials**, not {{OTHER_PORTAL}} credentials
- Try logging in at [{{PORTAL_URL}}]({{PORTAL_URL}}) in your browser to verify your credentials

**Extension not appearing in MoneyMoney**
- Confirm the `.lua` file is in the correct Extensions folder (see Installation above)
- Reload extensions or restart MoneyMoney

**Transactions missing / history too short**
- The portal limits history to {{MAX_HISTORY}} days. Older transactions cannot be retrieved.

## Changelog

| Version | Changes |
|---------|---------|
| {{CURRENT_VERSION}} | Initial public release |

## Contributing

Bug reports and pull requests are welcome. If the bank changes its login flow or API, please open an issue with the MoneyMoney log output — that makes it much easier to diagnose.

To test changes locally, copy the `.lua` file into the Extensions folder and reload extensions in MoneyMoney.

## Disclaimer

This extension is an independent community project and is **not affiliated with, endorsed by, or supported by {{BANK_NAME}}** or the MoneyMoney developers. Use at your own risk. Credentials are handled solely by MoneyMoney's built-in secure storage and are never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
