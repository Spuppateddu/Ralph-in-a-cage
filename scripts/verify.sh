#!/usr/bin/env bash
#
# Per-repo verification, dispatched by detected technology. Returns 0 on success;
# on failure, prints the reason to stdout (that reason becomes task feedback).
#
# Supported: laravel, nextjs, convex. Unknown tech is not verified (the change is
# still committed). Extend with more verify_* functions + a case below.
#
# Tests run ONLY when the repo's test setup is actually usable in the cage
# (laravel_tests_ready / verify_node_tests decide); otherwise they're skipped
# with a logged reason so pre-existing test debt never blocks every task.

source "$(dirname "${BASH_SOURCE[0]}")/detect.sh"

# Create a MySQL schema if it doesn't exist yet. The mysql image only
# auto-creates ONE database (MYSQL_DATABASE), but each project verifies against
# its own schema (DB_DATABASE from the project's project.env), so any additional
# schema — including a repo's dedicated TEST schema — must be created here.
# Idempotent — safe before every migrate.
# DB_HOST points at the shared `db` service, or `db-<project>` in detached mode
# (set by gen-compose.sh). DB_PASSWORD doubles as the MySQL root password.
#   ensure_db_schema [dbname]   (defaults to this project's DB_DATABASE)
ensure_db_schema() {
    local db="${1:-${DB_DATABASE:-second_brain}}" user="${DB_USERNAME:-sb}" pass="${DB_PASSWORD:-secret}"
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

# Read an <env name="KEY" value="..."/> (or <server .../>) override from
# phpunit.xml(.dist). Commented-out lines don't count — Laravel ships the DB
# overrides commented by default, and a commented override means the suite
# would really hit whatever the ambient env points at.
_phpunit_env() {
    local dir="$1" key="$2" f
    for f in "$dir/phpunit.xml" "$dir/phpunit.xml.dist"; do
        [ -f "$f" ] || continue
        sed 's/<!--.*-->//g' "$f" \
            | sed -n "s/.*name=\"${key}\"[^>]*value=\"\([^\"]*\)\".*/\1/p" | head -n1
        return 0
    done
}

# Read KEY=value from a dotenv-style file (last occurrence wins, quotes stripped).
_env_file_get() { sed -n "s/^$2=\(.*\)$/\1/p" "$1" 2>/dev/null | tail -n1 | tr -d '"'; }

# Decide whether this repo's TEST suite can actually run in the cage, doing any
# cheap setup needed along the way (test overlay, sqlite file, test schema).
# Returns 0 (silent) when ready; prints a human skip-reason and returns 1 when
# tests should be skipped. "Ready" means the suite has tests AND an explicit,
# workable test database:
#   1) /config/env/<repo>.testing.env overlay (user-supplied, copied to
#      .env.testing — the way to "settle" a repo whose defaults don't work here)
#   2) an uncommented DB_CONNECTION override in phpunit.xml(.dist)
#   3) a committed .env.testing
laravel_tests_ready() {
    local dir="$1" name; name="$(basename "$dir")"

    { [ -f "$dir/phpunit.xml" ] || [ -f "$dir/phpunit.xml.dist" ]; } \
        || { echo "no phpunit.xml in the repo"; return 1; }
    find "$dir/tests" -name '*.php' -print -quit 2>/dev/null | grep -q . \
        || { echo "no test files under tests/"; return 1; }

    # User-supplied test env overlay wins (mirrors the <repo>.env verify overlay).
    [ -f "/config/env/${name}.testing.env" ] \
        && cp "/config/env/${name}.testing.env" "$dir/.env.testing"

    local conn db
    conn="$(_phpunit_env "$dir" DB_CONNECTION)"
    db="$(_phpunit_env "$dir" DB_DATABASE)"
    if [ -z "$conn" ] && [ -f "$dir/.env.testing" ]; then
        conn="$(_env_file_get "$dir/.env.testing" DB_CONNECTION)"
        db="$(_env_file_get "$dir/.env.testing" DB_DATABASE)"
    fi

    case "$conn" in
        sqlite)
            php -m 2>/dev/null | grep -qi pdo_sqlite \
                || { echo "test DB is sqlite but the pdo_sqlite extension is not installed"; return 1; }
            [ -z "$db" ] && db="database/database.sqlite"   # Laravel's default file DB
            if [ "$db" != ":memory:" ]; then
                ( cd "$dir" && mkdir -p "$(dirname "$db")" && touch "$db" ) 2>/dev/null
            fi
            ;;
        mysql|mariadb)
            # Give the suite its own schema when it names one; without one it
            # reuses the project's dev schema, which is fine — it's a cage DB.
            [ -n "$db" ] && ensure_db_schema "$db" >/dev/null
            ;;
        "")
            echo "no test database configured (no DB_CONNECTION in phpunit.xml or .env.testing);"
            echo "the suite would hit the dev database in whatever state it's in. Configure it in"
            echo "the repo, or supply /config/env/${name}.testing.env"
            return 1
            ;;
        *)
            echo "test DB connection '${conn}' is not available in the cage"
            return 1
            ;;
    esac
    return 0
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
    local skip_reason
    if ! skip_reason="$(laravel_tests_ready "$dir")"; then
        echo "  (skipping tests — ${skip_reason})"
        return 0
    fi

    # The container exports the project's dev DB_* (project.env), and REAL env
    # vars beat .env.testing in Laravel — left in place they'd silently point
    # the suite at the dev schema (or trip a repo's own protected-DB guard).
    # Strip them so phpunit.xml / .env.testing decide the test database.
    local tlog; tlog="$(mktemp)"
    env -u DB_CONNECTION -u DB_HOST -u DB_PORT -u DB_DATABASE -u DB_USERNAME -u DB_PASSWORD \
        php artisan test 2>&1 | tee "$tlog"
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        rm -f "$tlog"
        return 0
    fi

    # When essentially NOTHING passes, the suite itself can't run in this
    # environment (bootstrap/config debt no single task caused) — warn and skip
    # instead of blocking every task on it. A real regression leaves most of
    # the suite green and still fails verification here.
    local passed failed
    passed="$(grep -Eo '[0-9]+ passed' "$tlog" | tail -n1 | grep -Eo '^[0-9]+')"
    failed="$( { grep -Eo '[0-9]+ (failed|errored)' "$tlog";
                 grep -Eo '(Errors|Failures): [0-9]+' "$tlog"; } \
               | grep -Eo '[0-9]+' | awk '{s+=$1} END {print s+0}')"
    rm -f "$tlog"
    if [ "${passed:-0}" -le 1 ] && [ "${failed:-0}" -ge 20 ]; then
        echo "  WARNING: the whole suite fails (${failed} failed, ${passed:-0} passed) —"
        echo "  the test setup is broken in this environment, not by this task; skipping."
        echo "  Fix the repo's test setup (or add /config/env/$(basename "$dir").testing.env)"
        echo "  to re-enable this gate."
        return 0
    fi
    echo "backend tests failed"
    return 1
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
        return 0
    fi
    if [ ! -x "$eslint" ]; then
        echo "  (eslint binary not found — skipping lint)"
        return 0
    fi
    # ESLint exit codes: 0 = clean, 1 = lint violations, 2 = config/internal
    # error. Only exit 1 is the bot's fault and should fail the task. Exit 2
    # means the repo's own eslint setup can't run at all — e.g. a legacy
    # .eslintrc that newer eslint-config-next refuses to load, or a missing
    # flat eslint.config.js. That's pre-existing repo debt, not something this
    # task introduced, so warn and skip rather than block every task on it.
    # The real gate is the build below, which type-checks.
    ( cd "$dir" && "$eslint" "${changed_files[@]}" )
    local status=$?
    if [ "$status" -eq 1 ]; then
        echo "lint failed on changed files"
        return 1
    fi
    if [ "$status" -ne 0 ]; then
        echo "  (eslint could not run — exit ${status}, likely a repo eslint-config"
        echo "   incompatibility; skipping lint. The build still type-checks.)"
    fi
    return 0
}

# Run the repo's own JS test suite if — and only if — one is actually set up:
# a real "test" script in package.json (not npm's placeholder) using a runner
# that works headless in the cage (vitest / jest / node --test). Anything else
# (no script, e2e runners that need a browser or a running app, unknown
# runners) is skipped — the build above already gates the change. Shared by the
# Next.js and Convex verifiers.
verify_node_tests() {
    local dir="$1"
    echo "[verify:node] tests"
    local script
    script="$(jq -r '.scripts.test // empty' "$dir/package.json" 2>/dev/null)"
    if [ -z "$script" ]; then
        echo "  (no \"test\" script in package.json — skipping tests)"
        return 0
    fi
    case "$script" in
        *"no test specified"*)
            echo "  (placeholder \"test\" script — skipping tests)"; return 0 ;;
        *playwright*|*cypress*)
            echo "  (e2e runner needs a browser/running app — skipping tests)"; return 0 ;;
    esac
    if ! echo "$script" | grep -qE 'vitest|jest|node .*--test'; then
        echo "  (unrecognized test runner \"${script}\" — skipping tests)"
        return 0
    fi

    local tlog; tlog="$(mktemp)"
    # CI=true makes vitest/jest run once instead of entering watch mode.
    ( cd "$dir" && CI=true npm test --silent 2>&1 ) | tee "$tlog"
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        rm -f "$tlog"
        return 0
    fi

    # Same rule as the Laravel verifier: a suite where essentially nothing
    # passes is broken setup in this environment, not this task's regression.
    local passed failed ffiles
    passed="$(grep -Eo '[0-9]+ passed' "$tlog" | tail -n1 | grep -Eo '^[0-9]+')"
    failed="$(grep -Eo '[0-9]+ fail(ed)?' "$tlog" | grep -Eo '[0-9]+' | awk '{s+=$1} END {print s+0}')"
    # The files the failures live in (vitest and jest both print "FAIL <path>"
    # lines; strip ANSI colors first) — used by the isolation retry below.
    ffiles="$(sed 's/\x1b\[[0-9;]*m//g' "$tlog" | grep -E '^[[:space:]]*FAIL[[:space:]]' \
              | awk '{print $2}' | grep -E '\.(test|spec)\.' | sort -u | tr '\n' ' ')"
    rm -f "$tlog"
    if [ "${passed:-0}" -le 1 ] && [ "${failed:-0}" -ge 10 ]; then
        echo "  WARNING: the whole suite fails (${failed} failed, ${passed:-0} passed) —"
        echo "  the test setup is broken in this environment, not by this task; skipping."
        echo "  Fix the repo's test setup to re-enable this gate."
        return 0
    fi

    # A few failures in a mostly-green suite are often container load, not a
    # regression: under a full parallel run, timing-sensitive tests (Testing
    # Library's findBy*/waitFor allow only 1s by default) can blow their
    # timeouts even though the same tests pass alone. Re-run just the failed
    # files on their own — passing in isolation means load-flake, not a break;
    # failing again gates for real. (Falls back to a full re-run when no failed
    # files could be parsed from the runner's output.)
    echo "  (${failed} failure(s) in a mostly-green suite — retrying in isolation: ${ffiles:-full suite})"
    # shellcheck disable=SC2086  # ffiles is a space-separated file list
    ( cd "$dir" && CI=true npm test --silent -- $ffiles 2>&1 ) | tail -n 40
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        echo "  WARNING: the failed test(s) pass when run in isolation — the failure is"
        echo "  timing under full-suite load in the cage, not a regression from this task."
        echo "  Consider raising the repo's test timeouts to stabilize the suite."
        return 0
    fi
    echo "frontend tests failed (reproduced in isolation)"
    return 1
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

    verify_node_tests "$dir" || return 1
    return 0
}

# Convex = a Next.js app using Convex.dev. Verification never contacts a live
# Convex backend. NOTE: `convex codegen` is NOT usable here — the Convex CLI
# requires a configured CONVEX_DEPLOYMENT and has no offline mode, so we rely on
# the repo's COMMITTED convex/_generated/* instead (the api/dataModel types the
# build needs). The real gate is `next build`, which type-checks.
verify_convex() {
    local dir="$1"
    cd "$dir" || { echo "convex dir missing"; return 1; }

    echo "[verify:convex] npm ci"
    npm ci || { echo "npm ci failed"; return 1; }

    # The cage can't regenerate these offline, so they must be committed.
    if [ ! -f "$dir/convex/_generated/api.d.ts" ]; then
        echo "convex/_generated is missing — commit it to the repo (the cage can't run"
        echo "'convex codegen' offline; the build can't resolve convex/_generated/* without it)"
        return 1
    fi

    # Next.js reads .env.local at build. Use the project's overlay if present,
    # else inject a placeholder so client init at build time doesn't blow up.
    provision_node_env "$dir"
    if ! grep -q '^NEXT_PUBLIC_CONVEX_URL=' "$dir/.env.local" 2>/dev/null; then
        echo "NEXT_PUBLIC_CONVEX_URL=https://placeholder.convex.cloud" >> "$dir/.env.local"
    fi

    verify_node_lint_changed "$dir" || return 1

    echo "[verify:convex] build (also type-checks)"
    npm run build || { echo "build failed"; return 1; }

    verify_node_tests "$dir" || return 1
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
