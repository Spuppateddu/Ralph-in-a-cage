#!/usr/bin/env bash
#
# Git helpers for the Ralph loop. Operate on cloned repo directories under
# /workspace. Push is over SSH; PRs are opened with gh (GH_TOKEN). The bot never
# pushes the base branch — only the day's branch ("bot/YYYY-MM-DD"), via a PR.

WORKSPACE="${WORKSPACE:-/workspace}"
BASE_BRANCH="${BASE_BRANCH:-master}"

daily_branch() { echo "bot/$(date +%F)"; }

# Echo every cloned repo directory (those with a .git).
list_repos() {
    local d
    for d in "$WORKSPACE"/*/; do
        [ -d "${d}.git" ] && echo "${d%/}"
    done
}

# Hard-reset a repo to the latest base branch, and drop any stray untracked files
# (e.g. build/verify artifacts left by a previous pass — a storage symlink, a
# sqlite test db, caches). `clean -fd` leaves gitignored deps (vendor/,
# node_modules/) in place, so we don't reinstall every pass.
sync_repo_dir() {
    local dir="$1"
    git -C "$dir" fetch --prune origin
    git -C "$dir" checkout "$BASE_BRANCH"
    git -C "$dir" reset --hard "origin/${BASE_BRANCH}"
    git -C "$dir" clean -fd
    echo "[repo:$(basename "$dir")] synced to origin/${BASE_BRANCH}"
}

# Check out the day's branch (created from base the first time; kept current with
# base on later runs so it accumulates the day's work).
ensure_daily_branch_dir() {
    local dir="$1" branch
    branch="$(daily_branch)"
    if git -C "$dir" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "$dir" checkout "$branch"
    elif git -C "$dir" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
        git -C "$dir" checkout -b "$branch" "origin/${branch}"
    else
        git -C "$dir" checkout -b "$branch" "origin/${BASE_BRANCH}"
    fi
    git -C "$dir" merge --no-edit "origin/${BASE_BRANCH}" >/dev/null 2>&1 || true
}

repo_has_changes() { [ -n "$(git -C "$1" status --porcelain)" ]; }

discard_changes() {
    git -C "$1" reset --hard >/dev/null 2>&1 || true
    git -C "$1" clean -fd >/dev/null 2>&1 || true
}

# Commit the working-tree changes on the daily branch (no push). Call this BEFORE
# verification, so the commit captures only the agent's edits — never the
# artifacts verification creates later (storage symlink, sqlite test db, caches).
commit_work() {
    local dir="$1" message="$2"
    git -C "$dir" add -A
    git -C "$dir" commit -m "$message"
}

# Undo the last task commit and drop any artifacts (used when verification fails).
revert_last_commit() {
    local dir="$1"
    git -C "$dir" reset --hard HEAD~1 >/dev/null 2>&1 || true
    git -C "$dir" clean -fd >/dev/null 2>&1 || true
}

# Push the daily branch over SSH and ensure a PR exists. Call AFTER a successful
# verify. Stages nothing — the commit already happened in commit_work().
push_open_pr() {
    local dir="$1" branch
    branch="$(daily_branch)"

    git -C "$dir" push -u origin "$branch"
    echo "[repo:$(basename "$dir")] pushed to $branch"

    if ! ( cd "$dir" && gh pr view "$branch" >/dev/null 2>&1 ); then
        ( cd "$dir" && gh pr create \
            --base "$BASE_BRANCH" --head "$branch" \
            --title "Ralph bot changes — $(date +%F)" \
            --body "Automated changes by the Ralph loop on $(date +%F). Review before merging." \
        ) && echo "[repo:$(basename "$dir")] opened PR $branch -> $BASE_BRANCH"
    else
        echo "[repo:$(basename "$dir")] PR for $branch already open"
    fi
}
