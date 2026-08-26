#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 <ssh-destination>"
    exit 64
fi

TARGET="$1"
STAMP="$(/bin/date +%Y%m%d%H%M%S)-$$"
SESSION="hub-smoke-$STAMP"
RENAMED="hub-smoke-renamed-$STAMP"
SSH_ARGS=(
    -nT
    -o BatchMode=yes
    -o ConnectTimeout=10
    "$TARGET"
)

cleanup() {
    /usr/bin/ssh "${SSH_ARGS[@]}" \
        "tmux kill-session -t $SESSION 2>/dev/null || tmux kill-session -t $RENAMED 2>/dev/null || true" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

/usr/bin/ssh "${SSH_ARGS[@]}" 'command -v tmux >/dev/null && tmux -V'
/usr/bin/ssh "${SSH_ARGS[@]}" "tmux new-session -d -s $SESSION"

LIST_OUTPUT="$(/usr/bin/ssh "${SSH_ARGS[@]}" \
    'tmux list-sessions -F#{session_name},#{session_id},#{session_created}')"
if [[ "$LIST_OUTPUT" != *"$SESSION,"* ]]; then
    print -u2 "error: created session was not discovered"
    exit 1
fi

/usr/bin/ssh "${SSH_ARGS[@]}" "tmux rename-session -t $SESSION $RENAMED"
LIST_OUTPUT="$(/usr/bin/ssh "${SSH_ARGS[@]}" \
    'tmux list-sessions -F#{session_name},#{session_id},#{session_created}')"
if [[ "$LIST_OUTPUT" != *"$RENAMED,"* ]]; then
    print -u2 "error: renamed session was not discovered"
    exit 1
fi

/usr/bin/ssh "${SSH_ARGS[@]}" "tmux kill-session -t $RENAMED"
trap - EXIT INT TERM
print "live SSH/tmux lifecycle passed for $TARGET"
