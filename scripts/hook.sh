#!/bin/sh
# Ephedrine hook. Claude Code calls this to signal busy/idle per session.
#   hook.sh busy <lease_seconds>   -> mark busy until now+lease
#   hook.sh idle                   -> mark session finished (remove its markers)
#
# Each marker file holds an expiry epoch (now + lease). The Ephedrine menu-bar
# app treats the session as busy while any of its markers is live. A SHORT
# lease covers Claude just generating; a LONG lease covers a running tool.
# (Claude Code fires no hook on Ctrl-C, so the lease is the recovery mechanism.)
#
#   <sid>          the session (UserPromptSubmit / PostToolUse, short lease)
#   <sid>~<tool>   one running tool call (PreToolUse, long lease), removed by
#                  that call's PostToolUse
#   <sid>~agent-<id>  one running subagent (SubagentStart, long lease), removed
#                  by its SubagentStop
#
# Per-call markers matter for subagents: their tool calls carry the parent's
# session_id, so with one marker per session a subagent's PostToolUse cut the
# parent Agent call's 2-hour lease to 5 minutes, and a subagent that then
# generated for 5+ minutes looked "finished" (2026-10-05: the Mac slept mid-task).
# Stop (the main turn ended) removes the session's markers but not its agents':
# a *background* agent keeps working after the main turn ends, and on
# 2026-10-20 one still generating looked finished, so the Mac slept with the lid
# shut. SessionEnd removes them all.

dir="$HOME/.claude/ephedrine/sessions"
mkdir -p "$dir"

action="$1"
lease="${2:-300}"
input=$(cat)

# Top-level JSON fields via plutil (a sed match could hit the same key inside
# tool_input / tool_response). Empty if absent.
field() { printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
clean() { tr -cd 'A-Za-z0-9._-'; }

sid=$(field session_id | clean)
[ -z "$sid" ] && sid="default"
event=$(field hook_event_name)
tid=$(field tool_use_id | clean)
aid=$(field agent_id | clean)

case "$action" in
    busy)
        expiry=$(( $(date +%s) + lease ))
        if [ "$event" = "PreToolUse" ] && [ -n "$tid" ]; then
            echo "$expiry" > "$dir/$sid~$tid"
        elif [ "$event" = "SubagentStart" ] && [ -n "$aid" ]; then
            echo "$expiry" > "$dir/$sid~agent-$aid"
        else
            [ "$event" = "PostToolUse" ] && [ -n "$tid" ] && rm -f "$dir/$sid~$tid"
            [ "$event" = "SubagentStop" ] && [ -n "$aid" ] && rm -f "$dir/$sid~agent-$aid"
            echo "$expiry" > "$dir/$sid"
        fi
        ;;
    idle)
        rm -f "$dir/$sid"
        for f in "$dir/$sid~"*; do
            [ "$event" = "Stop" ] && case "$f" in *"~agent-"*) continue ;; esac
            rm -f "$f"
        done
        ;;
esac

exit 0
