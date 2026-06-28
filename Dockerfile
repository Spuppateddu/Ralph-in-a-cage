# Ralph runner image — Ubuntu base with everything the loop needs:
# git + SSH, two coding agents (Claude Code + OpenAI Codex), and the toolchains
# for the supported project technologies (Laravel: PHP+Composer, Next.js: Node).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    NODE_MAJOR=20 \
    TZ=UTC

# --- Base system ------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release software-properties-common \
        git openssh-client jq cron unzip zip procps tzdata locales \
        default-mysql-client \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# --- PHP + Laravel extensions + Composer (Laravel support) ------------------
# PHP comes from the ondrej/php PPA so any version is available. Default 8.4
# (current stable; covers projects whose composer.lock needs >=8.4). Override for
# an older project with:  docker compose build --build-arg PHP_VERSION=8.3
ARG PHP_VERSION=8.4
RUN add-apt-repository -y ppa:ondrej/php \
    && apt-get update && apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml \
        php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-zip \
        php${PHP_VERSION}-curl php${PHP_VERSION}-mysql php${PHP_VERSION}-gd \
        php${PHP_VERSION}-sqlite3 \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://getcomposer.org/installer | php -- \
        --install-dir=/usr/local/bin --filename=composer

# --- Node.js 20 (Next.js support) -------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI (PR creation) -----------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Coding agents ----------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code @openai/codex

# --- Per-machine custom installs (optional, gitignored) ---------------------
# The wildcard also matches the committed custom-setup.example.sh, so the build
# works whether or not a real custom-setup.sh exists. See README.
COPY custom-setup*.sh /tmp/custom/
RUN if [ -f /tmp/custom/custom-setup.sh ]; then \
        echo ">> Running custom-setup.sh" && bash /tmp/custom/custom-setup.sh; \
    else echo ">> No custom-setup.sh; skipping custom installs"; fi \
    && rm -rf /tmp/custom

# --- Runner scripts ---------------------------------------------------------
COPY scripts/ /scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /scripts/*.sh \
    && mkdir -p /var/log/ralph /workspace /root/.ssh \
    && chmod 700 /root/.ssh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
