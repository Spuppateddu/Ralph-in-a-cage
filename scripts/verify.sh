#!/usr/bin/env bash
#
# Per-repo verification, dispatched by detected technology. Returns 0 on success;
# on failure, prints the reason to stdout (that reason becomes task feedback).
#
# Supported: laravel, nextjs. Unknown tech is not verified (the change is still
# committed). Extend with more verify_* functions + a case below.

source "$(dirname "${BASH_SOURCE[0]}")/detect.sh"

verify_laravel() {
    local dir="$1"
    cd "$dir" || { echo "laravel dir missing"; return 1; }

    echo "[verify:laravel] composer install"
    composer install --no-interaction --prefer-dist --no-progress \
        || { echo "composer install failed"; return 1; }

    # Throwaway env pointed at the bundled MySQL service for a real migration.
    if [ ! -f .env ]; then cp .env.example .env 2>/dev/null || true; fi
    {
        echo "APP_ENV=local"
        echo "DB_CONNECTION=mysql"
        echo "DB_HOST=${DB_HOST:-db}"
        echo "DB_PORT=${DB_PORT:-3306}"
        echo "DB_DATABASE=${DB_DATABASE:-second_brain}"
        echo "DB_USERNAME=${DB_USERNAME:-sb}"
        echo "DB_PASSWORD=${DB_PASSWORD:-secret}"
    } >> .env
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

    echo "[verify:nextjs] lint"
    npm run lint || { echo "lint failed"; return 1; }

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
