---
name: playwright-mcp-debug
description: |
  Diagnose `@playwright/mcp` failures inside the Symphony harness. The
  classic symptom — `Browser "<channel>" is not installed` — is a
  red herring most of the time; this skill maps it back to the real
  underlying causes.
---

# Diagnosing `@playwright/mcp` failures in the harness

`@playwright/mcp`'s error message `Browser "<channel>" is not installed. Run \`npx @playwright/mcp install-browser <channel>\` to install` is misleading — it fires whenever Playwright's launch throws, and the launch throws for at least three reasons that are NOT "the binary is missing". Verified 2026-04-24 against the running harness on Render.

## The three failure modes that hide behind "not installed"

### 1. Codex `app-server` strips `PLAYWRIGHT_BROWSERS_PATH`

**Most common cause in this harness.** The Dockerfile sets `ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` so the image-install puts Chromium there. That env propagates to shells but NOT to MCP subprocesses spawned by `codex app-server`. The MCP defaults to `~/.cache/ms-playwright` (empty), the chromium binary isn't found, and the launch surfaces the misleading "not installed" message.

**Fix:** wrap the MCP command in a shell script that re-exports the var before `exec`'ing npx. In `~/.codex/config.toml`:

```toml
[mcp_servers.playwright]
command = "/render/playwright-mcp.sh"
args = ["--browser", "chromium"]
```

Where `/render/playwright-mcp.sh` is:

```bash
#!/usr/bin/env bash
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/ms-playwright}"
exec npx -y @playwright/mcp@latest "$@"
```

The harness ships this wrapper at `render/playwright-mcp.sh` and the boot-time smoke test simulates Codex's env scrub (`env -u PLAYWRIGHT_BROWSERS_PATH`) to keep the regression visible in entrypoint logs.

### 2. `PLAYWRIGHT_BROWSERS_PATH` is set but the dir isn't writable

The MCP creates a per-session profile at `$PLAYWRIGHT_BROWSERS_PATH/mcp-<channel>-<cwdHash>` (see `playwright-core/lib/tools/mcp/browserFactory.js::createUserDataDir`). If the process user can't `mkdir` there, the launch fails and the same "not installed" message fires.

**Fix:** `chmod -R a+rwX /ms-playwright` in the Dockerfile so the unprivileged container user can write.

### 3. A required system library is missing

Chromium on Linux has a long list of `.so` deps. If a library load fails, Playwright's launch throws `cannot open shared object file` which can degrade to the same "not installed" string. `playwright install --with-deps chromium` fixes this at image-build time by running the chromium dep install.

## Diagnostic workflow

1. Look at the boot-time `mcp-smoke-test:` line in the Render entrypoint logs. Use the `render-ops` skill: `render logs -r srv-d7legdgg4nts73ctj9lg --text "mcp-smoke-test" --limit 20 -o text`. PASS means the harness can launch chromium end-to-end through the wrapper. FAIL means re-check the wrapper + chmod + system-deps in that order.
2. Reproduce the agent's failure locally: `docker run --rm symphony-harness:<tag>` then run the MCP as the unprivileged `vscode` user (not root — root masks the EACCES path) with `env -u PLAYWRIGHT_BROWSERS_PATH /render/playwright-mcp.sh --browser chromium` to mimic Codex's env scrub.
3. If you see "not installed" and have reason to believe the binary IS installed (e.g. `ls /ms-playwright/chromium-*` shows it), do NOT run `install-browser`. It's a no-op for the `chrome-for-testing` channel — that channel is just a `chromiumAliases` entry mapping to the already-installed Chromium binary.

## See also

- `render/entrypoint.sh::mcp-smoke-test` — boot-time end-to-end probe
- `render/playwright-mcp.sh` — the wrapper that fixes #1
- `.devcontainer/Dockerfile` — the `chmod a+rwX` line that fixes #2
- NTHPMV-41 (Linear) — dogfood ticket that proved the chain works on Render
