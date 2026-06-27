#!/usr/bin/env bash
#
# The Ralph loop. One pass = sync repos, then for each configured project pull
# the bot-doable tasks and, for each, let the chosen agent implement it, verify,
# and either open/extend a PR (success) or post feedback (failure). Run every 5
# minutes by cron under flock so passes never overlap.
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

log() { echo "[$(date '+%F %T')] $*"; }

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

# ---- Projects: "slug token [agent]" from .env or /config/projects.list ------
load_projects() {
    if [ -n "${PROJECT_SLUG:-}" ] && [ -n "${PROJECT_TOKEN:-}" ]; then
        echo "${PROJECT_SLUG} ${PROJECT_TOKEN} ${DEFAULT_AGENT}"
    elif [ -f /config/projects.list ]; then
        grep -vE '^\s*(#|$)' /config/projects.list
    fi
}

# ---- Build the agent prompt from the cloned repos --------------------------
build_prompt() {
    local title="$1" description="$2" dir tech repos_desc=""
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
        return 0
    fi

    local dir
    while read -r dir; do ensure_daily_branch_dir "$dir"; done < <(list_repos)

    local clog; clog="$(mktemp)"
    log "  running ${agent}"
    run_agent "$agent" "$(build_prompt "$title" "$description")" "$clog" "$WORKSPACE"
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
        rm -f "$clog"; return 0
    fi

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
        for dir in "${changed[@]}"; do discard_changes "$dir"; done
        bot_feedback "$slug" "$token" "$task_id" "$fail_reason" >/dev/null
        rm -f "$clog"; return 0
    fi

    for dir in "${changed[@]}"; do
        commit_push_pr "$dir" "Task #${task_id}: ${title}"
    done
    log "  task #${task_id} done (HTTP $(bot_done "$slug" "$token" "$task_id"))"
    rm -f "$clog"
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
            process_task "$slug" "$token" "$agent" "$task_id" "$title" "$description"
        done < <(echo "$body" | jq -r '.tasks[].id')
    done <<< "$projects"

    log "=== pass end ==="
}

main
