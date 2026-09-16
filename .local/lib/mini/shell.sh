# mini shell — a plain login shell on the Mini, no tmux.
#
# The escape hatch for when tmux itself is the thing that is broken.

mini_shell() {
    is_server && die "already on the Mini"
    require_reachable
    exec ssh -t "$MINI_HOST"
}
