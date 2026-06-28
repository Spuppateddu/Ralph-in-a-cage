#!/usr/bin/env bash
#
# The Ralph loop. One pass = sync repos, then for each configured project pull
# the bot-doable tasks and, for each, let the chosen agent implement it, verify,
# and either open/extend a PR (success) or post feedback (failure). Run on the
# configured interval by cron under flock so passes never overlap.
#
set -uo pipefail

cd "$(dirname "$0")"
[ -f ./runtime.env ] && source ./runtime.env

export WORKSPACE="${WORKSPACE:-/workspace}"
source ./repo.sh
source ./detect.sh
source ./verify.sh
source ./agent.sh

API="${PROJECT_API_BASE_URL:-}"
DEFAULT_AGENT="${DEFAULT_AGENT:-claude}"
# How many tasks to work in a single pass. 1 (default) = do one task to
# completion per trigger; 0 = drain all claimable tasks. Combined with the lock
# below, this guarantees a new task never starts while one is still in progress.
MAX_TASKS_PER_PASS="${MAX_TASKS_PER_PASS:-1}"

# Tag every line with the project name when known (RALPH_PROJECT is set per
# container by gen-compose.sh), so interleaved multi-project logs stay readable.
log() { echo "[$(date '+%F %T')]${RALPH_PROJECT:+ [${RALPH_PROJECT}]} $*"; }

# Single-flight: never run two passes at once — a cron tick, a manual
# `docker compose exec ... loop.sh`, and the startup pass all share this lock. If
# one is already running (agent still working a task), the new one just exits.
exec 9>/tmp/ralph.lock
if ! flock -n 9; then
    log "another pass is already running (a task is still in progress); skipping"
    exit 0
fi

# ---- Bot API helpers (body + trailing HTTP status) -------------------------
bot_get_tasks() {
    curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $2" \
        "${API}/api/v1/bot/$1/tasks"
}
bot_claim() {
    curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $2" \
        "${API}/api/v1/bot/$1/tasks/$3/claim"
}
bot_done() {
    curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $2" \
        "${API}/api/v1/bot/$1/tasks/$3/done"
}
bot_feedback() {
    curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
        --data "$(jq -nc --arg f "$4" '{feedback:$f}')" \
        "${API}/api/v1/bot/$1/tasks/$3/feedback"
}

# ---- Project: "slug token [agent]" -----------------------------------------
# Each runner container drives exactly ONE project: its slug/token/agent come
# from the project's config/projects/<name>/project.env (loaded into the env via
# docker-compose env_file). The /config/projects.list fallback is LEGACY — the
# old single-container, multi-project mode; multi-project is now N containers
# (see scripts/gen-compose.sh).
load_projects() {
    if [ -n "${PROJECT_SLUG:-}" ] && [ -n "${PROJECT_TOKEN:-}" ]; then
        echo "${PROJECT_SLUG} ${PROJECT_TOKEN} ${DEFAULT_AGENT}"
    elif [ -f /config/projects.list ]; then
        grep -vE '^\s*(#|$)' /config/projects.list   # legacy multi-project fallback
    fi
}

# ---- Build the agent prompt from the cloned repos --------------------------
build_prompt() {
    local title="$1" description="$2" summary_file="$3" dir tech repos_desc=""
    while read -r dir; do
        [ -z "$dir" ] && continue
        tech="$(detect_tech "$dir")"
        repos_desc+="- ./$(basename "$dir")  (${tech})"$'\n'
    done < <(list_repos)

    cat <<EOF
You are an autonomous senior engineer working on a single project whose
repositories are checked out in the current directory:
${repos_desc}
Implement the task below by editing files. Follow each repo's existing
conventions, keep the change minimal and correct, and update or add tests where
appropriate. Do NOT run git, do NOT commit, do NOT push — only edit files; the
harness commits and opens a PR.

When you are finished, write a concise summary of the changes you made to this
exact file path:
  ${summary_file}
Use 2-6 short bullet points describing WHAT you changed and WHY — name the key
files and the purpose of each change (e.g. "- app/Models/User.php: add email
verification scope"). This text becomes the commit message body, so be clear
and specific; do not just restate the task title. Write ONLY that one file
outside the repositories — do not create any other files in the repos.

TASK: ${title}

DETAILS:
${description}
EOF
}

# ---- Work one task end to end ----------------------------------------------
process_task() {
    local slug="$1" token="$2" agent="$3" task_id="$4" title="$5" description="$6"

    log "claiming task #${task_id} (${title}) [agent: ${agent}]"
    if [ "$(bot_claim "$slug" "$token" "$task_id")" != "200" ]; then
        log "  could not claim — already taken; skipping"
        return 20   # signal: nothing was worked, try the next task
    fi

    local dir
    while read -r dir; do ensure_daily_branch_dir "$dir"; done < <(list_repos)

    local clog summary_file; clog="$(mktemp)"; summary_file="$(mktemp)"
    log "  running ${agent}"
    run_agent "$agent" "$(build_prompt "$title" "$description" "$summary_file")" "$clog" "$WORKSPACE"
    local arc=$?

    local changed=()
    while read -r dir; do
        [ -z "$dir" ] && continue
        repo_has_changes "$dir" && changed+=("$dir")
    done < <(list_repos)

    if [ "${#changed[@]}" -eq 0 ]; then
        local reason="Agent produced no file changes."
        [ "$arc" -ne 0 ] && reason="Agent run failed (exit $arc) with no changes."$'\n\n'"$(tail -n 40 "$clog")"
        log "  no changes -> feedback"
        bot_feedback "$slug" "$token" "$task_id" "$reason" >/dev/null
        rm -f "$clog" "$summary_file"; return 0
    fi

    # The agent writes a human summary of its edits to summary_file (see
    # build_prompt). Use it as the commit body; commit_work appends a diffstat.
    local summary=""
    [ -s "$summary_file" ] && summary="$(cat "$summary_file")"

    # Commit the agent's edits up front, BEFORE verifying. Verification installs
    # deps and boots the app, which creates artifacts (storage symlink, sqlite
    # test db, caches); committing first guarantees the PR contains only the
    # agent's actual changes, never those artifacts.
    for dir in "${changed[@]}"; do
        commit_work "$dir" "Task #${task_id}: ${title}" "$summary"
    done

    local fail_reason="" vlog
    for dir in "${changed[@]}"; do
        log "  verifying $(basename "$dir")"
        vlog="$(mktemp)"
        if ! verify_repo "$dir" >"$vlog" 2>&1; then
            fail_reason="Verification failed in $(basename "$dir"):"$'\n\n'"$(tail -n 50 "$vlog")"
            rm -f "$vlog"; break
        fi
        rm -f "$vlog"
    done

    if [ -n "$fail_reason" ]; then
        log "  verification failed -> discard + feedback"
        for dir in "${changed[@]}"; do revert_last_commit "$dir"; done
        bot_feedback "$slug" "$token" "$task_id" "$fail_reason" >/dev/null
        rm -f "$clog" "$summary_file"; return 0
    fi

    for dir in "${changed[@]}"; do
        push_open_pr "$dir"
    done
    log "  task #${task_id} done (HTTP $(bot_done "$slug" "$token" "$task_id"))"
    rm -f "$clog" "$summary_file"
}

# ---- Main pass -------------------------------------------------------------
main() {
    [ -z "$API" ] && { log "PROJECT_API_BASE_URL not set; nothing to do"; exit 0; }

    if [ -z "$(list_repos)" ]; then
        log "no repos cloned yet — run: docker compose exec runner /scripts/setup.sh"
        exit 0
    fi

    log "=== pass start ==="
    local dir
    while read -r dir; do sync_repo_dir "$dir"; done < <(list_repos)

    local projects; projects="$(load_projects)"
    [ -z "$projects" ] && { log "no projects configured; nothing to do"; exit 0; }

    local processed=0

    while read -r slug token agent; do
        [ -z "$slug" ] && continue
        agent="${agent:-$DEFAULT_AGENT}"
        log "project ${slug}: fetching tasks"

        local resp body http count
        resp="$(bot_get_tasks "$slug" "$token")"
        http="$(echo "$resp" | tail -n1)"
        body="$(echo "$resp" | sed '$d')"

        if [ "$http" = "409" ]; then log "  project not in progress; skipping"; continue; fi
        if [ "$http" != "200" ]; then
            log "  unexpected response (HTTP $http): $(echo "$body" | head -c 200)"; continue
        fi

        count="$(echo "$body" | jq '.tasks | length')"
        log "  ${count} claimable task(s)"
        [ "$count" = "0" ] && continue

        local task_id title description
        while read -r task_id; do
            [ -z "$task_id" ] && continue
            title="$(echo "$body" | jq -r ".tasks[] | select(.id==${task_id}) | .title")"
            description="$(echo "$body" | jq -r ".tasks[] | select(.id==${task_id}) | (.description // \"\")")"
            # process_task returns 20 when it couldn't claim (skip, try next);
            # any other return means it actually worked a task.
            if process_task "$slug" "$token" "$agent" "$task_id" "$title" "$description"; then
                processed=$((processed + 1))
                if [ "$MAX_TASKS_PER_PASS" -gt 0 ] && [ "$processed" -ge "$MAX_TASKS_PER_PASS" ]; then
                    log "reached MAX_TASKS_PER_PASS=${MAX_TASKS_PER_PASS}; ending pass"
                    break 2
                fi
            fi
        done < <(echo "$body" | jq -r '.tasks[].id')
    done <<< "$projects"

    log "=== pass end ==="
}

main
