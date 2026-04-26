# surge-deploy fork: architecture

Notes on the seams between this harness repo and the product repo it
operates on. Written for someone landing in `~/code/symphony` for the
first time and trying to figure out where to make a change.

## Two repos, one harness

There are two repos in play. They are not the same; do not edit them
interchangeably.

- **Harness** — `surge-ai/symphony`, this repo. Default working branch
  is `surge-deploy`. Contains the Phoenix LiveView dashboard, the Elixir
  orchestrator, the Render Dockerfile, and the boot script. It does not
  contain product code or product workflow definitions.
- **Target** — `surge-ai/nth-prediction-market-viewer` at
  `~/code/nth-prediction-market-viewer`. Contains the product app, the
  `WORKFLOW.md` that defines Symphony's ticket-state flow, and
  `.codex/skills/*` that define how Codex agents handle each phase.

`upstream` on this repo is `openai/symphony`. `surge-deploy` is our
fork's deployable branch — diverging commits are local Render config,
local skills under `.claude/skills/`, the local CLAUDE.md, and any
out-of-tree patches that we have not yet upstreamed.

## What runs in production reads from the target repo, not the harness

The single most important seam. At boot, `render/entrypoint.sh:344-349`
clones the target repo into `/data/target/`. Then
`render/entrypoint.sh:388-391` execs the Symphony binary against
`$TARGET_DIR/WORKFLOW.md`:

```bash
cd "$TARGET_DIR"
exec /home/vscode/symphony/elixir/bin/symphony \
    "$TARGET_DIR/WORKFLOW.md" \
    --logs-root "$LOG_DIR" ...
```

That means:

- The `WORKFLOW.md` and `.codex/skills/` that govern production behavior
  live in the **target repo**, not in this one.
- Editing `~/code/symphony/elixir/WORKFLOW.md` does nothing in production.
  That file is a sample used only by the harness's own test suite.
- To change Symphony's ticket-state flow, agent prompts, or Codex skills,
  you edit the target repo and either merge to `main` or override
  `TARGET_BRANCH` in the Render env vars.

## Runtime topology

```
Render container (autoSync from surge-deploy)
  └── render/entrypoint.sh
        ├── starts local Postgres on 127.0.0.1:5432 (NTHPMV-36)
        ├── clones TARGET_REPO_URL @ TARGET_BRANCH -> /data/target/
        ├── starts nginx on $PORT (basic-auth proxy -> Phoenix on :4000)
        └── execs elixir/bin/symphony /data/target/WORKFLOW.md
              ├── reads WORKFLOW.md front matter -> SymphonyElixir.Config
              ├── polls Linear every polling.interval_ms
              ├── per claimed ticket:
              │     ├── creates ~/code/symphony-workspaces/<ticket>/
              │     ├── clones target repo into the workspace
              │     └── runs Codex against that workspace
              └── per-ticket Codex agents read .codex/skills/* from
                  their own workspace clone (not from the harness)
```

`/data` is Render's persistent disk — Codex auth, agent workspaces, and
the local Postgres datadir all symlink onto it so they survive
container restarts (`render/entrypoint.sh:26-44`).

## Where to edit for what

| Change | Where |
| --- | --- |
| Ticket-state flow, agent role definitions, prompt template | target repo `WORKFLOW.md` |
| Per-phase agent skill (`code-review`, `qa`, `land`, etc.) | target repo `.codex/skills/<name>/SKILL.md` |
| Render service config (plan, env vars, build filter) | harness `render.yaml` |
| Container image (Codex install, browsers, Postgres) | harness `.devcontainer/Dockerfile` |
| Boot sequence (clone target, start pg, start nginx, exec Symphony) | harness `render/entrypoint.sh` |
| Linear polling, ticket claiming, retry/reconciliation | harness `elixir/lib/symphony_elixir/orchestrator.ex` |
| Workspace lifecycle, per-ticket clones | harness `elixir/lib/symphony_elixir/workspace.ex` |
| Codex spawning, app-server protocol | harness `elixir/lib/symphony_elixir/codex/` |
| Phoenix dashboard | harness `elixir/lib/symphony_elixir_web/` |
| Operating runbooks for me (Claude) | harness `.claude/skills/<name>/SKILL.md` |

## Two `.codex/skills/` directories — keep them straight

Both the harness and the target have skill directories, with
overlapping names but different consumers:

- **Target repo** `.codex/skills/*/SKILL.md` — read by **Codex** running
  inside a per-ticket workspace. These define how the production agent
  handles each ticket phase. Production behavior depends on this dir.
- **Harness repo** `.claude/skills/*/SKILL.md` — read by **Claude Code**
  running in `~/code/symphony` (i.e. me, when you're operating the
  harness from the laptop). These are runbooks for me, not for Codex.
  Production does not read them.

If you find yourself editing a skill in the harness repo and expecting
production behavior to change, you are in the wrong directory. Move to
the target repo.

## Deploy paths

- Harness changes (this repo): `git push origin surge-deploy` →
  Render auto-deploys via `autoSync: true` in `render.yaml`. Build
  filter at the top of `render.yaml` skips deploys for
  `.claude/**`, `docs/**`, and any `*.md`, so doc-only edits do not
  trigger a rebuild.
- Target changes (`nth-prediction-market-viewer`): merge to `main` and
  wait for the next harness OOM cycle (~hourly under load), or trigger
  `render deploys create srv-d7legdgg4nts73ctj9lg`. The harness re-clones
  the target on every boot (`entrypoint.sh:346-349`).
- Branch override: set `TARGET_BRANCH` in the Render env (dashboard) to
  test a target branch other than `main` without merging.

## Conventions

- Linear tickets that Codex can act on: state `Todo`, no `infra` label.
- Linear tickets that only the human operator can do (Render/Vercel/Neon
  dashboard work, harness Docker changes): label `infra`. The
  `file-linear-ticket` skill in `.claude/skills/` documents this.
- Operator credentials (Render API key, etc.) live in `~/.surge-creds`,
  mode 0600 — explicitly *not* in `.devcontainer/.env`, because that
  file is slurped wholesale into the harness container env and from
  there into every Codex agent.
- The harness CLAUDE.md says "don't write product code" with narrow
  exceptions for `WORKFLOW.md` and `.codex/skills/*` in the target
  repo. Treat that as load-bearing.
