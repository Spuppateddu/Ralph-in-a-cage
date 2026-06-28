#!/usr/bin/env bash
#
# Technology detection for a cloned repo. Supported now: laravel, nextjs, convex.
# Add more cases here (and a matching verify_* in verify.sh) to support more.
#
# Order matters: a Convex app is ALSO a Next.js app (it has "next" in
# package.json), so the convex check must come before the nextjs check.

detect_tech() {
    local dir="$1"
    if [ -f "$dir/artisan" ] && [ -f "$dir/composer.json" ]; then
        echo "laravel"
    elif [ -f "$dir/package.json" ] && grep -q '"convex"' "$dir/package.json" && [ -d "$dir/convex" ]; then
        echo "convex"
    elif [ -f "$dir/package.json" ] && grep -q '"next"' "$dir/package.json"; then
        echo "nextjs"
    else
        echo "unknown"
    fi
}
