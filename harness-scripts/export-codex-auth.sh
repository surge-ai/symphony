#!/usr/bin/env bash
#
# Emit ~/.codex/auth.json as a single-line base64 string suitable for
# pasting into Render's CODEX_AUTH_JSON_B64 secret.
#
# Usage:
#     ./scripts/export-codex-auth.sh | pbcopy
#
# The file contains your ChatGPT Team OAuth tokens — treat it like a
# long-lived credential. Do not commit or paste into chat.

set -euo pipefail

AUTH="${HOME}/.codex/auth.json"

if [ ! -f "$AUTH" ]; then
    cat >&2 <<EOF
No ChatGPT auth found at $AUTH.
Run \`codex login\` on this machine first.
EOF
    exit 1
fi

if base64 --version 2>/dev/null | grep -q 'GNU coreutils'; then
    base64 -w 0 "$AUTH"
else
    base64 -i "$AUTH" | tr -d '\n'
fi
