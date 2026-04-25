---
name: render-ops
description: |
  Operate the Render-deployed Symphony harness from the laptop. Use the
  `render` CLI (already logged in) — not the REST API.
---

# Operating the Render harness

The Symphony harness runs as a Render web service. The `render` CLI is installed locally and logged in to the workspace that owns it. Default to the CLI for every Render operation; reach for the REST API only if a needed endpoint isn't exposed there.

## Identity

- **Workspace**: `Nick's workspace` (`tea-d7ldknbeo5us73didg4g`), owner `nick@surgehq.ai`.
- **Service name**: `symphony-harness`
- **Service ID**: `srv-d7legdgg4nts73ctj9lg`
- **Public URL**: `https://symphony-harness-8vrr.onrender.com/` — dashboard requires basic auth (`DASHBOARD_USER` / `DASHBOARD_PASSWORD` env vars on the service).

Confirm CLI session is the right one before any destructive action: `render workspace current -o text` should print `Active Workspace: Nick's workspace (tea-d7ldknbeo5us73didg4g)`.

## Common operations

```bash
# List services in the active workspace
render services -o text

# Trigger a manual deploy (e.g. to pick up a config change in the cloned target repo)
render deploys create srv-d7legdgg4nts73ctj9lg -o text

# Trigger and wait for completion (non-zero exit on failure)
render deploys create srv-d7legdgg4nts73ctj9lg --wait -o text

# Recent deploys
render deploys list srv-d7legdgg4nts73ctj9lg -o text | head

# Tail container logs
render logs -r srv-d7legdgg4nts73ctj9lg --tail -o text

# One-shot log query (text search across recent stdout)
render logs -r srv-d7legdgg4nts73ctj9lg --text "OOMKilled" --limit 50 -o text

# Per-instance logs (instance ID comes from `render services instances`)
render services instances srv-d7legdgg4nts73ctj9lg -o text
```

## When to redeploy vs wait

The harness clones `WORKFLOW.md` and the target repo at boot, so config changes in the *product* repo (`nth-prediction-market-viewer`) only take effect after a container restart. The harness OOM-cycles roughly hourly under current load, so most config edits land naturally on the next OOM. Trigger a manual `render deploys create` only when the new value is urgent or the OOM cadence has stabilized.

Changes to the *harness* repo (this one — Dockerfile, render.yaml, entrypoint.sh) auto-deploy because `autoSync: true` in `render.yaml`. Don't manually redeploy unless a push didn't trigger one.

## Operator credentials

`RENDER_API_KEY` lives at `~/.surge-creds` (operator-only, mode 0600). It's NOT in `.devcontainer/.env` because that file is slurped wholesale by `docker --env-file` into the harness's container env (and from there into every Codex agent). Source the creds file only when something specifically needs the REST API: `set -a; . ~/.surge-creds; set +a`.

The CLI auth lives in `~/.config/render/` (or wherever `render login` stashes it on macOS) — separate from the API key, so the CLI keeps working even if the API key is missing.

## See also

- `~/code/symphony/render.yaml` — Blueprint definition (plan, build filter, env vars)
- `~/code/symphony/.devcontainer/Dockerfile` — image used by the service
- `~/code/symphony/render/entrypoint.sh` — boot script (Postgres start, smoke tests, Symphony launch)
