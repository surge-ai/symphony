---
name: file-linear-ticket
description: |
  Conventions for filing new Linear tickets in this project. Default new
  tickets to `Todo` so Symphony picks them up; reserve `Backlog` for
  explicitly deferred work that's blocked.
---

# Filing new Linear tickets

When creating a new Linear ticket via `mcp__plugin_linear_linear__save_issue`, set `state: "Todo"` by default. Linear's API defaults new issues to Backlog, but Symphony's poll loop only claims tickets from `active_states` (Todo, In Progress, Merging, Rework). A Backlog ticket sits invisible to Symphony until a human moves it.

## When to use Todo vs Backlog

- **Todo** (default) — anything I want Symphony's Codex agents to start on. Ticket appears in the queue, gets claimed within `polling.interval_ms` (5 s in our config).
- **Backlog** — only when the ticket is explicitly deferred. Combine with `blockedBy` so the prerequisite is recorded:
  ```
  state: omitted (so it lands in Backlog)
  blockedBy: ["NTHPMV-50"]
  ```
  Re-prompts that mention "file this for later" or "to be done after Y" → Backlog with blockedBy. Everything else → Todo.

## Other conventions in this project

- **Apply the `infra` label** when the ticket is harness/dashboard work that Codex agents can't perform (Dockerfile changes in `symphony-harness`, Render config, Vercel/Neon dashboard tweaks, monitoring setup). Symphony's NTHPMV-51 patch will eventually filter labeled tickets out of the agent queue, but in the meantime the label tells the human reader who's going to do the work.
- **Acceptance criteria + verification** — every ticket should be specific enough that a fresh agent can know when it's done and produce evidence. Mirror the structure: bullet list of acceptance criteria, then "How to reproduce" + "How to verify" sections. The .codex/skills/linear/SKILL.md in the product repo has the canonical shape.
- **Inline screenshots** — for UI bugs, attach a screenshot via the `fileUpload` flow (see `.codex/skills/linear/SKILL.md` for the `Content-Type` PUT gotcha).

## Example

```ts
mcp__plugin_linear_linear__save_issue({
  team: "nth-prediction-market-viewer",
  title: "...",
  state: "Todo",                  // default
  priority: 2,
  labels: ["infra"],              // when applicable
  description: "...",
})
```
