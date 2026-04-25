#!/usr/bin/env bash
set -euo pipefail

# Copy the read-only host SSH mount into a writable ~/.ssh so Symphony workspace
# hooks (git clone ...) can authenticate against GitHub.
if [ -d "$HOME/.ssh-host" ] && [ ! -d "$HOME/.ssh" ]; then
    mkdir -p "$HOME/.ssh"
    cp -R "$HOME/.ssh-host/"* "$HOME/.ssh/" 2>/dev/null || true
    chmod 700 "$HOME/.ssh"
    find "$HOME/.ssh" -type f -exec chmod 600 {} +
    ssh-keyscan -t rsa,ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

mkdir -p "$HOME/code/symphony-workspaces"

echo "harness ready. symphony escript at /home/vscode/symphony/elixir/bin/symphony"
