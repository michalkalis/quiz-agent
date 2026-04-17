# CarQuiz — TestFlight CI/CD Runbook

Postup na jednorazový setup. Potom už Claude (alebo ty) bude vedieť kedykoľvek spustiť `gh workflow run ios-release.yml` a build pôjde do TestFlight.

> **Poznámka k názvu súboru:** runbook je mimo `fastlane/` adresára, lebo fastlane pri každom behu prepisuje `fastlane/README.md` svojou auto-generovanou dokumentáciou. Tento súbor je v bezpečí.

**Bezpečnostný model v skratke:**
- Distribučný certifikát a provisioning profile sú **šifrované (AES-256)** v privátnom git repe `carquiz-certs`.
- Dešifrovanie potrebuje `MATCH_PASSWORD` (len v GitHub Secrets).
- Apple prístup ide cez **App Store Connect API Key** (.p8) — nie cez Apple ID + heslo.
- Na CI runneri sa všetky credentials píšu len do `$RUNNER_TEMP` a do dočasného keychainu, ktorý sa **vždy** vymaže v `always()` cleanup kroku.
- Lokálne ti na disku nič necertifikované nezostane — match importuje do dočasného keychainu aj pri bootstrape.

---

## Prerekvizity

- Apple Developer Program (Organization) — ✅ máš
- GitHub repo `quiz-agent` — ✅ máš
- `gh` CLI prihlásené — over `gh auth status`
- **Ruby 3.3+** na lokálny bootstrap. System Ruby na tvojom Macu je 2.6 — nestačí. Nainštaluj:
  ```bash
  brew install ruby@3.3
  echo 'export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"' >> ~/.zshrc
  exec zsh
  ruby --version   # musí byť 3.3.x
  gem install bundler
  ```

---

## Časť A — App Store Connect: registrácia appky + API kľúč

### A1. Zaregistruj Bundle ID

> **Rozhodnuté:** bundle ID je **`com.missinghue.hangs`**, app name **`hangs`**. Xcode projekt a folder stále nesú názov `CarQuiz` (to premenujeme neskôr, nezávislé od TestFlightu).

1. https://developer.apple.com/account/resources/identifiers/list
2. **+** → App IDs → Continue → App → Continue.
3. Description: `hangs`
4. Bundle ID: **Explicit** → `com.missinghue.hangs`
5. Capabilities: zatiaľ nič extra — Background Modes sa rieši v Info.plist.
6. Continue → Register.

### A2. Vytvor appku v App Store Connect

1. https://appstoreconnect.apple.com/apps
2. **+** → New App → iOS.
3. Name: **`hangs`** (alebo čo si vybral — zobrazuje sa v TestFlighte)
4. Primary Language: English (U.S.)
5. Bundle ID: vyber z dropdownu
6. SKU: `carquiz-ios` (interné, ľubovoľné)
7. User Access: Full Access → Create.

### A3. Vytvor App Store Connect API kľúč

1. https://appstoreconnect.apple.com/access/integrations/api
2. Tab **Team Keys**.
3. **Generate API Key** (prvýkrát odsúhlas agreement).
4. Name: `CarQuiz CI`
5. Access: **App Manager** (least privilege — stačí na certs + TestFlight upload).
6. Generate.
7. **Ihneď** stiahni `.p8` (`AuthKey_XXXXXXXXXX.p8`). **Apple ti ho dá len raz.**
8. Z riadka si skopíruj **Key ID** (10 znakov) + **Issuer ID** (UUID hore).

### A4. Ulož si `.p8` bezpečne

- 1Password / Keychain Access ako secure note.
- Druhá kópia na USB v trezore.
- **Nikdy** necommituj .p8 — `.gitignore` to blokuje.

---

## Časť B — Privátny repo pre certifikáty

### B1. Vytvor prázdny privátny repo

```bash
gh repo create carquiz-certs --private --description "Encrypted iOS distribution certs for CarQuiz/hangs. Do NOT make public."
```

Transfer na firemný org kedykoľvek neskôr — match si iba zapamätá novú `MATCH_GIT_URL`.

### B2. Dedicovaný SSH deploy key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/carquiz_match_deploy -N "" -C "carquiz-match-deploy"
```

Vytvoria sa:
- `~/.ssh/carquiz_match_deploy` (private — pôjde do GitHub Secrets)
- `~/.ssh/carquiz_match_deploy.pub` (public — pôjde do repo settings)

### B3. Pridaj public key ako Deploy Key

```bash
gh repo deploy-key add ~/.ssh/carquiz_match_deploy.pub \
  --repo <tvoj-github-username>/carquiz-certs \
  --title "GitHub Actions CI" \
  --allow-write
```

Po bootstrape môžeš cez GitHub UI zrušiť write access: Settings → Deploy keys → edit → odškrtni "Allow write access".

---

## Časť C — Jednorazový lokálny bootstrap

### C1. Vygeneruj match password

```bash
openssl rand -base64 32
```

Ulož si ho do 1Password ako "CarQuiz MATCH_PASSWORD".

### C2. Priprav lokálny `fastlane/.env`

> Fastlane natívne auto-loaduje `fastlane/.env` a `fastlane/.env.default`. Súbor je gitignorovaný.

```bash
cd apps/ios-app/CarQuiz/fastlane
cp .env.example .env
# Edituj .env a vyplň hodnoty z A3 + B + C1.
# MATCH_READONLY=false  ← pre bootstrap
```

Obsah `.p8` musí byť kompletný, vrátane BEGIN/END, multi-line medzi úvodzovkami:

```bash
ASC_API_KEY_CONTENT="-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM...<obsah>...
-----END PRIVATE KEY-----"
```

### C3. Nainštaluj Ruby deps

```bash
cd apps/ios-app/CarQuiz
bundle install
```

### C4. Bootstrap

```bash
cd apps/ios-app/CarQuiz
bundle exec fastlane ios bootstrap_certs
```

Čo sa stane:
1. Match sa prihlási cez ASC API.
2. Skontroluje `carquiz-certs` — je prázdny.
3. Cez ASC API vytvorí Apple Distribution cert + App Store profile.
4. Zašifruje cez `MATCH_PASSWORD` a pushne do `carquiz-certs`.
5. Dešifruje a importuje lokálne (aby si vedel robiť archive aj lokálne).

### C5. Sanity check

```bash
MATCH_READONLY=true bundle exec fastlane ios verify_setup
```

`Match read OK.` = môžeš ísť na CI.

---

## Časť D — GitHub Secrets

```bash
cd /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent

gh secret set ASC_API_KEY_ID --body "ABC1234DEF"
gh secret set ASC_API_ISSUER_ID --body "69a6de7f-0000-0000-0000-000000000000"
gh secret set ASC_API_KEY_CONTENT < ~/Downloads/AuthKey_ABC1234DEF.p8
gh secret set MATCH_GIT_URL --body "git@github.com:<tvoj-username>/carquiz-certs.git"
gh secret set MATCH_PASSWORD --body "<paste z 1Password>"
gh secret set MATCH_DEPLOY_KEY < ~/.ssh/carquiz_match_deploy
gh secret set KEYCHAIN_PASSWORD --body "$(openssl rand -base64 24)"

gh secret list   # overenie — 7 secrets
```

---

## Časť E — Prvý release build

```bash
gh workflow run ios-release.yml
gh run watch
```

Po ~10-15 min je build v TestFlighte, po ďalších ~5-10 min je dostupný na inštaláciu.

---

## Poznámka k premenovaniu projektu

Bundle ID je už `com.missinghue.hangs` vo všetkých configoch (commitnuté 2026-04-17). Ostatné názvy (`CarQuiz/` folder, `CarQuiz.xcodeproj`, schemes `CarQuiz-Local/Prod`, Sentry project) sú zatiaľ nezmenené — je to čisto kozmetika, dá sa to spraviť kedykoľvek neskôr bez dopadu na TestFlight. Keď budeš chcieť full rename, stačí povedať.

---

## Troubleshooting

| Chyba | Príčina | Riešenie |
|---|---|---|
| `Missing environment variable(s)` v bootstrap lane | `fastlane/.env` chýba alebo má iný názov | Musí to byť presne `fastlane/.env` (bez prípony). Over `ls -la apps/ios-app/CarQuiz/fastlane/.env` |
| `No code signing identity found` | Match nenahral cert do keychainu | Skontroluj `MATCH_DEPLOY_KEY` — SSH k repu musí fungovať |
| `Invalid JWT token` | ASC API kľúč revoknutý alebo zle zadaný | Over Key ID a Issuer ID, skontroluj že `.p8` má BEGIN/END riadky |
| `Couldn't find bundle identifier 'X' on App Store Connect` | Bundle ID v ASC nezhodne s Fastfile | Uisti sa že bundle ID v ASC je identický s `app_identifier` v Appfile |
| `Build already exists` | Build number konflikt | Fastfile rieši automaticky cez `latest_testflight_build_number + 1` |
| `fastlane finished with errors` hneď na `ensure_env_vars` | `.env` nenájdený | viď 1. riadok |

---

## Rotácia secrets

Raz ročne alebo pri podozrení z úniku:
1. **ASC API kľúč** — ASC → Revoke starý, vytvor nový, update 3 secrets.
2. **MATCH_PASSWORD** — `bundle exec fastlane match change_password`, update secret.
3. **SSH deploy key** — nový `ssh-keygen`, update deploy key + secret.

## Ak uniknú certy

```bash
bundle exec fastlane ios nuke_certs   # zadaj "NUKE" pre potvrdenie
```

Potom vymaž obsah `carquiz-certs` repa a spusti `bootstrap_certs` znova. Existujúce TestFlight buildy zostanú funkčné — revoke platí len pre nové buildy.

## Presun `carquiz-certs` na firemný org neskôr

1. GitHub UI → repo → Settings → Transfer ownership.
2. Nový deploy key pre nový repo.
3. Update `MATCH_GIT_URL` secret v `quiz-agent`.
