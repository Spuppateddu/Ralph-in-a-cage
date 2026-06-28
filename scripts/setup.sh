#!/usr/bin/env bash
#
# One-time interactive setup, run INSIDE the container:
#
#     docker compose exec -it runner /scripts/setup.sh
#
# Does the things that need you in the loop, persisting them to Docker volumes so
# you only do this once per machine:
#   1. SSH key for GitHub (generate + show the public key to add to GitHub)
#   2. Log in to a chosen coding agent (Claude Code and/or OpenAI Codex)
#   3. Clone the project repos from /config/repos.list
#   4. Install each repo's toolchain (Laravel/Next.js, auto-detected)
#
set -uo pipefail

source /scripts/detect.sh
source /scripts/verify.sh   # for provision_laravel_env
WORKSPACE="${WORKSPACE:-/workspace}"
SSH_KEY="/root/.ssh/id_ed25519"

pause() { read -rp "$1"; }
hr() { echo "------------------------------------------------------------"; }

# --- 1. SSH key -------------------------------------------------------------
hr; echo "1) GitHub SSH key"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f "$SSH_KEY" ]; then
    ssh-keygen -t ed25519 -N "" -C "ralph-runner@$(hostname)" -f "$SSH_KEY"
    echo "Generated a new SSH key."
else
    echo "SSH key already exists."
fi
# Trust github.com so git never prompts.
ssh-keygen -F github.com >/dev/null 2>&1 || ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
echo
echo ">>> Add this PUBLIC key to GitHub (Settings → SSH and GPG keys → New SSH key):"
echo
cat "${SSH_KEY}.pub"
echo
pause "Press Enter once you've added it to GitHub... "
echo "Testing GitHub SSH access..."
ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -i "successfully authenticated" \
    && echo "SSH OK." || echo "(If you didn't see 'successfully authenticated', re-check the key on GitHub.)"

# --- 2. Agent logins --------------------------------------------------------
hr; echo "2) Agent login (persisted to volumes)"
echo
echo "Which coding agent do you want to log in to?"
echo "  1) Claude Code   (Pro/Max)"
echo "  2) OpenAI Codex  (ChatGPT plan)"
echo "  3) Both"
# Default to whatever DEFAULT_AGENT is set to in .env (claude -> 1, codex -> 2).
default_choice=1
[ "${DEFAULT_AGENT:-claude}" = "codex" ] && default_choice=2
read -rp "Choose [1/2/3] (default ${default_choice}): " agent_choice
agent_choice="${agent_choice:-$default_choice}"

login_claude() {
    echo
    echo ">>> Claude Code: the TUI will open. Type '/login', complete sign-in (Pro/Max),"
    echo "    then '/exit' to return here."
    pause "Press Enter to launch Claude... "
    claude || true
}
login_codex() {
    echo
    echo ">>> OpenAI Codex: follow the prompts to sign in to your ChatGPT plan."
    pause "Press Enter to launch Codex login... "
    codex login || true
}

case "$agent_choice" in
    1) login_claude ;;
    2) login_codex ;;
    3) login_claude; login_codex ;;
    *) echo "Unrecognized choice '$agent_choice' — skipping agent login."
       echo "Re-run this script to log in later." ;;
esac

# --- 3. Clone repos ---------------------------------------------------------
hr; echo "3) Cloning repos"
if [ ! -f /config/repos.list ]; then
    echo "No /config/repos.list found. Create config/repos.list (see config/repos.list.example)"
    echo "with one SSH clone URL per line, then re-run this script."
else
    while read -r url; do
        case "$url" in ''|\#*) continue ;; esac
        name="$(basename "$url" .git)"
        dir="${WORKSPACE}/${name}"
        if [ -d "${dir}/.git" ]; then
            echo "  $name already cloned."
        else
            echo "  cloning $name ..."
            git clone "$url" "$dir" || echo "  !! clone failed for $url"
        fi
    done < /config/repos.list
fi

# --- 4. Install toolchains --------------------------------------------------
hr; echo "4) Installing project dependencies"
for dir in "$WORKSPACE"/*/; do
    [ -d "${dir}.git" ] || continue
    dir="${dir%/}"
    tech="$(detect_tech "$dir")"
    echo "  $(basename "$dir") -> ${tech}"
    case "$tech" in
        laravel)
            # Provide .env first so the app can boot during install (see verify.sh).
            provision_laravel_env "$dir"
            ( cd "$dir" && composer install --no-interaction --prefer-dist --no-progress ) || true
            ( cd "$dir" && php artisan key:generate --force >/dev/null 2>&1 ) || true ;;
        nextjs)  ( cd "$dir" && npm install ) || true ;;
        *)       echo "    (unknown tech — skipping dependency install)" ;;
    esac
done

hr
echo "Setup complete. The loop runs every 5 minutes."
echo "Watch it with:  docker compose logs -f runner"
echo "Run one pass now:  docker compose exec runner /scripts/loop.sh"
