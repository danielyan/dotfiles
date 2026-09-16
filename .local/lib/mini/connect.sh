# mini connect — attach to (or create) a persistent tmux session on the Mini.
#
# This is the core of the remote-first model: work lives in a long-running tmux
# session on the Mini, so attaching from anywhere drops you exactly where you
# left off, including a Claude Code conversation mid-task.

mini_connect() {
    local session="${1:-$MINI_SESSION}"

    if is_server; then
        # Already on the Mini: attaching over ssh to ourselves would be absurd.
        exec tmux new -A -s "$session"
    fi

    require_reachable

    # `new -A` attaches if the session exists and creates it otherwise, so one
    # command covers both "start my day" and "reattach".
    if have mosh; then
        # mosh survives lid-close, IP changes and long suspends; ssh does not.
        exec mosh "$MINI_HOST" -- tmux new -A -s "$session"
    else
        exec ssh -t "$MINI_HOST" tmux new -A -s "$session"
    fi
}
