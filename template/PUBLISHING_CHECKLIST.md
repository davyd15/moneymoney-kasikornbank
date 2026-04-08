# GitHub Publishing Checklist – MoneyMoney Extension

Use this checklist every time you publish a new extension.

## 1. Fill in the README template

Replace all `{{PLACEHOLDERS}}` in `template/README.md`:

| Placeholder | Example (KasikornBank) |
|-------------|------------------------|
| `{{BANK_NAME}}` | Kasikorn Bank |
| `{{BANK_SHORT}}` | KBank |
| `{{COUNTRY}}` | Thailand |
| `{{PORTAL_NAME}}` | K BIZ Online Banking |
| `{{PORTAL_URL}}` | https://kbiz.kasikornbank.com |
| `{{EXTENSION_FILE}}` | KasikornBank.lua |
| `{{REPO_NAME}}` | moneymoney-kasikornbank |
| `{{MONEYMONEY_SERVICE_NAME}}` | Kasikorn Bank (KBiz) |
| `{{ACCOUNT_TYPES}}` | Current (CA), Savings (SA), Fixed Deposit (FD) |
| `{{CURRENCY}}` | THB |
| `{{MAX_HISTORY}}` | 180 |
| `{{CURRENT_VERSION}}` | 3.65 |
| `{{ACCESS_NOTE}}` | Both personal and business customers can use K BIZ... |
| `{{OTHER_PORTAL}}` | K PLUS |

## 2. Clean up git history before pushing

The Claude Code hook creates `Auto:` commits on every save. Squash them:

```bash
# Find the last real commit (before all the Auto: ones)
git log --oneline

# Soft-reset to it (keeps all changes staged)
git reset --soft <last-real-sha>

# Commit in logical units
git add ExtensionName.lua
git commit -m "feat: initial implementation (v1.0)"

git add README.md LICENSE .gitignore
git commit -m "chore: add README, LICENSE, and .gitignore for public release"
```

If CLAUDE.md ended up tracked: remove it first.
```bash
git rm --cached CLAUDE.md
git commit -m "chore: remove internal CLAUDE.md from version control"
```

All commit messages must be in **English** and follow Conventional Commits:
`fix:` `feat:` `refactor:` `chore:` `docs:`

## 3. Create the GitHub repository

```bash
# Get token from keychain
TOKEN=$(git credential fill <<'EOF'
protocol=https
host=github.com
EOF
grep ^password | cut -d= -f2)

# Create repo
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/repos \
  -d '{
    "name": "moneymoney-BANKNAME",
    "description": "MoneyMoney extension for BANK – PORTAL",
    "homepage": "https://github.com/davyd15/moneymoney-BANKNAME",
    "private": false,
    "has_issues": true,
    "has_projects": false,
    "has_wiki": false
  }'

# Set topics
curl -s -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/davyd15/moneymoney-BANKNAME/topics \
  -d '{"names":["moneymoney","lua","banking","extension","COUNTRY","BANKNAME"]}'
```

## 4. Push

```bash
git remote add origin https://github.com/davyd15/moneymoney-BANKNAME.git
git push -u origin main
```

## 5. Tag and create release

```bash
git tag vX.XX
git push origin vX.XX

curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/davyd15/moneymoney-BANKNAME/releases \
  -d '{
    "tag_name": "vX.XX",
    "name": "vX.XX",
    "body": "### Whats new\n\n- ...\n\n### Installation\n\n1. Download `ExtensionName.lua` below\n2. Move to MoneyMoney Extensions folder\n3. Reload extensions in MoneyMoney",
    "draft": false,
    "prerelease": false,
    "make_latest": "true"
  }'
```

## 6. Final checks

- [ ] README has no unfilled `{{PLACEHOLDERS}}`
- [ ] Clone URL in README matches actual repo name
- [ ] All commit messages in English
- [ ] No `Auto:` commits in history
- [ ] No CLAUDE.md or `.claude/` in repository
- [ ] License year and name correct
- [ ] GitHub release published (not just a tag)
- [ ] Topics set on repository
- [ ] Homepage URL set to GitHub repo (not bank website)
