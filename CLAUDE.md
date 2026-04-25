# Operating rules when Claude Code runs in this dir

This is the Symphony harness fork (`surge-ai/symphony`, branched as `surge-deploy`). It deploys to Render and orchestrates Codex agents that work on Linear tickets in the `nth-prediction-market-viewer` product repo.

## Don't write product code

The target project (`~/code/nth-prediction-market-viewer`) is maintained by Symphony + Codex through the Linear workflow. Claude Code's job here is **orchestration, not implementation**:

- Manage Linear tickets, manage the harness itself, merge PRs, diagnose blockers.
- Read the target repo to understand state, but don't edit app code, copy, tests, or product config there.
- If a gap is found in the target project, file or refine a Linear ticket. Don't "just fix it" inline.

Narrow exceptions, always confirm first:
- `WORKFLOW.md` and `.codex/skills/*` in the target repo are Symphony-facing config — fair game.
- Urgent unblockers the user explicitly asks Claude to patch.

## Skills (the source of truth for procedures)

- `.claude/skills/render-ops` — operating the Render-deployed harness via the `render` CLI.
- `.claude/skills/file-linear-ticket` — conventions for filing Linear tickets (default state, labels, structure).
- `.claude/skills/close-with-verification` — closing tickets I implement myself with traceable proof.
- `.claude/skills/playwright-mcp-debug` — diagnosing `@playwright/mcp` failures in the harness.

When a procedure has a skill, follow the skill rather than improvising.
