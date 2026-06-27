#!/usr/bin/env bash
#
# Technology detection for a cloned repo. Supported now: laravel, nextjs.
# Add more cases here (and a matching verify_* in verify.sh) to support more.

detect_tech() {
    local dir="$1"
    if [ -f "$dir/artisan" ] && [ -f "$dir/composer.json" ]; then
        echo "laravel"
    elif [ -f "$dir/package.json" ] && grep -q '"next"' "$dir/package.json"; then
        echo "nextjs"
    else
        echo "unknown"
    fi
}
