#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .devcontainer/.env ]; then
    echo "missing .devcontainer/.env — copy .devcontainer/.env.example and fill in LINEAR_API_KEY" >&2
    exit 1
fi

TARGET="${HOME}/code/nth-prediction-market-viewer"
if [ ! -f "$TARGET/WORKFLOW.md" ]; then
    echo "expected target repo at $TARGET with WORKFLOW.md" >&2
    exit 1
fi

# Pass the host's `gh` token into the container so Codex can open PRs, add
# labels, etc. macOS stores the token in the keychain, so we cannot just mount
# ~/.config/gh/ — we have to print-and-inject.
if command -v gh >/dev/null && GH_TOKEN_VALUE=$(gh auth token 2>/dev/null) && [ -n "$GH_TOKEN_VALUE" ]; then
    umask 077
    printf 'GH_TOKEN=%s\n' "$GH_TOKEN_VALUE" > .devcontainer/.env.local
else
    echo "warn: could not resolve a host \`gh auth token\` — Codex will not be able to open PRs" >&2
    : > .devcontainer/.env.local
fi

npx -y @devcontainers/cli up --workspace-folder .

# Kill any stale BEAM (Elixir runtime) from a previous run — devcontainer exec
# does not always forward SIGTERM into the container, so Symphony can outlive
# the host wrapper and keep holding port 4000.
npx -y @devcontainers/cli exec --workspace-folder . \
    bash -lc 'pkill -x beam.smp 2>/dev/null; sleep 0.5; exit 0'

exec npx -y @devcontainers/cli exec --workspace-folder . \
    bash -lc 'exec /home/vscode/symphony/elixir/bin/symphony /workspaces/target/WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails'
