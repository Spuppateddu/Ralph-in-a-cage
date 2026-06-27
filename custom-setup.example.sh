#!/usr/bin/env bash
#
# TEMPLATE — copy to `custom-setup.sh` (gitignored) to install whatever extra
# tools your tasks need. This runs AT IMAGE BUILD TIME, as root, inside the
# container, after the base toolchain is already installed. Re-run on every
# `docker compose build`.
#
# Already installed in the base image (Ubuntu 24.04 — do NOT reinstall):
#   - PHP 8.3 (cli) + Laravel extensions (mbstring, xml, bcmath, intl, zip,
#     curl, mysql, gd, sqlite3) + Composer
#   - Node.js 20 + npm
#   - git, OpenSSH client, GitHub CLI (gh), jq, curl, unzip, cron
#   - MySQL client
#   - Claude Code (@anthropic-ai/claude-code) + OpenAI Codex (@openai/codex)
#
# Rules:
#   - This is for INSTALLING TOOLS only. Secrets/config go in `.env`.
#   - Keep it idempotent — it runs fresh on every build.
#   - Use `apt-get install -y --no-install-recommends ...` for system packages.
#
set -euo pipefail

echo ">> custom-setup.sh: installing extra tooling"

# ---- Example: extra system packages ----------------------------------------
# apt-get update && apt-get install -y --no-install-recommends \
#     imagemagick ripgrep \
#  && rm -rf /var/lib/apt/lists/*

# ---- Example: a Python runtime for scripts/tests ---------------------------
# apt-get update && apt-get install -y --no-install-recommends python3 python3-pip \
#  && rm -rf /var/lib/apt/lists/*

# ---- Example: a global npm tool --------------------------------------------
# npm install -g pnpm

# ---- Example: an extra PHP extension ---------------------------------------
# docker-php-ext-install gd

echo ">> custom-setup.sh: done"
