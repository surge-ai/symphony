FROM elixir:1.19.5-otp-28

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git \
        curl \
        ca-certificates \
        build-essential \
        inotify-tools \
        sudo \
        jq \
        openssh-client \
        nginx \
        apache2-utils \
        gettext-base \
        postgresql \
        postgresql-contrib \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (Codex's workflow needs `gh pr create`, label, etc.).
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @openai/codex@0.125.0 vercel

# Playwright + chromium for Codex's @playwright/mcp MCP server.
# `playwright install --with-deps chromium` runs `apt install` internally for
# all of chromium's required system libs, then downloads the browser binary.
# Needs world-writable mode: at runtime, @playwright/mcp creates a
# per-session profile dir at ${PLAYWRIGHT_BROWSERS_PATH}/mcp-<channel>-<hash>
# (see browserFactory.js::createUserDataDir), and the container runs as the
# unprivileged vscode user. `chmod a+rX` (no write) breaks this with EACCES;
# the MCP surfaces the failure as the misleading 'Browser "chrome-for-testing"
# is not installed' message. a+rwX fixes it.
# The `chrome-for-testing` channel is just an alias for chromium in the
# Playwright registry (chromiumAliases in registry/index.js) — the bundled
# chromium-N binary is the executable that actually gets launched, so no
# separate install-browser step is needed.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright @playwright/mcp \
    && playwright install --with-deps chromium \
    && chmod -R a+rwX /ms-playwright

RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m -s /bin/bash $USERNAME \
    && echo "$USERNAME ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

USER $USERNAME
WORKDIR /home/$USERNAME
RUN mix local.hex --force && mix local.rebar --force

# Symphony source lives in this repo (this is the surge-ai/symphony fork).
# Copy the elixir tree directly instead of cloning + patching at build time.
USER root
COPY --chown=$USERNAME:$USERNAME elixir /home/$USERNAME/symphony/elixir
USER $USERNAME
WORKDIR /home/$USERNAME/symphony/elixir
RUN mix deps.get && mix escript.build

# Render entrypoint + nginx template for cloud deployment. Harmless for the
# devcontainer.
USER root
COPY --chmod=0755 render/entrypoint.sh /render/entrypoint.sh
COPY --chmod=0755 render/playwright-mcp.sh /render/playwright-mcp.sh
COPY render/nginx.conf.template /render/nginx.conf.template
USER $USERNAME

WORKDIR /home/$USERNAME
