# Issue 34 — Claude Code context/token optimization

**Triage:** infra · done

## Status (2026-05-07)

Tier 1 + Tier 2.2 + Tier 3.1/3.2/3.3 applied in this session. Tier 2.1 was a no-op — `~/.claude/skills/` did not exist; all quiz-agent skills were already project-scoped. Tier 3.4 (allowlist consolidation) intentionally deferred — cosmetic, no context impact.

Validation pending after session restart: measure new initial context size and confirm `< 28k` acceptance criterion.

## Problem

Pri otvorení novej Claude Code session sa initial context naplní na **~36k tokenov** ešte pred prvým toolcallom. To zvyšuje latency, zhoršuje cache hit rate a zžiera context window pre reálnu prácu.

## Diagnóza (zo session 2026-05-07)

Hlavní žráči pri starte:

| Sekcia | Odhad | Príčina |
|---|---|---|
| Skills listing (~50 zručností) | ~3–4k | Veľa user-level skillov je projektovo-špecifických pre quiz-agent |
| MCP "Instructions" bloky | ~3–5k | `context7`, `pencil`, `XcodeBuildMCP` — tri zo štyroch failujú connect, ale instructions sa stále loadujú |
| Deferred-tools list (~80 mien) | ~500–700 | XcodeBuildMCP sám má 50+ tools |
| `gitStatus` blok | ~500–800 | ~30 untracked súborov v `data/generated/`, `data/scored/`, `data/verification/` |
| CLAUDE.md + rules/shared.md + MEMORY.md | ~1.5–2k | OK, drobné |
| auto-memory inštrukcie | ~1.5k | systémové, nemenné |

`claude mcp list` výstup z 2026-05-07:
```
plugin:github:github   ✗ Failed to connect
XcodeBuildMCP          ✗ Failed to connect
pencil                 ✓ Connected
context7               ✗ Failed to connect
```

## Cieľ

Znížiť startup tokens z ~36k na **~22–28k** (úspora ~7.5–13k).

---

## Tier 1 — okamžité veľké úspory (~5–8k tokenov)

### 1.1 Cleanup nefunkčných MCP serverov ⏱ 10 min

**`apps/.../.mcp.json`** (project-level):
- [x] Odstrániť `context7` server (failuje, instructions sa stále loadujú). Použiť `WebFetch` alebo `Read` na docs namiesto toho.
- [x] Po odstránení overiť `claude mcp list` — má zostať len `pencil`.

**User-level MCP** (`~/.claude.json` alebo cez `claude mcp remove`):
- [x] **XcodeBuildMCP**: odstránené z user-scope (`claude mcp remove XcodeBuildMCP --scope user`). Pridať späť cez `claude mcp add` keď treba iOS UI automation.
- [x] **plugin:github (Copilot)**: vypnuté v `~/.claude/settings.json` (`github@claude-plugins-official: false`).

Príkazy:
```bash
claude mcp list                          # baseline
claude mcp remove XcodeBuildMCP          # ak je v user scope
# upraviť .mcp.json — odstrániť context7
claude mcp list                          # potvrdiť cleanup
```

### 1.2 Vypnúť rzridka používané pluginy ⏱ 5 min

V `~/.claude/settings.json` (user-level):
- [x] `github@claude-plugins-official: false` (failuje MCP connect, `gh` CLI funguje rovnako)
- [ ] `feature-dev@claude-plugins-official` — ponechané (môže sa hodiť); on/off podľa potreby
- [ ] `code-review@claude-plugins-official` — ponechané (môže sa hodiť); on/off podľa potreby

V `.claude/settings.json` (project-level):
- [x] `claude-md-management@claude-plugins-official: false` (používané raz za pár mesiacov; zapnúť on-demand)

> Každý zapnutý plugin pridáva svoje skills/agents do listingu zobrazeného pri starte.

---

## Tier 2 — stredný dopad (~2–4k tokenov)

### 2.1 Presun projektových skillov z user-scope do project-scope ⏱ 30 min

V `~/.claude/skills/` je 28 zručností; mnohé sú **iba pre quiz-agent**. Presunúť do `.claude/skills/` v repe.

**Presunúť do `.claude/skills/` (project):**
- [ ] `generate-questions/` — quiz-agent specific
- [ ] `verify-questions/` — quiz-agent specific
- [ ] `score-questions/` — quiz-agent specific
- [ ] `regression/` — quiz-agent specific (RS-01..RS-NN)
- [ ] `testflight/` — quiz-agent fastlane
- [ ] `check-crashes/` — quiz-agent Sentry
- [ ] `deploy/` — quiz-agent Fly.io
- [ ] `triage/` — quiz-agent docs/issues
- [ ] `to-prd/`, `write-prd/` — quiz-agent docs/product
- [ ] `catchup/`, `summarize/`, `todo/` — quiz-agent workflow
- [ ] `start-local/`, `test-backend/`, `test-ios/`, `build-ios/` — quiz-agent build/test
- [ ] `improve-codebase-architecture/`, `zoom-out/` — používa `CONTEXT.md` z quiz-agent
- [ ] `competitive-analysis/`, `user-stories/` — quiz-agent docs/product
- [ ] `verify-api/`, `review-ui/` — quiz-agent specific

**Ponechať v `~/.claude/skills/` (user/global):**
- `research`, `claude-api`, `best-practices`, `simplify`, `loop`, `schedule`, `init`, `review`, `security-review`, `update-config`, `keybindings-help`, `fewer-permission-prompts`

Postup:
```bash
cd /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent
mkdir -p .claude/skills
for skill in generate-questions verify-questions score-questions regression testflight \
             check-crashes deploy triage to-prd write-prd catchup summarize todo \
             start-local test-backend test-ios build-ios improve-codebase-architecture \
             zoom-out competitive-analysis user-stories verify-api review-ui; do
  if [ -d "$HOME/.claude/skills/$skill" ]; then
    mv "$HOME/.claude/skills/$skill" .claude/skills/
    echo "moved $skill"
  fi
done
git add .claude/skills
```

> Po presune: keď otvoríš _iný_ projekt, tieto skilly už nezaťažujú jeho context. V quiz-agent sa stále zobrazia (project-scope).

### 2.2 `.gitignore` pre data artefakty ⏱ 2 min

- [x] Pridať do `.gitignore`:
  ```
  data/generated/
  data/scored/
  data/verification/
  ```
- [x] Overiť `git status` — počet untracked klesol z ~40 na 15 (zostávajú legitímne nové issue/plánovacie súbory).

---

## Tier 3 — drobné upratovanie (~0.5–1k tokenov)

### 3.1 Zlúčiť alebo odstrániť `user-prompt-submit.sh` hook ⏱ 5 min

- [x] Súbor `.claude/hooks/user-prompt-submit.sh` zmazaný (duplikoval `session-start.sh`).
- [x] `UserPromptSubmit` blok odstránený z `.claude/settings.json`.

### 3.2 Trim MEMORY.md ⏱ 10 min

Aktuálny stav: 30 memory súborov, 589 riadkov spolu, MEMORY.md index 40 riadkov.

Akcie:
- [x] **Zmazané vyriešené:** `project_app_rename.md`, `project_chroma_update_bug.md`.
- [x] **Premiestnené do `.claude/rules/backend.md`:** `project_dockerfile_drift.md`, `project_prod_chroma_mount.md` (sekcia "Production Deployment Pitfalls").
- [x] MEMORY.md index aktualizovaný — 4 položky odstránené.

### 3.3 Zhustiť CLAUDE.md (83 → 60 riadkov) ⏱ 10 min

- [x] `Repository Structure` zhustená na jednu vetu.
- [x] `Workflow Skills` sekcia odstránená — duplikuje skills listing.
- [x] Výsledok: 60 riadkov.

### 3.4 Konsolidovať `settings.local.json` allowlist ⏱ 15 min

180+ entries, mnohé jednorazové (konkrétne SESSION_ID curl príkazy, /tmp paths).

- [ ] Konsolidovať na pattern-based:
  - `Bash(fly:*)` namiesto 8 fly variantov
  - `Bash(git:*)` namiesto 12 git variantov
  - `Bash(uv:*)` namiesto 5 uv variantov
- [ ] Zmazať jednorazové (`SESSION_ID="sess_9fb45fcc687b" ...`, `/tmp/fix_*.py`, atď.).

> Pozn.: allowlist nie je v context, ale veľký súbor môže ovplyvniť startup latency a údržbu.

---

## Validácia

Po každom tieri:
1. Reštartovať Claude Code session.
2. Spýtať sa Claude: "Aký je tvoj približný initial context size?" alebo skontrolovať cez `/cost` ak je dostupné.
3. Zmerať delta voči baseline 36k.

**Acceptance criteria:**
- [ ] Initial context < 28k tokenov.
- [ ] `claude mcp list` ukazuje 0 failujúcich serverov (alebo zámerne odstránených).
- [ ] `git status` má < 10 untracked entries v "default" stave.
- [ ] Skills listing pri starte v inom projekte (mimo quiz-agent) je výrazne kratší.

---

## Poradie spustenia (odporúčané)

1. **Najprv Tier 1.1 + 1.2** (najväčší dopad, malé riziko, ~15 min) — reštartovať session, zmerať.
2. **Potom Tier 2.2** (.gitignore, 2 min) + Tier 3.1 (hook, 5 min) + Tier 3.2 (memory trim, 10 min) — quick wins.
3. **Tier 2.1** (presun skillov) ako samostatný krok — najväčšia údržbová operácia, ale aj najväčší cross-project benefit.
4. **Tier 3.3 + 3.4** (CLAUDE.md, allowlist) — kosmetika, robiť keď je čas.

## Súvisiace súbory

- `~/.claude/settings.json` — user-level pluginy a MCP
- `.claude/settings.json` — project-level hooks a pluginy
- `.claude/settings.local.json` — permission allowlist
- `.mcp.json` — project MCP servers
- `~/.claude/skills/*/` — user skills (kandidáti na presun)
- `.claude/hooks/*.sh` — session-start, user-prompt-submit hooks
- `~/.claude/projects/-Users-michalkalis-Documents-personal-ai-developer-course-code-quiz-agent/memory/` — auto-memory
- `CLAUDE.md`, `.claude/rules/shared.md`

## Notes / open questions

- XcodeBuildMCP failure príčina nezistená — možno permission issue v sandbox alebo `npx` cache. Ak ho potrebujeme pre iOS UI automation neskôr, treba debug ako samostatný issue.
- Context7 môže byť užitočný pre lookup docs (React, FastAPI, atď.) — alternatíva je pridávať `WebFetch` domains do allowlistu pre konkrétne docs sites.
- Zvážiť: má `.claude/rules/shared.md` zostať auto-loaded? Aktuálne sa loaduje do contextu pri každom starte. Ak áno, drž ho minimal (~30 riadkov).
