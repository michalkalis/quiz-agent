# Issue #8: Workflow & Architecture Research

## Status: DONE (2026-04-03)

## Research topics
- Best practices for Claude Code + iOS development
- MVVM architecture patterns that prevent state bugs (like "suchy bodliak")
- Testing strategies for voice-first apps
- How to validate question quality in the pipeline before serving
- Tools for mobile app state machine visualization
- How to prevent translation-related data corruption

## Deliverable
Research report with actionable recommendations for the quiz-agent project.

## Result
Full report: [`docs/research/architecture-workflow-research.md`](../research/architecture-workflow-research.md)

### Key Outcomes
- **14 prioritized action items** ranging from 30-minute quick wins to multi-day refactors
- **P0 (immediate):** Add state transition validation to QuizState enum + cancel-all-tasks pattern
- **P1 (this week):** Mermaid state diagram, ViewModel unit tests, translation caching, XcodeBuildMCP
- **P2 (next sprint):** Consolidate enum state, verification pipeline, pre-translate at generation time
- **P3 (backlog):** TCA evaluation, audio test corpus, source backfill
