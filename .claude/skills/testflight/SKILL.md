---
name: testflight
description: Trigger TestFlight release build via GitHub Actions (fastlane + match). Builds IPA, uploads to TestFlight.
model: haiku
allowed-tools: Bash
argument-hint: "[release notes — optional]"
---

# TestFlight Release

Triggers the `ios-release.yml` GitHub Actions workflow which:
1. Runs on `macos-26` with Xcode 26.3
2. Uses fastlane `match` (read-only) to import the distribution cert from `carquiz-certs` repo into an isolated keychain
3. Runs `fastlane ios beta` — archives, exports IPA, uploads to TestFlight
4. Auto-increments build number based on latest TestFlight build
5. Uploads IPA + dSYM as workflow artifacts (14-day retention) for Sentry symbolication

**Bundle ID:** `com.missinghue.hangs` · **App name in TestFlight:** `hangs`

## Prerequisites (one-time, already done)

Full setup runbook is in `apps/ios-app/Hangs/TESTFLIGHT_SETUP.md`. Seven GitHub secrets must exist: `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_CONTENT`, `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_DEPLOY_KEY`, `KEYCHAIN_PASSWORD`. If the workflow fails with a `Missing required secrets` error, see the runbook.

## Usage

### 1. Pre-flight — make sure main is pushed

The workflow builds from `main` on the remote. If there are unpushed commits, the TestFlight build won't include them.

```bash
git status
git log origin/main..HEAD --oneline   # must be empty
```

If there are unpushed commits, ask the user before pushing (per `feedback_commit_autonomy` memory: push needs explicit confirmation).

### 2. Trigger the workflow

```bash
gh workflow run ios-release.yml --ref main -f notes="<short release notes>"
```

Notes are optional. Keep them short — they show up in workflow run metadata, not in TestFlight itself.

### 3. Watch the run

```bash
# Get the run ID of the most recent release
gh run list --workflow=ios-release.yml --limit 1 --json databaseId,status,conclusion,headBranch

# Stream logs live (blocks until done, ~10–15 min)
gh run watch <run-id>

# Or poll status without blocking
gh run view <run-id> --json status,conclusion,jobs
```

**Typical timing:** ~10–15 min for build + upload. TestFlight then needs another ~5–10 min before the build is installable (Apple-side processing).

### 4. Handle failures

If the run fails, get the logs:

```bash
gh run view <run-id> --log-failed
```

Common failure modes (see `TESTFLIGHT_SETUP.md` troubleshooting table):

| Symptom | Likely cause |
|---|---|
| `Missing required secrets` | A GH secret is missing — re-run the `gh secret set` commands |
| `Invalid JWT token` | ASC API key revoked or `ASC_API_KEY_CONTENT` missing BEGIN/END lines |
| `No code signing identity found` | `MATCH_DEPLOY_KEY` SSH key can't reach `carquiz-certs` repo |
| `Build already exists` | Shouldn't happen — Fastfile auto-bumps via `latest_testflight_build_number + 1` |
| Xcode version mismatch | Runner's Xcode changed — check `Select Xcode 26.3` step logs |

Do NOT amend the failing commit or force-push. Diagnose, fix forward, push a new commit, re-trigger.

## Export compliance

Info.plist has `ITSAppUsesNonExemptEncryption = false` baked in — the app declares it uses only exempt encryption (HTTPS/TLS and Apple's system crypto frameworks; no custom crypto). Uploaded builds arrive in TestFlight as **"Ready to Submit"**, skipping the Missing Compliance prompt.

If a build ever shows **"Missing Compliance"** (e.g. the Info.plist key got lost):

```bash
cd apps/ios-app/Hangs
PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH" bundle exec fastlane ios set_compliance
```

This uses Spaceship ConnectAPI to PATCH `usesNonExemptEncryption=false` on the latest build. It's idempotent — no-op if already declared.

**Before running it, confirm the declaration is still accurate:** no custom crypto algorithms were added since last review (grep for `CommonCrypto`, `CryptoKit`, third-party crypto libs). If any custom encryption exists, the correct answer may be `true`, which requires a US government export compliance classification — stop and ask the user.

## Notes

- **Manual-only trigger.** No auto-release on push to main — releases are deliberate.
- **Concurrency group** `ios-release` prevents parallel runs (avoids match cert locks and build number races).
- **Keychain is isolated.** The workflow creates a temporary keychain and deletes it in `always()` cleanup — nothing leaks to the runner's login keychain.
- **Local builds still work.** After the one-time bootstrap, `bundle exec fastlane ios beta` works locally too, but prefer CI for consistency.
