# Ralph in a Cage 🦖🔒

A coding-agent **Ralph loop** kept in a cage. Every 5 minutes it pulls the latest
code, asks the Second Brain bot API for tasks flagged "can be done by a bot", lets
a coding agent (**Claude Code** or **OpenAI Codex**) implement each one, verifies
the result by running the project, and opens a pull request for you to review.

The "cage" is an **isolated Ubuntu Docker container** — the agent can edit your
cloned repos but can't touch the rest of your machine. This folder is safe to
commit: no secrets here. Credentials live in Docker volumes (agent logins + SSH
key, created by a one-time setup) and in a gitignored `.env`.

## How it works

Each 5-minute pass (cron + `flock`, never overlapping):

1. **Sync** — hard-reset every cloned repo to the latest `origin/<base>`.
2. **Fetch tasks** — `GET /api/v1/bot/{slug}/tasks` with the project's token.
   Tasks come back only while the project is **In progress** and are flagged
   `can_be_done_by_bot`.
3. **Claim** — atomically (two passes never grab the same task).
4. **Do it** — the chosen agent edits the repos (it doesn't touch git).
5. **Verify** — auto-detected per repo: Laravel ⇒ `composer install` + real MySQL
   migrate + `php artisan test`; Next.js ⇒ `npm ci` + lint + build.
6. **Settle** —
   - ✅ commit to the **day's branch** (`bot/YYYY-MM-DD`, reused all day), push
     over SSH, open one **PR → base branch** per repo, mark the task **done**
     (you get a push notification).
   - ❌ discard the changes and post the error as task **feedback**.

The bot **never pushes the base branch** — only the daily branch, via a PR.

## Supported technologies

Auto-detected per repo: **Laravel** (PHP + Composer) and **Next.js** (Node).
Add more by extending `scripts/detect.sh` and `scripts/verify.sh`.

## Setup

### 1. Host (one command)

```sh
cd ralph-runner
./install.sh          # installs Docker + Compose, adds you to the docker group, scaffolds .env
```

Log out/in (or `newgrp docker`) if it added you to the docker group. `install.sh`
only touches the host's Docker — it's idempotent.

### 2. Configure

```sh
nano .env                                   # API URL + token, DEFAULT_AGENT, GH_TOKEN, ...
cp config/repos.list.example config/repos.list
nano config/repos.list                      # one SSH clone URL per repo
```

In the Second Brain UI: open the project → **Bot API → Generate token**, copy it
into `PROJECT_TOKEN`, and set the project to **In progress**.

### 3. Build, start, and do the one-time in-container setup

```sh
docker compose build
docker compose up -d
docker compose exec -it runner /scripts/setup.sh
```

`setup.sh` walks you through, persisting everything to volumes:
1. **Generates an SSH key** and prints the public key — add it to GitHub
   (Settings → SSH and GPG keys).
2. **Logs you in** to Claude Code (Pro/Max) and OpenAI Codex.
3. **Clones** the repos from `config/repos.list`.
4. **Installs** each repo's dependencies.

Then it's live:

```sh
docker compose logs -f runner                 # watch the loop
docker compose exec runner /scripts/loop.sh   # trigger one pass now
```

Moving to another machine: copy the folder, recreate `.env` + `config/repos.list`,
`./install.sh`, `docker compose up -d`, and run `setup.sh` again (new SSH key +
logins for that machine).

## Configuration (`.env`)

| Variable | What it is |
| --- | --- |
| `PROJECT_API_BASE_URL` | Deployed backend URL (no trailing slash). For a backend on this host: `http://host.docker.internal:8000` |
| `PROJECT_SLUG` / `PROJECT_TOKEN` | The project's slug + bot token |
| `DEFAULT_AGENT` | `claude` or `codex` — which agent does the work |
| `BASE_BRANCH` | Branch to pull from / target PRs at (default `master`); never pushed to |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | Commit identity |
| `GH_TOKEN` | GitHub token (`repo` scope) — used only to open PRs (push uses SSH) |
| `DB_*` | MySQL settings for Laravel verification (defaults match the `db` service) |
| `CLAUDE_TIMEOUT` | Max seconds an agent may run on one task |

### Multiple projects

Leave `PROJECT_SLUG`/`PROJECT_TOKEN` empty and create `config/projects.list`
with `slug token [agent]` per line (the agent column overrides `DEFAULT_AGENT`
for that project). See `config/projects.list.example`.

## Customizing what's installed in the image

The base image has git + SSH, PHP 8.3 (+ Laravel extensions), Composer, Node 20,
GitHub CLI, `jq`, the MySQL client, and both agents (Claude Code + Codex).

Need more? Put install commands in **`custom-setup.sh`** (gitignored; template in
`custom-setup.example.sh`), then `docker compose build`. Rule of thumb:
**`custom-setup.sh` = what to install; `.env` = config; volumes = credentials.**

## Safety model

- Runs entirely in a container; the only host paths it sees are the read-only
  `config/` mount and Docker-managed volumes.
- Agents run fully autonomously (`--dangerously-skip-permissions` /
  `--dangerously-bypass-approvals-and-sandbox`) **because** they're sandboxed in
  the container — they can edit the cloned repos but nothing on your PC.
- Never force-pushes, never writes the base branch; all output is a PR you review.

## Operating

```sh
docker compose logs -f runner
docker compose exec runner cat /var/log/ralph/loop.log
docker compose down                 # stop (volumes, so logins/repos, persist)
docker compose build --no-cache     # rebuild after editing custom-setup.sh
```

Change the cadence by editing the cron line in `entrypoint.sh` (default
`*/5 * * * *`). Long passes are fine — `flock` makes the next tick skip while one
is running.

## Auto-start on every reboot

The services already use `restart: unless-stopped`, so once they're up they come
back automatically — **as long as the Docker daemon starts on boot**. Make that
true per OS:

### Linux (systemd)

Enable the Docker daemon at boot (once):

```sh
sudo systemctl enable --now docker
```

That plus the `restart: unless-stopped` policy is enough: after a reboot, Docker
starts and brings the runner + db back. (If you ever `docker compose down`, they
won't auto-start until you `up -d` again — that's what "unless-stopped" means.)

**Optional — guarantee `up -d` on every boot** (also recovers if a container was
removed). Create a systemd unit:

```sh
sudo tee /etc/systemd/system/ralph-in-a-cage.service >/dev/null <<EOF
[Unit]
Description=Ralph in a Cage
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$(pwd)
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ralph-in-a-cage.service
```

(Run from the `ralph-in-a-cage` folder so `WorkingDirectory` is captured. If your
user needs sudo for docker, that's fine — the unit runs as root.)

### macOS (Docker Desktop)

There's no headless Docker daemon on macOS — containers only run while **Docker
Desktop** is running. So:

1. Open **Docker Desktop → Settings (gear) → General**.
2. Enable **“Start Docker Desktop when you sign in”**.
3. Apply & restart.

On login, Docker Desktop launches and the `restart: unless-stopped` services come
back automatically. (Keep "auto-login" on for the macOS user account if the
machine should recover unattended after a power cycle.)
