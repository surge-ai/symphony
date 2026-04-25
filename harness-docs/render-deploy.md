# Deploying the harness to Render

Run Symphony 24/7 on Render instead of on a laptop, while keeping your
ChatGPT Team billing by copying the Codex OAuth tokens onto a persistent
disk. Single replica, single disk — the same Dockerfile the devcontainer
uses.

## What you'll end up with

- One Render **web service** (`symphony-harness`) running the baked
  `./bin/symphony` escript.
- A 10 GB **persistent disk** at `/data` holding:
  - `/data/codex` — OAuth tokens + session rollouts (symlinked to `~/.codex`).
  - `/data/workspaces` — per-issue workspace clones (symlinked to `~/code/symphony-workspaces`).
  - `/data/target` — shallow clone of the target repo; `git fetch`/reset on each boot.
  - `/data/log` — Symphony's structured logs.
- Dashboard logs via the Render UI; the optional Phoenix UI at `:4000` is
  not exposed (workers can't publish ports).

## Prereqs

- Homebrew's `render` CLI: `brew install render`, then `render login`.
- On your laptop: `codex login` has already run and `~/.codex/auth.json`
  exists. That's the ChatGPT Team session we'll copy onto Render.
- Tokens for: Linear, OpenAI API (fallback), GitHub (bot), Vercel.

## One-time setup

### 1. Export the ChatGPT auth

```sh
./scripts/export-codex-auth.sh | pbcopy
```

The script reads `~/.codex/auth.json` and base64-encodes it to the clipboard.
This is a long-lived credential — don't commit it or paste it anywhere but
Render's secret-value field.

### 2. Create the service from the Blueprint

**Via the CLI** (recommended for reproducibility):

```sh
render blueprint launch
```

Pick this repo. Render reads `render.yaml`, prompts for any `sync: false`
env vars, and creates the service + disk.

**Or via dashboard**: New + → Blueprint → point at `surge-ai/symphony-harness`.

### 3. Set the secrets

Render will prompt for five secret env vars. Paste each:

| Key                      | Where to get it                                        |
|--------------------------|--------------------------------------------------------|
| `LINEAR_API_KEY`         | Linear → Settings → Security & access → Personal API keys |
| `OPENAI_API_KEY`         | OpenAI platform → API keys (fallback only; see below)  |
| `GH_TOKEN`               | `gh auth token` on your laptop                         |
| `VERCEL_TOKEN`           | Vercel → Account → Tokens                              |
| `CODEX_AUTH_JSON_B64`    | The clipboard contents from step 1                     |

`OPENAI_API_KEY` is a fallback — primary Codex auth comes from
`CODEX_AUTH_JSON_B64`, which bills against ChatGPT Team. If the OAuth
tokens ever fail to refresh, Codex will fall through to the API key.

### 4. Deploy and verify

Render builds the image (5–8 min first time; cached thereafter), mounts
the disk, runs `/render/entrypoint.sh`. On first boot the entrypoint seeds
`/data/codex/auth.json` from the env var, clones the target repo, and
starts Symphony.

Watch the log:

```sh
render logs -s symphony-harness -f
```

You should see Symphony's status block appear. File a Linear ticket in the
target project → it should show up in the log within ~5 s.

## Day-to-day

- **Logs**: `render logs -s symphony-harness -f` or the dashboard.
- **Redeploy on env change**: dashboard → Manual Deploy. (Env changes
  don't auto-restart the running container.)
- **Bump Symphony version**: edit `SYMPHONY_REF` in
  `.devcontainer/Dockerfile`, push to `main`, Render auto-deploys.
- **Rotate a secret**: update the value on Render → redeploy. Don't purge
  the disk unless you also want a fresh `auth.json` — the existing one
  will stay put.

## ChatGPT auth lifecycle

Codex refreshes the OAuth access token on its own schedule (roughly every
28 days) and writes the result back to `auth.json`. Because `auth.json`
lives on the persistent disk, the refresh survives restarts. Under normal
operation the seed value of `CODEX_AUTH_JSON_B64` is **only used once**.

If refresh ever fails (session revoked, refresh token expired, ChatGPT
account change):

1. Re-run `codex login` on your laptop.
2. `./scripts/export-codex-auth.sh | pbcopy`.
3. Update `CODEX_AUTH_JSON_B64` on Render with the new value.
4. Shell into the service (`render ssh symphony-harness`) and
   `rm /data/codex/auth.json` so the entrypoint re-seeds on restart.
5. Manual Deploy → Restart.

## Things you can't do and shouldn't try

- **More than one replica.** Symphony's dispatch/retry state is in-memory;
  a second copy will double-claim Linear issues. Render also won't let a
  service with a persistent disk scale past one, which happens to be the
  right guardrail here.
- **Expose the Phoenix dashboard.** Render workers don't publish ports. If
  you want the dashboard, change the service `type` to `private_service`
  in `render.yaml` and gate it with auth you trust. Symphony is explicitly
  preview software with no built-in auth on that dashboard.
- **Commit anything from `/data`.** The target repo is checked out in
  there at runtime; it's not a source of truth. Edit the real repo on
  GitHub.

## Recreating the setup from scratch

1. `render services delete symphony-harness` (or dashboard).
2. Delete the `symphony-data` disk.
3. Re-run `render blueprint launch`.
4. Re-paste the five secrets.
5. First boot re-seeds `auth.json` from `CODEX_AUTH_JSON_B64`, re-clones
   the target repo, and picks up wherever Symphony left off — per-issue
   state lives in Linear, not in the harness. You lose: in-flight workspace
   filesystems (Codex handles the reset via the Rework flow), Symphony's
   own logs.

## Accessing the dashboard

The service fronts Symphony's Phoenix dashboard with nginx + HTTP basic
auth. Default user is `admin`; password is whatever you set in the
`DASHBOARD_PASSWORD` secret.

Public URL is whatever Render assigns (e.g.
`https://symphony-harness.onrender.com`). Visit it, plug in the creds.

To change the password, update the `DASHBOARD_PASSWORD` secret on Render
and redeploy — the entrypoint regenerates `/tmp/htpasswd` on every boot.

`/healthz` is exempt from auth so Render's health check works.
