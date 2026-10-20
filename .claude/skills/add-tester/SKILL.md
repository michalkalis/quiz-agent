---
name: add-tester
description: Add a new TestFlight tester (family+friends, Public beta or Founder group) through App Store Connect. Use when the founder asks to add a tester / „pridaj testera“ with an e-mail.
model: haiku
allowed-tools: Bash, AskUserQuestion
argument-hint: "<email> [group] [first name] [last name]"
---

# Add a TestFlight tester

Runs `.github/workflows/asc-add-tester.yml` (script `scripts/asc_add_tester.py`). Groups and flow: `docs/setup/release-flow.md`. The founder asking for a tester = consent to write to App Store Connect for that person.

## 1. Inputs

- **email** (required) — the tester's Apple ID e-mail.
- **group** — if not given, ask once: `family+friends` (close people, builds without Apple review) or `Public beta` (strangers, builds after Apple beta review). `Founder` only on explicit request.
- **first / last name** — optional; derive from the e-mail if obvious (martin.kalis → Martin Kalis), else leave empty.

## 2. Dry run, then apply

```bash
gh workflow run asc-add-tester.yml -f email="$EMAIL" -f first_name="$FIRST" -f last_name="$LAST" -f group="$GROUP"
sleep 5; RUN=$(gh run list --workflow asc-add-tester.yml -L1 --json databaseId -q '.[0].databaseId'); gh run watch "$RUN" --exit-status >/dev/null; gh run view "$RUN" --log | grep -E "DRY RUN|APPLY|POST|done:|invited:|pending:|!!"
```

If the dry run looks right, repeat with `-f apply=true`. The repo is public: e-mail and names are masked in logs (`***`), never paste them into PRs/issues.

## 3. Read the result line

| Line | Meaning | Tell the founder |
|---|---|---|
| `done: added to <group>` | tester in the group, Apple e-mails the TestFlight invite | install TestFlight, accept the e-mail; builds come when the group gets them (`promote`) |
| `invited:` | internal group, person had no App Store Connect access yet; invitation sent | they accept the App Store Connect e-mail (signing in with their Apple ID), then rerun this skill to finish |
| `pending:` | invitation still not accepted | same as above, ping the tester |
| `done: already a tester` | nothing to do | — |
| `!! 403` on `/userInvitations` | API key lacks Admin role | founder does steps 1–2 of „Pridanie blízkeho testera“ in `docs/setup/release-flow.md` manually, then rerun |

The tester gets builds only once a build is in their group: Founder automatically, others on the founder's command (`asc-store-upload.yml -f steps=promote`). Offer to add the latest build if the founder wants them testing now.
