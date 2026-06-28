#!/usr/bin/env bash
#
# Per-repo verification, dispatched by detected technology. Returns 0 on success;
# on failure, prints the reason to stdout (that reason becomes task feedback).
#
# Supported: laravel, nextjs, convex. Unknown tech is not verified (the change is
# still committed). Extend with more verify_* functions + a case below.

source "$(dirname "${BASH_SOURCE[0]}")/detect.sh"

# Create this project's MySQL schema if it doesn't exist yet. The mysql image
# only auto-creates ONE database (MYSQL_DATABASE), but each project verifies
# against its own schema (DB_DATABASE from the project's project.env), so any
# additional schema must be created here. Idempotent — safe before every migrate.
# DB_HOST points at the shared `db` service, or `db-<project>` in detached mode
# (set by gen-compose.sh). DB_PASSWORD doubles as the MySQL root password.
ensure_db_schema() {
    local db="${DB_DATABASE:-second_brain}" user="${DB_USERNAME:-sb}" pass="${DB_PASSWORD:-secret}"
    mysql -h "${DB_HOST:-db}" -P "${DB_PORT:-3306}" -uroot -p"${pass}" 2>/dev/null <<SQL || \
        echo "[verify] WARNING: could not ensure schema ${db} (continuing — migrate will report if it's really missing)"
CREATE DATABASE IF NOT EXISTS \`${db}\`;
CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'%';
FLUSH PRIVILEGES;
SQL
}

# Put a usable .env in place BEFORE anything boots the app. Laravel boots during
# `composer install` (package:discover), so env-dependent boot services (web-push,
# mail, ...) need config first or the install itself fails. Precedence:
#   1) /config/env/<repo>.env   (user-supplied, authoritative — app secrets)
#   2) an existing .env          (survives git reset between passes)
#   3) .env.example
# Then the cage DB settings are forced in (idempotent). See config/env README.
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

# Copy this project's per-repo overlay into a Node (Next.js/Convex) checkout as
# .env.local, which Next.js reads at build time. Optional — absence is fine.
provision_node_env() {
    local dir="$1" name; name="$(basename "$dir")"
    local tmpl="/config/env/${name}.env"
    [ -f "$tmpl" ] && cp "$tmpl" "$dir/.env.local"
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

    # Make sure this project's schema exists (projects don't share a database).
    ensure_db_schema

    echo "[verify:laravel] migrate (real DB)"
    php artisan migrate:fresh --force || { echo "migrations failed"; return 1; }

    echo "[verify:laravel] tests"
    php artisan test || { echo "backend tests failed"; return 1; }
    return 0
}

# Lint only the files THIS task changed, not the whole repo — otherwise the
# repo's pre-existing lint debt blocks every task. This still catches any lint
# error the bot itself introduces. (HEAD is the agent's commit, made by
# commit_work before verify; HEAD~1 is the pre-task state.) Shared by the Next.js
# and Convex verifiers.
verify_node_lint_changed() {
    local dir="$1"
    echo "[verify:node] lint (changed files only)"
    local eslint="$dir/node_modules/.bin/eslint"
    local changed_files
    mapfile -t changed_files < <(git -C "$dir" diff --name-only --diff-filter=ACM HEAD~1 HEAD \
        -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' 2>/dev/null)
    if [ "${#changed_files[@]}" -eq 0 ]; then
        echo "  (no JS/TS files changed — skipping lint)"
    elif [ -x "$eslint" ]; then
        "$eslint" "${changed_files[@]}" || { echo "lint failed on changed files"; return 1; }
    else
        echo "  (eslint binary not found — skipping lint)"
    fi
    return 0
}

verify_nextjs() {
    local dir="$1"
    cd "$dir" || { echo "nextjs dir missing"; return 1; }

    echo "[verify:nextjs] npm ci"
    npm ci || { echo "npm ci failed"; return 1; }

    provision_node_env "$dir"
    verify_node_lint_changed "$dir" || return 1

    echo "[verify:nextjs] build"
    npm run build || { echo "build failed"; return 1; }
    return 0
}

# Convex = a Next.js app using Convex.dev. Verification never contacts a live
# Convex backend: `convex codegen` is offline (it regenerates convex/_generated/*
# from the local convex/ functions so tsc/build can resolve the api types). Full
# `convex deploy`/`dev` need a real deployment and are intentionally skipped.
verify_convex() {
    local dir="$1"
    cd "$dir" || { echo "convex dir missing"; return 1; }

    echo "[verify:convex] npm ci"
    npm ci || { echo "npm ci failed"; return 1; }

    echo "[verify:convex] convex codegen (offline)"
    npx --no-install convex codegen || { echo "convex codegen failed"; return 1; }

    # Next.js reads .env.local at build. Use the project's overlay if present,
    # else inject a placeholder so client init at build time doesn't blow up.
    provision_node_env "$dir"
    if ! grep -q '^NEXT_PUBLIC_CONVEX_URL=' "$dir/.env.local" 2>/dev/null; then
        echo "NEXT_PUBLIC_CONVEX_URL=https://placeholder.convex.cloud" >> "$dir/.env.local"
    fi

    verify_node_lint_changed "$dir" || return 1

    echo "[verify:convex] build (also type-checks)"
    npm run build || { echo "build failed"; return 1; }
    return 0
}

# verify_repo <dir>
verify_repo() {
    local dir="$1" tech
    tech="$(detect_tech "$dir")"
    case "$tech" in
        laravel) verify_laravel "$dir" ;;
        convex)  verify_convex "$dir" ;;
        nextjs)  verify_nextjs "$dir" ;;
        *)       echo "[verify] unknown tech for $(basename "$dir") — skipping checks"; return 0 ;;
    esac
}
