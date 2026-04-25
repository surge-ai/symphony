#!/usr/bin/env bash
# Wrapper around @playwright/mcp that restores PLAYWRIGHT_BROWSERS_PATH.
#
# The Dockerfile sets `ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` so the
# image-install step puts chromium there. But `codex app-server` spawns
# MCP subprocesses with a scrubbed env that drops the var. Without it,
# @playwright/mcp falls back to looking at ~/.cache/ms-playwright — which
# is empty on Render — and surfaces the result as the misleading
# `Browser "chrome-for-testing" is not installed` error.
#
# Re-exporting the var here, right before exec'ing the MCP, is a narrow
# fix: it only affects the MCP process and its children, not Codex itself.

set -e

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"
exec npx -y @playwright/mcp@latest "$@"
