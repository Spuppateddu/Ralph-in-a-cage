#!/usr/bin/env bash
#
# Container entrypoint: configure git/SSH/gh, then run the loop every 5 minutes
# via cron (PID 1). Agent logins + the SSH key come from persisted volumes and
# are set up once via /scripts/setup.sh.
#
set -uo pipefail

echo "[entrypoint] starting Ralph runner"

# --- Git identity + safety --------------------------------------------------
git config --global user.name  "${GIT_AUTHOR_NAME:-Ralph Bot}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-ralph-bot@users.noreply.github.com}"
git config --global --add safe.directory '*'
git config --global init.defaultBranch "${BASE_BRANCH:-master}"

# --- Trust github.com for SSH (no interactive prompt) -----------------------
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f /root/.ssh/known_hosts ] || ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null || true
fi

# --- gh uses GH_TOKEN from the environment for PR creation ------------------
if [ -z "${GH_TOKEN:-}" ]; then
    echo "[entrypoint] WARNING: GH_TOKEN not set — opening PRs will fail (push over SSH still works)"
fi

# --- Make env available to cron jobs ----------------------------------------
printenv | grep -vE '^(PWD|SHLVL|_|HOME)=' | sed 's/^/export /' > /scripts/runtime.env
chmod 600 /scripts/runtime.env

# --- Schedule the loop ------------------------------------------------------
# Frequency is configurable: CHECK_INTERVAL_MINUTES (default 5), or a full
# CRON_SCHEDULE for anything cron can express (e.g. "0 * * * *" hourly).
# loop.sh self-locks, so overlapping triggers never run two passes at once.
CRON_SCHEDULE="${CRON_SCHEDULE:-*/${CHECK_INTERVAL_MINUTES:-5} * * * *}"
mkdir -p /var/log/ralph
cat > /etc/cron.d/ralph <<CRON
${CRON_SCHEDULE} root /scripts/loop.sh >> /var/log/ralph/loop.log 2>&1
CRON
chmod 0644 /etc/cron.d/ralph
echo "[entrypoint] scheduled loop: '${CRON_SCHEDULE}'"

# First pass immediately (no-op until setup.sh has cloned repos).
/scripts/loop.sh >> /var/log/ralph/loop.log 2>&1 || true

touch /var/log/ralph/loop.log
tail -F /var/log/ralph/loop.log &
exec cron -f
