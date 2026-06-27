#!/usr/bin/env bash
#
# Agent dispatch: run a task prompt through Claude Code or OpenAI Codex.
# Both run fully autonomously — safe because the whole thing is sandboxed in the
# container. The agent only edits files; it must NOT touch git (the loop does).

CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1800}"

# run_agent <agent> <prompt> <logfile> <workdir>
# Returns the agent's exit code; output goes to <logfile>.
run_agent() {
    local agent="$1" prompt="$2" logfile="$3" workdir="$4"

    case "$agent" in
        claude)
            ( cd "$workdir" && timeout "$CLAUDE_TIMEOUT" \
                claude -p "$prompt" --dangerously-skip-permissions ) \
                >"$logfile" 2>&1
            ;;
        codex)
            # `codex exec` is the non-interactive mode; the bypass flag gives it
            # full autonomy (fine inside this container).
            ( cd "$workdir" && timeout "$CLAUDE_TIMEOUT" \
                codex exec --dangerously-bypass-approvals-and-sandbox \
                    --skip-git-repo-check "$prompt" ) \
                >"$logfile" 2>&1
            ;;
        *)
            echo "unknown agent: $agent" >"$logfile"
            return 2
            ;;
    esac
}
