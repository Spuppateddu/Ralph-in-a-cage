#!/usr/bin/env bash
#
# Per-repo verification, dispatched by detected technology. Returns 0 on success;
# on failure, prints the reason to stdout (that reason becomes task feedback).
#
# Supported: laravel, nextjs. Unknown tech is not verified (the change is still
# committed). Extend with more verify_* functions + a case below.

source "$(dirname "${BASH_SOURCE[0]}")/detect.sh"

# Put a usable .env in place BEFORE anything boots the app. Laravel boots during
# `composer install` (package:discover), so env-dependent boot services (web-push,
# mail, ...) need config first or the install itself fails. Precedence:
#   1) /config/env/<repo>.env   (user-supplied, authoritative — app secrets)
#   2) an existing .env          (survives git reset between passes)
#   3) .env.example
# Then the cage DB settings are forced in (idempotent). See config/env/README.md.
provision_laravel_env() {
    local dir="$1" name; name="$(basename "$dir")"
    local tmpl="/config/env/${name}.env"
    if [ -f "$tmpl" ]; then
        cp "$tmpl" "$dir/.env"
    elif [ ! -f "$dir/.env" ] && [ -f "$dir/.env.example" ]; then
        cp "$dir/.env.example" "$dir/.env"
    fi
    [ -f "$dir/.env" ] || : > "$dir/.env"

    # Force the cage DB settings (idempotent: replace in place if present).
    local f="$dir/.env"
    _set_env() {
        if grep -qE "^$1=" "$f"; then sed -i "s|^$1=.*|$1=$2|" "$f"; else echo "$1=$2" >> "$f"; fi
    }
    _set_env APP_ENV local
    _set_env DB_CONNECTION mysql
    _set_env DB_HOST "${DB_HOST:-db}"
    _set_env DB_PORT "${DB_PORT:-3306}"
    _set_env DB_DATABASE "${DB_DATABASE:-second_brain}"
    _set_env DB_USERNAME "${DB_USERNAME:-sb}"
    _set_env DB_PASSWORD "${DB_PASSWORD:-secret}"
}

verify_laravel() {
    local dir="$1"
    cd "$dir" || { echo "laravel dir missing"; return 1; }

    # Env first, so the app can boot during install/package discovery.
    provision_laravel_env "$dir"

    echo "[verify:laravel] composer install"
    composer install --no-interaction --prefer-dist --no-progress \
        || { echo "composer install failed"; return 1; }

    php artisan key:generate --force >/dev/null 2>&1 || true
    php artisan config:clear >/dev/null 2>&1 || true

    echo "[verify:laravel] migrate (real DB)"
    php artisan migrate:fresh --force || { echo "migrations failed"; return 1; }

    echo "[verify:laravel] tests"
    php artisan test || { echo "backend tests failed"; return 1; }
    return 0
}

verify_nextjs() {
    local dir="$1"
    cd "$dir" || { echo "nextjs dir missing"; return 1; }

    echo "[verify:nextjs] npm ci"
    npm ci || { echo "npm ci failed"; return 1; }

    # Lint only the files THIS task changed, not the whole repo — otherwise the
    # repo's pre-existing lint debt blocks every task. This still catches any
    # lint error the bot itself introduces. (HEAD is the agent's commit, made by
    # commit_work before verify; HEAD~1 is the pre-task state.)
    echo "[verify:nextjs] lint (changed files only)"
    local eslint="$dir/node_modules/.bin/eslint"
    mapfile -t changed_files < <(git -C "$dir" diff --name-only --diff-filter=ACM HEAD~1 HEAD \
        -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' 2>/dev/null)
    if [ "${#changed_files[@]}" -eq 0 ]; then
        echo "  (no JS/TS files changed — skipping lint)"
    elif [ -x "$eslint" ]; then
        "$eslint" "${changed_files[@]}" || { echo "lint failed on changed files"; return 1; }
    else
        echo "  (eslint binary not found — skipping lint)"
    fi

    echo "[verify:nextjs] build"
    npm run build || { echo "build failed"; return 1; }
    return 0
}

# verify_repo <dir>
verify_repo() {
    local dir="$1" tech
    tech="$(detect_tech "$dir")"
    case "$tech" in
        laravel) verify_laravel "$dir" ;;
        nextjs)  verify_nextjs "$dir" ;;
        *)       echo "[verify] unknown tech for $(basename "$dir") — skipping checks"; return 0 ;;
    esac
}
