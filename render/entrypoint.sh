#!/usr/bin/env bash
#
# Entrypoint for Symphony Harness on Render.
# (Rev 2026-05-17 — forced restart: orchestrator looked dead while nginx kept /healthz green.)
#
# Expects, in Render's env:
#   - LINEAR_API_KEY, OPENAI_API_KEY, GH_TOKEN, VERCEL_TOKEN   (secrets)
#   - CODEX_AUTH_JSON_B64      (first boot only; seeds ChatGPT Team OAuth)
#   - TARGET_REPO_URL          (HTTPS URL of the target repo)
#   - TARGET_BRANCH            (default: main)
#   - SYMPHONY_DATA_DIR        (default: /data; points at persistent disk)
#
# What it does, idempotently:
#   1. Symlinks ~/.codex, ~/code/symphony-workspaces, and logs onto the
#      persistent disk so state survives restarts.
#   2. Seeds ~/.codex/auth.json from CODEX_AUTH_JSON_B64 on a fresh disk.
#   3. Clones or fast-forwards the target repo.
#   4. Execs Symphony against the target's WORKFLOW.md.

set -euo pipefail

log() { printf '[render-entrypoint] %s\n' "$*" >&2; }

DATA_DIR="${SYMPHONY_DATA_DIR:-/data}"
mkdir -p "$DATA_DIR"

# ---- 1. Persistent-disk symlinks ---------------------------------------------

CODEX_PERSIST="$DATA_DIR/codex"
mkdir -p "$CODEX_PERSIST"
if [ ! -L "$HOME/.codex" ]; then
    rm -rf "$HOME/.codex"
    ln -sfn "$CODEX_PERSIST" "$HOME/.codex"
fi

WORKSPACES_PERSIST="$DATA_DIR/workspaces"
mkdir -p "$WORKSPACES_PERSIST"
mkdir -p "$HOME/code"
if [ ! -L "$HOME/code/symphony-workspaces" ]; then
    rm -rf "$HOME/code/symphony-workspaces"
    ln -sfn "$WORKSPACES_PERSIST" "$HOME/code/symphony-workspaces"
fi

LOG_DIR="$DATA_DIR/log"
mkdir -p "$LOG_DIR"

TARGET_DIR="$DATA_DIR/target"

# ---- 1b. Local Postgres ------------------------------------------------------
#
# NTHPMV-36. The target app's `lib/live-market-data.ts` is gated on
# POSTGRES_URL / POSTGRES_URL_NON_POOLING / DATABASE_URL; without any of those,
# the Postgres-backed history cache is skipped and we only exercise the
# in-memory fallback. That's a weaker test surface than production, where
# Neon is attached. Ship a local Postgres inside the harness so Codex's
# `npm run dev` loop exercises the real cache path.

PG_DATA="$DATA_DIR/postgres"
PG_SOCKET_DIR="$DATA_DIR/postgres-sock"
PG_LOG="$LOG_DIR/postgres.log"
# Debian postgres installs binaries under /usr/lib/postgresql/<version>/bin
# and does NOT add them to PATH. Resolve the highest installed version here.
PG_BIN="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
if [ -n "$PG_BIN" ]; then
    export PATH="$PG_BIN:$PATH"
fi

mkdir -p "$PG_DATA" "$PG_SOCKET_DIR"
# Postgres rejects the data dir unless it's 0700 or 0750. Render's persistent
# disk default is 0755, so set it explicitly on every boot — `mkdir -p` won't
# tighten permissions on an existing dir, and an old initdb-from-755 dir
# would still trip the check on subsequent boots.
chmod 0700 "$PG_DATA"

# First-boot init. The persistent disk is empty on the first deploy, and we
# want data to survive container restarts after that.
if [ ! -s "$PG_DATA/PG_VERSION" ]; then
    log "initdb -D $PG_DATA (first-boot Postgres)"
    # --auth=trust is safe because Postgres only listens on 127.0.0.1 + unix
    # socket, both inside the single container. Nothing external can reach it.
    # locale=C.UTF-8 avoids the `sh: locale: command not found` noise.
    initdb -D "$PG_DATA" -U postgres --auth=trust --locale=C.UTF-8 --encoding=UTF8 >> "$PG_LOG" 2>&1
fi

# Clean up stale lockfile from a previous container that didn't shut down
# cleanly. Render terminates containers with SIGKILL after a grace window,
# so postmaster.pid + shared-memory segments can be left behind even though
# no postgres process is actually running. pg_ctl detects the pid file and
# refuses to start. Solution: if postmaster.pid points at a PID that isn't
# running, remove it before pg_ctl tries.
PG_PID_FILE="$PG_DATA/postmaster.pid"
if [ -f "$PG_PID_FILE" ]; then
    stale_pid=$(head -1 "$PG_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$stale_pid" ] && ! kill -0 "$stale_pid" 2>/dev/null; then
        log "removing stale $PG_PID_FILE (pid=$stale_pid is not running)"
        rm -f "$PG_PID_FILE"
        # pg also leaves shared-memory segments; clean those up too.
        rm -f "$PG_DATA"/postmaster.opts 2>/dev/null || true
    fi
fi

# Start Postgres if it isn't running. `pg_ctl status` returns 3 when there's
# no PID file, 0 when up, 4 when there's a pid but it can't connect — treat
# anything non-zero as "not running, start it". Don't `set -e`-fail the
# whole entrypoint if pg_ctl trips — log it and continue so Symphony still
# comes up and the dashboard is reachable for diagnosis.
if ! pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
    log "pg_ctl start -D $PG_DATA (listen 127.0.0.1:5432, socket $PG_SOCKET_DIR)"
    if ! pg_ctl -D "$PG_DATA" -l "$PG_LOG" \
            -o "-h 127.0.0.1 -p 5432 -k $PG_SOCKET_DIR" \
            -w start; then
        log "WARN: pg_ctl start failed; recent log:"
        tail -20 "$PG_LOG" 2>/dev/null | while read -r line; do log "  pg: $line"; done || true
        log "WARN: continuing without postgres — app will fall back to in-memory cache"
    fi
fi

# Trap SIGTERM/SIGINT to stop pg gracefully on container shutdown so the
# next boot doesn't have to clean up stale state.
cleanup_pg() {
    if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
        log "stopping postgres (entrypoint exiting)"
        pg_ctl -D "$PG_DATA" -m fast stop >/dev/null 2>&1 || true
    fi
}
trap 'cleanup_pg' EXIT

# Create the app database if it doesn't exist. Idempotent — `createdb` exits 1
# if it already exists, which we swallow. Skip the whole block if pg never
# started (otherwise we'd cascade "connection refused" log noise).
if pg_ctl -D "$PG_DATA" status >/dev/null 2>&1; then
    if ! psql -h 127.0.0.1 -U postgres -lqt | cut -d '|' -f1 | grep -qw prediction_market; then
        log "createdb prediction_market"
        createdb -h 127.0.0.1 -U postgres prediction_market
    fi
else
    log "skipping createdb — pg not running"
fi

# Export the URL for Symphony, Codex, and their children. shell_environment_policy
# in the Codex config.toml is set to `all` so these propagate into the
# `npm run dev` shells the agent spawns.
export POSTGRES_URL="postgresql://postgres@127.0.0.1:5432/prediction_market"
export POSTGRES_URL_NON_POOLING="$POSTGRES_URL"
export DATABASE_URL="$POSTGRES_URL"

# End-to-end connectivity probe: connect as the same vscode user a Codex
# `bash -c "npm run dev"` shell would, with the same POSTGRES_URL. Logs both
# success and failure so we can read it back from Render's stdout pipeline.
log "===== postgres diagnostic ====="
log "POSTGRES_URL=$POSTGRES_URL"
pg_probe_out="$(psql "$POSTGRES_URL" -tAc "SELECT current_database() || ' / ' || current_user" 2>&1)"
pg_probe_rc=$?
log "  psql: $pg_probe_out"
if [ $pg_probe_rc -eq 0 ]; then
    log "postgres-connect: PASS"
else
    log "postgres-connect: FAIL (psql exit $pg_probe_rc)"
fi
# Prove write privileges with a throwaway table.
pg_write_out="$(psql "$POSTGRES_URL" -tAc "CREATE TABLE IF NOT EXISTS _harness_probe (ts timestamptz DEFAULT now()); INSERT INTO _harness_probe DEFAULT VALUES RETURNING ts; DROP TABLE _harness_probe" 2>&1 | tail -1)"
pg_write_rc=$?
log "  probe: $pg_write_out"
if [ $pg_write_rc -eq 0 ]; then
    log "postgres-write: PASS"
else
    log "postgres-write: FAIL"
fi
# Snapshot whether any agent has actually written market_history_cache yet.
# It's created lazily by the app on first successful render that reaches the
# cache path. Until then it doesn't exist; once Codex's `npm run dev`
# exercises the path, this climbs.
# Trailing `|| true` is load-bearing: under `set -euo pipefail`, the pipeline
# fails when the table doesn't exist, the failure propagates through the $()
# substitution, and the whole script exits — taking nginx + Symphony with it.
mhc_count="$(psql "$POSTGRES_URL" -tAc "SELECT count(*) FROM market_history_cache" 2>/dev/null | tail -1 | tr -d ' ' || true)"
case "$mhc_count" in
    [0-9]*)
        log "market_history_cache rows: $mhc_count (>0 means Codex has written via npm run dev)"
        ;;
    *)
        log "market_history_cache: not created yet (Codex hasn't hit the cache path)"
        ;;
esac
log "================================="

# Symphony's persisted token + runtime totals (loaded on init by the
# patches/0001-persist-codex-totals.patch). Logging on every boot makes it
# obvious whether the persistence is working: this should be > 0 from the
# second boot onward (the first boot writes the file as agents run; later
# boots load it back).
log "===== symphony totals diagnostic ====="
SYMPHONY_TOTALS_FILE="${SYMPHONY_TOTALS_PATH:-$DATA_DIR/symphony/totals.json}"
if [ -f "$SYMPHONY_TOTALS_FILE" ]; then
    totals_contents="$(cat "$SYMPHONY_TOTALS_FILE" 2>/dev/null || echo '<read-failed>')"
    log "  $SYMPHONY_TOTALS_FILE: $totals_contents"
else
    log "  $SYMPHONY_TOTALS_FILE: not yet created (first boot OR no token deltas yet)"
fi
log "======================================"

# ---- 2. Seed codex auth on first boot ----------------------------------------

if [ ! -f "$CODEX_PERSIST/auth.json" ]; then
    if [ -z "${CODEX_AUTH_JSON_B64:-}" ]; then
        cat >&2 <<'EOF'
FATAL: no existing auth.json on the persistent disk and no
CODEX_AUTH_JSON_B64 env var to seed it from.

Generate the seed value on your laptop:

    ./scripts/export-codex-auth.sh | pbcopy

then paste it into Render's CODEX_AUTH_JSON_B64 secret and redeploy.
EOF
        exit 1
    fi
    log "seeding $CODEX_PERSIST/auth.json from CODEX_AUTH_JSON_B64"
    printf '%s' "$CODEX_AUTH_JSON_B64" | base64 -d > "$CODEX_PERSIST/auth.json"
    chmod 600 "$CODEX_PERSIST/auth.json"
fi

# Seed a minimal Codex config.toml if the persistent disk doesn't already have
# one. Without this, Codex has no MCP servers registered at all — our laptop
# picks up the user's config.toml via bind-mount, but Render's disk starts
# empty. The [features] rmcp_client line is required to enable the newer MCP
# client path that actually surfaces MCP tools to Codex turns.
# Always (re)write config.toml on boot. On Render the only thing that lives in
# it is harness config — users don't edit it by hand. If we skip the rewrite,
# an older seed without `--browser chromium` keeps the persistent disk stuck
# on Google-Chrome-not-found errors.
log "writing $CODEX_PERSIST/config.toml (Playwright MCP w/ chromium, gpt-5.5 xhigh)"
cat > "$CODEX_PERSIST/config.toml" <<'TOML'
# Managed by render/entrypoint.sh — this file is rewritten on every container
# boot. Edits made here will be lost on the next restart.

# Pin the latest-and-greatest model + max reasoning effort. xhigh costs more
# tokens per turn than high but the agent runs unattended on harness tickets,
# so slower/more-deliberate is the right tradeoff — rework cycles are more
# expensive than tokens.
model = "gpt-5.5"
model_reasoning_effort = "xhigh"

# Pass through the harness env (POSTGRES_URL, VERCEL_AUTOMATION_BYPASS_SECRET,
# etc.) to shells Codex spawns. Default is `core` which only keeps PATH/HOME.
[shell_environment_policy]
inherit = "all"

[features]
rmcp_client = true

[mcp_servers.playwright]
# /render/playwright-mcp.sh re-exports PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
# before exec'ing npx @playwright/mcp. `codex app-server` strips that env var
# when spawning MCP subprocesses; without the wrapper, MCP falls back to
# ~/.cache/ms-playwright and surfaces the missing-browser failure as the
# misleading 'Browser "chrome-for-testing" is not installed' error.
command = "/render/playwright-mcp.sh"
# `--browser chromium` points @playwright/mcp at the Chromium build we ship
# in the Docker image (via `playwright install --with-deps chromium`).
# Without this, the MCP defaults to looking for Google Chrome stable at
# /opt/google/chrome/chrome and fails to launch.
args = ["--browser", "chromium"]
TOML
chmod 600 "$CODEX_PERSIST/config.toml"

# Diagnostic dump so we can prove the container has the browser + perms.
# Symphony stdout is captured by Render's log pipeline.
log "===== playwright diagnostic ====="
log "whoami=$(whoami) uid=$(id -u) gid=$(id -g)"
log "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-unset}"
log "/ms-playwright perms:"
stat -c '  %a %U:%G %n' /ms-playwright 2>&1 | while read -r line; do log "$line"; done
ls -la /ms-playwright 2>&1 | head -10 | while read -r line; do log "$line"; done
# Can the runtime user write there?
if mkdir -p /ms-playwright/mcp-boot-probe 2>/dev/null; then
    log "mkdir-probe: OK (vscode CAN write to /ms-playwright)"
    rmdir /ms-playwright/mcp-boot-probe
else
    log "mkdir-probe: FAIL (EACCES — this is the bug, rebuild needed)"
fi

# End-to-end smoke test of @playwright/mcp, through the same wrapper
# Codex uses. Strip PLAYWRIGHT_BROWSERS_PATH from the test env so we
# exercise the exact code path Codex triggers (see the wrapper script's
# header for why Codex spawns without that var). If the wrapper's
# re-export works, this test passes; if it doesn't, this test fails
# loudly at boot so we catch it before the agent does.
log "mcp-smoke-test: starting (simulating codex's env-scrubbed spawn)"
mcp_smoke_log="$LOG_DIR/mcp-smoke.log"
{
    exec 3< <(
        echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"entrypoint-smoke","version":"1.0"}}}'
        sleep 1
        echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
        sleep 1
        echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_navigate","arguments":{"url":"https://example.com"}}}'
        sleep 4
    )
    env -u PLAYWRIGHT_BROWSERS_PATH timeout 60 /render/playwright-mcp.sh --browser chromium <&3 2>&1 || echo "SMOKE_EXIT=$?"
} > "$mcp_smoke_log" 2>&1 || true
if grep -q '"Page URL": "https://example.com' "$mcp_smoke_log" || grep -q 'Example Domain' "$mcp_smoke_log"; then
    log "mcp-smoke-test: PASS (MCP launched chromium and navigated via wrapper)"
elif grep -q 'is not installed' "$mcp_smoke_log"; then
    log "mcp-smoke-test: FAIL (wrapper did not restore PLAYWRIGHT_BROWSERS_PATH)"
    tail -20 "$mcp_smoke_log" | while read -r line; do log "  smoke: $line"; done
else
    log "mcp-smoke-test: INCONCLUSIVE"
    tail -10 "$mcp_smoke_log" | while read -r line; do log "  smoke: $line"; done
fi
log "=================================="

# ---- 3. Clone or refresh the target repo -------------------------------------

TARGET_REPO_URL="${TARGET_REPO_URL:?TARGET_REPO_URL must be set}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"

# Defensively trim whitespace from token-shaped env vars. Render's UI / API
# can save values with a stray trailing newline which breaks the git URL.
strip_ws() { printf '%s' "$1" | tr -d '[:space:]'; }
GH_TOKEN="$(strip_ws "${GH_TOKEN:-}")"
LINEAR_API_KEY="$(strip_ws "${LINEAR_API_KEY:-}")"
VERCEL_TOKEN="$(strip_ws "${VERCEL_TOKEN:-}")"
OPENAI_API_KEY="$(strip_ws "${OPENAI_API_KEY:-}")"
export GH_TOKEN LINEAR_API_KEY VERCEL_TOKEN OPENAI_API_KEY

# Rewrite HTTPS GitHub URLs to include the bot token so we can clone private
# repos without SSH. Non-GitHub or non-HTTPS URLs are used as-is.
case "$TARGET_REPO_URL" in
    https://github.com/*)
        if [ -z "${GH_TOKEN:-}" ]; then
            log "FATAL: GH_TOKEN must be set to clone an HTTPS GitHub repo"
            exit 1
        fi
        CLONE_URL="https://x-access-token:${GH_TOKEN}@${TARGET_REPO_URL#https://}"
        ;;
    *)
        CLONE_URL="$TARGET_REPO_URL"
        ;;
esac

if [ ! -d "$TARGET_DIR/.git" ]; then
    log "cloning $TARGET_REPO_URL @ $TARGET_BRANCH -> $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    git clone --branch "$TARGET_BRANCH" "$CLONE_URL" "$TARGET_DIR"
else
    log "refreshing $TARGET_DIR from $TARGET_REPO_URL @ $TARGET_BRANCH"
    git -C "$TARGET_DIR" remote set-url origin "$CLONE_URL"
    git -C "$TARGET_DIR" fetch --depth 100 origin "$TARGET_BRANCH"
    git -C "$TARGET_DIR" reset --hard "origin/$TARGET_BRANCH"
fi

# ---- 4. Start nginx (basic-auth proxy) in front of the Phoenix dashboard ----
#
# Render web_services must bind to $PORT. Phoenix stays on the internal
# UPSTREAM_PORT; nginx fronts it with basic auth sourced from the
# DASHBOARD_USER / DASHBOARD_PASSWORD env. If the env vars are missing we
# still start nginx but lock everyone out — so we log loudly instead.

if [ -n "${PORT:-}" ]; then
    UPSTREAM_PORT=4000
    DASHBOARD_USER="${DASHBOARD_USER:-admin}"
    if [ -z "${DASHBOARD_PASSWORD:-}" ]; then
        log "WARN: DASHBOARD_PASSWORD not set; dashboard will reject all auth."
        DASHBOARD_PASSWORD="$(head -c 24 /dev/urandom | base64)"
    fi

    # htpasswd (bcrypt cost 10) at /tmp/htpasswd
    htpasswd -bcB /tmp/htpasswd "$DASHBOARD_USER" "$DASHBOARD_PASSWORD"

    export PORT UPSTREAM_PORT
    envsubst '$PORT $UPSTREAM_PORT' \
        < /render/nginx.conf.template > /tmp/nginx.conf

    log "starting nginx on :$PORT -> Phoenix on :$UPSTREAM_PORT (basic auth on)"
    # Run nginx as the unprivileged vscode user — Render's no_new_privs flag
    # blocks sudo, and our nginx.conf.template keeps every writable path under
    # /tmp so no elevated permissions are needed.
    nginx -c /tmp/nginx.conf &
    NGINX_PID=$!

    # If nginx dies, tear down the container — Render restart handles recovery.
    # Combine with the pg cleanup trap set earlier so both run on shutdown.
    trap 'log "entrypoint shutting down"; kill $NGINX_PID 2>/dev/null || true; cleanup_pg' EXIT
fi

# ---- 5. Run Symphony (foreground; keeps the container alive) -----------------

cd "$TARGET_DIR"
log "starting Symphony against $TARGET_DIR/WORKFLOW.md"
exec /home/vscode/symphony/elixir/bin/symphony \
    "$TARGET_DIR/WORKFLOW.md" \
    --logs-root "$LOG_DIR" \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails
