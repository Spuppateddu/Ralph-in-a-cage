# Ralph in a Cage 🦖🔒

<p align="center">
  <img src="ralp_in_a_cage.png" alt="Ralph in a cage" width="520">
</p>

A coding-agent **Ralph loop** kept in a cage. On an interval you choose, it pulls
the latest code, asks a **task API** for tasks flagged "can be done by a bot", lets
a coding agent (**Claude Code** or **OpenAI Codex**) implement each one, verifies
the result by running the project, and opens a pull request for you to review.

The runner talks to a small HTTP **task API** (for projects, tasks, claiming, and
feedback) — the contract is documented in [Task API contract](#task-api-contract)
so you can point it at your own backend.

The "cage" is an **isolated Ubuntu Docker container** — the agent can edit your
cloned repos but can't touch the rest of your machine. This folder is safe to
commit: no secrets here. Credentials live in Docker volumes (agent logins + SSH
key, created by a one-time setup) and in a gitignored `.env`.

## How it works

Each pass (cron + `flock`, never overlapping) — the interval is yours to set:

1. **Sync** — hard-reset every cloned repo to the latest `origin/<base>`.
2. **Fetch tasks** — `GET /api/v1/bot/{slug}/tasks` with the project's token.
   Tasks come back only while the project is **In progress** and are flagged
   `can_be_done_by_bot`.
3. **Claim** — atomically (two passes never grab the same task).
4. **Do it** — the chosen agent edits the repos (it doesn't touch git).
5. **Verify** — auto-detected per repo: Laravel ⇒ `composer install` + real MySQL
   migrate + `php artisan test`; Next.js ⇒ `npm ci` + lint + build; Convex
   (Next.js + Convex.dev) ⇒ `npm ci` + `convex codegen` + lint + build.
6. **Settle** —
   - ✅ commit to the **day's branch** (`bot/YYYY-MM-DD`, reused all day), push
     over SSH, open one **PR → base branch** per repo, mark the task **done**
     (you get a push notification).
   - ❌ discard the changes and post the error as task **feedback**.

The bot **never pushes the base branch** — only the daily branch, via a PR.

## Task API contract

The runner is backend-agnostic: it only needs an HTTP API that speaks these four
endpoints. Build your own (any language/framework) and point `PROJECT_API_BASE_URL`
at it, or use a hosted one (see the bottom of this README).

All requests are authenticated with the project's bot token:
`Authorization: Bearer <PROJECT_TOKEN>`. `{slug}` is the project's `PROJECT_SLUG`,
`{id}` is a task id. Base path: `{PROJECT_API_BASE_URL}/api/v1/bot`.

| Method & path | Purpose | Notes |
| --- | --- | --- |
| `GET  /{slug}/tasks` | List workable tasks | Return **only** tasks for an **In progress** project that are flagged `can_be_done_by_bot`. The server does the filtering. |
| `POST /{slug}/tasks/{id}/claim` | Atomically claim a task | Return `200` if this caller got it, non-`200` if it's already taken. This is what keeps two passes from grabbing the same task. |
| `POST /{slug}/tasks/{id}/done` | Mark a task complete | Called after the PR is opened. |
| `POST /{slug}/tasks/{id}/feedback` | Attach a failure note | Body: `{"feedback": "<text>"}` (JSON). Used when the agent made no changes or verification failed. |

`GET /{slug}/tasks` returns JSON shaped like:

```json
{
  "tasks": [
    { "id": 123, "title": "Short task title", "description": "Full task details…" }
  ]
}
```

Only `id`, `title`, and `description` are read (`description` may be omitted). The
runner builds the agent's prompt from `title` + `description`.

## Supported technologies

Auto-detected per repo:

- **Laravel** (PHP + Composer) — `composer install` + real MySQL `migrate:fresh` + `php artisan test`.
- **Next.js** (Node) — `npm ci` + lint (changed files) + `next build`.
- **Convex** (Next.js + [Convex.dev](https://convex.dev)) — `npm ci` + `npx convex codegen` +
  lint (changed files) + `next build`. Detected when `package.json` has the `convex`
  dependency and a `convex/` directory. Verification is **offline**: `convex codegen`
  regenerates `convex/_generated/*` from the local `convex/` functions so the build can
  type-check, and a placeholder `NEXT_PUBLIC_CONVEX_URL` is injected — it never contacts a
  live Convex deployment.

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

First the machine-global `.env` (shared by every project):

```sh
nano .env          # ISOLATION_MODE, GH_TOKEN, GIT_AUTHOR_*, CHECK_INTERVAL_MINUTES, DB creds
```

Then **one directory per project** under `config/projects/`. Copy the committed
`example` template and fill it in:

```sh
cp -r config/projects/example config/projects/<your-project>
cd config/projects/<your-project>
cp project.env.example project.env          # slug, token, API URL, agent, BASE_BRANCH, DB_DATABASE
cp repos.list.example repos.list            # one SSH clone URL per repo, for THIS project
nano project.env repos.list
```

Each project gets its own runner container and its own `/workspace`. `project.env`
holds the per-project task-API `PROJECT_SLUG`/`PROJECT_TOKEN`, the agent, the
`BASE_BRANCH`, and a unique `DB_DATABASE` (the MySQL schema used for verification —
created on demand, so no manual db setup). In your task API: generate a bot token,
copy it into `PROJECT_TOKEN`, and set the project to **In progress** (the API only
returns tasks for in-progress projects). See [Task API contract](#task-api-contract).

**Per-repo verify env (required for Laravel repos).** A Laravel app boots during
`composer install`, so it needs valid config *before* the runner can write one —
otherwise install/verify fails. For each Laravel repo, create
`config/projects/<your-project>/env/<repo>.env` (the repo's directory name, i.e.
the clone URL's basename without `.git`) and fill in the app-specific bits the
runner can't infer (e.g. VAPID keys):

```sh
cp env/laravel-repo.env.example env/<repo>.env
nano env/<repo>.env                         # VAPID keys, mail=log, dummy 3rd-party keys
```

The runner overwrites `DB_*` to point at the cage MySQL (this project's
`DB_DATABASE`) and runs `key:generate`, so you only supply the disposable app
config. See `config/projects/example/env/README.md` for details. **Next.js** repos
need no file here. **Convex** repos optionally take an `env/<repo>.env` with
`NEXT_PUBLIC_CONVEX_URL` (else a placeholder is injected for the build).

### 3. Generate the stack, start, and do the one-time in-container setup

`scripts/gen-compose.sh` reads `config/projects/*` + `ISOLATION_MODE` and writes
`docker-compose.generated.yml` — one `runner-<project>` service per project (plus
a shared or per-project `db`). Re-run it whenever you add a project or change the
mode.

```sh
scripts/gen-compose.sh
docker compose -f docker-compose.generated.yml up -d
```

Then run the one-time setup **inside each project's container**:

```sh
docker compose -f docker-compose.generated.yml exec -it runner-<project> /scripts/setup.sh
```

`setup.sh` walks you through, persisting everything to volumes:
1. **Generates an SSH key** and prints the public key — add it to GitHub
   (Settings → SSH and GPG keys).
2. **Logs you in** to Claude Code (Pro/Max) and OpenAI Codex.
3. **Clones** the project's repos from its `repos.list`.
4. **Installs** each repo's dependencies.

In **`ISOLATION_MODE=shared`** (default) the SSH key + agent logins live in volumes
shared by every runner, so steps 1–2 only happen in the **first** container you run
`setup.sh` in; later containers detect the existing key/login and skip straight to
clone + install. In **`detached`** mode each project has its own credential volumes,
so you log in once per project.

Then it's live:

```sh
docker compose -f docker-compose.generated.yml logs -f runner-<project>          # watch the loop
docker compose -f docker-compose.generated.yml exec runner-<project> /scripts/loop.sh   # one pass now
```

## Replicating on another machine

A fresh `git clone` gives you the code but **none of the per-machine config or
credentials** — those are gitignored or live in Docker volumes by design. To
stand up an identical runner on a new host:

```sh
git clone git@github.com:Spuppateddu/Ralph-in-a-cage.git ralph-runner
cd ralph-runner
./install.sh                                  # Docker + Compose + docker group + .env scaffold
```

Then recreate every gitignored file (none of these come from the clone):

| File | From | Holds |
| --- | --- | --- |
| `.env` | `.env.example` (scaffolded by `install.sh`) | machine-global: `ISOLATION_MODE`, `GH_TOKEN`, `GIT_AUTHOR_*`, `CHECK_INTERVAL_MINUTES`, shared DB creds |
| `config/projects/<name>/project.env` | `config/projects/example/project.env.example` | per-project: `PROJECT_SLUG`/`PROJECT_TOKEN`, API URL, `DEFAULT_AGENT`, `BASE_BRANCH`, `DB_DATABASE` |
| `config/projects/<name>/repos.list` | `config/projects/example/repos.list.example` | one SSH clone URL per repo, for that project |
| `config/projects/<name>/env/<repo>.env` | `config/projects/example/env/*.example` | per-repo Laravel/Convex verify config (VAPID, Convex URL) — **required for Laravel repos** |
| `custom-setup.sh` | `custom-setup.example.sh` | *(optional)* extra packages baked into the image |

(`docker-compose.generated.yml` is regenerated by `scripts/gen-compose.sh`, not copied.)

The fastest way is to copy these files over from your existing machine (e.g.
`scp`), since they hold the exact same values. They contain secrets — transfer
them privately, don't commit them.

Then generate the stack, start, and do the one-time in-container setup —
credentials (SSH key, agent logins) and cloned repos live in volumes, so they must
be created **per machine**; they are *not* copied by `scp`:

```sh
scripts/gen-compose.sh
docker compose -f docker-compose.generated.yml up -d
# per project (in shared mode the first one creates the shared key + login):
docker compose -f docker-compose.generated.yml exec -it runner-<project> /scripts/setup.sh
```

`setup.sh` prints a **new** SSH public key for this machine — add it to GitHub
(Settings → SSH and GPG keys) and log into the agent again, because those secrets
are per-machine and never leave their volumes. Finally, enable auto-start on
reboot (see [Auto-start on every reboot](#auto-start-on-every-reboot)).

## Configuration

Config is split in two: **machine-global** values in `.env`, and **per-project**
values in each `config/projects/<name>/project.env` (which overrides `.env` for
that project's runner).

**Machine-global (`.env`):**

| Variable | What it is |
| --- | --- |
| `ISOLATION_MODE` | `shared` (default) or `detached` — see [Multiple projects](#multiple-projects) |
| `CHECK_INTERVAL_MINUTES` | How often to check for tasks (default `5`) |
| `CRON_SCHEDULE` | Optional full cron expression; overrides the interval (e.g. `0 * * * *` hourly) |
| `MAX_TASKS_PER_PASS` | Tasks worked per check: `1` (default) = one at a time; `0` = drain all |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | Commit identity |
| `GH_TOKEN` | GitHub token (`repo` scope) — used only to open PRs (push uses SSH) |
| `DB_HOST` / `DB_PORT` / `DB_USERNAME` / `DB_PASSWORD` | Shared MySQL server host + creds (the per-project schema is `DB_DATABASE` below) |
| `CLAUDE_TIMEOUT` | Max seconds an agent may run on one task |

**Per-project (`config/projects/<name>/project.env`):**

| Variable | What it is |
| --- | --- |
| `PROJECT_API_BASE_URL` | Deployed backend URL (no trailing slash). For a backend on this host: `http://host.docker.internal:8000` |
| `PROJECT_SLUG` / `PROJECT_TOKEN` | The project's slug + bot token |
| `DEFAULT_AGENT` | `claude` or `codex` — which agent does this project's work |
| `BASE_BRANCH` | Branch to pull from / target PRs at; never pushed to |
| `DB_DATABASE` | This project's MySQL schema for verification (must be unique per project; created on demand) |

Plus `config/projects/<name>/repos.list` (the project's repos) and
`config/projects/<name>/env/<repo>.env` (per-repo verify overlays).

### Multiple projects

Run several projects on one machine **without cloning ralph-runner per project** —
each project is one runner container built from the same image. Add a project by
dropping a `config/projects/<name>/` directory (copy `config/projects/example/`),
then regenerate and bring the stack up:

```sh
scripts/gen-compose.sh
docker compose -f docker-compose.generated.yml up -d
docker compose -f docker-compose.generated.yml exec -it runner-<name> /scripts/setup.sh
```

`ISOLATION_MODE` (in `.env`) decides how projects share infrastructure:

- **`shared`** (default) — one MySQL `db` container (a separate schema per project)
  and shared `claude`/`codex`/`ssh` volumes. You log in to the agent and add the
  GitHub SSH key **once**; every runner reuses them. Lightest on the host.
- **`detached`** — each project gets its own `db-<name>` container and its own
  credential volumes. Full isolation; log in **once per project**.

Either way every project always gets its own runner container, its own `/workspace`,
and its own logs, and never sees another project's repos.

> The old `config/projects.list` (one container fanning out across projects) is
> **legacy** — see `config/projects.list.example`.

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

All commands use the generated file; `runner-<project>` is the per-project service.

```sh
C="docker compose -f docker-compose.generated.yml"
$C logs -f runner-<project>
$C exec runner-<project> cat /var/log/ralph/loop.log
$C down                          # stop all projects (volumes persist logins/repos)
$C build --no-cache              # rebuild after editing custom-setup.sh
$C up -d                         # apply after re-running scripts/gen-compose.sh
```

Set the cadence with `CHECK_INTERVAL_MINUTES` (or `CRON_SCHEDULE`) in `.env` —
no need to edit any script. Long passes are fine: `loop.sh` takes a single-flight
lock, so a tick that fires while the previous pass is still working just skips.
With `MAX_TASKS_PER_PASS=1` (default), each check finishes one task before the
next check can start another, so an agent is never working two tasks at once.

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
ExecStart=/usr/bin/docker compose -f docker-compose.generated.yml up -d
ExecStop=/usr/bin/docker compose -f docker-compose.generated.yml down

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

---

## Don't want to build the API?

The runner works with any backend that implements the [Task API
contract](#task-api-contract). If you'd rather not build one yourself, you can use
the hosted task API — projects, tasks, bot tokens, and the "can be done by a bot"
flag are all ready to go:

**👉 [the-second-brain.com](https://www.the-second-brain.com)**
